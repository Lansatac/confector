module controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.storage;
import confector.core.trigger;
import confector.runner.engine;
import confector.runner.serverless_runner;
import confector.queue.queue;

import std.format : format;

URLRouter apiRouter(TaskEngine engine, WorkQueue queue = null)
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
    }

    // Pipeline Trigger & Execution endpoint
    router.post("/pipeline/execute", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            Json bodyJson = req.json;
            PipelineDefinition pipeline = deserializeJson!PipelineDefinition(bodyJson["pipeline"]);
            TriggerEvent event = deserializeJson!TriggerEvent(bodyJson["event"]);
            string workspaceDir = bodyJson["workspace_dir"].get!string;
            string buildId = "build_id" in bodyJson ? bodyJson["build_id"].get!string : "build_" ~ Clock.currTime.toISOString();

            // Resolve triggering
            string[] matchingTasks = TriggerMatcher.findMatchingTasks(pipeline, event);
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
            auto fullGraph = new TaskGraph(pipeline);
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

            // Create sub-pipeline
            TaskNode[] subTasks;
            foreach (task; pipeline.tasks)
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

            PipelineDefinition subPipeline;
            subPipeline.schemaVersion = pipeline.schemaVersion;
            subPipeline.tasks = subTasks;

            auto subGraph = new TaskGraph(subPipeline);
            string[] sortedOrder = subGraph.topologicalSort();
            ExecutionPlan plan;
            plan.orderedTaskIds = sortedOrder;
            plan.toExecuteTaskIds = sortedOrder;

            auto result = engine.executePipeline(buildId, subPipeline, plan, workspaceDir, event.force);
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

    return router;
}
