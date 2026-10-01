module confector.runner.serverless_runner;

import confector.core.model;
import confector.core.storage;
import confector.core.executor : TaskRunner;
import confector.runner.engine;
import confector.core.plugin;

import vibe.data.json;
import vibe.data.serialization : asName = name;
import std.format : format;

/**
 * Serverless / FaaS execution request payload.
 */
struct ServerlessTaskRequest
{
    @asName("build_id") string buildId;
    TaskNode task;
    @asName("workspace_dir") string workspaceDir;
    @asName("upstream_artifact_hashes") string[string] upstreamArtifactHashes;
    bool force = false;
    @asName("storage_base_dir") string storageBaseDir;
}

/**
 * Serverless / FaaS execution response payload.
 */
struct ServerlessTaskResponse
{
    @asName("task_id") string taskId;
    @asName("build_id") string buildId;
    TaskStatus status;
    string fingerprint;
    @asName("exit_code") int exitCode;
    string[] logs;
    @asName("error_message") string errorMessage;
    @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @asName("duration_ms") ulong durationMs;
}

/**
 * JSON RPC wrapper envelope for serverless invocation.
 */
struct JsonRpcRequest
{
    @asName("jsonrpc") string jsonRpc = "2.0";
    string method;
    Json params;
    Json id;
}

struct JsonRpcResponse
{
    @asName("jsonrpc") string jsonRpc = "2.0";
    Json result;
    Json error;
    Json id;
}

/**
 * Executes a single task request in a stateless serverless context.
 */
ServerlessTaskResponse executeServerlessTask(
    in ServerlessTaskRequest request,
    TaskEngine customEngine = null
)
{
    TaskEngine engine = customEngine;
    if (engine is null)
    {
        string storageDir = request.storageBaseDir.length > 0 ? request.storageBaseDir : ".confector/artifacts";
        auto storage = new LocalArtifactStorage(storageDir);
        auto stateRepo = new InMemoryBuildStateRepository();
        engine = new TaskEngine(storage, stateRepo);
    }

    auto res = engine.executeTask(
        request.buildId,
        request.task,
        request.workspaceDir,
        request.upstreamArtifactHashes,
        request.force
    );

    ServerlessTaskResponse response;
    response.taskId = res.taskId;
    response.buildId = res.buildId;
    response.status = res.status;
    response.fingerprint = res.fingerprint;
    response.exitCode = res.exitCode;
    response.logs = res.logs;
    response.errorMessage = res.errorMessage;
    response.producedArtifacts = res.producedArtifacts;
    response.durationMs = res.durationMs;

    return response;
}

/**
 * Standard JSON RPC handler for serverless event processing.
 */
string handleServerlessJsonRpc(string jsonRequestString, TaskEngine customEngine = null)
{
    try
    {
        Json reqJson = parseJsonString(jsonRequestString);
        JsonRpcRequest rpcReq = deserializeJson!JsonRpcRequest(reqJson);

        if (rpcReq.method != "executeTask" && rpcReq.method != "confector.executeTask")
        {
            JsonRpcResponse errRes;
            errRes.id = rpcReq.id;
            errRes.error = Json.emptyObject;
            errRes.error["code"] = Json(-32601);
            errRes.error["message"] = Json(format("Method not found: %s", rpcReq.method));
            return serializeToJsonString(errRes);
        }

        ServerlessTaskRequest taskReq = deserializeJson!ServerlessTaskRequest(rpcReq.params);
        ServerlessTaskResponse taskRes = executeServerlessTask(taskReq, customEngine);

        JsonRpcResponse successRes;
        successRes.id = rpcReq.id;
        successRes.result = serializeToJson(taskRes);
        return serializeToJsonString(successRes);
    }
    catch (Exception e)
    {
        JsonRpcResponse errRes;
        errRes.id = Json(null);
        errRes.error = Json.emptyObject;
        errRes.error["code"] = Json(-32600);
        errRes.error["message"] = Json(format("Invalid Request: %s", e.msg));
        return serializeToJsonString(errRes);
    }
}

unittest
{
    import std.file : exists, isFile, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;

    string testDir = "test_serverless_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    ServerlessTaskRequest req;
    req.buildId = "srv_bld_1";
    req.workspaceDir = testDir;
    req.storageBaseDir = buildPath(testDir, "artifacts");

    TaskNode node;
    node.id = "echo_step";
    node.name = "Echo Step";
    version(Windows)
    {
        node.script = "cmd /c \"echo serverless test\"";
    }
    else
    {
        node.script = "echo serverless test";
    }
    req.task = node;

    // Test struct-based execution
    auto response = executeServerlessTask(req);
    assert(response.taskId == "echo_step");
    assert(response.status == TaskStatus.succeeded);
    assert(response.exitCode == 0);

    // Test JSON RPC execution
    string jsonReq = format(
        `{"jsonrpc":"2.0","method":"executeTask","params":%s,"id":1}`,
        serializeToJsonString(req)
    );

    string jsonResponse = handleServerlessJsonRpc(jsonReq);
    Json parsedRes = parseJsonString(jsonResponse);
    assert(parsedRes["id"].get!long == 1);
    assert(parsedRes["result"]["status"].get!string == "succeeded");
    assert(parsedRes["result"]["task_id"].get!string == "echo_step");
}
