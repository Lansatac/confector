module controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;
import confector.core.trigger;
import confector.core.executor : CapacityBroker;
import confector.runner_core.engine;
import confector.orchestrator.coordinator;
import confector.plugin_api.dispatch_queue;

import std.format : format;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;

URLRouter apiRouter(TaskEngine engine, DispatchQueue queue = null, BuildCoordinator coordinator = null, StateStores stores = null, CapacityBroker capacityBroker = null)
{
    import std.algorithm.searching : startsWith;
    auto router = new URLRouter();

    void postRoute(H)(string path, H handler)
    {
        router.post(path, handler);
        if (!path.startsWith("/api/v1"))
        {
            router.post("/api/v1" ~ (path.startsWith("/") ? path : "/" ~ path), handler);
        }
    }

    void getRoute(H)(string path, H handler)
    {
        router.get(path, handler);
        if (!path.startsWith("/api/v1"))
        {
            router.get("/api/v1" ~ (path.startsWith("/") ? path : "/" ~ path), handler);
        }
    }

    void anyRoute(H)(string path, H handler)
    {
        router.any(path, handler);
        if (!path.startsWith("/api/v1"))
        {
            router.any("/api/v1" ~ (path.startsWith("/") ? path : "/" ~ path), handler);
        }
    }

    void deleteRoute(H)(string path, H handler)
    {
        router.delete_(path, handler);
        if (!path.startsWith("/api/v1"))
        {
            router.delete_("/api/v1" ~ (path.startsWith("/") ? path : "/" ~ path), handler);
        }
    }

    // Dispatch queue endpoints, for workers that receive work through the control plane. The
    // dispatch queue is internal delivery only; it is never listed or counted for display.
    if (queue !is null)
    {
        void writeQueueError(HTTPServerResponse res, Exception e)
        {
            // A lost lease is a conflict the worker must react to (stop or skip the work); a usage
            // error is a malformed request; anything else is a server-side failure.
            if (cast(LeaseLostException) e)
                res.statusCode = HTTPStatus.conflict;
            else if (cast(DispatchQueueUsageException) e)
                res.statusCode = HTTPStatus.badRequest;
            else
                res.statusCode = HTTPStatus.internalServerError;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }

        postRoute("/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;

                auto pMax = "max_messages" in req.json;
                auto pVis = "visibility_timeout" in req.json;
                size_t maxMsgs = pMax !is null ? pMax.get!size_t : 1;
                long visibility = pVis !is null ? pVis.get!long : 30;
                auto received = queue.receive(defaultPoolQueue, maxMsgs, visibility.seconds);
                Json leases = Json.emptyArray;
                try
                {
                    foreach (lease; received)
                    {
                        WorkOrder order = deserializeJson!WorkOrder(lease.message);
                        // Mark the task running, so capacity demand stops counting it.
                        TaskStatus status;
                        if (stores !is null && stores.legacyBuilds.getTaskStatus(order.buildId, order.taskId, status) && status == TaskStatus.queued)
                        {
                            stores.legacyBuilds.setTaskStatus(order.buildId, order.taskId, TaskStatus.running);
                        }
                        Json item = Json.emptyObject;
                        item["receipt"] = Json(lease.receipt);
                        item["receive_count"] = Json(lease.receiveCount);
                        item["work_order"] = lease.message;
                        leases ~= item;
                    }
                }
                catch (Exception e)
                {
                    // The worker will never see these leases; give them back rather than leave the
                    // work invisible until the leases expire. Best effort: the original error is
                    // what the caller needs.
                    foreach (lease; received)
                    {
                        try
                            queue.release(defaultPoolQueue, lease.receipt);
                        catch (Exception releaseError)
                            logError("[api] Failed to release receipt '%s' after a failed receive: %s", lease.receipt, releaseError.msg);
                    }
                    throw e;
                }
                res.writeJsonBody(leases);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                queue.ack(defaultPoolQueue, req.json["receipt"].get!string);
                Json resp = Json.emptyObject;
                resp["status"] = Json("acknowledged");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/extend", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;

                auto pVis = "visibility_timeout" in req.json;
                long visibility = pVis !is null ? pVis.get!long : 30;
                queue.extend(defaultPoolQueue, req.json["receipt"].get!string, visibility.seconds);
                Json resp = Json.emptyObject;
                resp["status"] = Json("extended");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/release", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;

                auto pDelay = "delay" in req.json;
                long delay = pDelay !is null ? pDelay.get!long : 0;
                queue.release(defaultPoolQueue, req.json["receipt"].get!string, delay.seconds);
                Json resp = Json.emptyObject;
                resp["status"] = Json("released");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });
    }

    // Task Execution Query and Log Endpoints
    getRoute("/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string statusFilter = req.query.get("status", "");
            string projectFilter = req.query.get("project_id", "");
            string limitStr = req.query.get("limit", "50");
            size_t limit = 50;
            try { import std.conv : to; limit = limitStr.to!size_t; } catch (Exception) {}

            auto tasks = stores !is null ? stores.legacyBuilds.listRecentTaskExecutions(limit, statusFilter, projectFilter) : [];
            res.writeJsonBody(tasks);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/builds/:build_id/tasks/:task_id", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.params["build_id"];
            string taskId = req.params["task_id"];

            TaskExecutionRecord record;
            if (stores !is null && stores.legacyBuilds.getTaskExecution(buildId, taskId, record))
            {
                res.writeJsonBody(record);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json(format("Task execution not found for build '%s', task '%s'", buildId, taskId));
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/builds/:build_id/tasks/:task_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.params["build_id"];
            string taskId = req.params["task_id"];

            string[] logs = stores !is null ? stores.logs.getTaskLogs(buildId, taskId) : [];
            Json resp = Json.emptyObject;
            resp["build_id"] = Json(buildId);
            resp["task_id"] = Json(taskId);
            resp["logs"] = serializeToJson(logs);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Remote Worker Task Completion Callback endpoints
    postRoute("/tasks/:fingerprint/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string fingerprint = req.params["fingerprint"];
            TaskExecutionResult result = deserializeJson!TaskExecutionResult(req.json);
            if (result.fingerprint.length == 0)
            {
                result.fingerprint = fingerprint;
            }
            if (result.receiptHandle.length == 0 && "receipt_handle" in req.query)
            {
                result.receiptHandle = req.query["receipt_handle"];
            }

            if (coordinator !is null)
            {
                coordinator.onTaskCompleted(fingerprint, result);
            }
            else if (stores !is null)
            {
                if (result.buildId.length > 0 && result.taskId.length > 0)
                {
                    stores.legacyBuilds.setTaskStatus(result.buildId, result.taskId, result.status, result.errorMessage);
                }
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("recorded");
            resp["fingerprint"] = Json(fingerprint);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/builds/:build_id/tasks/:task_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.params["build_id"];
            string taskId = req.params["task_id"];
            TaskExecutionResult result = deserializeJson!TaskExecutionResult(req.json);
            result.buildId = buildId;
            result.taskId = taskId;
            if (result.receiptHandle.length == 0 && "receipt_handle" in req.query)
            {
                result.receiptHandle = req.query["receipt_handle"];
            }

            if (coordinator !is null)
            {
                coordinator.onTaskCompleted(buildId, taskId, result);
            }
            else if (stores !is null)
            {
                stores.legacyBuilds.setTaskStatus(buildId, taskId, result.status, result.errorMessage);
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("recorded");
            resp["build_id"] = Json(buildId);
            resp["task_id"] = Json(taskId);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/builds/:build_id/tasks/:task_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.params["build_id"];
            string taskId = req.params["task_id"];
            Json bodyJson = req.json;
            string[] lines;
            if ("lines" in bodyJson && bodyJson["lines"].type == Json.Type.array)
            {
                lines = deserializeJson!(string[])(bodyJson["lines"]);
            }
            else if ("logs" in bodyJson && bodyJson["logs"].type == Json.Type.array)
            {
                lines = deserializeJson!(string[])(bodyJson["logs"]);
            }
            else if ("line" in bodyJson && bodyJson["line"].type == Json.Type.string)
            {
                lines = [bodyJson["line"].get!string];
            }

            if (stores !is null)
            {
                foreach (line; lines)
                {
                    stores.logs.appendBuildLog(buildId, format("[%s] %s", taskId, line));
                    stores.logs.appendTaskLog(buildId, taskId, line);
                }
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("ok");
            resp["build_id"] = Json(buildId);
            resp["task_id"] = Json(taskId);
            resp["appended"] = Json(lines.length);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Run Project via the queue-backed coordinator (JSON body)
    postRoute("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projectId = req.json["project_id"].get!string;
            auto pTarget = "target_task_id" in req.json;
            auto pForce = "force" in req.json;
            auto pWorkspace = "workspace_dir" in req.json;
            string targetTaskId = pTarget !is null ? pTarget.get!string : "";
            bool force = pForce !is null ? pForce.get!bool : false;
            string workspaceDir = pWorkspace !is null ? pWorkspace.get!string : "";

            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projectId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projectId);
                res.writeJsonBody(err);
                return;
            }

            if (coordinator is null)
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("Build coordinator is required for task execution");
                res.writeJsonBody(err);
                return;
            }

            string buildId = coordinator.startBuild(proj, targetTaskId.length > 0 ? targetTaskId : null, force, "api", workspaceDir);
            Json resp = Json.emptyObject;
            resp["build_id"] = Json(buildId);
            resp["status"] = Json("queued");
            resp["project_id"] = Json(projectId);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Run Project by ID (path parameter) — used by scheduler for cron triggers
    postRoute("/projects/:id/run", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projectId = req.params["id"];
            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projectId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projectId);
                res.writeJsonBody(err);
                return;
            }

            if (coordinator is null)
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("Build coordinator is required for task execution");
                res.writeJsonBody(err);
                return;
            }

            string buildId = coordinator.startBuild(proj, null, false, "cron", "");
            Json resp = Json.emptyObject;
            resp["build_id"] = Json(buildId);
            resp["status"] = Json("queued");
            resp["project_id"] = Json(projectId);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Task Graph Trigger & Execution endpoint
    postRoute("/tasks/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            Json bodyJson = req.json;
            TaskNode[] tasks = deserializeJson!(TaskNode[])(bodyJson["tasks"]);
            TriggerEvent event = deserializeJson!TriggerEvent(bodyJson["event"]);
            string workspaceDir = bodyJson["workspace_dir"].get!string;
            string buildId = "build_id" in bodyJson ? bodyJson["build_id"].get!string : "build_" ~ Clock.currTime.toISOString();
            string projectId = "project_id" in bodyJson ? bodyJson["project_id"].get!string : "";
            string projectName = "project_name" in bodyJson ? bodyJson["project_name"].get!string : "default";

            // Resolve triggering
            string[] matchingTasks = TriggerMatcher.findMatchingTasks(tasks, event);
            if (matchingTasks.length == 0)
            {
                Json noop = Json.emptyObject;
                noop["build_id"] = Json(buildId);
                noop["message"] = Json("No tasks matched trigger event criteria");
                noop["executed"] = Json.emptyArray;
                res.writeJsonBody(noop);
                return;
            }

            // Resolve subgraph and topological sort
            auto fullGraph = new TaskGraph(tasks);
            string[] targetSubgraphs;
            foreach (taskId; matchingTasks)
            {
                auto sub = fullGraph.resolveSubgraph(taskId);
                foreach (s; sub)
                {
                    bool already = false;
                    foreach (t; targetSubgraphs) if (t == s) { already = true; break; }
                    if (!already) targetSubgraphs ~= s;
                }
            }

            // Create sub-tasks list
            TaskNode[] subTasks;
            foreach (task; tasks)
            {
                foreach (targetId; targetSubgraphs)
                {
                    if (task.id == targetId)
                    {
                        subTasks ~= task;
                        break;
                    }
                }
            }

            if (coordinator is null)
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("Build coordinator is required for task execution");
                res.writeJsonBody(err);
                return;
            }

            ProjectRecord triggerProject;
            triggerProject.id = projectId;
            triggerProject.name = projectName;
            triggerProject.tasks = subTasks;
            string queuedBuildId = coordinator.startBuild(
                triggerProject,
                null,
                event.force,
                "trigger",
                workspaceDir);

            Json result = Json.emptyObject;
            result["build_id"] = Json(queuedBuildId);
            result["status"] = Json("queued");
            result["task_ids"] = serializeToJson(targetSubgraphs);
            res.writeJsonBody(result);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Builds API
    getRoute("/builds", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            if (stores is null)
            {
                res.writeJsonBody(Json.emptyArray);
                return;
            }
            auto builds = stores.legacyBuilds.listBuilds(50);
            res.writeJsonBody(builds);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/builds/details", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.query.get("id", "");
            if (stores is null)
            {
                res.statusCode = HTTPStatus.notFound;
                res.writeJsonBody(["error": "No state stores configured"]);
                return;
            }

            BuildRecord buildRec;
            if (stores.legacyBuilds.getBuild(buildId, buildRec))
            {
                auto taskRecs = stores.legacyBuilds.getTaskExecutionsForBuild(buildId);
                foreach (rec; taskRecs)
                {
                    buildRec.taskRecords[rec.taskId] = rec;
                }
                res.writeJsonBody(buildRec);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Build not found: " ~ buildId);
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/builds/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.query.get("id", "");
            string[] logs = stores !is null ? stores.logs.getBuildLogs(buildId) : [];
            Json resp = Json.emptyObject;
            resp["build_id"] = Json(buildId);
            resp["logs"] = serializeToJson(logs);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Trigger Rules API
    getRoute("/triggers", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto rules = stores !is null ? stores.triggerRules.list() : [];
            res.writeJsonBody(rules);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/triggers/create", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            TriggerRuleRecord rule = deserializeJson!TriggerRuleRecord(req.json);
            if (rule.id.length == 0)
            {
                rule.id = "trig_" ~ randomUUID().toString();
            }
            if (rule.createdAt.length == 0)
            {
                rule.createdAt = Clock.currTime.toISOString();
            }

            if (stores !is null)
            {
                stores.triggerRules.save(rule);
            }
            res.writeJsonBody(rule);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/triggers/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string ruleId = req.json["id"].get!string;
            bool ok = stores !is null && stores.triggerRules.remove(ruleId);
            Json resp = Json.emptyObject;
            resp["deleted"] = Json(ok);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Projects REST API
    getRoute("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto projects = stores !is null ? stores.projects.list() : [];
            res.writeJsonBody(projects);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            ProjectRecord proj = deserializeJson!ProjectRecord(req.json);
            if (proj.id.length == 0)
            {
                proj.id = "proj_" ~ randomUUID().toString()[0 .. 8];
            }
            string now = Clock.currTime.toISOString();
            if (proj.createdAt.length == 0)
            {
                proj.createdAt = now;
            }
            proj.updatedAt = now;

            if (stores !is null)
            {
                stores.projects.put(proj);
            }
            res.writeJsonBody(proj);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            ProjectRecord proj;
            if (stores !is null && stores.projects.get(projId).tryValue(proj))
            {
                res.writeJsonBody(proj);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    deleteRoute("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            bool ok = stores !is null && stores.projects.remove(projId);
            if (ok)
            {
                Json resp = Json.emptyObject;
                resp["deleted"] = Json(true);
                res.writeJsonBody(resp);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Project Tasks API
    getRoute("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            ProjectRecord proj;
            if (stores !is null && stores.projects.get(projId).tryValue(proj))
            {
                res.writeJsonBody(proj.tasks);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
                return;
            }

            TaskNode task = deserializeJson!TaskNode(req.json);
            if (task.id.length == 0)
            {
                task.id = "task_" ~ randomUUID().toString()[0 .. 8];
            }

            // Replace or append
            bool updated = false;
            foreach (ref existing; proj.tasks)
            {
                if (existing.id == task.id)
                {
                    existing = task;
                    updated = true;
                    break;
                }
            }
            if (!updated)
            {
                proj.tasks ~= task;
            }

            // Validate DAG
            auto graph = new TaskGraph(proj.tasks);

            proj.updatedAt = Clock.currTime.toISOString();
            stores.projects.put(proj);

            res.writeJsonBody(task);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    getRoute("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string taskId = req.params["taskId"];
            ProjectRecord proj;
            if (stores !is null && stores.projects.get(projId).tryValue(proj))
            {
                foreach (task; proj.tasks)
                {
                    if (task.id == taskId)
                    {
                        res.writeJsonBody(task);
                        return;
                    }
                }
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Task not found in project: " ~ taskId);
                res.writeJsonBody(err);
            }
            else
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
            }
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    deleteRoute("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string taskId = req.params["taskId"];
            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
                return;
            }

            TaskNode[] remainingTasks;
            bool found = false;
            foreach (task; proj.tasks)
            {
                if (task.id == taskId)
                {
                    found = true;
                }
                else
                {
                    remainingTasks ~= task;
                }
            }

            if (!found)
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Task not found in project: " ~ taskId);
                res.writeJsonBody(err);
                return;
            }

            proj.tasks = remainingTasks;
            proj.updatedAt = Clock.currTime.toISOString();
            stores.projects.put(proj);

            Json resp = Json.emptyObject;
            resp["deleted"] = Json(true);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Project Task Graph Execution endpoint
    postRoute("/projects/:id/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
                return;
            }

            Json bodyJson = req.json.type == Json.Type.object ? req.json : Json.emptyObject;
            string targetTaskId = "";
            bool force = false;
            string workspaceDir = ".";

            if ("target_task_id" in bodyJson && bodyJson["target_task_id"].type == Json.Type.string)
            {
                targetTaskId = bodyJson["target_task_id"].get!string;
            }
            if ("force" in bodyJson && bodyJson["force"].type == Json.Type.bool_)
            {
                force = bodyJson["force"].get!bool;
            }
            if ("workspace_dir" in bodyJson && bodyJson["workspace_dir"].type == Json.Type.string)
            {
                workspaceDir = bodyJson["workspace_dir"].get!string;
            }

            if (coordinator is null)
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("Build coordinator is required for task execution");
                res.writeJsonBody(err);
                return;
            }

            string buildId = coordinator.startBuild(
                proj,
                targetTaskId.length > 0 ? targetTaskId : null,
                force,
                "api",
                workspaceDir);
            Json response = Json.emptyObject;
            response["build_id"] = Json(buildId);
            response["status"] = Json("queued");
            response["project_id"] = Json(proj.id);
            res.writeJsonBody(response);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    postRoute("/projects/:id/tasks/:taskId/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string targetTaskId = req.params["taskId"];
            ProjectRecord proj;
            if (stores is null || !stores.projects.get(projId).tryValue(proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projId);
                res.writeJsonBody(err);
                return;
            }

            Json bodyJson = req.json.type == Json.Type.object ? req.json : Json.emptyObject;
            bool force = false;
            string workspaceDir = ".";

            if ("force" in bodyJson && bodyJson["force"].type == Json.Type.bool_)
            {
                force = bodyJson["force"].get!bool;
            }
            if ("workspace_dir" in bodyJson && bodyJson["workspace_dir"].type == Json.Type.string)
            {
                workspaceDir = bodyJson["workspace_dir"].get!string;
            }

            if (coordinator is null)
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("Build coordinator is required for task execution");
                res.writeJsonBody(err);
                return;
            }

            string buildId = coordinator.startBuild(proj, targetTaskId, force, "api", workspaceDir);
            Json response = Json.emptyObject;
            response["build_id"] = Json(buildId);
            response["status"] = Json("queued");
            response["project_id"] = Json(proj.id);
            response["task_id"] = Json(targetTaskId);
            res.writeJsonBody(response);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Generic VCS-agnostic webhook ingestion endpoint
    postRoute("/webhooks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            import confector.core.plugin : PluginRegistry;
            import confector.plugin_api.vcs : VcsStateResolver;
            import confector.plugin_api.model : VcsRepositoryState, VcsChangeRecord;
            import std.json : parseJSON, JSONValue;

            // Collect HTTP headers
            string[string] headers;
            foreach (name, values; req.headers.byKeyValue())
            {
                string joined;
                foreach (v; values)
                {
                    if (joined.length > 0) joined ~= ", ";
                    joined ~= v;
                }
                headers[name] = joined;
            }

            auto payload = parseJSON(req.json.toString());

            // Find a VCS resolver that can handle this webhook
            VcsStateResolver matchedResolver = null;
            foreach (resolver; PluginRegistry.instance.getVcsResolvers())
            {
                if (resolver.canHandleWebhook(headers, payload))
                {
                    matchedResolver = resolver;
                    break;
                }
            }

            if (matchedResolver is null)
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json("No registered VCS plugin could handle this webhook payload");
                res.writeJsonBody(err);
                return;
            }

            // Parse the webhook payload
            VcsRepositoryState resolvedState;
            if (!matchedResolver.parseWebhookPayload(headers, payload, resolvedState))
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json("VCS plugin failed to parse webhook payload");
                res.writeJsonBody(err);
                return;
            }

            // Check for revision change and persist state
            VcsRepositoryState previousState;
            bool changed = false;
            string fromRevision = "";

            if (stores && stores.vcsStates.getState(resolvedState.repositoryUrl, resolvedState.targetRef, previousState))
            {
                fromRevision = previousState.revision;
                if (previousState.revision != resolvedState.revision)
                {
                    changed = true;
                }
            }
            else
            {
                changed = true;
            }

            // Save the new state
            if (stores)
            {
                resolvedState.updatedAt = Clock.currTime.toISOString();
                stores.vcsStates.saveState(resolvedState);

                if (changed)
                {
                    VcsChangeRecord change;
                    change.id = "change_" ~ randomUUID().toString();
                    change.repositoryUrl = resolvedState.repositoryUrl;
                    change.providerType = resolvedState.providerType;
                    change.targetRef = resolvedState.targetRef;
                    change.fromRevision = fromRevision;
                    change.toRevision = resolvedState.revision;
                    change.detectedAt = Clock.currTime.toISOString();
                    change.triggerSource = "webhook";
                    stores.vcsStates.recordChange(change);
                }
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("processed");
            resp["provider"] = Json(matchedResolver.providerType());
            resp["repository"] = Json(resolvedState.repositoryUrl);
            resp["revision"] = Json(resolvedState.revision);
            resp["changed"] = Json(changed);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Generic VCS-agnostic webhook ingestion with trigger ID routing
    postRoute("/webhooks/:triggerId", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            import confector.core.plugin : PluginRegistry;
            import confector.plugin_api.vcs : VcsStateResolver;
            import confector.plugin_api.model : VcsRepositoryState, VcsChangeRecord;
            import std.json : parseJSON, JSONValue;

            string triggerId = req.params["triggerId"];

            // Look up the trigger rule to find the associated repository
            VcsRepositoryState resolvedState;
            if (stores)
            {
                auto rules = stores.triggerRules.list();
                string targetRepoUrl = "";
                foreach (rule; rules)
                {
                    if (rule.id == triggerId)
                    {
                        // Try to find the project associated with this trigger
                        ProjectRecord proj;
                        if (stores.projects.get(rule.projectId).tryValue(proj))
                        {
                            // Repositories come from task inputs: the target task first, then the rest.
                            string[] candidates;
                            foreach (t; proj.tasks)
                            {
                                if (t.id == rule.targetTaskId) candidates = repositoryIds(t) ~ candidates;
                                else candidates ~= repositoryIds(t);
                            }
                            foreach (cand; candidates)
                            {
                                // Candidates are repository ids; only registered repositories have an address.
                                RepositoryRecord repoRec;
                                if (!stores.repositories.get(cand).tryValue(repoRec)) continue;
                                if (repoRec.address.length > 0 && PluginRegistry.instance.findVcsResolver(repoRec.address) !is null)
                                {
                                    targetRepoUrl = repoRec.address;
                                    break;
                                }
                            }
                            break;
                        }
                    }
                }

                if (targetRepoUrl.length == 0)
                {
                    res.statusCode = HTTPStatus.notFound;
                    Json err = Json.emptyObject;
                    err["error"] = Json("Trigger not found or no associated repository: " ~ triggerId);
                    res.writeJsonBody(err);
                    return;
                }

                // Find the VCS resolver for this repository
                auto resolver = PluginRegistry.instance.findVcsResolver(targetRepoUrl);
                if (resolver is null)
                {
                    res.statusCode = HTTPStatus.badRequest;
                    Json err = Json.emptyObject;
                    err["error"] = Json("No VCS plugin registered for repository: " ~ targetRepoUrl);
                    res.writeJsonBody(err);
                    return;
                }

                // Collect HTTP headers
                string[string] headers;
                foreach (name, values; req.headers.byKeyValue())
                {
                    string joined;
                    foreach (v; values)
                    {
                        if (joined.length > 0) joined ~= ", ";
                        joined ~= v;
                    }
                    headers[name] = joined;
                }

                auto payload = parseJSON(req.json.toString());

                if (!resolver.parseWebhookPayload(headers, payload, resolvedState))
                {
                    res.statusCode = HTTPStatus.badRequest;
                    Json err = Json.emptyObject;
                    err["error"] = Json("VCS plugin failed to parse webhook payload");
                    res.writeJsonBody(err);
                    return;
                }

                // Check for revision change and persist
                VcsRepositoryState previousState;
                bool changed = false;
                string fromRevision = "";

                if (stores.vcsStates.getState(resolvedState.repositoryUrl, resolvedState.targetRef, previousState))
                {
                    fromRevision = previousState.revision;
                    if (previousState.revision != resolvedState.revision)
                    {
                        changed = true;
                    }
                }
                else
                {
                    changed = true;
                }

                resolvedState.updatedAt = Clock.currTime.toISOString();
                stores.vcsStates.saveState(resolvedState);

                if (changed)
                {
                    VcsChangeRecord change;
                    change.id = "change_" ~ randomUUID().toString();
                    change.repositoryUrl = resolvedState.repositoryUrl;
                    change.providerType = resolvedState.providerType;
                    change.targetRef = resolvedState.targetRef;
                    change.fromRevision = fromRevision;
                    change.toRevision = resolvedState.revision;
                    change.detectedAt = Clock.currTime.toISOString();
                    change.triggerSource = "webhook";
                    stores.vcsStates.recordChange(change);
                }
            }
            else
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("No state stores available");
                res.writeJsonBody(err);
                return;
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("processed");
            resp["trigger_id"] = Json(triggerId);
            resp["repository"] = Json(resolvedState.repositoryUrl);
            resp["revision"] = Json(resolvedState.revision);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });


    // Capacity broker endpoint — called by the scheduler plugin via HTTP
    if (capacityBroker !is null)
    {
        postRoute("/broker/evaluate", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                capacityBroker.evaluateDemand();
                Json resp = Json.emptyObject;
                resp["status"] = Json("ok");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                res.statusCode = HTTPStatus.internalServerError;
                Json err = Json.emptyObject;
                err["error"] = Json(e.msg);
                res.writeJsonBody(err);
            }
        });
    }



    return router;
}

unittest
{
    import confector.core.plugin;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;

    string testDir = "test_api_controller_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    class MockApiPlugin : Plugin
    {
        @property string name() const { return "mock-api-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock api plugin"; }
        @property PluginCategory category() const { return PluginCategory.definition; }
        ConfigDefinition[] configDefinitions() const { return null; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}
    }

    PluginRegistry.instance.registerPlugin(new MockApiPlugin());
    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto engine = new TaskEngine(storage);
    auto queue = new InMemoryDispatchQueue();

    auto router = apiRouter(engine, queue);
    assert(router !is null);

    // Test Trigger Rules state via repo
    TriggerRuleRecord rule;
    rule.id = "rule1";
    rule.name = "CI Build";
    rule.triggerType = "git_push";
    rule.criteria = "main";
    stores.triggerRules.save(rule);

    assert(stores.triggerRules.list().length == 1);
    assert(stores.triggerRules.list()[0].name == "CI Build");

    // Test Build record tracking
    BuildRecord bRec;
    bRec.buildId = "build_test_1";
    bRec.status = "succeeded";
    bRec.startedAt = "2026-10-15T14:02:00Z";
    stores.legacyBuilds.createBuild(bRec);
    stores.logs.appendBuildLog("build_test_1", "Test log line");

    BuildRecord fetched;
    assert(stores.legacyBuilds.getBuild("build_test_1", fetched));
    assert(fetched.status == "succeeded");
    assert(stores.logs.getBuildLogs("build_test_1").length == 1);

    // Test Projects and Tasks via repo
    ProjectRecord proj;
    proj.id = "proj_api_1";
    proj.name = "API Project";
    TaskNode node;
    node.id = "n1";
    node.steps = [BuildStep("Echo", "bash", null, "echo hi")];
    proj.tasks = [node];
    stores.projects.put(proj);
    assert(stores.projects.list().length == 1);

    ProjectRecord fetchedProj;
    assert(stores.projects.get("proj_api_1").tryValue(fetchedProj));
    assert(fetchedProj.name == "API Project");
    assert(fetchedProj.tasks.length == 1);
    assert(fetchedProj.tasks[0].id == "n1");

    // Test BuildCoordinator integration with apiRouter
    auto coordinator = new BuildCoordinator(storage, stores, queue);
    auto routerWithCoord = apiRouter(engine, queue, coordinator);
    assert(routerWithCoord !is null);

    string bldId = coordinator.startBuild(proj, null, true);
    assert(bldId.length > 0);
    auto received = receiveWorkOrders(queue, 10);
    assert(received.length == 1);
    assert(received[0].workOrder.taskId == "n1");
    assert(received[0].workOrder.buildId == bldId);

    // Simulate remote worker callback
    TaskExecutionResult workerRes;
    workerRes.buildId = bldId;
    workerRes.taskId = "n1";
    workerRes.status = TaskStatus.succeeded;
    workerRes.exitCode = 0;
    workerRes.durationMs = 85;
    coordinator.onTaskCompleted(bldId, "n1", workerRes);

    BuildRecord bldDetails;
    assert(stores.legacyBuilds.getBuild(bldId, bldDetails));
    assert(bldDetails.status == "succeeded");

    TaskExecutionRecord taskRec;
    assert(stores.legacyBuilds.getTaskExecution(bldId, "n1", taskRec));
    assert(taskRec.status == "succeeded");
    assert(taskRec.durationMs == 85);
}
