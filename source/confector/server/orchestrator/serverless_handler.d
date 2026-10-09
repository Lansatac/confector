module confector.orchestrator.serverless_handler;

import confector.core.model;
import confector.runner_core.engine;
import confector.core.plugin;
import confector.storage.configured_storage : ConfiguredArtifactStorage;

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
    @optional @asName("allowed_repositories") string[] allowedRepositories;
    @optional @asName("repository_map") string[string] repositoryMap;
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
 *
 * Params:
 *   request = The serverless task request payload.
 *   customEngine = Optional pre-configured TaskEngine; if null, one is created from the PluginRegistry default storage.
 */
ServerlessTaskResponse executeServerlessTask(
    in ServerlessTaskRequest request,
    TaskEngine customEngine = null
)
{
    TaskEngine engine = customEngine;
    if (engine is null)
    {
        // Use ConfiguredArtifactStorage so the engine always forwards to the currently
        // configured storage, supporting runtime config changes.
        auto configuredStorage = new ConfiguredArtifactStorage(PluginRegistry.instance);
        engine = new TaskEngine(configuredStorage);
    }

    auto res = engine.executeTask(
        request.buildId,
        request.task,
        request.workspaceDir,
        request.upstreamArtifactHashes,
        request.force,
        null,
        request.allowedRepositories,
        request.repositoryMap
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

    class MockServerlessStepRunner : Plugin, BuildStepSystem
    {
        @property string name() const pure nothrow @safe { return "mock_serverless_runner"; }
        @property string versionString() const pure nothrow @safe { return "1.0.0"; }
        @property string description() const pure nothrow @safe { return "Mock Serverless Step Runner"; }
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.step_executor; }
        ConfigDefinition[] configDefinitions() const { return null; }
        @property string systemName() const pure nothrow @safe { return "mock-serverless-step-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecuteStep(in BuildStep step) const { return true; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            res.success = true;
            res.exitCode = 0;
            return res;
        }
    }

    import confector.core.test_storage : InMemoryArtifactStorage;

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockServerlessStepRunner());
    PluginRegistry.instance.registerArtifactStorage(new InMemoryArtifactStorage());

    string testDir = "test_serverless_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    ServerlessTaskRequest req;
    req.buildId = "srv_bld_1";
    req.workspaceDir = testDir;

    TaskNode node;
    node.id = "echo_step";
    node.name = "Echo Step";
    node.steps = [BuildStep("Echo Step", "process", null, "echo serverless test")];
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
