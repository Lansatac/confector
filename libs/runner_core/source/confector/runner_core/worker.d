module confector.runner_core.worker;

import confector.api.model;
import confector.api.dispatch_queue : Lease;
import confector.core.worker_pool_credential : requireWorkerPoolCredential, workerPoolCredentialHeader;
import confector.core.worker_token : workerTokenHeader;
import confector.runner_core.task_executor;
import confector.runner_core.http_artifact_storage;
import confector.runner_core.logging;
import confector.runner_core.steps.step : StepRunner;

import vibe.data.json : Json, serializeToJson, deserializeJson, serializeToJsonString, parseJsonString;

import std.net.curl : HTTP;
import std.file : exists, mkdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.format : format;
import std.stdio : writeln;
import std.algorithm.searching : canFind;
import core.thread : Thread;
import core.time : Duration, seconds, msecs;

/**
 * The server answered a request with a status other than 2xx. `statusCode` is that status.
 */
class ServerResponseException : Exception
{
    const ushort statusCode;

    this(ushort statusCode, string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.statusCode = statusCode;
    }
}

/**
 * What became of a reported completion.
 */
enum CompletionReport
{
    /// The server recorded it.
    recorded,
    /// The server rejected it for good: the execution already finished (409), the completion is
    /// invalid (400, 422), or the execution does not exist (404). Running the work order again
    /// would be rejected the same way, so its lease is acknowledged.
    rejected,
    /// It did not reach the server, or the server failed (5xx, or any other status): the lease is
    /// left unacknowledged so the work order is delivered again.
    notRecorded
}

/**
 * Configuration options for the HTTP-based remote worker daemon.
 */
struct HttpWorkerConfig
{
    string serverUrl = "http://localhost:8080";
    string workerId = "";
    string workspaceDir = "";
    size_t pollIntervalSeconds = 2;
    size_t visibilityTimeoutSeconds = 60;
    size_t heartbeatIntervalSeconds = 15;
    size_t maxTasksToProcess = 0; // 0 = continuous loop
    bool verbose = false;
    /// The worker pool credential the server admits this worker's receives with. Required: the
    /// client refuses to start without one of at least 32 bytes.
    string workerPoolCredential = "";
}

/**
 * HTTP client for worker-to-server control plane protocol.
 * Handles receiving work orders, lease extensions, log streaming, and completion reporting.
 */
class HttpWorkerClient
{
    private string m_serverUrl;
    private string m_workerId;
    private string m_workerPoolCredential;

    /// Throws if `workerPoolCredential` is too short to be the pool's credential.
    this(string serverUrl, string workerId, string workerPoolCredential)
    {
        requireWorkerPoolCredential(workerPoolCredential);
        this.m_serverUrl = normalizeBaseUrl(serverUrl);
        this.m_workerId = workerId.length > 0 ? workerId : "worker_" ~ randomUUID().toString()[0 .. 8];
        this.m_workerPoolCredential = workerPoolCredential;
    }

    @property string serverUrl() const pure nothrow @safe { return m_serverUrl; }
    @property string workerId() const pure nothrow @safe { return m_workerId; }

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

    /// Sends a request to the control plane. `workerToken`, the execution's token from its work
    /// order, is sent in the worker token header. `workerPoolCredential` is sent in the pool
    /// credential header, and only receiving work sends it; no other route is given it.
    Json sendJson(string endpointPath, string method = "POST", in Json bodyJson = Json.undefined, string workerToken = "",
        string workerPoolCredential = "")
    {
        string fullUrl = resolveEndpointUrl(endpointPath);
        auto http = HTTP(fullUrl);

        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("Accept", "application/json");
        if (m_workerId.length > 0)
        {
            http.addRequestHeader("X-Worker-ID", m_workerId);
        }
        if (workerToken.length > 0)
        {
            http.addRequestHeader(workerTokenHeader, workerToken);
        }
        if (workerPoolCredential.length > 0)
        {
            http.addRequestHeader(workerPoolCredentialHeader, workerPoolCredential);
        }
        // A credential is never sent to another location: a redirect is a failed request. Phobos
        // follows redirects up to maxRedirects, so uint.max is what turns following off
        if (workerToken.length > 0 || workerPoolCredential.length > 0)
        {
            http.maxRedirects = uint.max;
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
            throw new ServerResponseException(http.statusLine.code,
                format("Server request to '%s' failed (HTTP %d): %s", fullUrl, http.statusLine.code, errMsg));
        }
    }

    /**
     * Receives up to maxMessages work orders, leased for visibilityTimeout seconds. Each lease's
     * message is a WorkOrder in JSON.
     */
    Lease[] receiveWork(size_t maxMessages = 1, size_t visibilityTimeout = 30)
    {
        Json req = Json.emptyObject;
        req["max_messages"] = Json(maxMessages);
        req["visibility_timeout"] = Json(visibilityTimeout);
        req["worker_id"] = Json(m_workerId);

        Json res = sendJson("/queue/receive", "POST", req, "", m_workerPoolCredential);
        if (res.type != Json.Type.array)
        {
            throw new Exception(format("Server returned %s from /queue/receive, not an array of leases", res.toString()));
        }
        Lease[] leases;
        foreach (item; res)
        {
            leases ~= Lease(item["receipt"].get!string, item["receive_count"].get!uint, item["work_order"]);
        }
        return leases;
    }

    /// Extends the lease `receipt`, which `workerToken` (from the same work order) was issued with.
    bool extendLease(string receipt, string workerToken, size_t visibilityTimeout = 30)
    {
        if (receipt.length == 0) return false;
        try
        {
            Json req = Json.emptyObject;
            req["receipt"] = Json(receipt);
            req["visibility_timeout"] = Json(visibilityTimeout);
            req["worker_id"] = Json(m_workerId);
            sendJson("/queue/extend", "POST", req, workerToken);
            return true;
        }
        catch (Exception e)
        {
            logWarn("[HttpWorkerClient] Failed to extend lease for receipt '%s': %s", receipt, e.msg);
            return false;
        }
    }

    /// Acknowledges the lease `receipt`, which `workerToken` (from the same work order) was issued with.
    bool ackTask(string receipt, string workerToken)
    {
        if (receipt.length == 0) return false;
        try
        {
            Json req = Json.emptyObject;
            req["receipt"] = Json(receipt);
            req["worker_id"] = Json(m_workerId);
            sendJson("/queue/ack", "POST", req, workerToken);
            return true;
        }
        catch (Exception e)
        {
            logError("[HttpWorkerClient] Failed to acknowledge task receipt '%s': %s", receipt, e.msg);
            return false;
        }
    }

    /// Appends `lines` to execution `executionId`'s log, with the execution's `workerToken`.
    /// Returns false, logging why, if the server did not take them.
    bool streamLogs(string executionId, string[] lines, string workerToken)
    {
        if (lines.length == 0) return true;
        try
        {
            Json req = Json.emptyObject;
            req["lines"] = serializeToJson(lines);
            req["worker_id"] = Json(m_workerId);
            string endpoint = format("/executions/%s/logs", executionId);
            sendJson(endpoint, "POST", req, workerToken);
            return true;
        }
        catch (Exception e)
        {
            logWarn("[HttpWorkerClient] Failed to stream logs for execution '%s': %s", executionId, e.msg);
            return false;
        }
    }

    /// Reports the completion of execution `executionId` (`WorkOrder.executionId`), with the
    /// execution's `workerToken`. The result names no fingerprint: the server reads it from the
    /// execution. Logs why it was not recorded; see CompletionReport for which outcomes are permanent.
    CompletionReport reportCompletion(string executionId, in TaskExecutionResult result, string workerToken)
    {
        try
        {
            Json bodyJson = serializeToJson(result);
            string endpoint = format("/executions/%s/complete", executionId);
            sendJson(endpoint, "POST", bodyJson, workerToken);
            return CompletionReport.recorded;
        }
        catch (ServerResponseException e)
        {
            const permanent = e.statusCode == 400 || e.statusCode == 404 || e.statusCode == 409 || e.statusCode == 422;
            logError("[HttpWorkerClient] The server %s the completion of execution '%s' (task: %s): %s",
                permanent ? "rejected" : "did not record", executionId, result.taskId, e.msg);
            return permanent ? CompletionReport.rejected : CompletionReport.notRecorded;
        }
        catch (Exception e)
        {
            logError("[HttpWorkerClient] Failed to report the completion of execution '%s' (task: %s) to the server: %s",
                executionId, result.taskId, e.msg);
            return CompletionReport.notRecorded;
        }
    }
}

/**
 * Runner loop handling work order receipt, execution via TaskExecutor, lease extensions,
 * artifact packing/unpacking, and completion reporting over HTTP. Steps run with the
 * `StepRunner` it is given.
 */
class HttpWorkerDaemon
{
    private HttpWorkerConfig m_config;
    private HttpWorkerClient m_client;
    private StepRunner m_steps;
    private TaskExecutor m_executor;
    private HttpArtifactStorage m_storage;
    private bool m_stopRequested = false;
    private bool m_running = false;
    private size_t m_tasksProcessed = 0;

    /// Throws: Exception if `steps` is null.
    this(in HttpWorkerConfig config, StepRunner steps, HttpWorkerClient client = null)
    {
        if (steps is null) throw new Exception("A worker needs a step runner");
        this.m_config = config;
        this.m_steps = steps;
        this.m_client = client !is null ? client : new HttpWorkerClient(config.serverUrl, config.workerId, config.workerPoolCredential);
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

        // Use HttpArtifactStorage so the worker communicates with the server for all
        // artifact operations. The server decides whether to use presigned URLs or proxy.
        m_storage = new HttpArtifactStorage(m_config.serverUrl);
        m_executor = new TaskExecutor(m_storage, m_steps);
    }

    TaskExecutionResult processOneMessage(in Lease lease)
    {
        const WorkOrder msg = deserializeJson!WorkOrder(lease.message);
        if (msg.executionId.length == 0)
        {
            // Its completion could not name what it completes: refuse it before running anything
            throw new Exception(format("Work order for task '%s' (receipt '%s') names no execution; it cannot be run or completed",
                msg.taskNode.id, lease.receipt));
        }
        if (msg.workerToken.length == 0)
        {
            // Every call to the server needs it: refuse before running anything
            throw new Exception(format("Work order for execution '%s' (receipt '%s') carries no worker token; it cannot be run",
                msg.executionId, lease.receipt));
        }
        const string executionId = msg.executionId;
        const string workerToken = msg.workerToken;
        const string taskId = msg.taskNode.id;
        string taskWsDir = buildPath(m_config.workspaceDir, executionId);
        if (!exists(taskWsDir))
        {
            mkdirRecurse(taskWsDir);
        }

        logInfo("[worker] Processing task '%s' for execution '%s' (receipt: %s)", taskId, executionId, lease.receipt);

        // Heartbeat periodic timer
        Thread heartbeatThread;
        bool heartbeatRunning = false;
        if (lease.receipt.length > 0 && m_config.heartbeatIntervalSeconds > 0)
        {
            heartbeatRunning = true;
            string handle = lease.receipt;
            size_t intervalSec = m_config.heartbeatIntervalSeconds;
            size_t visTimeout = m_config.visibilityTimeoutSeconds;
            heartbeatThread = new Thread({
                while (heartbeatRunning)
                {
                    Thread.sleep(intervalSec.seconds);
                    if (!heartbeatRunning) break;
                    if (m_client !is null && handle.length > 0)
                    {
                        m_client.extendLease(handle, workerToken, visTimeout);
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

        // The artifact routes accept only this execution's token
        m_storage.workerToken = workerToken;
        scope(exit) m_storage.workerToken = "";

        // The task's steps, environment and declared outputs come from its definition
        TaskNode taskNode = deserializeJson!TaskNode(serializeToJson(msg.taskNode));

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
                m_client.streamLogs(executionId, flushLines, workerToken);
            }
        }

        // The work order's resolved inputs drive everything input-related: task_output inputs
        // name the upstream artifacts to stage (from the upstream fingerprint they pin), and the
        // checkout step checks repository inputs out by name. The fingerprint is the work
        // order's; the worker never computes one.
        TaskExecutionResult result;
        try
        {
            result = m_executor.executeTask(
                executionId,
                taskNode,
                taskWsDir,
                msg.fingerprint,
                msg.payload.inputs,
                msg.payload.repositoryAddresses,
                &onLogLine
            );
        }
        catch (Exception e)
        {
            result.taskId = taskId;
            result.status = ExecutionStatus.failed;
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
            m_client.streamLogs(executionId, finalLogs, workerToken);
        }

        // Report the execution's completion over HTTP, after its last log lines (flushed above),
        // since the server refuses log lines for a finished execution
        final switch (m_client.reportCompletion(msg.executionId, result, workerToken))
        {
            case CompletionReport.recorded:
            case CompletionReport.rejected:
                // A rejection is permanent: delivering the work order again would only run the
                // task again and be rejected again
                if (lease.receipt.length > 0) m_client.ackTask(lease.receipt, workerToken);
                break;
            case CompletionReport.notRecorded:
                // Not acknowledged: the lease expires and the work order is delivered again,
                // rather than the work order disappearing with its completion never recorded.
                logError("[worker] Completion of task '%s' (execution '%s') was not recorded; leaving receipt '%s' unacknowledged so it is delivered again",
                    taskId, msg.executionId, lease.receipt);
                break;
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
                auto messages = m_client.receiveWork(1, m_config.visibilityTimeoutSeconds);
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

version (unittest)
{
    private enum testWorkerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";

    /// The /queue/receive response holding one lease on a work order.
    private Json testLeases(string receipt, WorkOrder order)
    {
        Json lease = Json.emptyObject;
        lease["receipt"] = Json(receipt);
        lease["receive_count"] = Json(1);
        lease["work_order"] = serializeToJson(order);
        return Json([lease]);
    }
}


version (unittest)
{
    import confector.runner_core.steps.step : StepContext, StepResult;

    /// A step runner for tests: each line of a step's `command` config is one line of its
    /// output. A step whose command is "fail" fails with exit code 4. Counts the steps it runs; it is
    /// passed to the worker explicitly, so the worker's thread sees it.
    private final class ScriptedStepRunner : StepRunner
    {
        size_t stepsRun;

        StepResult run(in BuildStep step, ref StepContext context)
        {
            import std.string : splitLines;

            ++stepsRun;
            StepResult result;
            const command = step.config["command"].get!string;
            if (command == "fail")
            {
                context.log("scripted failure");
                result.success = false;
                result.exitCode = 4;
                result.errorMessage = "The scripted step failed";
                return result;
            }
            foreach (line; command.splitLines) context.log(line);
            return result;
        }
    }

    private BuildStep scriptedStep(string name, string command)
    {
        return BuildStep(name, "scripted", Json(["command": Json(command)]));
    }

    /// A TCP port nothing listens on at the moment, for a test server.
    private ushort freePort()
    {
        import std.socket : InternetAddress, Socket, TcpSocket;

        auto probe = new TcpSocket();
        scope(exit) probe.close();
        probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        return (cast(InternetAddress) probe.localAddress).port;
    }

    /// Runs `work` on a thread of its own while this thread's event loop serves the mock
    /// control plane, and returns once it is done. Rethrows what `work` threw.
    private void runOffThread(void delegate() work)
    {
        import vibe.core.core : sleep;
        import core.time : msecs;

        Throwable thrown;
        auto thread = new Thread({
            try work();
            catch (Throwable t) thrown = t;
        });
        thread.start();
        while (thread.isRunning) sleep(10.msecs);
        thread.join();
        if (thrown !is null) throw thrown;
    }
}

unittest
{
    // The worker protocol against a mock control plane: receive a lease, run the task with the
    // step runner it was given, stream its logs, report its completion, acknowledge the lease.
    // Handlers only record what they see; the test asserts after the worker is done, on this
    // thread, so a wrong value fails the test.
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;

    string testDir = "test_http_worker_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto client = new HttpWorkerClient("http://127.0.0.1:9099", "test_worker_1", testWorkerPoolCredential);
    assert(client.resolveEndpointUrl("/queue/receive") == "http://127.0.0.1:9099/api/v1/queue/receive");
    assert(client.resolveEndpointUrl("/api/v1/queue/receive") == "http://127.0.0.1:9099/api/v1/queue/receive");
    auto clientApiV1 = new HttpWorkerClient("http://127.0.0.1:9099/api/v1", "test_worker_1", testWorkerPoolCredential);
    assert(clientApiV1.resolveEndpointUrl("/queue/receive") == "http://127.0.0.1:9099/api/v1/queue/receive");

    // A runner without a usable worker pool credential does not start: it could never receive work
    import std.exception : assertThrown;
    assertThrown!Exception(new HttpWorkerClient("http://127.0.0.1:9099", "test_worker_1", ""));
    assertThrown!Exception(new HttpWorkerClient("http://127.0.0.1:9099", "test_worker_1", "too-short"));
    HttpWorkerConfig unconfigured;
    unconfigured.serverUrl = "http://127.0.0.1:9099";
    assertThrown!Exception(new HttpWorkerDaemon(unconfigured, new ScriptedStepRunner()));

    auto router = new URLRouter();
    // A redirect from the server is not followed, so a credential never goes to its target
    router.post("/api/v1/queue/receive-redirect", (HTTPServerRequest req, HTTPServerResponse res) {
        res.statusCode = 302;
        res.headers["Location"] = "http://127.0.0.1:19188/api/v1/queue/receive";
        res.writeVoidBody();
    });
    bool dequeueCalled = false;
    string[] loggedExecutions;
    string[] completedExecutions;
    TaskExecutionResult[] reported;
    bool[] reportedFingerprint;
    string[] ackedReceipts;
    int rejectCompletion = 0;
    string[] presentedTokens;
    string[] receivePoolCredentials;
    string[] otherPoolCredentials;
    void recordToken(HTTPServerRequest req)
    {
        presentedTokens ~= req.headers.get(workerTokenHeader, "");
        otherPoolCredentials ~= req.headers.get(workerPoolCredentialHeader, "");
    }

    WorkOrder mockOrder;
    mockOrder.executionId = "exe_mock_1";
    mockOrder.workerToken = "token_exe_mock_1";
    mockOrder.fingerprint = "fp_mock_123";
    mockOrder.taskNode.id = "task_test_1";
    mockOrder.taskNode.steps = [scriptedStep("step", "Mock step execution finished successfully")];
    Json mockLeases = testLeases("receipt_xyz", mockOrder);

    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        dequeueCalled = true;
        receivePoolCredentials ~= req.headers.get(workerPoolCredentialHeader, "");
        res.writeJsonBody(ackedReceipts.length == 0 ? mockLeases : Json.emptyArray);
    });
    router.post("/api/v1/queue/extend", (HTTPServerRequest req, HTTPServerResponse res) {
        recordToken(req);
        res.writeJsonBody(["status": "heartbeat_extended"]);
    });
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        recordToken(req);
        loggedExecutions ~= req.params["execution_id"];
        res.writeJsonBody(["status": "ok"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        recordToken(req);
        completedExecutions ~= req.params["execution_id"];
        reportedFingerprint ~= ("fingerprint" in req.json) !is null;
        reported ~= deserializeJson!TaskExecutionResult(req.json);
        if (rejectCompletion != 0)
        {
            res.statusCode = rejectCompletion;
            res.writeJsonBody(["error": format("Completion of 'exe_mock_1' answered with HTTP %s", rejectCompletion)]);
            return;
        }
        res.writeJsonBody(["status": "recorded"]);
    });
    router.post("/api/v1/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
        recordToken(req);
        ackedReceipts ~= req.json["receipt"].get!string;
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
    config.maxTasksToProcess = 1;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;

    // A redirect answer is a failed request with its status, and the credential is not sent to
    // the location it names: the receive route the redirect points at is never reached
    const receivesBeforeRedirect = receivePoolCredentials.length;
    auto probe = new HttpWorkerClient("http://127.0.0.1:19188", "test_worker_1", testWorkerPoolCredential);
    int redirectStatus = 0;
    runOffThread({
        try
        {
            probe.sendJson("/queue/receive-redirect", "POST", Json.emptyObject, "", testWorkerPoolCredential);
        }
        catch (ServerResponseException e)
        {
            redirectStatus = e.statusCode;
        }
    });
    assert(redirectStatus == 302, format("A redirect answered %s", redirectStatus));
    assert(receivePoolCredentials.length == receivesBeforeRedirect, "The credential was followed to the redirect target");

    auto steps = new ScriptedStepRunner();
    auto workerRunner = new HttpWorkerDaemon(config, steps);
    runOffThread({ workerRunner.run(); });

    assert(workerRunner.tasksProcessed == 1);
    assert(dequeueCalled);
    // Only receiving work presents the pool credential; the execution routes never do
    assert(receivePoolCredentials.length >= 1);
    foreach (presented; receivePoolCredentials) assert(presented == testWorkerPoolCredential, "Receive presented '" ~ presented ~ "'");
    assert(otherPoolCredentials.length >= 3);
    foreach (presented; otherPoolCredentials) assert(presented.length == 0, "A non-receive route presented the pool credential");
    assert(steps.stepsRun == 1, "The worker ran the task's step with the step runner it was given");
    assert(completedExecutions == ["exe_mock_1"], "The completion names the work order's execution");
    assert(reported.length == 1 && reported[0].status == ExecutionStatus.succeeded, format("Reported %s", reported));
    assert(reported[0].taskId == "task_test_1" && reported[0].exitCode == 0 && reported[0].errorMessage.length == 0);
    assert(reportedFingerprint == [false], "The completion carries no fingerprint");
    assert(ackedReceipts == ["receipt_xyz"]);
    assert(loggedExecutions.length > 0);
    foreach (logged; loggedExecutions) assert(logged == "exe_mock_1", logged);

    // Logs, completion and acknowledgement all present the work order's token
    assert(presentedTokens.length >= 3);
    foreach (presented; presentedTokens) assert(presented == "token_exe_mock_1", "Presented '" ~ presented ~ "'");

    // The workspace is the execution's own directory
    assert(exists(buildPath(config.workspaceDir, "exe_mock_1")));

    // A completion the server failed to record (5xx) leaves the lease unacknowledged, so the work
    // order is delivered again instead of disappearing. One the server rejected for good (a
    // duplicate or late completion, 409; an invalid one, 422) is acknowledged: running the work
    // order again would only be rejected again
    auto lease = Lease("receipt_xyz", 1, serializeToJson(mockOrder));
    foreach (status, acked; [500: false, 503: false, 409: true, 422: true])
    {
        rejectCompletion = status;
        ackedReceipts = null;
        reported = null;
        runOffThread({ workerRunner.processOneMessage(lease); });
        assert(reported.length == 1 && reported[0].status == ExecutionStatus.succeeded, format("HTTP %s: reported %s", status, reported));
        string[] expectedAcks;
        if (acked) expectedAcks = ["receipt_xyz"];
        assert(ackedReceipts == expectedAcks, format("HTTP %s: acknowledged %s", status, ackedReceipts));
    }
    rejectCompletion = 0;

    // A failing step is reported as a failed task, with its exit code and error
    WorkOrder failing = mockOrder;
    failing.executionId = "exe_failing";
    failing.workerToken = "token_exe_failing";
    failing.taskNode.steps = [scriptedStep("Fail", "fail"), scriptedStep("Never", "never runs")];
    reported = null;
    ackedReceipts = null;
    steps.stepsRun = 0;
    auto failingLease = Lease("receipt_failing", 1, serializeToJson(failing));
    runOffThread({ workerRunner.processOneMessage(failingLease); });
    assert(reported.length == 1 && reported[0].status == ExecutionStatus.failed, format("Reported %s", reported));
    assert(reported[0].exitCode == 4 && reported[0].errorMessage == "The scripted step failed", reported[0].errorMessage);
    assert(steps.stepsRun == 1, "Steps after a failed one do not run");
    assert(ackedReceipts == ["receipt_failing"]);

    // A work order naming no execution is refused before anything runs: its completion could
    // not say what it completes
    reported = null;
    ackedReceipts = null;
    WorkOrder anonymous = mockOrder;
    anonymous.executionId = null;
    auto anonymousLease = Lease("receipt_anon", 1, serializeToJson(anonymous));
    string refusal;
    try runOffThread({ workerRunner.processOneMessage(anonymousLease); });
    catch (Exception e) refusal = e.msg;
    assert(refusal.canFind("names no execution"), refusal);
    assert(reported.length == 0 && ackedReceipts.length == 0);

    // So is one without a token: the server would refuse every call it made
    WorkOrder untokened = mockOrder;
    untokened.workerToken = null;
    auto untokenedLease = Lease("receipt_untokened", 1, serializeToJson(untokened));
    refusal = null;
    try runOffThread({ workerRunner.processOneMessage(untokenedLease); });
    catch (Exception e) refusal = e.msg;
    assert(refusal.canFind("no worker token"), refusal);
    assert(reported.length == 0 && ackedReceipts.length == 0);
}

unittest
{
    // With the runner's built-in steps, a step type that is not built in fails the task and a
    // built-in that is not implemented yet fails it loudly; both are reported, naming the bead.
    // The server does not store log lines yet (bead confector-z7z.31.12) and answers 501: the
    // worker only warns, and still reports and acknowledges each execution
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import confector.runner_core.steps.builtin : BuiltinStepRunner;

    string testDir = "test_http_worker_builtin";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto router = new URLRouter();
    TaskExecutionResult[string] reported;
    string[] ackedReceipts;
    size_t logUploads;
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        ++logUploads;
        res.statusCode = 501;
        res.writeJsonBody(["error": "Build logs are not implemented", "bead": "confector-z7z.31.12"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        reported[req.params["execution_id"]] = deserializeJson!TaskExecutionResult(req.json);
        res.writeJsonBody(["status": "recorded"]);
    });
    router.post("/api/v1/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
        ackedReceipts ~= req.json["receipt"].get!string;
        res.writeJsonBody(["status": "acknowledged"]);
    });

    auto settings = new HTTPServerSettings();
    settings.port = 19190;
    settings.bindAddresses = ["127.0.0.1"];
    auto listener = listenHTTP(settings, router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = "http://127.0.0.1:19190";
    config.workerId = "test_builtin_worker";
    config.workspaceDir = buildPath(testDir, "ws");
    config.heartbeatIntervalSeconds = 0;
    config.workerPoolCredential = testWorkerPoolCredential;
    auto worker = new HttpWorkerDaemon(config, new BuiltinStepRunner());

    WorkOrder order;
    order.fingerprint = "fp_package";
    order.workerToken = "token_package";
    order.taskNode.id = "package";
    foreach (type, execution; ["docker:build": "exe_unknown", "bash": "exe_bash", "powershell": "exe_powershell"])
    {
        order.executionId = execution;
        BuildStep step;
        step.type = type;
        order.taskNode.steps = [step];
        auto lease = Lease("receipt_" ~ execution, 1, serializeToJson(order));
        runOffThread({ worker.initialize(); worker.processOneMessage(lease); });
    }
    assert(reported["exe_unknown"].status == ExecutionStatus.failed);
    assert(reported["exe_unknown"].errorMessage.canFind("confector-z7z.35.1"), reported["exe_unknown"].errorMessage);
    foreach (execution; ["exe_bash", "exe_powershell"])
    {
        assert(reported[execution].status == ExecutionStatus.failed, execution);
        assert(reported[execution].errorMessage.canFind("confector-z7z.35.6"), reported[execution].errorMessage);
    }
    // Each failure was recorded and its lease acknowledged, so the work order is not delivered
    // again only to fail the same way
    import std.algorithm.sorting : sort;
    assert(ackedReceipts.sort.release == ["receipt_exe_bash", "receipt_exe_powershell", "receipt_exe_unknown"], format("Acknowledged %s", ackedReceipts));
    assert(logUploads > 0, "The worker tried to upload its log lines");
}

unittest
{
    // Two work orders in a row: every line a task's steps log reaches its execution's log, in
    // order, before its completion
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.array : join;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;

    string testDir = "test_http_multistep_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto router = new URLRouter();
    string[] completedExecutions;
    ExecutionStatus[string] reportedStatus;
    string[] acknowledgedReceipts;
    string[][string] streamedByExecution;
    bool logAfterCompletion = false;

    // More lines than the worker sends in one batch, so batching and the final flush both count
    string[] firstLines;
    foreach (i; 1 .. 13) firstLines ~= format("first task line %s", i);

    WorkOrder orderStep1;
    orderStep1.executionId = "exe_step_1";
    orderStep1.workerToken = "token_step_1";
    orderStep1.fingerprint = "fp_step_1";
    orderStep1.taskNode.id = "task_step_1";
    orderStep1.taskNode.steps = [scriptedStep("step1", firstLines.join("\n"))];
    Json msgStep1 = testLeases("receipt_step_1", orderStep1);

    WorkOrder orderStep2;
    orderStep2.executionId = "exe_step_2";
    orderStep2.workerToken = "token_step_2";
    orderStep2.fingerprint = "fp_step_2";
    orderStep2.taskNode.id = "task_step_2";
    orderStep2.taskNode.steps = [scriptedStep("step2a", "second task line 1"), scriptedStep("step2b", "second task line 2")];
    Json msgStep2 = testLeases("receipt_step_2", orderStep2);

    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        if (completedExecutions.length == 0) res.writeJsonBody(msgStep1);
        else if (completedExecutions.length == 1) res.writeJsonBody(msgStep2);
        else res.writeJsonBody(Json.emptyArray);
    });
    router.post("/api/v1/queue/extend", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeJsonBody(["status": "heartbeat_extended"]);
    });
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        const execution = req.params["execution_id"];
        // The server refuses log lines for a finished execution: the worker must send its last
        // lines before its completion
        if (completedExecutions.canFind(execution)) logAfterCompletion = true;
        foreach (line; req.json["lines"]) streamedByExecution[execution] ~= line.get!string;
        res.writeJsonBody(["status": "ok"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        completedExecutions ~= req.params["execution_id"];
        reportedStatus[req.params["execution_id"]] = deserializeJson!TaskExecutionResult(req.json).status;
        res.writeJsonBody(["status": "recorded"]);
    });
    router.post("/api/v1/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
        acknowledgedReceipts ~= req.json["receipt"].get!string;
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
    config.maxTasksToProcess = 2;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;

    auto workerRunner = new HttpWorkerDaemon(config, new ScriptedStepRunner());
    runOffThread({ workerRunner.run(); });

    assert(workerRunner.tasksProcessed == 2);
    assert(completedExecutions == ["exe_step_1", "exe_step_2"]);
    assert(reportedStatus == ["exe_step_1": ExecutionStatus.succeeded, "exe_step_2": ExecutionStatus.succeeded], format("Reported %s", reportedStatus));
    assert(acknowledgedReceipts == ["receipt_step_1", "receipt_step_2"]);
    assert(streamedByExecution.length == 2, format("Logs went to %s", streamedByExecution.keys));
    assert(!logAfterCompletion, "A log batch was sent after the completion");

    // Each execution's log holds its steps' lines in order (among the runner's own lines)
    string[][string] expectedLines = ["exe_step_1": firstLines, "exe_step_2": ["second task line 1", "second task line 2"]];
    foreach (execution, expected; expectedLines)
    {
        auto streamed = streamedByExecution[execution];
        size_t next = 0;
        foreach (line; streamed)
        {
            if (next < expected.length && line == expected[next]) ++next;
        }
        assert(next == expected.length, format("%s: streamed %s, expected %s in order", execution, streamed, expected));
    }
}

unittest
{
    // The artifact storage sends the execution's token to the server, never to a presigned URL
    // (which belongs to the storage backend), and refuses to talk to the server without one. A
    // 401 or 403 is an authorization error, not a missing artifact and not a cue to try another route.
    import std.exception : collectException;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerSettings, HTTPServerRequest, HTTPServerResponse, listenHTTP;

    const port = freePort();
    const serverUrl = format("http://127.0.0.1:%d", port);
    string[string] presented;
    int refuseWith = 0;
    size_t proxyUploads;
    auto router = new URLRouter();
    router.get("/api/v1/artifacts/presign-upload", (HTTPServerRequest req, HTTPServerResponse res) {
        presented["presign-upload"] = req.headers.get(workerTokenHeader, "");
        if (refuseWith != 0)
        {
            res.statusCode = refuseWith;
            return res.writeJsonBody(["error": "refused"]);
        }
        res.writeJsonBody(["uploadUrl": serverUrl ~ "/backend/upload"]);
    });
    router.put("/backend/upload", (HTTPServerRequest req, HTTPServerResponse res) {
        presented["backend"] = req.headers.get(workerTokenHeader, "none");
        res.writeJsonBody(["status": "ok"]);
    });
    router.post("/api/v1/artifacts/:fingerprint/:artifactId/upload", (HTTPServerRequest req, HTTPServerResponse res) {
        ++proxyUploads;
        res.writeJsonBody(["status": "ok"]);
    });
    router.get("/api/v1/artifacts/presign-download", (HTTPServerRequest req, HTTPServerResponse res) {
        presented["presign-download"] = req.headers.get(workerTokenHeader, "");
        if (refuseWith != 0)
        {
            res.statusCode = refuseWith;
            return res.writeJsonBody(["error": "refused"]);
        }
        res.writeJsonBody(Json.emptyObject);
    });
    router.get("/api/v1/artifacts/:fingerprint/:artifactId/download", (HTTPServerRequest req, HTTPServerResponse res) {
        presented["download"] = req.headers.get(workerTokenHeader, "");
        res.writeBody("bytes");
    });
    router.get("/api/v1/artifacts/_head/:fingerprint/:artifactId", (HTTPServerRequest req, HTTPServerResponse res) {
        presented["head"] = req.headers.get(workerTokenHeader, "");
        res.statusCode = refuseWith != 0 ? refuseWith : 200;
        res.writeVoidBody();
    });

    auto settings = new HTTPServerSettings();
    settings.port = port;
    settings.bindAddresses = ["127.0.0.1"];
    auto listener = listenHTTP(settings, router);
    scope(exit) listener.stopListening();

    auto storage = new HttpArtifactStorage(serverUrl);
    string failure;
    bool exists;
    string downloaded;
    string deleteFailure;
    runOffThread({
        failure = collectException(storage.storeArtifactStream("fp", "art", (void delegate(const(ubyte)[]) sink) {
            sink(cast(const(ubyte)[]) "x");
        })).msg;
        storage.workerToken = "token_exe_1";
        storage.storeArtifactStream("fp", "art", (void delegate(const(ubyte)[]) sink) { sink(cast(const(ubyte)[]) "x"); });
        storage.retrieveArtifactStream("fp", "art", (const(ubyte)[] chunk) { downloaded ~= cast(string) chunk; });
        exists = storage.artifactExists("fp", "art");
        deleteFailure = collectException(storage.deleteArtifact("fp", "art")).msg;
    });
    assert(failure.canFind("No worker token"), failure);
    assert(presented["presign-upload"] == "token_exe_1" && presented["presign-download"] == "token_exe_1");
    assert(presented["download"] == "token_exe_1" && presented["head"] == "token_exe_1");
    assert(presented["backend"] == "none", "The token must not reach the storage backend");
    assert(downloaded == "bytes" && exists);
    assert(deleteFailure.canFind("cannot delete"), deleteFailure);

    // A refusal throws an authorization error from every call: no "missing artifact", and no
    // silent fallback to the proxy upload
    foreach (status; [401, 403])
    {
        refuseWith = status;
        proxyUploads = 0;
        Exception[] refusals;
        runOffThread({
            refusals ~= collectException(storage.artifactExists("fp", "art"));
            refusals ~= collectException(storage.presignUpload("fp", "art"));
            refusals ~= collectException(storage.presignDownload("fp", "art"));
            refusals ~= collectException(storage.storeArtifactStream("fp", "art", (void delegate(const(ubyte)[]) sink) {
                sink(cast(const(ubyte)[]) "x");
            }));
        });
        assert(refusals.length == 4);
        foreach (refusal; refusals)
        {
            auto refused = cast(ArtifactAuthException) refusal;
            assert(refused !is null && refused.statusCode == status, format("HTTP %d: %s", status, refusal));
        }
        assert(proxyUploads == 0, "A refused presign must not fall back to the proxy route");
    }
}
