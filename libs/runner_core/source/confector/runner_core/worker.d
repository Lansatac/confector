module confector.runner_core.worker;

import confector.api.model;
import confector.core.work_orders : ClaimedWork, LeaseAnswer, maxLeaseDuration;
import confector.core.worker_pool_credential : requireWorkerPoolCredential, workerPoolCredentialHeader;
import confector.core.worker_token : workerTokenHeader;
import confector.runner_core.task_executor;
import confector.runner_core.http_artifact_storage;
import confector.runner_core.logging;
import confector.runner_core.steps.process : warnIfStopCannotBeSent;
import confector.runner_core.steps.step : StepRunner;

import vibe.data.json : Json, serializeToJson, deserializeJson, serializeToJsonString, parseJsonString;

import std.net.curl : HTTP;
import std.file : exists, mkdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;
import std.format : format;
import std.stdio : writeln;
import std.algorithm.searching : canFind;
import std.typecons : Nullable, nullable;
import core.atomic : atomicLoad, atomicStore;
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
    /// The server rejected it for good: the execution already finished or a later attempt holds
    /// it (409), the completion is invalid (400, 422), the execution does not exist (404), or the
    /// worker token does not allow it (401, 403). Reporting it again would be rejected the same way.
    rejected,
    /// It did not reach the server, or the server failed (5xx, or any other status). The server did
    /// not record it, so the worker may report it again. If the worker gives up, the lease expires,
    /// which requeues the execution as an infrastructure failure counted against the attempt limit.
    notRecorded
}

/// The longest wait between two reports of a completion the server did not record, in seconds.
enum size_t completionRetryBackoffCapSeconds = 60;

/**
 * Configuration options for the HTTP-based remote worker daemon.
 */
struct HttpWorkerConfig
{
    string serverUrl = "http://localhost:8080";
    string workerId = "";
    string workspaceDir = "";
    size_t pollIntervalSeconds = 2;
    /// How long the server holds an execution for this worker without a heartbeat.
    size_t leaseSeconds = 60;
    size_t heartbeatIntervalSeconds = 15;
    size_t maxTasksToProcess = 0; // 0 = continuous loop
    bool verbose = false;
    /// The worker pool credential the server admits this worker's receives with. Required: the
    /// client refuses to start without one of at least 32 bytes.
    string workerPoolCredential = "";
    /// How many times the worker reports a completion the server did not record before it gives
    /// up. Reports are spaced by the backoff below, while the worker still holds the execution.
    size_t completionAttempts = 5;
    /// The wait before the first repeated completion report, doubled before each further one up to
    /// `completionRetryBackoffCapSeconds`.
    size_t completionRetryBackoffSeconds = 2;
}

/**
 * Throws, naming the setting, unless the lease is from 1 second to the server's longest lease
 * and the heartbeat interval is at least 1 second and shorter than the lease: otherwise the
 * server would expire every execution this worker holds, or refuse its requests.
 */
void requireUsableLease(in HttpWorkerConfig config)
{
    const longest = maxLeaseDuration.total!"seconds";
    if (config.leaseSeconds < 1 || config.leaseSeconds > longest)
    {
        throw new Exception(format("The lease of %s seconds is outside 1 to %s seconds", config.leaseSeconds, longest));
    }
    if (config.heartbeatIntervalSeconds < 1 || config.heartbeatIntervalSeconds >= config.leaseSeconds)
    {
        throw new Exception(format("The heartbeat interval of %s seconds must be at least 1 and shorter than the lease of %s seconds",
            config.heartbeatIntervalSeconds, config.leaseSeconds));
    }
}

/**
 * Throws, naming the setting, unless the worker reports a completion at least once: with no
 * attempts a finished execution would never be reported.
 */
void requireUsableCompletionAttempts(in HttpWorkerConfig config)
{
    if (config.completionAttempts < 1)
    {
        throw new Exception("The completion attempts must be at least 1, or a finished execution is never reported");
    }
}

/// Longest a control-plane request may take to connect, and in all. A server that stops answering
/// fails the request, so the worker retries or gives the execution back instead of waiting forever.
enum controlConnectTimeout = 10.seconds;
enum controlRequestTimeout = 60.seconds;

/// The start of a server's answer, for an error message: a long answer is cut short.
private string prefixOf(string text) pure nothrow @safe
{
    enum shownLength = 200;
    return text.length > shownLength ? text[0 .. shownLength] ~ "..." : text;
}

/**
 * HTTP client for worker-to-server control plane protocol.
 * Handles receiving work orders, heartbeats, log streaming, and completion reporting.
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
        http.connectTimeout = controlConnectTimeout;
        http.operationTimeout = controlRequestTimeout;

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

        // 204 has no body: it is how the server says no work is queued
        if (http.statusLine.code == 204) return Json.emptyObject;
        if (http.statusLine.code >= 200 && http.statusLine.code < 300)
        {
            const text = responseData.idup;
            try return parseJsonString(text);
            catch (Exception e)
            {
                throw new Exception(format("Server request to '%s' answered HTTP %d with a body that is not JSON (%s): %s",
                    fullUrl, http.statusLine.code, e.msg, prefixOf(text)));
            }
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
     * Asks the server for one execution to run, held for `leaseSeconds` until the first heartbeat.
     * Returns its work order, which carries the execution's worker token, and the attempt the
     * worker must present from then on; null if nothing is queued.
     */
    Nullable!ClaimedWork receiveWork(size_t leaseSeconds)
    {
        Json req = Json.emptyObject;
        req["lease_seconds"] = Json(leaseSeconds);
        req["worker_id"] = Json(m_workerId);

        Json res = sendJson("/queue/receive", "POST", req, "", m_workerPoolCredential);
        if (res.type != Json.Type.object)
        {
            throw new Exception(format("Server returned %s from /queue/receive, not a work order", res.toString()));
        }
        if (res.length == 0) return Nullable!ClaimedWork.init;
        return ClaimedWork(deserializeJson!WorkOrder(res["work_order"]), res["attempt"].get!ulong).nullable;
    }

    /// Extends the lease of attempt `attempt` of execution `executionId` by `leaseSeconds`, with
    /// the execution's `workerToken`, and returns the server's answer: continue, cancel or
    /// superseded. Throws if the server cannot be reached or refuses the request.
    LeaseAnswer heartbeat(string executionId, ulong attempt, size_t leaseSeconds, string workerToken)
    {
        Json req = Json.emptyObject;
        req["attempt"] = Json(attempt);
        req["lease_seconds"] = Json(leaseSeconds);
        req["worker_id"] = Json(m_workerId);
        return answerOf(sendJson(format("/executions/%s/heartbeat", executionId), "POST", req, workerToken));
    }

    private static LeaseAnswer answerOf(in Json response)
    {
        if (response.type != Json.Type.object || "answer" !in response)
        {
            throw new Exception(format("Server answered %s, which holds no answer", response.toString()));
        }
        return deserializeJson!LeaseAnswer(response["answer"]);
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
            // The token of an execution does not change while it is held, so 401 and 403 would refuse
            // the same report again
            const permanent = e.statusCode == 400 || e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404
                || e.statusCode == 409 || e.statusCode == 422;
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
 * Runner loop handling work order receipt, execution via TaskExecutor, heartbeats,
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
    private shared bool m_stopRequested = false;
    private bool m_running = false;
    private size_t m_tasksProcessed = 0;

    /// Throws: Exception if `steps` is null or the lease and heartbeat interval cannot work
    /// (see `requireUsableLease`), or the completion attempts are zero (see
    /// `requireUsableCompletionAttempts`).
    this(in HttpWorkerConfig config, StepRunner steps, HttpWorkerClient client = null)
    {
        if (steps is null) throw new Exception("A worker needs a step runner");
        requireUsableLease(config);
        requireUsableCompletionAttempts(config);
        this.m_config = config;
        this.m_steps = steps;
        this.m_client = client !is null ? client : new HttpWorkerClient(config.serverUrl, config.workerId, config.workerPoolCredential);
    }

    @property const(HttpWorkerConfig) config() const pure nothrow @safe { return m_config; }
    @property HttpWorkerClient client() { return m_client; }
    @property size_t tasksProcessed() const pure nothrow @safe { return m_tasksProcessed; }
    @property bool isRunning() const pure nothrow @safe { return m_running; }

    /// Asks the loop in `run` to return after its current iteration. Safe to call from another thread.
    void requestStop() nothrow @safe
    {
        atomicStore(m_stopRequested, true);
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

    /// Runs the work order `work` holds, heartbeating while it runs, and reports its completion
    /// with the attempt the order was claimed as. Returns the task's result.
    TaskExecutionResult processOneMessage(in ClaimedWork work)
    {
        const WorkOrder msg = work.workOrder;
        if (msg.executionId.length == 0)
        {
            // Its completion could not name what it completes: refuse it before running anything
            throw new Exception(format("Work order for task '%s' names no execution; it cannot be run or completed",
                msg.taskNode.id));
        }
        if (msg.workerToken.length == 0)
        {
            // Every call to the server needs it: refuse before running anything
            throw new Exception(format("Work order for execution '%s' carries no worker token; it cannot be run",
                msg.executionId));
        }
        const string executionId = msg.executionId;
        const string workerToken = msg.workerToken;
        const string taskId = msg.taskNode.id;
        string taskWsDir = buildPath(m_config.workspaceDir, executionId);
        if (!exists(taskWsDir))
        {
            mkdirRecurse(taskWsDir);
        }

        const ulong attempt = work.attempt;
        logInfo("[worker] Processing task '%s' for execution '%s' (attempt %s)", taskId, executionId, attempt);

        // Heartbeat periodic timer. The server answers whether the worker still holds the
        // execution; once it says otherwise, the worker has lost it.
        Thread heartbeatThread;
        shared bool heartbeatRunning = false;
        shared bool lostExecution = false;
        {
            atomicStore(heartbeatRunning, true);
            size_t intervalSec = m_config.heartbeatIntervalSeconds;
            size_t leaseSeconds = m_config.leaseSeconds;
            heartbeatThread = new Thread({
                while (atomicLoad(heartbeatRunning))
                {
                    Thread.sleep(intervalSec.seconds);
                    if (!atomicLoad(heartbeatRunning)) break;
                    try
                    {
                        const answer = m_client.heartbeat(executionId, attempt, leaseSeconds, workerToken);
                        if (answer != LeaseAnswer.continue_)
                        {
                            atomicStore(lostExecution, true);
                            logWarn("[worker] The server answered %s to the heartbeat of execution '%s' (attempt %s)",
                                cast(string) answer, executionId, attempt);
                        }
                    }
                    catch (Exception e)
                    {
                        // A missed heartbeat is not a lost execution: the next one may get through
                        logWarn("[worker] Heartbeat of execution '%s' failed: %s", executionId, e.msg);
                    }
                }
            });
            heartbeatThread.isDaemon = true;
            heartbeatThread.start();
        }
        scope(exit)
        {
            atomicStore(heartbeatRunning, false);
            heartbeatThread.join();
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
        // order's; the worker never computes one. The timeout is the work order's too: the
        // executor stops the task at it, inside the lifetime of the token it was issued with.
        TaskExecutionResult result;
        try
        {
            result = m_executor.executeTask(
                executionId,
                taskNode,
                taskWsDir,
                msg.fingerprint,
                msg.timeoutSeconds.seconds,
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
        result.attempt = attempt;
        if (atomicLoad(lostExecution))
        {
            logError("[worker] Not reporting task '%s' (execution '%s'): the server no longer holds attempt %s for this worker",
                taskId, msg.executionId, attempt);
        }
        else final switch (reportCompletionWithRetries(msg.executionId, result, workerToken, () => !atomicLoad(lostExecution)))
        {
            case CompletionReport.recorded:
            case CompletionReport.rejected:
                // A rejection is permanent: running the task again would only be rejected again
                break;
            case CompletionReport.notRecorded:
                // Giving up leaves the lease to expire, which requeues the execution as an infrastructure
                // failure counted against the attempt limit
                logError("[worker] Completion of task '%s' (execution '%s') was not recorded after the worker gave up reporting it; "
                    ~ "its lease will expire and requeue it as an infrastructure failure", taskId, msg.executionId);
                break;
        }

        m_tasksProcessed++;
        return result;
    }

    /**
     * Reports the completion of `executionId`. While the server does not record it (`notRecorded`),
     * waits and reports it again, for at most `completionAttempts` reports in all. The wait starts at
     * `completionRetryBackoffSeconds` and doubles, up to `completionRetryBackoffCapSeconds`. Stops at
     * once on a report the server rejects, and when `stillHeld` says the worker no longer holds the
     * execution, checked again after each wait so a lost lease seen by the heartbeat stops the retries.
     * Returns the last report.
     */
    private CompletionReport reportCompletionWithRetries(string executionId, in TaskExecutionResult result, string workerToken,
        bool delegate() stillHeld)
    {
        import std.algorithm.comparison : min;
        size_t backoff = min(m_config.completionRetryBackoffSeconds, completionRetryBackoffCapSeconds);
        CompletionReport report = CompletionReport.notRecorded;
        foreach (reports; 1 .. m_config.completionAttempts + 1)
        {
            report = m_client.reportCompletion(executionId, result, workerToken);
            if (report != CompletionReport.notRecorded || reports == m_config.completionAttempts)
            {
                return report;
            }
            logWarn("[worker] Reporting the completion of execution '%s' again in %s seconds (report %s of %s)",
                executionId, backoff, reports + 1, m_config.completionAttempts);
            Thread.sleep(backoff.seconds);
            if (!stillHeld())
            {
                logError("[worker] The worker lost execution '%s' while its completion was unrecorded; not reporting it again",
                    executionId);
                return report;
            }
            // Doubling stops at the cap, so no backoff overflows
            backoff = backoff > completionRetryBackoffCapSeconds / 2 ? completionRetryBackoffCapSeconds : backoff * 2;
        }
        return report;
    }

    void run()
    {
        initialize();
        m_running = true;
        scope(exit) m_running = false;

        logInfo("[worker] Remote worker '%s' started, polling server '%s'...", m_client.workerId, m_client.serverUrl);
        warnIfStopCannotBeSent();

        while (!atomicLoad(m_stopRequested))
        {
            try
            {
                auto work = m_client.receiveWork(m_config.leaseSeconds);
                if (work.isNull)
                {
                    if (m_config.maxTasksToProcess > 0 && m_tasksProcessed >= m_config.maxTasksToProcess)
                    {
                        break;
                    }
                    Thread.sleep(m_config.pollIntervalSeconds.seconds);
                    continue;
                }

                processOneMessage(work.get);

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

    /// The /queue/receive response handing out a work order claimed as attempt `attempt`.
    private Json testWork(ulong attempt, WorkOrder order)
    {
        Json work = Json.emptyObject;
        work["attempt"] = Json(attempt);
        work["work_order"] = serializeToJson(order);
        return work;
    }

    import vibe.http.server : HTTPServerResponse;
    import confector.testing.threads : freePort, loopbackServerSettings, runOffThread;

    /// Answers a /queue/receive with nothing queued.
    private void answerNoWork(HTTPServerResponse res)
    {
        res.statusCode = 204;
        res.writeVoidBody();
    }
}


version (unittest)
{
    import confector.runner_core.steps.step : StepContext, StepResult, StopLimits;

    /// A step runner for tests: each line of a step's `command` config is one line of its
    /// output. A step whose command is "fail" fails with exit code 4, and one whose command is
    /// "sleep" takes a few seconds. A command of "sleep process" runs a process that outlasts the
    /// task's deadline. Counts the steps it runs; it is
    /// passed to the worker explicitly, so the worker's thread sees it.
    private final class ScriptedStepRunner : StepRunner
    {
        size_t stepsRun;

        StepResult run(in BuildStep step, ref StepContext context)
        {
            import std.process : environment;
            import std.string : splitLines;
            import confector.runner_core.steps.process : runProcess;
            import confector.testing.processes : shellArgs, sleepingCommand;

            ++stepsRun;
            StepResult result;
            const command = step.config["command"].get!string;
            if (command == "sleep")
            {
                // Long enough for a heartbeat to go out
                Thread.sleep(2500.msecs);
                return result;
            }
            if (command == "sleep process")
            {
                // Throws StepTimeoutException once the task's deadline passes
                runProcess(shellArgs(sleepingCommand), context.workingDirectory, environment.toAA, context.deadline,
                    StopLimits(1.seconds, 5.seconds, 5.seconds), context.log);
                return result;
            }
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
}

unittest
{
    // The worker protocol against a mock control plane: receive a work order, run the task with
    // the step runner it was given, stream its logs, heartbeat, report its completion with the
    // attempt it was given.
    // Handlers only record what they see; the test asserts after the worker is done, on this
    // thread, so a wrong value fails the test.
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;

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

    // Settings that can never work stop the worker at startup, naming the setting
    import std.exception : collectException;
    foreach (timing; [[0, 0], [60, 0], [60, 60], [60, 61], [12 * 3600 + 1, 15]])
    {
        const lease = timing[0], heartbeat = timing[1];
        HttpWorkerConfig unusable;
        unusable.leaseSeconds = lease;
        unusable.heartbeatIntervalSeconds = heartbeat;
        unusable.workerPoolCredential = testWorkerPoolCredential;
        auto failure = collectException(new HttpWorkerDaemon(unusable, new ScriptedStepRunner()));
        assert(failure !is null && (failure.msg.canFind("lease") || failure.msg.canFind("heartbeat")),
            format("lease %s, heartbeat %s was accepted", lease, heartbeat));
    }
    HttpWorkerConfig usable;
    usable.leaseSeconds = 12 * 3600;
    usable.heartbeatIntervalSeconds = 1;
    usable.workerPoolCredential = testWorkerPoolCredential;
    new HttpWorkerDaemon(usable, new ScriptedStepRunner());

    // A worker that reports a completion at least once: zero attempts would never report one
    HttpWorkerConfig noCompletionAttempts = usable;
    noCompletionAttempts.completionAttempts = 0;
    assertThrown!Exception(new HttpWorkerDaemon(noCompletionAttempts, new ScriptedStepRunner()));

    const port = freePort();
    auto router = new URLRouter();
    // A redirect from the server is not followed, so a credential never goes to its target
    router.post("/api/v1/queue/receive-redirect", (HTTPServerRequest req, HTTPServerResponse res) {
        res.statusCode = 302;
        res.headers["Location"] = format("http://127.0.0.1:%d/api/v1/queue/receive", port);
        res.writeVoidBody();
    });
    bool dequeueCalled = false;
    string[] loggedExecutions;
    string[] completedExecutions;
    TaskExecutionResult[] reported;
    bool[] reportedFingerprint;
    string[] heartbeatExecutions;
    long[] heartbeatAttempts;
    string heartbeatAnswer = "continue";
    Json[] receiveRequests;
    // The answers the next completion reports get, in order: an HTTP status, or 0 to record it.
    // Once they run out, reports are recorded.
    int[] completionAnswers;
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
    Json mockWork = testWork(1, mockOrder);

    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        dequeueCalled = true;
        receivePoolCredentials ~= req.headers.get(workerPoolCredentialHeader, "");
        receiveRequests ~= req.json;
        if (completedExecutions.length == 0) res.writeJsonBody(mockWork);
        else answerNoWork(res);
    });
    router.post("/api/v1/executions/:execution_id/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        recordToken(req);
        heartbeatExecutions ~= req.params["execution_id"];
        heartbeatAttempts ~= req.json["attempt"].get!long;
        res.writeJsonBody(["answer": heartbeatAnswer]);
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
        if (completionAnswers.length > 0)
        {
            const answer = completionAnswers[0];
            completionAnswers = completionAnswers[1 .. $];
            if (answer != 0)
            {
                res.statusCode = answer;
                res.writeJsonBody(["error": format("Completion of 'exe_mock_1' answered with HTTP %s", answer)]);
                return;
            }
        }
        res.writeJsonBody(["status": "recorded"]);
    });
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = format("http://127.0.0.1:%d", port);
    config.workerId = "test_worker_runner";
    config.workspaceDir = buildPath(testDir, "ws");
    config.maxTasksToProcess = 1;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;
    // Three reports in all, with no wait between them, so a retry that gives up is quick to see
    config.completionAttempts = 3;
    config.completionRetryBackoffSeconds = 0;

    // A redirect answer is a failed request with its status, and the credential is not sent to
    // the location it names: the receive route the redirect points at is never reached
    const receivesBeforeRedirect = receivePoolCredentials.length;
    auto probe = new HttpWorkerClient(config.serverUrl, "test_worker_1", testWorkerPoolCredential);
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
    runOffThread({ workerRunner.run(); }, { workerRunner.requestStop(); });

    assert(workerRunner.tasksProcessed == 1);
    assert(dequeueCalled);
    // Only receiving work presents the pool credential; the execution routes never do
    assert(receivePoolCredentials.length >= 1);
    foreach (presented; receivePoolCredentials) assert(presented == testWorkerPoolCredential, "Receive presented '" ~ presented ~ "'");
    assert(otherPoolCredentials.length >= 2);
    foreach (presented; otherPoolCredentials) assert(presented.length == 0, "A non-receive route presented the pool credential");
    assert(steps.stepsRun == 1, "The worker ran the task's step with the step runner it was given");
    assert(completedExecutions == ["exe_mock_1"], "The completion names the work order's execution");
    assert(reported.length == 1 && reported[0].status == ExecutionStatus.succeeded, format("Reported %s", reported));
    assert(reported[0].taskId == "task_test_1" && reported[0].exitCode == 0 && reported[0].errorMessage.length == 0);
    assert(reportedFingerprint == [false], "The completion carries no fingerprint");
    assert(receiveRequests[0]["worker_id"].get!string == "test_worker_runner" && receiveRequests[0]["lease_seconds"].get!long == 60,
        "Receiving names the worker and the lease it asks for");
    assert(reported[0].attempt == 1, "The completion carries the attempt the work order was claimed as");
    assert(loggedExecutions.length > 0);
    foreach (logged; loggedExecutions) assert(logged == "exe_mock_1", logged);

    // Logs, completion and heartbeats all present the work order's token
    assert(presentedTokens.length >= 2);
    foreach (presented; presentedTokens) assert(presented == "token_exe_mock_1", "Presented '" ~ presented ~ "'");

    // The workspace is the execution's own directory
    assert(exists(buildPath(config.workspaceDir, "exe_mock_1")));

    // A completion the server does not record (5xx) is reported again, after its backoff, until the
    // server records it
    auto work = ClaimedWork(mockOrder, 1);
    completionAnswers = [500, 503];
    reported = null;
    runOffThread({ workerRunner.processOneMessage(work); });
    assert(reported.length == 3, format("Two refusals, then a record: reported %s times", reported.length));
    assert(reported[2].status == ExecutionStatus.succeeded, format("The third report: %s", reported[2].status));

    // With the server refusing every report, the worker gives up after completionAttempts (3) reports
    completionAnswers = [500, 500, 500, 500];
    reported = null;
    runOffThread({ workerRunner.processOneMessage(work); });
    assert(reported.length == 3, format("Gave up after %s reports", reported.length));

    // A report the server rejects for good ends the retries: the attempt was superseded in the meantime
    completionAnswers = [500, 409];
    reported = null;
    runOffThread({ workerRunner.processOneMessage(work); });
    assert(reported.length == 2, format("A rejected retry is the last report: %s reports", reported.length));

    // A heartbeat that answers superseded while a completion waits to be reported again stops the
    // retries: the worker no longer holds the execution. The backoff is long enough for a heartbeat
    // to come in between two reports
    HttpWorkerConfig lostConfig = config;
    lostConfig.completionAttempts = 5;
    lostConfig.completionRetryBackoffSeconds = 2;
    auto lostRunner = new HttpWorkerDaemon(lostConfig, steps);
    completionAnswers = [500, 500, 500, 500, 500];
    heartbeatAnswer = "superseded";
    reported = null;
    runOffThread({ lostRunner.initialize(); lostRunner.processOneMessage(work); });
    heartbeatAnswer = "continue";
    completionAnswers = null;
    assert(reported.length == 1, format("A lost lease stops the retries after one report: %s reports", reported.length));

    // A report rejected for good is not repeated: a duplicate or late completion (409), an invalid
    // one (400, 422), or one the token does not allow (401, 403)
    foreach (status; [400, 401, 403, 409, 422])
    {
        completionAnswers = [status];
        reported = null;
        runOffThread({ workerRunner.processOneMessage(work); });
        assert(reported.length == 1, format("HTTP %s: reported %s times", status, reported.length));
    }
    completionAnswers = null;

    // A heartbeat the server answers superseded (or cancel) means the worker lost the execution:
    // its result is not reported, since the server would reject it
    foreach (answered; ["superseded", "cancel"])
    {
        heartbeatAnswer = answered;
        heartbeatExecutions = null;
        reported = null;
        WorkOrder slow = mockOrder;
        slow.taskNode.steps = [scriptedStep("Slow", "sleep")];
        runOffThread({ workerRunner.processOneMessage(ClaimedWork(slow, 1)); });
        assert(heartbeatExecutions.length > 0 && heartbeatExecutions[0] == "exe_mock_1", answered);
        assert(reported.length == 0, "A lost execution is not reported: " ~ answered);
    }
    heartbeatAnswer = "continue";

    // A failing step is reported as a failed task, with its exit code and error
    WorkOrder failing = mockOrder;
    failing.executionId = "exe_failing";
    failing.workerToken = "token_exe_failing";
    failing.taskNode.steps = [scriptedStep("Fail", "fail"), scriptedStep("Never", "never runs")];
    reported = null;
    steps.stepsRun = 0;
    runOffThread({ workerRunner.processOneMessage(ClaimedWork(failing, 1)); });
    assert(reported.length == 1 && reported[0].status == ExecutionStatus.failed, format("Reported %s", reported));
    assert(reported[0].exitCode == 4 && reported[0].errorMessage == "The scripted step failed", reported[0].errorMessage);
    assert(steps.stepsRun == 1, "Steps after a failed one do not run");

    // A work order naming no execution is refused before anything runs: its completion could
    // not say what it completes
    reported = null;
    WorkOrder anonymous = mockOrder;
    anonymous.executionId = null;
    string refusal;
    try runOffThread({ workerRunner.processOneMessage(ClaimedWork(anonymous, 1)); });
    catch (Exception e) refusal = e.msg;
    assert(refusal.canFind("names no execution"), refusal);
    assert(reported.length == 0);

    // So is one without a token: the server would refuse every call it made
    WorkOrder untokened = mockOrder;
    untokened.workerToken = null;
    refusal = null;
    try runOffThread({ workerRunner.processOneMessage(ClaimedWork(untokened, 1)); });
    catch (Exception e) refusal = e.msg;
    assert(refusal.canFind("no worker token"), refusal);
    assert(reported.length == 0);
}

unittest
{
    // With the runner's built-in steps, a step type that is not built in fails the task and a
    // built-in that is not implemented yet fails it loudly; both are reported.
    // The server does not store log lines yet and answers 501: the worker only warns, and still
    // reports each execution
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import confector.runner_core.steps.builtin : BuiltinStepRunner;

    string testDir = "test_http_worker_builtin";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto router = new URLRouter();
    TaskExecutionResult[string] reported;
    size_t logUploads;
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        ++logUploads;
        res.statusCode = 501;
        res.writeJsonBody(["error": "Build logs are not implemented"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        reported[req.params["execution_id"]] = deserializeJson!TaskExecutionResult(req.json);
        res.writeJsonBody(["status": "recorded"]);
    });

    const port = freePort();
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = format("http://127.0.0.1:%d", port);
    config.workerId = "test_builtin_worker";
    config.workspaceDir = buildPath(testDir, "ws");
    config.heartbeatIntervalSeconds = 1;
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
        auto work = ClaimedWork(order, 1);
        runOffThread({ worker.initialize(); worker.processOneMessage(work); });
    }
    assert(reported["exe_unknown"].status == ExecutionStatus.failed);
    assert(reported["exe_unknown"].errorMessage.canFind("is not supported"), reported["exe_unknown"].errorMessage);
    foreach (execution; ["exe_bash", "exe_powershell"])
    {
        assert(reported[execution].status == ExecutionStatus.failed, execution);
        assert(reported[execution].errorMessage.canFind("Built-in bash/PowerShell step is not implemented yet"), reported[execution].errorMessage);
    }
    assert(logUploads > 0, "The worker tried to upload its log lines");
}

unittest
{
    // Two work orders in a row: every line a task's steps log reaches its execution's log, in
    // order, before its completion
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.array : join;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;

    string testDir = "test_http_multistep_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto router = new URLRouter();
    string[] completedExecutions;
    ExecutionStatus[string] reportedStatus;
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
    Json msgStep1 = testWork(1, orderStep1);

    WorkOrder orderStep2;
    orderStep2.executionId = "exe_step_2";
    orderStep2.workerToken = "token_step_2";
    orderStep2.fingerprint = "fp_step_2";
    orderStep2.taskNode.id = "task_step_2";
    orderStep2.taskNode.steps = [scriptedStep("step2a", "second task line 1"), scriptedStep("step2b", "second task line 2")];
    Json msgStep2 = testWork(1, orderStep2);

    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        if (completedExecutions.length == 0) res.writeJsonBody(msgStep1);
        else if (completedExecutions.length == 1) res.writeJsonBody(msgStep2);
        else answerNoWork(res);
    });
    router.post("/api/v1/executions/:execution_id/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeJsonBody(["answer": "continue"]);
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

    const port = freePort();
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = format("http://127.0.0.1:%d", port);
    config.workerId = "test_multistep_worker";
    config.workspaceDir = buildPath(testDir, "ws");
    config.maxTasksToProcess = 2;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;

    auto workerRunner = new HttpWorkerDaemon(config, new ScriptedStepRunner());
    runOffThread({ workerRunner.run(); }, { workerRunner.requestStop(); });

    assert(workerRunner.tasksProcessed == 2);
    assert(completedExecutions == ["exe_step_1", "exe_step_2"]);
    assert(reportedStatus == ["exe_step_1": ExecutionStatus.succeeded, "exe_step_2": ExecutionStatus.succeeded], format("Reported %s", reportedStatus));
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
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;

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

    auto listener = listenHTTP(loopbackServerSettings(port), router);
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
    foreach (status; [401, 403, 409])
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

unittest
{
    // A runner runs a task end to end against the in-memory backends: the control plane's routes
    // are backed by the core's claim, heartbeat and completion over the state stores in
    // an in-memory document store. The runner claims the queued execution, runs its steps,
    // heartbeats, and its completion records the execution and folds it into the ledger. A second
    // runner finds nothing queued, and a late completion of the finished execution is refused.
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import confector.core.fingerprint_ledger : ClaimOutcome;
    import confector.core.state_stores : StateStores;
    import confector.core.work_orders : StaleCompletionException, claimWork, completeExecution, heartbeatExecution;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    string testDir = "test_http_worker_end_to_end";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto stores = new StateStores(new InMemoryDocumentStore());
    TaskNode build;
    build.id = "build";
    build.steps = [scriptedStep("Build", "building"), scriptedStep("Package", "packaging")];
    ActiveExecution queued;
    queued.projectId = "game";
    queued.taskId = "build";
    queued.definitionId = stores.definitions.put(ProjectDefinition([build]));
    queued.createdAt = "2026-10-16T10:00:00Z";
    const claimed = stores.ledgers.claim("fp_e2e", 0, queued);
    assert(claimed.outcome == ClaimOutcome.won);

    import core.time : seconds;

    auto router = new URLRouter();
    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        auto work = claimWork(stores, req.json["worker_id"].get!string, req.json["lease_seconds"].get!long.seconds);
        if (work.isNull) return answerNoWork(res);
        work.get.workOrder.workerToken = "token_" ~ work.get.workOrder.executionId;
        res.writeJsonBody(testWork(work.get.attempt, work.get.workOrder));
    });
    router.post("/api/v1/executions/:execution_id/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        const answer = heartbeatExecution(stores, "fp_e2e", req.params["execution_id"], req.json["attempt"].get!ulong,
            req.json["lease_seconds"].get!long.seconds);
        res.writeJsonBody(["answer": cast(string) answer]);
    });
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeJsonBody(["status": "ok"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            completeExecution(stores, "fp_e2e", req.params["execution_id"], deserializeJson!TaskExecutionResult(req.json));
            res.writeJsonBody(["status": "recorded"]);
        }
        catch (StaleCompletionException e)
        {
            res.statusCode = 409;
            res.writeJsonBody(["error": e.msg]);
        }
    });

    const port = freePort();
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = format("http://127.0.0.1:%d", port);
    config.workerId = "runner_one";
    config.workspaceDir = buildPath(testDir, "ws");
    config.maxTasksToProcess = 1;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;

    auto steps = new ScriptedStepRunner();
    auto runner = new HttpWorkerDaemon(config, steps);
    runOffThread({ runner.run(); }, { runner.requestStop(); });

    assert(runner.tasksProcessed == 1 && steps.stepsRun == 2);
    auto finished = stores.executions.get(claimed.executionId).get;
    assert(finished.status == ExecutionStatus.succeeded && finished.attempts == 1 && finished.worker == "runner_one");
    assert(finished.exitCode == 0 && finished.finishedAt.length > 0);
    auto ledger = stores.ledgers.get("fp_e2e").get;
    assert(ledger.active.isNull && ledger.lastSuccessExecutionId == claimed.executionId, "The outcome was folded");

    // Nothing is queued any more: a second runner finds no work and the finished execution is left alone
    assert(claimWork(stores, "runner_two", 60.seconds).isNull);
    bool rejected = false;
    try
    {
        TaskExecutionResult late;
        late.status = ExecutionStatus.failed;
        late.attempt = 1;
        completeExecution(stores, "fp_e2e", claimed.executionId, late);
    }
    catch (StaleCompletionException e) rejected = true;
    assert(rejected && stores.executions.get(claimed.executionId).get.status == ExecutionStatus.succeeded);
}

unittest
{
    // The mock control plane's listeners never share a port: a port another listener holds fails
    // the bind, so a worker cannot be answered by a different server. The other listener is a
    // socket with address reuse, as another process's listener would be. This proves the fix only
    // on Windows: Linux refuses any second bind on the port regardless of reuse
    import std.exception : assertThrown;
    import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;
    import vibe.http.router : URLRouter;
    import vibe.http.server : listenHTTP;

    const port = freePort();
    auto other = new TcpSocket();
    scope(exit) other.close();
    other.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    other.bind(new InternetAddress("127.0.0.1", port));
    other.listen(1);

    assertThrown(listenHTTP(loopbackServerSettings(port), new URLRouter()));
}

unittest
{
    // A 2xx answer must be JSON. 204 is the only answer without a body, and it is how the server
    // says no work is queued. Any other body is not the control plane's answer: it fails loudly
    // rather than reading as no work
    import std.exception : collectException;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;

    const port = freePort();
    auto router = new URLRouter();
    router.post("/api/v1/answers/text", (HTTPServerRequest req, HTTPServerResponse res) {
        res.statusCode = 200;
        res.writeBody("not json at all");
    });
    router.post("/api/v1/answers/empty", (HTTPServerRequest req, HTTPServerResponse res) {
        res.statusCode = 200;
        res.writeVoidBody();
    });
    router.post("/api/v1/answers/none", (HTTPServerRequest req, HTTPServerResponse res) {
        answerNoWork(res);
    });
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    auto client = new HttpWorkerClient(format("http://127.0.0.1:%d", port), "test_answers", testWorkerPoolCredential);
    string textFailure;
    string emptyFailure;
    Json none;
    runOffThread({
        textFailure = collectException(client.sendJson("/answers/text")).msg;
        emptyFailure = collectException(client.sendJson("/answers/empty")).msg;
        none = client.sendJson("/answers/none");
    });
    assert(textFailure.canFind("/api/v1/answers/text") && textFailure.canFind("HTTP 200") && textFailure.canFind("not json at all"),
        textFailure);
    assert(emptyFailure.canFind("/api/v1/answers/empty") && emptyFailure.canFind("not JSON"), emptyFailure);
    assert(none.type == Json.Type.object && none.length == 0, "204 is no work");
}

unittest
{
    // A task that runs past its work order's timeout is stopped and its execution is recorded as
    // failed, with the timeout as its error. The control plane does not requeue it: a failed task is
    // retried only when a user asks, so no other runner is handed it
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerRequest, HTTPServerResponse, listenHTTP;
    import confector.core.state_stores : StateStores;
    import confector.core.work_orders : StaleCompletionException, claimWork, completeExecution, heartbeatExecution;
    import confector.core.fingerprint_ledger : ClaimOutcome;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import core.time : seconds;

    string testDir = "test_http_worker_timeout";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto stores = new StateStores(new InMemoryDocumentStore());
    TaskNode slow;
    slow.id = "slow";
    slow.timeoutSeconds = 3;
    slow.steps = [scriptedStep("Wait", "sleep process")];
    ActiveExecution queued;
    queued.projectId = "game";
    queued.taskId = "slow";
    queued.definitionId = stores.definitions.put(ProjectDefinition([slow]));
    queued.createdAt = "2026-10-16T10:00:00Z";
    const claimed = stores.ledgers.claim("fp_timeout", 0, queued);
    assert(claimed.outcome == ClaimOutcome.won);

    auto router = new URLRouter();
    router.post("/api/v1/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        auto work = claimWork(stores, req.json["worker_id"].get!string, req.json["lease_seconds"].get!long.seconds);
        if (work.isNull) return answerNoWork(res);
        work.get.workOrder.workerToken = "token_" ~ work.get.workOrder.executionId;
        res.writeJsonBody(testWork(work.get.attempt, work.get.workOrder));
    });
    router.post("/api/v1/executions/:execution_id/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        const answer = heartbeatExecution(stores, "fp_timeout", req.params["execution_id"], req.json["attempt"].get!ulong,
            req.json["lease_seconds"].get!long.seconds);
        res.writeJsonBody(["answer": cast(string) answer]);
    });
    router.post("/api/v1/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeJsonBody(["status": "ok"]);
    });
    router.post("/api/v1/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            completeExecution(stores, "fp_timeout", req.params["execution_id"], deserializeJson!TaskExecutionResult(req.json));
            res.writeJsonBody(["status": "recorded"]);
        }
        catch (StaleCompletionException e)
        {
            res.statusCode = 409;
            res.writeJsonBody(["error": e.msg]);
        }
    });

    const port = freePort();
    auto listener = listenHTTP(loopbackServerSettings(port), router);
    scope(exit) listener.stopListening();

    HttpWorkerConfig config;
    config.serverUrl = format("http://127.0.0.1:%d", port);
    config.workerId = "runner_timeout";
    config.workspaceDir = buildPath(testDir, "ws");
    config.maxTasksToProcess = 1;
    config.pollIntervalSeconds = 1;
    config.heartbeatIntervalSeconds = 1;
    config.workerPoolCredential = testWorkerPoolCredential;

    auto runner = new HttpWorkerDaemon(config, new ScriptedStepRunner());
    runOffThread({ runner.run(); }, { runner.requestStop(); });

    assert(runner.tasksProcessed == 1);
    auto finished = stores.executions.get(claimed.executionId).get;
    assert(finished.status == ExecutionStatus.failed, format("Recorded %s", finished.status));
    assert(finished.errorMessage.canFind("'slow' timed out after 3 seconds"), finished.errorMessage);
    assert(finished.attempts == 1, "A timed-out task is not claimed again");
    assert(stores.ledgers.get("fp_timeout").get.active.isNull, "The failure is folded, not left active");
    assert(claimWork(stores, "runner_other", 60.seconds).isNull, "Nothing is queued for another runner");
}
