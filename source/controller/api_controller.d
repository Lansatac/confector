module controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.storage;
import confector.core.trigger;
import confector.runner.engine;
import confector.runner.serverless_runner;
import confector.runner.coordinator;
import confector.queue.queue;

import std.format : format;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;

URLRouter apiRouter(TaskEngine engine, WorkQueue queue = null, BuildCoordinator coordinator = null)
{
    auto router = new URLRouter();

    // Serverless JSON-RPC endpoint
    router.post("/rpc", (HTTPServerRequest req, HTTPServerResponse res) {
        string bodyText = req.bodyReader.readAllUTF8();
        string rpcResponse = handleServerlessJsonRpc(bodyText, engine);
        res.contentType = "application/json";
        res.writeBody(rpcResponse);
    });

    // Direct Task Execution endpoint
    router.post("/tasks/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            Json bodyJson = req.json;
            ServerlessTaskRequest taskReq = deserializeJson!ServerlessTaskRequest(bodyJson);
            ServerlessTaskResponse taskRes = executeServerlessTask(taskReq, engine);
            res.writeJsonBody(taskRes);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Work Queue endpoints
    if (queue !is null)
    {
        router.post("/queue/enqueue", (HTTPServerRequest req, HTTPServerResponse res) {
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

        router.post("/queue/dequeue", (HTTPServerRequest req, HTTPServerResponse res) {
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

        router.post("/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
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

        router.post("/queue/nack", (HTTPServerRequest req, HTTPServerResponse res) {
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

        router.post("/queue/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
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

        router.get("/queue/stats", (HTTPServerRequest req, HTTPServerResponse res) {
            Json stats = Json.emptyObject;
            stats["pending_count"] = Json(queue.getPendingCount());
            stats["dead_letter_count"] = Json(queue.getDeadLetterMessages().length);
            res.writeJsonBody(stats);
        });

        router.get("/queue/pending", (HTTPServerRequest req, HTTPServerResponse res) {
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

    // Remote Worker Task Completion Callback endpoint
    router.post("/builds/:build_id/tasks/:task_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.params["build_id"];
            string taskId = req.params["task_id"];
            TaskExecutionResult result = deserializeJson!TaskExecutionResult(req.json);
            result.buildId = buildId;
            result.taskId = taskId;

            if (coordinator !is null)
            {
                coordinator.onTaskCompleted(buildId, taskId, result);
            }
            else if (engine.stateRepository !is null)
            {
                engine.stateRepository.setTaskStatus(buildId, taskId, result.status, result.errorMessage);
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

    // Run Project via Coordinator / Engine
    router.post("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projectId = req.json["project_id"].get!string;
            auto pTarget = "target_task_id" in req.json;
            auto pForce = "force" in req.json;
            auto pWorkspace = "workspace_dir" in req.json;
            string targetTaskId = pTarget !is null ? pTarget.get!string : "";
            bool force = pForce !is null ? pForce.get!bool : false;
            string workspaceDir = pWorkspace !is null ? pWorkspace.get!string : "";

            auto repo = engine.stateRepository;
            ProjectRecord proj;
            if (repo is null || !repo.getProject(projectId, proj))
            {
                res.statusCode = HTTPStatus.notFound;
                Json err = Json.emptyObject;
                err["error"] = Json("Project not found: " ~ projectId);
                res.writeJsonBody(err);
                return;
            }

            if (coordinator !is null)
            {
                string buildId = coordinator.startBuild(proj, targetTaskId.length > 0 ? targetTaskId : null, force, "api", workspaceDir);
                Json resp = Json.emptyObject;
                resp["build_id"] = Json(buildId);
                resp["status"] = Json("running");
                resp["project_id"] = Json(projectId);
                res.writeJsonBody(resp);
            }
            else
            {
                auto graph = new TaskGraph(proj.tasks);
                string[] sorted = targetTaskId.length > 0 ? graph.resolveSubgraph(targetTaskId) : graph.topologicalSort();
                ExecutionPlan plan;
                plan.orderedTaskIds = sorted;
                plan.toExecuteTaskIds = sorted;
                string buildId = "build_" ~ randomUUID().toString()[0 .. 8];
                auto result = engine.executeTasks(buildId, proj.tasks, plan, workspaceDir, proj.id, proj.name, targetTaskId, force);
                res.writeJsonBody(result);
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

    // Task Graph Trigger & Execution endpoint
    router.post("/tasks/execute", (HTTPServerRequest req, HTTPServerResponse res) {
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

            auto subGraph = new TaskGraph(subTasks);
            string[] sortedOrder = subGraph.topologicalSort();
            ExecutionPlan plan;
            plan.orderedTaskIds = sortedOrder;
            plan.toExecuteTaskIds = sortedOrder;

            auto result = engine.executeTasks(buildId, subTasks, plan, workspaceDir, projectId, projectName, event.targetTaskId, event.force);
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
    router.get("/builds", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto repo = engine.stateRepository;
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

    router.get("/builds/details", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.query.get("id", "");
            auto repo = engine.stateRepository;
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

    router.get("/builds/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string buildId = req.query.get("id", "");
            auto repo = engine.stateRepository;
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
    router.get("/triggers", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto repo = engine.stateRepository;
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

    router.post("/triggers/create", (HTTPServerRequest req, HTTPServerResponse res) {
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

            auto repo = engine.stateRepository;
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

    router.post("/triggers/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string ruleId = req.json["id"].get!string;
            auto repo = engine.stateRepository;
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
    router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            auto repo = engine.stateRepository;
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

    router.post("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
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

            auto repo = engine.stateRepository;
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

    router.get("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            auto repo = engine.stateRepository;
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

    router.delete_("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            auto repo = engine.stateRepository;
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
    router.get("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            auto repo = engine.stateRepository;
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

    router.post("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            auto repo = engine.stateRepository;
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

    router.get("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string taskId = req.params["taskId"];
            auto repo = engine.stateRepository;
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

    router.delete_("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string taskId = req.params["taskId"];
            auto repo = engine.stateRepository;
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
    router.post("/projects/:id/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            auto repo = engine.stateRepository;
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

            auto graph = new TaskGraph(proj.tasks);
            string[] orderedTasks;
            if (targetTaskId.length > 0)
            {
                orderedTasks = graph.resolveSubgraph(targetTaskId);
            }
            else
            {
                orderedTasks = graph.topologicalSort();
            }

            ExecutionPlan plan;
            plan.orderedTaskIds = orderedTasks;
            plan.toExecuteTaskIds = orderedTasks;

            string buildId = "build_" ~ randomUUID().toString()[0 .. 8];
            if ("build_id" in bodyJson && bodyJson["build_id"].type == Json.Type.string)
            {
                buildId = bodyJson["build_id"].get!string;
            }

            auto execResult = engine.executeTasks(buildId, proj.tasks, plan, workspaceDir, proj.id, proj.name, targetTaskId, force);
            res.writeJsonBody(execResult);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    router.post("/projects/:id/tasks/:taskId/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.params["id"];
            string targetTaskId = req.params["taskId"];
            auto repo = engine.stateRepository;
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

            auto graph = new TaskGraph(proj.tasks);
            string[] orderedTasks = graph.resolveSubgraph(targetTaskId);

            ExecutionPlan plan;
            plan.orderedTaskIds = orderedTasks;
            plan.toExecuteTaskIds = orderedTasks;

            string buildId = "build_" ~ randomUUID().toString()[0 .. 8];
            if ("build_id" in bodyJson && bodyJson["build_id"].type == Json.Type.string)
            {
                buildId = bodyJson["build_id"].get!string;
            }

            auto execResult = engine.executeTasks(buildId, proj.tasks, plan, workspaceDir, proj.id, proj.name, targetTaskId, force);
            res.writeJsonBody(execResult);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.badRequest;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }
    });

    // Webhook receiver endpoint
    router.post("/triggers/webhook", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            Json bodyJson = req.json;
            TriggerEvent event;
            event.type = TriggerType.webhook;
            if ("branch" in bodyJson) event.branch = bodyJson["branch"].get!string;
            if ("tag" in bodyJson) event.tag = bodyJson["tag"].get!string;
            if ("endpoint" in bodyJson) event.endpoint = bodyJson["endpoint"].get!string;
            if ("target_task_id" in bodyJson) event.targetTaskId = bodyJson["target_task_id"].get!string;
            if ("force" in bodyJson) event.force = bodyJson["force"].get!bool;

            Json resp = Json.emptyObject;
            resp["status"] = Json("received");
            resp["event"] = serializeToJson(event);
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
        void initialize(PluginContext context = null) {}
        void shutdown() {}
    }

    PluginRegistry.instance.registerPlugin(new MockApiPlugin());
    auto storage = new LocalArtifactStorage(buildPath(testDir, "storage"));
    auto stateRepo = new InMemoryBuildStateRepository();
    auto engine = new TaskEngine(storage, stateRepo);
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
    node.script = "echo hi";
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
