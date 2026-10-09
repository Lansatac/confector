module controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.storage;
import confector.core.trigger;
import confector.runner_core.engine;
import confector.orchestrator.coordinator;
import confector.queue.queue;

import std.format : format;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;

URLRouter apiRouter(TaskEngine engine, WorkQueue queue = null, BuildCoordinator coordinator = null, BuildStateRepository stateRepo = null)
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

    // Work Queue endpoints
    if (queue !is null)
    {
        postRoute("/queue/enqueue", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                TaskQueueMessage msg = deserializeJson!TaskQueueMessage(req.json);
                queue.enqueue(msg);
                Json resp = Json.emptyObject;
                resp["status"] = Json("enqueued");
                resp["message_id"] = Json(msg.messageId);
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

        postRoute("/queue/dequeue", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                auto pMax = "max_messages" in req.json;
                auto pVis = "visibility_timeout" in req.json;
                size_t maxMsgs = pMax !is null ? pMax.get!size_t : 1;
                size_t visibility = pVis !is null ? pVis.get!size_t : 30;
                auto msgs = queue.dequeue(maxMsgs, visibility);
                res.writeJsonBody(msgs);
            }
            catch (Exception e)
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json(e.msg);
                res.writeJsonBody(err);
            }
        });

        postRoute("/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                string receiptHandle = req.json["receipt_handle"].get!string;
                queue.ack(receiptHandle);
                Json resp = Json.emptyObject;
                resp["status"] = Json("acknowledged");
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

        postRoute("/queue/nack", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                string receiptHandle = req.json["receipt_handle"].get!string;
                auto pReq = "requeue" in req.json;
                auto pErr = "error_reason" in req.json;
                bool requeue = pReq !is null ? pReq.get!bool : true;
                string errorReason = pErr !is null ? pErr.get!string : "";
                queue.nack(receiptHandle, requeue, errorReason);
                Json resp = Json.emptyObject;
                resp["status"] = Json("nacked");
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

        postRoute("/queue/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                string receiptHandle = req.json["receipt_handle"].get!string;
                auto pExt = "extension_seconds" in req.json;
                size_t extension = pExt !is null ? pExt.get!size_t : 30;
                queue.heartbeat(receiptHandle, extension);
                Json resp = Json.emptyObject;
                resp["status"] = Json("heartbeat_extended");
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

        getRoute("/queue/stats", (HTTPServerRequest req, HTTPServerResponse res) {
            Json stats = Json.emptyObject;
            stats["pending_count"] = Json(queue.getPendingCount());
            stats["dead_letter_count"] = Json(queue.getDeadLetterMessages().length);
            res.writeJsonBody(stats);
        });

        getRoute("/queue/pending", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                auto msgs = queue.getPendingMessages(50);
                res.writeJsonBody(msgs);
            }
            catch (Exception e)
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json(e.msg);
                res.writeJsonBody(err);
            }
        });
    }

    // Task Execution Query and Log Endpoints
    getRoute("/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto repo = stateRepo;
            string statusFilter = req.query.get("status", "");
            string projectFilter = req.query.get("project_id", "");
            string limitStr = req.query.get("limit", "50");
            size_t limit = 50;
            try { import std.conv : to; limit = limitStr.to!size_t; } catch (Exception) {}

            auto tasks = repo !is null ? repo.listRecentTaskExecutions(limit, statusFilter, projectFilter) : [];
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
            auto repo = stateRepo;

            TaskExecutionRecord record;
            if (repo !is null && repo.getTaskExecution(buildId, taskId, record))
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
            auto repo = stateRepo;

            string[] logs = repo !is null ? repo.getTaskLogs(buildId, taskId) : [];
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
            if (result.fingerprint.length == 0 || result.fingerprint == "unknown")
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
            else if (stateRepo !is null)
            {
                if (result.buildId.length > 0 && result.taskId.length > 0)
                {
                    stateRepo.setTaskStatus(result.buildId, result.taskId, result.status, result.errorMessage);
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
            else if (stateRepo !is null)
            {
                stateRepo.setTaskStatus(buildId, taskId, result.status, result.errorMessage);
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

            auto repo = stateRepo;
            if (repo !is null)
            {
                foreach (line; lines)
                {
                    repo.appendBuildLog(buildId, format("[%s] %s", taskId, line));
                    repo.appendTaskLog(buildId, taskId, line);
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

    // Run Project via the queue-backed coordinator
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

            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projectId, proj))
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
            auto repo = stateRepo;
            if (repo is null)
            {
                res.writeJsonBody(Json.emptyArray);
                return;
            }
            auto builds = repo.listBuilds(50);
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
            auto repo = stateRepo;
            if (repo is null)
            {
                res.statusCode = HTTPStatus.notFound;
                res.writeJsonBody(["error": "No state repository configured"]);
                return;
            }

            BuildRecord buildRec;
            if (repo.getBuild(buildId, buildRec))
            {
                auto taskRecs = repo.getTaskExecutionsForBuild(buildId);
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
            auto repo = stateRepo;
            string[] logs = repo !is null ? repo.getBuildLogs(buildId) : [];
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
            auto repo = stateRepo;
            auto rules = repo !is null ? repo.listTriggerRules() : [];
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

            auto repo = stateRepo;
            if (repo !is null)
            {
                repo.saveTriggerRule(rule);
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
            auto repo = stateRepo;
            bool ok = repo !is null && repo.deleteTriggerRule(ruleId);
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
            auto repo = stateRepo;
            auto projects = repo !is null ? repo.listProjects() : [];
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

            auto repo = stateRepo;
            if (repo !is null)
            {
                repo.saveProject(proj);
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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo !is null && repo.getProject(projId, proj))
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
            auto repo = stateRepo;
            bool ok = repo !is null && repo.deleteProject(projId);
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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo !is null && repo.getProject(projId, proj))
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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projId, proj))
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
            repo.saveProject(proj);

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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo !is null && repo.getProject(projId, proj))
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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projId, proj))
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
            repo.saveProject(proj);

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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projId, proj))
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
            auto repo = stateRepo;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projId, proj))
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

            if (stateRepo && stateRepo.getRepositoryState(resolvedState.repositoryUrl, resolvedState.targetRef, previousState))
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
            if (stateRepo)
            {
                resolvedState.updatedAt = Clock.currTime.toISOString();
                stateRepo.saveRepositoryState(resolvedState);

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
                    stateRepo.recordRepositoryChange(change);
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
            if (stateRepo)
            {
                auto rules = stateRepo.listTriggerRules();
                string targetRepoUrl = "";
                foreach (rule; rules)
                {
                    if (rule.id == triggerId)
                    {
                        // Try to find the project associated with this trigger
                        ProjectRecord proj;
                        if (stateRepo.getProject(rule.projectId, proj))
                        {
                            targetRepoUrl = proj.repositoryUrl;
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

                if (stateRepo.getRepositoryState(resolvedState.repositoryUrl, resolvedState.targetRef, previousState))
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
                stateRepo.saveRepositoryState(resolvedState);

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
                    stateRepo.recordRepositoryChange(change);
                }
            }
            else
            {
                res.statusCode = HTTPStatus.serviceUnavailable;
                Json err = Json.emptyObject;
                err["error"] = Json("No state repository available");
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

    // Generic polling endpoint for VCS state refresh
    postRoute("/repositories/poll", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            import confector.core.plugin : PluginRegistry;
            import confector.plugin_api.vcs : VcsStateResolver;
            import confector.plugin_api.model : VcsRepositoryState, VcsChangeRecord;

            Json bodyJson = req.json.type == Json.Type.object ? req.json : Json.emptyObject;
            string[] repoUrls;

            if ("repositories" in bodyJson && bodyJson["repositories"].type == Json.Type.array)
            {
                auto reposJson = bodyJson["repositories"];
                foreach (item; reposJson)
                {
                    repoUrls ~= item.get!string;
                }
            }
            else if (stateRepo)
            {
                // If no specific repos provided, poll all tracked repos
                foreach (proj; stateRepo.listProjects())
                {
                    if (proj.repositoryUrl.length > 0)
                    {
                        repoUrls ~= proj.repositoryUrl;
                    }
                }
            }

            int changedCount = 0;
            int errorCount = 0;
            Json changes = Json.emptyArray;

            foreach (repoUrl; repoUrls)
            {
                auto resolver = PluginRegistry.instance.findVcsResolver(repoUrl);
                if (resolver is null)
                {
                    errorCount++;
                    continue;
                }

                try
                {
                    auto newState = resolver.fetchLatestState(repoUrl);

                    VcsRepositoryState previousState;
                    bool changed = false;
                    string fromRevision = "";

                    if (stateRepo && stateRepo.getRepositoryState(newState.repositoryUrl, newState.targetRef, previousState))
                    {
                        fromRevision = previousState.revision;
                        if (previousState.revision != newState.revision)
                        {
                            changed = true;
                        }
                    }
                    else
                    {
                        changed = true;
                    }

                    if (stateRepo)
                    {
                        newState.updatedAt = Clock.currTime.toISOString();
                        stateRepo.saveRepositoryState(newState);

                        if (changed)
                        {
                            VcsChangeRecord change;
                            change.id = "change_" ~ randomUUID().toString();
                            change.repositoryUrl = newState.repositoryUrl;
                            change.providerType = newState.providerType;
                            change.targetRef = newState.targetRef;
                            change.fromRevision = fromRevision;
                            change.toRevision = newState.revision;
                            change.detectedAt = Clock.currTime.toISOString();
                            change.triggerSource = "polling";
                            stateRepo.recordRepositoryChange(change);
                            changedCount++;

                            Json changeJson = Json.emptyObject;
                            changeJson["repository"] = Json(newState.repositoryUrl);
                            changeJson["from"] = Json(fromRevision);
                            changeJson["to"] = Json(newState.revision);
                            changes ~= changeJson;
                        }
                    }
                }
                catch (Exception e)
                {
                    errorCount++;
                }
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("completed");
            resp["polled"] = Json(repoUrls.length);
            resp["changed"] = Json(changedCount);
            resp["errors"] = Json(errorCount);
            resp["changes"] = changes;
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

    return router;
}

unittest
{
    import confector.core.plugin;
    import confector.core.test_storage : InMemoryArtifactStorage, InMemoryBuildStateRepository, InMemoryWorkQueue;
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
    auto stateRepo = new InMemoryBuildStateRepository();
    auto engine = new TaskEngine(storage);
    auto queue = new InMemoryWorkQueue();

    auto router = apiRouter(engine, queue);
    assert(router !is null);

    // Test Trigger Rules state via repo
    TriggerRuleRecord rule;
    rule.id = "rule1";
    rule.name = "CI Build";
    rule.triggerType = "git_push";
    rule.criteria = "main";
    stateRepo.saveTriggerRule(rule);

    assert(stateRepo.listTriggerRules().length == 1);
    assert(stateRepo.listTriggerRules()[0].name == "CI Build");

    // Test Build record tracking
    BuildRecord bRec;
    bRec.buildId = "build_test_1";
    bRec.status = "succeeded";
    stateRepo.recordBuild(bRec);
    stateRepo.appendBuildLog("build_test_1", "Test log line");

    BuildRecord fetched;
    assert(stateRepo.getBuild("build_test_1", fetched));
    assert(fetched.status == "succeeded");
    assert(stateRepo.getBuildLogs("build_test_1").length == 1);

    // Test Projects and Tasks via repo
    ProjectRecord proj;
    proj.id = "proj_api_1";
    proj.name = "API Project";
    TaskNode node;
    node.id = "n1";
    node.steps = [BuildStep("Echo", "bash", null, "echo hi")];
    proj.tasks = [node];
    stateRepo.saveProject(proj);
    assert(stateRepo.listProjects().length == 1);

    ProjectRecord fetchedProj;
    assert(stateRepo.getProject("proj_api_1", fetchedProj));
    assert(fetchedProj.name == "API Project");
    assert(fetchedProj.tasks.length == 1);
    assert(fetchedProj.tasks[0].id == "n1");

    // Test BuildCoordinator integration with apiRouter
    auto coordinator = new BuildCoordinator(storage, stateRepo, queue);
    auto routerWithCoord = apiRouter(engine, queue, coordinator);
    assert(routerWithCoord !is null);

    string bldId = coordinator.startBuild(proj, null, true);
    assert(bldId.length > 0);
    assert(queue.getPendingCount() == 1);

    auto pendingMsgs = queue.getPendingMessages(10);
    assert(pendingMsgs.length == 1);
    assert(pendingMsgs[0].taskId == "n1");
    assert(pendingMsgs[0].buildId == bldId);

    // Simulate remote worker callback
    TaskExecutionResult workerRes;
    workerRes.buildId = bldId;
    workerRes.taskId = "n1";
    workerRes.status = TaskStatus.succeeded;
    workerRes.exitCode = 0;
    workerRes.durationMs = 85;
    coordinator.onTaskCompleted(bldId, "n1", workerRes);

    BuildRecord bldDetails;
    assert(stateRepo.getBuild(bldId, bldDetails));
    assert(bldDetails.status == "succeeded");

    TaskExecutionRecord taskRec;
    assert(stateRepo.getTaskExecution(bldId, "n1", taskRec));
    assert(taskRec.status == "succeeded");
    assert(taskRec.durationMs == 85);
}
