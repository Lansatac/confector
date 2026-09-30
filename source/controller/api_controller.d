module controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.storage;
import confector.core.trigger;
import confector.runner.engine;
import confector.runner.serverless_runner;

import std.format : format;

URLRouter apiRouter(TaskEngine engine)
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
