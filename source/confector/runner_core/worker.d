module confector.runner_core.worker;

import confector.core.model;
import confector.core.storage;
import confector.core.plugin;
import confector.core.plugin_loader;
import confector.queue.queue;
import confector.runner_core.engine;
import confector.runner_core.artifacts;
import confector.runner_core.logging;

import vibe.data.json : Json, serializeToJson, deserializeJson, serializeToJsonString, parseJsonString;

import std.net.curl : HTTP;
import std.file : exists, mkdirRecurse, isDir;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.format : format;
import std.stdio : writeln, stderr;
import std.datetime.systime : Clock;
import std.process : environment;
import std.algorithm.searching : canFind;
import core.thread : Thread;
import core.time : Duration, seconds, msecs;

/**
 * Configuration options for the HTTP-based remote worker daemon.
 */
struct HttpWorkerConfig
{
    string serverUrl = "http://localhost:8080";
    string workerId = "";
    string workerToken = "";
    string workspaceDir = ".confector/worker_workspace";
    string storageDir = ".confector/worker_storage";
    string pluginsDir = "plugins";
    size_t pollIntervalSeconds = 2;
    size_t visibilityTimeoutSeconds = 60;
    size_t heartbeatIntervalSeconds = 15;
    size_t maxTasksToProcess = 0; // 0 = continuous loop
    bool verbose = false;
}

/**
 * HTTP client for worker-to-server control plane protocol.
 * Handles task dequeuing, heartbeat renewals, log streaming, and completion reporting.
 */
class HttpWorkerClient
{
    private string m_serverUrl;
    private string m_workerId;
    private string m_workerToken;

    this(string serverUrl, string workerId = "", string workerToken = "")
    {
        this.m_serverUrl = normalizeBaseUrl(serverUrl);
        this.m_workerId = workerId.length > 0 ? workerId : "worker_" ~ randomUUID().toString()[0 .. 8];
        this.m_workerToken = workerToken.length > 0 ? workerToken : environment.get("CONFECTOR_WORKER_TOKEN", environment.get("CONFECTOR_SECRET_TOKEN", ""));
    }

    @property string serverUrl() const pure nothrow @safe { return m_serverUrl; }
    @property string workerId() const pure nothrow @safe { return m_workerId; }
    @property string workerToken() const pure nothrow @safe { return m_workerToken; }

    static string normalizeBaseUrl(string url)
    {
        import std.string : endsWith;
        string result = url;
        while (result.length > 0 && result.endsWith("/"))
        {
            result = result[0 .. $ - 1];
        }
        return result;
    }

    string resolveEndpointUrl(string path) const
    {
        import std.string : startsWith, endsWith;
        string cleanPath = path;
        if (!cleanPath.startsWith("/")) cleanPath = "/" ~ cleanPath;

        if (m_serverUrl.endsWith("/api/v1"))
        {
            if (cleanPath.startsWith("/api/v1/"))
            {
                cleanPath = cleanPath[7 .. $];
            }
            return m_serverUrl ~ cleanPath;
        }
        else
        {
            if (!cleanPath.startsWith("/api/v1/"))
            {
                cleanPath = "/api/v1" ~ cleanPath;
            }
            return m_serverUrl ~ cleanPath;
        }
    }

    Json sendJson(string endpointPath, string method = "POST", in Json bodyJson = Json.undefined)
    {
        string fullUrl = resolveEndpointUrl(endpointPath);
        auto http = HTTP(fullUrl);

        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("Accept", "application/json");

        if (m_workerToken.length > 0)
        {
            http.addRequestHeader("X-Worker-Token", m_workerToken);
            http.addRequestHeader("Authorization", "Bearer " ~ m_workerToken);
        }
        if (m_workerId.length > 0)
        {
            http.addRequestHeader("X-Worker-ID", m_workerId);
        }

        char[] responseData;
        http.onReceive = (ubyte[] data) {
            responseData ~= cast(char[])data;
            return data.length;
        };

        if (bodyJson.type != Json.Type.undefined && bodyJson.type != Json.Type.null_)
        {
            string bodyStr = serializeToJsonString(bodyJson);
            http.setPostData(bodyStr, "application/json");
        }
        else if (method == "POST")
        {
            http.setPostData("{}", "application/json");
        }

        http.method = HTTP.Method.post;
        if (method == "GET") http.method = HTTP.Method.get;
        else if (method == "PUT") http.method = HTTP.Method.put;
        else if (method == "DELETE") http.method = HTTP.Method.del;

        http.perform();

        if (http.statusLine.code >= 200 && http.statusLine.code < 300)
        {
            if (responseData.length > 0)
            {
                try
                {
                    return parseJsonString(responseData.idup);
                }
                catch (Exception)
                {
                    return Json.emptyObject;
                }
            }
            return Json.emptyObject;
        }
        else
        {
            string errMsg;
            if (responseData.length > 0)
            {
                try
                {
                    auto errJson = parseJsonString(responseData.idup);
                    if ("error" in errJson) errMsg = errJson["error"].get!string;
                    else errMsg = responseData.idup;
                }
                catch (Exception)
                {
                    errMsg = responseData.idup;
                }
            }
            if (errMsg.length == 0) errMsg = format("HTTP %d %s", http.statusLine.code, http.statusLine.reason);
            throw new Exception(format("Server request to '%s' failed: %s", fullUrl, errMsg));
        }
    }

    TaskQueueMessage[] dequeueTasks(size_t maxMessages = 1, size_t visibilityTimeout = 30)
    {
        Json req = Json.emptyObject;
        req["max_messages"] = Json(maxMessages);
        req["visibility_timeout"] = Json(visibilityTimeout);
        req["worker_id"] = Json(m_workerId);

        Json res = sendJson("/queue/dequeue", "POST", req);
        if (res.type == Json.Type.array)
        {
            return deserializeJson!(TaskQueueMessage[])(res);
        }
        return [];
    }

    bool extendHeartbeat(string receiptHandle, size_t extensionSeconds = 30)
    {
        if (receiptHandle.length == 0) return false;
        try
        {
            Json req = Json.emptyObject;
            req["receipt_handle"] = Json(receiptHandle);
            req["extension_seconds"] = Json(extensionSeconds);
            req["worker_id"] = Json(m_workerId);
            sendJson("/queue/heartbeat", "POST", req);
            return true;
        }
        catch (Exception e)
        {
            logWarn("[HttpWorkerClient] Failed to extend heartbeat for receipt '%s': %s", receiptHandle, e.msg);
            return false;
        }
    }

    bool ackTask(string receiptHandle)
    {
        if (receiptHandle.length == 0) return false;
        try
        {
            Json req = Json.emptyObject;
            req["receipt_handle"] = Json(receiptHandle);
            req["worker_id"] = Json(m_workerId);
            sendJson("/queue/ack", "POST", req);
            return true;
        }
        catch (Exception e)
        {
            logError("[HttpWorkerClient] Failed to acknowledge task receipt '%s': %s", receiptHandle, e.msg);
            return false;
        }
    }

    bool nackTask(string receiptHandle, bool requeue = true, string errorReason = "")
    {
        if (receiptHandle.length == 0) return false;
        try
        {
            Json req = Json.emptyObject;
            req["receipt_handle"] = Json(receiptHandle);
            req["requeue"] = Json(requeue);
            req["error_reason"] = Json(errorReason);
            req["worker_id"] = Json(m_workerId);
            sendJson("/queue/nack", "POST", req);
            return true;
        }
        catch (Exception e)
        {
            logError("[HttpWorkerClient] Failed to nack task receipt '%s': %s", receiptHandle, e.msg);
            return false;
        }
    }

    bool streamLogs(string buildId, string taskId, string[] lines)
    {
        if (lines.length == 0) return true;
        try
        {
            Json req = Json.emptyObject;
            req["lines"] = serializeToJson(lines);
            req["worker_id"] = Json(m_workerId);
            string endpoint = format("/builds/%s/tasks/%s/logs", buildId, taskId);
            sendJson(endpoint, "POST", req);
            return true;
        }
        catch (Exception e)
        {
            logWarn("[HttpWorkerClient] Failed to stream logs for build '%s' task '%s': %s", buildId, taskId, e.msg);
            return false;
        }
    }

    bool reportCompletion(string buildId, string taskId, in TaskExecutionResult result, string callbackUrl = null)
    {
        bool success = false;
        try
        {
            Json bodyJson = serializeToJson(result);
            string endpoint = format("/builds/%s/tasks/%s/complete", buildId, taskId);
            sendJson(endpoint, "POST", bodyJson);
            success = true;
        }
        catch (Exception e)
        {
            logError("[HttpWorkerClient] Failed to report task completion to server (build: %s, task: %s): %s", buildId, taskId, e.msg);
        }

        if (callbackUrl.length > 0)
        {
            try
            {
                auto http = HTTP(callbackUrl);
                http.addRequestHeader("Content-Type", "application/json");
                string bodyStr = serializeToJsonString(result);
                http.setPostData(bodyStr, "application/json");
                http.perform();
            }
            catch (Exception e)
            {
                logWarn("[HttpWorkerClient] Failed to notify callback URL '%s': %s", callbackUrl, e.msg);
            }
        }

        return success;
    }
}

/**
 * Runner loop handling task dequeuing, execution via TaskEngine, heartbeat renewals,
 * artifact packing/unpacking, and completion reporting over HTTP.
 */
class HttpWorkerRunner
{
    private HttpWorkerConfig m_config;
    private HttpWorkerClient m_client;
    private TaskEngine m_engine;
    private ArtifactStorage m_storage;
    private bool m_stopRequested = false;
    private bool m_running = false;
    private size_t m_tasksProcessed = 0;

    this(in HttpWorkerConfig config, HttpWorkerClient client = null)
    {
        this.m_config = config;
        this.m_client = client !is null ? client : new HttpWorkerClient(config.serverUrl, config.workerId, config.workerToken);
    }

    @property const(HttpWorkerConfig) config() const pure nothrow @safe { return m_config; }
    @property HttpWorkerClient client() { return m_client; }
    @property size_t tasksProcessed() const pure nothrow @safe { return m_tasksProcessed; }
    @property bool isRunning() const pure nothrow @safe { return m_running; }

    void requestStop() pure nothrow @safe
    {
        m_stopRequested = true;
    }

    void initialize()
    {
        if (!exists(m_config.workspaceDir))
        {
            mkdirRecurse(m_config.workspaceDir);
        }
        if (!exists(m_config.storageDir))
        {
            mkdirRecurse(m_config.storageDir);
        }

        // Load runner category plugins
        string[] searchDirs = [m_config.pluginsDir, "bin/plugins", "plugins"];
        foreach (dir; searchDirs)
        {
            if (exists(dir) && isDir(dir))
            {
                PluginLoader.instance.loadBundledPlugins(dir, [PluginCategory.runner]);
            }
        }

        m_storage = new LocalArtifactStorage(m_config.storageDir);
        m_engine = new TaskEngine(m_storage);
    }

    TaskExecutionResult processOneMessage(in TaskQueueMessage msg)
    {
        string buildId = msg.buildId.length > 0 ? msg.buildId : "build_anon";
        string taskId = msg.taskId;
        string taskWsDir = buildPath(m_config.workspaceDir, buildId, taskId);
        if (!exists(taskWsDir))
        {
            mkdirRecurse(taskWsDir);
        }

        logInfo("[worker] Processing task '%s' for build '%s' (receipt: %s)", taskId, buildId, msg.receiptHandle);

        // Heartbeat periodic timer
        Thread heartbeatThread;
        bool heartbeatRunning = false;
        if (msg.receiptHandle.length > 0 && m_config.heartbeatIntervalSeconds > 0)
        {
            heartbeatRunning = true;
            string handle = msg.receiptHandle;
            size_t intervalSec = m_config.heartbeatIntervalSeconds;
            size_t visTimeout = m_config.visibilityTimeoutSeconds;
            heartbeatThread = new Thread({
                while (heartbeatRunning)
                {
                    Thread.sleep(intervalSec.seconds);
                    if (!heartbeatRunning) break;
                    if (m_client !is null && handle.length > 0)
                    {
                        m_client.extendHeartbeat(handle, visTimeout);
                    }
                }
            });
            heartbeatThread.isDaemon = true;
            heartbeatThread.start();
        }
        scope(exit)
        {
            if (heartbeatRunning)
            {
                heartbeatRunning = false;
                if (heartbeatThread !is null)
                {
                    heartbeatThread.join();
                }
            }
        }

        // Prepare TaskNode
        TaskNode taskNode = deserializeJson!TaskNode(serializeToJson(msg.taskNode));
        if (taskNode.id.length == 0)
        {
            taskNode.id = taskId;
        }

        if (taskNode.script.length == 0 && msg.executionPayload.script.length > 0)
        {
            taskNode.script = msg.executionPayload.script;
        }
        if (taskNode.environment.length == 0 && msg.executionPayload.environment.length > 0)
        {
            foreach (k, v; msg.executionPayload.environment)
            {
                taskNode.environment[k] = v;
            }
        }

        // Map input_artifacts to taskNode upstream artifacts
        if (msg.executionPayload.inputArtifacts.length > 0)
        {
            foreach (inArt; msg.executionPayload.inputArtifacts)
            {
                UpstreamArtifactRef refArt;
                refArt.taskId = inArt.taskId;
                refArt.artifactId = inArt.artifactId;
                refArt.destination = inArt.destination.length > 0 ? inArt.destination : inArt.targetPath;
                refArt.sha256 = inArt.sha256;
                taskNode.inputs.upstreamArtifacts ~= refArt;
            }
        }

        // Map expectedOutputs to taskNode outputs
        if (msg.executionPayload.expectedOutputs.length > 0)
        {
            foreach (expOut; msg.executionPayload.expectedOutputs)
            {
                taskNode.outputs.artifacts ~= expOut;
            }
        }

        // Live Log streaming buffer
        string[] logBuffer;
        auto logLock = new Object();
        void onLogLine(string line)
        {
            synchronized (logLock)
            {
                logBuffer ~= line;
            }
            if (m_config.verbose)
            {
                writeln(line);
            }
            if (logBuffer.length >= 10)
            {
                string[] flushLines;
                synchronized (logLock)
                {
                    flushLines = logBuffer.dup;
                    logBuffer.length = 0;
                }
                m_client.streamLogs(buildId, taskId, flushLines);
            }
        }

        string[string] upstreamHashes = msg.executionPayload.upstreamArtifactHashes.dup;
        string[] allowedRepos = msg.executionPayload.allowedRepositories.dup;
        string[string] repoMap = msg.executionPayload.repositoryMap.dup;

        TaskExecutionResult result;
        try
        {
            result = m_engine.executeTask(
                buildId,
                taskNode,
                taskWsDir,
                upstreamHashes,
                msg.executionPayload.force,
                &onLogLine,
                allowedRepos,
                repoMap,
                msg.nodeFingerprint
            );
        }
        catch (Exception e)
        {
            result.status = TaskStatus.failed;
            result.errorMessage = format("Worker unhandled exception during task execution: %s", e.msg);
            result.exitCode = 1;
            onLogLine(format("[worker] Exception: %s", e.msg));
        }

        // Flush remaining log buffer
        string[] finalLogs;
        synchronized (logLock)
        {
            finalLogs = logBuffer.dup;
            logBuffer.length = 0;
        }
        if (finalLogs.length > 0)
        {
            m_client.streamLogs(buildId, taskId, finalLogs);
        }

        // Report task completion over HTTP
        m_client.reportCompletion(buildId, taskId, result, msg.executionPayload.callbackUrl);

        // Acknowledge task message from queue
        if (msg.receiptHandle.length > 0)
        {
            m_client.ackTask(msg.receiptHandle);
        }

        m_tasksProcessed++;
        return result;
    }

    void run()
    {
        initialize();
        m_running = true;
        scope(exit) m_running = false;

        logInfo("[worker] Remote worker '%s' started, polling server '%s'...", m_client.workerId, m_client.serverUrl);

        while (!m_stopRequested)
        {
            try
            {
                auto messages = m_client.dequeueTasks(1, m_config.visibilityTimeoutSeconds);
                if (messages.length == 0)
                {
                    if (m_config.maxTasksToProcess > 0 && m_tasksProcessed >= m_config.maxTasksToProcess)
                    {
                        break;
                    }
                    Thread.sleep(m_config.pollIntervalSeconds.seconds);
                    continue;
                }

                foreach (msg; messages)
                {
                    processOneMessage(msg);
                    if (m_config.maxTasksToProcess > 0 && m_tasksProcessed >= m_config.maxTasksToProcess)
                    {
                        break;
                    }
                }

                if (m_config.maxTasksToProcess > 0 && m_tasksProcessed >= m_config.maxTasksToProcess)
                {
                    break;
                }
            }
            catch (Exception e)
            {
                logError("[worker] Error during worker polling loop: %s", e.msg);
                Thread.sleep(m_config.pollIntervalSeconds.seconds);
            }
        }

        logInfo("[worker] Worker '%s' stopped. Total tasks processed: %d", m_client.workerId, m_tasksProcessed);
    }
}

unittest
{
    import std.file : exists, rmdirRecurse, mkdirRecurse, write;
    import confector.core.plugin : PluginRegistry, Plugin;
    import confector.plugin_api : BuildStepSystem, StepExecutionContext, StepExecutionResult, PluginCategory, LogDelegate;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import vibe.core.core : runTask, sleep;
    import core.time : msecs;

    class MockStepRunner : Plugin, BuildStepSystem
    {
        @property string name() const pure nothrow @safe { return "mock_runner"; }
        @property string versionString() const pure nothrow @safe { return "1.0.0"; }
        @property string description() const pure nothrow @safe { return "Mock Step Runner"; }
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.runner; }
        ConfigDefinition[] configDefinitions() const { return null; }
        @property string systemName() const pure nothrow @safe { return "mock-step-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecuteStep(in BuildStep step) const { return true; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            res.exitCode = 0;
            res.success = true;
            res.outputLines = ["Mock step execution finished successfully"];
            if (context.logCallback !is null)
            {
                context.logCallback("Mock step execution finished successfully");
            }
            return res;
        }
    }

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockStepRunner());
    scope(exit) PluginRegistry.instance.unregisterPlugin("mock_step_runner");

    string testDir = "test_http_worker_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Test URL resolution & client headers
    auto client = new HttpWorkerClient("http://127.0.0.1:9099", "test_worker_1", "secret_tok_123");
    assert(client.resolveEndpointUrl("/queue/dequeue") == "http://127.0.0.1:9099/api/v1/queue/dequeue");
    assert(client.resolveEndpointUrl("/api/v1/queue/dequeue") == "http://127.0.0.1:9099/api/v1/queue/dequeue");

    auto clientApiV1 = new HttpWorkerClient("http://127.0.0.1:9099/api/v1", "test_worker_1");
    assert(clientApiV1.resolveEndpointUrl("/queue/dequeue") == "http://127.0.0.1:9099/api/v1/queue/dequeue");

    // Setup Mock HTTP Control Plane Server
    auto router = new URLRouter();
    bool dequeueCalled = false;
    bool heartbeatCalled = false;
    bool logsCalled = false;
    bool completeCalled = false;
    bool ackCalled = false;

    TaskQueueMessage mockMsg;
    mockMsg.messageId = "msg_1";
    mockMsg.receiptHandle = "receipt_xyz";
    mockMsg.buildId = "build_test_1";
    mockMsg.taskId = "task_test_1";
    mockMsg.nodeFingerprint = "fp_mock_123";
    mockMsg.taskNode.id = "task_test_1";
    mockMsg.taskNode.steps = [BuildStep("step", "mock", null, "echo done")];

    router.post("/api/v1/queue/dequeue", (HTTPServerRequest req, HTTPServerResponse res) {
        dequeueCalled = true;
        if (dequeueCalled && !ackCalled)
        {
            res.writeJsonBody([mockMsg]);
        }
        else
        {
            res.writeJsonBody(cast(TaskQueueMessage[])[]);
        }
    });

    router.post("/api/v1/queue/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        heartbeatCalled = true;
        res.writeJsonBody(["status": "heartbeat_extended"]);
    });

    router.post("/api/v1/builds/:build_id/tasks/:task_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        logsCalled = true;
        res.writeJsonBody(["status": "ok"]);
    });

    router.post("/api/v1/builds/:build_id/tasks/:task_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        completeCalled = true;
        auto result = deserializeJson!TaskExecutionResult(req.json);
        assert(result.status == TaskStatus.succeeded);
        res.writeJsonBody(["status": "recorded"]);
    });

    router.post("/api/v1/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
        ackCalled = true;
        assert(req.json["receipt_handle"].get!string == "receipt_xyz");
        res.writeJsonBody(["status": "acknowledged"]);
    });

    auto settings = new HTTPServerSettings();
    settings.port = 19188;
    settings.bindAddresses = ["127.0.0.1"];
    auto listener = listenHTTP(settings, router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = "http://127.0.0.1:19188";
    config.workerId = "test_worker_runner";
    config.workspaceDir = buildPath(testDir, "ws");
    config.storageDir = buildPath(testDir, "storage");
    config.maxTasksToProcess = 1;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;

    auto workerRunner = new HttpWorkerRunner(config);
    auto workerThread = new Thread({
        workerRunner.run();
    });
    workerThread.start();

    // Drive vibe event loop until worker thread completes
    while (workerThread.isRunning)
    {
        sleep(50.msecs);
    }
    workerThread.join();

    assert(workerRunner.tasksProcessed == 1);
    assert(dequeueCalled);
    assert(completeCalled);
    assert(ackCalled);
}

unittest
{
    import std.file : exists, rmdirRecurse, mkdirRecurse, write;
    import confector.core.plugin : PluginRegistry, Plugin;
    import confector.plugin_api : BuildStepSystem, StepExecutionContext, StepExecutionResult, PluginCategory, LogDelegate;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import vibe.core.core : runTask, sleep;
    import core.time : msecs;

    class MockMultiStepRunner : Plugin, BuildStepSystem
    {
        @property string name() const pure nothrow @safe { return "mock_multistep_runner"; }
        @property string versionString() const pure nothrow @safe { return "1.0.0"; }
        @property string description() const pure nothrow @safe { return "Mock Multistep Runner"; }
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.runner; }
        ConfigDefinition[] configDefinitions() const { return null; }
        @property string systemName() const pure nothrow @safe { return "mock-multistep-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecuteStep(in BuildStep step) const { return true; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            res.exitCode = 0;
            res.success = true;
            res.outputLines = ["Step finished"];
            if (context.logCallback !is null)
            {
                context.logCallback(step.script.length > 0 ? step.script : step.command);
            }
            return res;
        }
    }

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockMultiStepRunner());
    scope(exit) PluginRegistry.instance.unregisterPlugin("mock_multistep_runner");

    string testDir = "test_http_multistep_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Setup Multi-Step HTTP Control Plane
    auto router = new URLRouter();
    int dequeueCount = 0;
    string[] completedTasks;
    string[] acknowledgedReceipts;
    string[] streamedLogs;

    TaskQueueMessage msgStep1;
    msgStep1.messageId = "msg_step_1";
    msgStep1.receiptHandle = "receipt_step_1";
    msgStep1.buildId = "build_multistep_1";
    msgStep1.taskId = "task_step_1";
    msgStep1.nodeFingerprint = "fp_step_1";
    msgStep1.taskNode.id = "task_step_1";
    msgStep1.taskNode.steps = [BuildStep("step1", "mock", null, "echo step 1 finished")];

    TaskQueueMessage msgStep2;
    msgStep2.messageId = "msg_step_2";
    msgStep2.receiptHandle = "receipt_step_2";
    msgStep2.buildId = "build_multistep_1";
    msgStep2.taskId = "task_step_2";
    msgStep2.nodeFingerprint = "fp_step_2";
    msgStep2.taskNode.id = "task_step_2";
    msgStep2.taskNode.steps = [BuildStep("step2", "mock", null, "echo step 2 finished")];

    router.post("/api/v1/queue/dequeue", (HTTPServerRequest req, HTTPServerResponse res) {
        dequeueCount++;
        if (completedTasks.length == 0)
        {
            res.writeJsonBody([msgStep1]);
        }
        else if (completedTasks.length == 1)
        {
            res.writeJsonBody([msgStep2]);
        }
        else
        {
            res.writeJsonBody(cast(TaskQueueMessage[])[]);
        }
    });

    router.post("/api/v1/queue/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeJsonBody(["status": "heartbeat_extended"]);
    });

    router.post("/api/v1/builds/:build_id/tasks/:task_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        if ("lines" in req.json)
        {
            foreach (line; req.json["lines"])
            {
                streamedLogs ~= line.get!string;
            }
        }
        res.writeJsonBody(["status": "ok"]);
    });

    router.post("/api/v1/builds/:build_id/tasks/:task_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        string tId = req.params["task_id"];
        completedTasks ~= tId;
        auto result = deserializeJson!TaskExecutionResult(req.json);
        assert(result.status == TaskStatus.succeeded);
        res.writeJsonBody(["status": "recorded"]);
    });

    router.post("/api/v1/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
        acknowledgedReceipts ~= req.json["receipt_handle"].get!string;
        res.writeJsonBody(["status": "acknowledged"]);
    });

    auto settings = new HTTPServerSettings();
    settings.port = 19189;
    settings.bindAddresses = ["127.0.0.1"];
    auto listener = listenHTTP(settings, router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = "http://127.0.0.1:19189";
    config.workerId = "test_multistep_worker";
    config.workspaceDir = buildPath(testDir, "ws");
    config.storageDir = buildPath(testDir, "storage");
    config.maxTasksToProcess = 2; // Process both chained steps
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;

    auto workerRunner = new HttpWorkerRunner(config);
    auto workerThread = new Thread({
        workerRunner.run();
    });
    workerThread.start();

    // Drive vibe event loop until worker thread completes
    while (workerThread.isRunning)
    {
        sleep(50.msecs);
    }
    workerThread.join();

    assert(workerRunner.tasksProcessed == 2);
    assert(completedTasks.length == 2);
    assert(completedTasks[0] == "task_step_1");
    assert(completedTasks[1] == "task_step_2");
    assert(acknowledgedReceipts.length == 2);
    assert(acknowledgedReceipts[0] == "receipt_step_1");
    assert(acknowledgedReceipts[1] == "receipt_step_2");
    assert(streamedLogs.length > 0);
}
