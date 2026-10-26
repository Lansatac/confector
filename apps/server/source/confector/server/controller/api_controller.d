module confector.server.controller.api_controller;

import vibe.vibe;
import confector.api.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
import confector.core.intake : IntakeException, IntakeFailure, IntakeRequest, IntakeResult, RequestIntake;
import confector.core.not_implemented : NotImplementedException;
import confector.core.state_stores : StateStores;
import confector.core.worker_token : WorkerTokenClaims, mintWorkerToken, requireCurrentAttempt, requireExecution, requireSigningKey,
    workerTokenClaimsFor;
import core.time : Duration;
import confector.core.worker_pool_credential : requireWorkerPoolCredential;
import confector.server.scheduler_callback : schedulerCallback;
import confector.server.worker_auth : authenticateWorker, authenticateWorkerPool, permitWorker, requireCurrentExecutionAttempt;
import confector.server.authenticator : Authenticator;
import confector.server.route_access : AuthorizedRoutes, ExcludedBy;
import confector.core.sweep : sweepCoordination;
import confector.core.work_orders : InvalidLeaseRequestException, LeaseAnswer, UnknownExecutionException, claimWork, completeExecution,
    finishExecution, heartbeatExecution, leaseOfSeconds, releaseExecution, requireAttemptLimit, utcNow;

import std.format : format;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;

/**
 * Why the scheduler's route that starts builds fails: scheduled builds need trigger rules and
 * request intake from a schedule, which come after manual requests. The
 * route answers 501 Not Implemented with this exception's message.
 */
NotImplementedException scheduledBuildsNotImplemented()
{
    return new NotImplementedException("Scheduled builds");
}

/**
 * Why the build log routes fail: build logs live in the log store, which is not written yet. The
 * routes answer 501 Not Implemented with this exception's message; a worker only warns when its
 * log lines are refused.
 */
NotImplementedException logsNotImplemented()
{
    return new NotImplementedException("Build logs");
}

/// The answer to a request that was recorded.
private Json runAnswer(in IntakeResult result)
{
    Json answer = Json.emptyObject;
    answer["request_id"] = Json(result.requestId);
    answer["chain_id"] = Json(result.chainId);
    answer["chain_number"] = Json(result.chainNumber);
    return answer;
}

/**
 * Reads the body of a request to start a build (see the route's comment).
 *
 * Throws: IntakeException (invalid) if the body is not an object of the documented shape.
 */
IntakeRequest parseRunRequest(in Json body)
{
    void invalid(string message) { throw new IntakeException(IntakeFailure.invalid, message); }

    if (body.type != Json.Type.object) invalid("The body must be a JSON object");
    IntakeRequest request;
    bool hasProject;
    foreach (string key, value; body)
    {
        switch (key)
        {
            case "project_id":
                if (value.type != Json.Type.string) invalid("'project_id' must be a string");
                request.projectId = value.get!string;
                hasProject = true;
                break;
            case "targets":
                if (value.type != Json.Type.array) invalid("'targets' must be an array of task ids");
                foreach (target; value)
                {
                    if (target.type != Json.Type.string) invalid("'targets' must be an array of task ids");
                    request.targets ~= target.get!string;
                }
                break;
            case "intent":
                if (value.type != Json.Type.string) invalid("'intent' must be \"build\", \"retry\" or \"rerun\"");
                bool known;
                foreach (intent; [BuildIntent.build, BuildIntent.retry, BuildIntent.rerun])
                {
                    if (cast(string) intent == value.get!string)
                    {
                        request.intent = intent;
                        known = true;
                    }
                }
                if (!known) invalid("'intent' must be \"build\", \"retry\" or \"rerun\"");
                break;
            case "chain":
                if (value.type == Json.Type.string && value.get!string.length > 0) request.chainId = value.get!string;
                else if (value.type == Json.Type.int_ && value.get!long > 0) request.chainNumber = cast(ulong) value.get!long;
                else invalid("'chain' must be a chain id or a positive chain number");
                break;
            case "refs":
                if (value.type != Json.Type.object) invalid("'refs' must be an object of ref names by repository id");
                foreach (string repository, name; value)
                {
                    if (name.type != Json.Type.string) invalid("'refs' must be an object of ref names by repository id");
                    request.refs[repository] = name.get!string;
                }
                break;
            default:
                invalid(format("Unknown field '%s'", key));
        }
    }
    if (!hasProject) invalid("'project_id' is required");
    return request;
}

/**
 * The REST API, served under /api/v1. Every route is registered once, with the prefix and its access
 * (see confector.server.route_access); the route helpers take paths relative to it.
 *
 * Receiving work (/queue/receive) needs the worker pool credential, `workerPoolCredential`, which
 * is checked before anything else. Receiving mints the worker token of the execution it hands
 * out; the routes a worker calls once it holds a work order (heartbeat, release, logs,
 * completion) need that token, signed with `workerTokenKey`. Neither is reached by a user
 * identity.
 *
 * The worker and sweep routes read lease and sweep times from `now` (default `utcNow`), so that a
 * test can move time forward without sleeping. Worker tokens stay on the real clock: they are
 * issued and checked against it whatever `now` says.
 */
AuthorizedRoutes apiRouter(Authenticator authenticator, string schedulerCallbackSecret, string workerTokenKey, string workerPoolCredential,
    uint maxAttempts, StateStores stores = null, RequestIntake intake = null, string delegate() now = null)
{
    requireSigningKey(workerTokenKey);
    requireWorkerPoolCredential(workerPoolCredential);
    requireAttemptLimit(maxAttempts);
    auto router = new AuthorizedRoutes(authenticator);
    string delegate() clock = now !is null ? now : () => utcNow();

    enum string apiPrefix = "/api/v1";

    void postRoute(H)(string path, Role role, H handler)
    {
        router.post(apiPrefix ~ path, role, handler);
    }

    // Routes the scheduler calls back into. Each one requires the scheduler secret; see
    // scheduler_callback.d. Add every new scheduler callback through this helper.
    void schedulerRoute(H)(string path, H handler)
    {
        router.excluded(HTTPMethod.POST, apiPrefix ~ path, ExcludedBy.schedulerSecret,
            schedulerCallback(schedulerCallbackSecret, handler));
    }

    // Routes a worker calls with the token of its execution. Each one checks the token itself.
    void workerRoute(H)(HTTPMethod method, string path, H handler)
    {
        router.excluded(method, apiPrefix ~ path, ExcludedBy.workerToken, handler);
    }

    // The route that receives work. It checks the worker pool credential itself.
    void poolRoute(H)(string path, H handler)
    {
        router.excluded(HTTPMethod.POST, apiPrefix ~ path, ExcludedBy.workerPoolCredential, handler);
    }

    void getRoute(H)(string path, Role role, H handler)
    {
        router.get(apiPrefix ~ path, role, handler);
    }

    void deleteRoute(H)(string path, Role role, H handler)
    {
        router.delete_(apiPrefix ~ path, role, handler);
    }

    // A stub route answers 501 Not Implemented with the exception's message.
    void writeNotImplemented(HTTPServerResponse res, NotImplementedException e)
    {
        res.statusCode = HTTPStatus.notImplemented;
        Json err = Json.emptyObject;
        err["error"] = Json(e.msg);
        res.writeJsonBody(err);
    }

    // The routes that read or write executions need the state stores.
    bool requireStores(HTTPServerResponse res)
    {
        if (stores !is null) return true;
        res.statusCode = HTTPStatus.internalServerError;
        Json err = Json.emptyObject;
        err["error"] = Json("This route needs the state stores, which are not configured");
        res.writeJsonBody(err);
        return false;
    }

    // The worker routes answer with a status that tells a worker what to do: 400 for a malformed
    // request, 404 for an unknown execution, 409 for a report that came too late (the execution
    // already finished, or a later attempt holds it), 422 for a completion that can never be
    // recorded as reported, and 500 for anything else (a store failure), which the worker may
    // retry. A completion rejected with 409 or 422 would be rejected again, so it is not retried.
    void writeError(HTTPServerResponse res, HTTPStatus status, string message)
    {
        res.statusCode = status;
        Json err = Json.emptyObject;
        err["error"] = Json(message);
        res.writeJsonBody(err);
    }

    // Receiving work: the worker pool credential admits a worker, which asks for one execution to
    // run under a lease of `lease_seconds`. The control plane claims a queued execution for it
    // and answers with the attempt and the work order, which carries the execution's worker
    // token, or with 204 when nothing is queued. A claimed execution that cannot be given a token
    // is failed, with the reason, and the next one is claimed.
    poolRoute("/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
        if (!authenticateWorkerPool(workerPoolCredential, req, res)) return;
        if (!requireStores(res)) return;
        try
        {
            string workerId;
            Duration lease;
            try
            {
                auto pWorker = "worker_id" in req.json;
                auto pLease = "lease_seconds" in req.json;
                if (pLease is null)
                    throw new InvalidLeaseRequestException("Receiving work needs lease_seconds: how long the worker holds the work before its heartbeat");
                // An empty id is refused by claimWork: the execution records which worker holds it
                workerId = pWorker !is null ? pWorker.get!string : null;
                lease = leaseOfSeconds(pLease.get!long);
            }
            catch (InvalidLeaseRequestException e)
            {
                throw e;
            }
            catch (Exception e)
            {
                throw new InvalidLeaseRequestException(format("Malformed request: it needs a string worker_id and an integer lease_seconds: %s", e.msg));
            }
            while (true)
            {
                auto claimed = claimWork(stores, workerId, lease, clock());
                if (claimed.isNull)
                {
                    res.statusCode = HTTPStatus.noContent;
                    res.writeVoidBody();
                    return;
                }
                auto work = claimed.get;
                try
                {
                    work.workOrder.workerToken = mintWorkerToken(workerTokenKey,
                        workerTokenClaimsFor(work.workOrder, work.attempt, Clock.currTime.toUnixTime()));
                }
                catch (Exception e)
                {
                    // This execution cannot be run (say, an input without a resolved
                    // value), and would fail every receive that meets it. Fail it, recording why,
                    // and hand out the next one.
                    logError("[api] Failing execution '%s': it cannot be given a worker token: %s", work.workOrder.executionId, e.msg);
                    finishExecution(stores, work.workOrder.fingerprint, work.workOrder.executionId, ExecutionStatus.failed, 1,
                        "The execution could not be dispatched: " ~ e.msg, null, clock());
                    continue;
                }
                Json answer = Json.emptyObject;
                answer["attempt"] = Json(work.attempt);
                answer["work_order"] = serializeToJson(work.workOrder);
                res.writeJsonBody(answer);
                return;
            }
        }
        catch (InvalidLeaseRequestException e)
        {
            writeError(res, HTTPStatus.badRequest, e.msg);
        }
        catch (Exception e)
        {
            logError("[api] Could not hand out work: %s", e.msg);
            writeError(res, HTTPStatus.internalServerError, e.msg);
        }
    });

    // The attempt, and for a heartbeat the lease, a worker's request carries. Answers 400 and
    // returns false if the body lacks them or they are out of range. The attempt must be the
    // token's, which the callers check.
    bool readLeaseRequest(HTTPServerRequest req, HTTPServerResponse res, bool withLease, out ulong attempt, out Duration lease)
    {
        try
        {
            attempt = req.json["attempt"].get!ulong;
            if (withLease) lease = leaseOfSeconds(req.json["lease_seconds"].get!long);
            return true;
        }
        catch (InvalidLeaseRequestException e)
        {
            writeError(res, HTTPStatus.badRequest, e.msg);
            return false;
        }
        catch (Exception e)
        {
            writeError(res, HTTPStatus.badRequest, format("Malformed request: it needs an integer attempt%s: %s",
                withLease ? " and an integer lease_seconds" : "", e.msg));
            return false;
        }
    }

    // What a worker is told about the execution it holds: continue, cancel or superseded (a
    // release answers released instead of continue). Superseded and cancel are answers, not
    // errors: the worker stops.
    void writeLeaseAnswer(HTTPServerResponse res, LeaseAnswer answer)
    {
        Json resp = Json.emptyObject;
        resp["answer"] = Json(cast(string) answer);
        res.writeJsonBody(resp);
    }

    // A worker holding an execution extends its lease with the attempt it was given. Only the
    // execution's own token for that attempt is accepted.
    workerRoute(HTTPMethod.POST, "/executions/:execution_id/heartbeat", (HTTPServerRequest req, HTTPServerResponse res) {
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        if (!requireStores(res)) return;
        const executionId = req.params["execution_id"];
        if (!permitWorker(req, res, { requireExecution(claims, executionId); })) return;
        ulong attempt;
        Duration lease;
        if (!readLeaseRequest(req, res, true, attempt, lease)) return;
        if (!permitWorker(req, res, { requireCurrentAttempt(claims, attempt); })) return;
        try
        {
            writeLeaseAnswer(res, heartbeatExecution(stores, claims.fingerprint, executionId, attempt, lease, clock()));
        }
        catch (UnknownExecutionException e) writeError(res, HTTPStatus.notFound, e.msg);
        catch (InvalidLeaseRequestException e) writeError(res, HTTPStatus.badRequest, e.msg);
        catch (Exception e)
        {
            logError("[api] Could not extend the lease of execution '%s': %s", executionId, e.msg);
            writeError(res, HTTPStatus.internalServerError, e.msg);
        }
    });

    // A worker that cannot run its execution gives it back at once, with the attempt it was given.
    workerRoute(HTTPMethod.POST, "/executions/:execution_id/release", (HTTPServerRequest req, HTTPServerResponse res) {
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        if (!requireStores(res)) return;
        const executionId = req.params["execution_id"];
        if (!permitWorker(req, res, { requireExecution(claims, executionId); })) return;
        ulong attempt;
        Duration unused;
        if (!readLeaseRequest(req, res, false, attempt, unused)) return;
        if (!permitWorker(req, res, { requireCurrentAttempt(claims, attempt); })) return;
        try
        {
            writeLeaseAnswer(res, releaseExecution(stores, claims.fingerprint, executionId, attempt));
        }
        catch (UnknownExecutionException e) writeError(res, HTTPStatus.notFound, e.msg);
        catch (Exception e)
        {
            logError("[api] Could not release execution '%s': %s", executionId, e.msg);
            writeError(res, HTTPStatus.internalServerError, e.msg);
        }
    });

    // An execution's log: reading it, and the lines its worker streams. Not implemented until
    // the log store lands (see logsNotImplemented). Only the execution's own token posts lines.
    getRoute("/executions/:execution_id/logs", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, logsNotImplemented());
    });

    workerRoute(HTTPMethod.POST, "/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        if (!requireStores(res)) return;
        if (!permitWorker(req, res, {
            requireExecution(claims, req.params["execution_id"]);
            requireCurrentExecutionAttempt(stores, claims, true);
        })) return;
        writeNotImplemented(res, logsNotImplemented());
    });

    // A worker's completion of an execution. It names the execution only: the fingerprint comes
    // from the worker's token and the task from the ledger's active execution, and anything that
    // does not match them is rejected. A completion records the execution, folds it into its
    // fingerprint's ledger; see confector.core.work_orders.completeExecution. A completion from a
    // superseded attempt is rejected.
    workerRoute(HTTPMethod.POST, "/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        import confector.core.work_orders : InvalidCompletionException, OutcomeNotFoldedException, StaleCompletionException;

        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        string executionId = req.params["execution_id"];
        if (!requireStores(res)) return;
        if (!permitWorker(req, res, {
            requireExecution(claims, executionId);
            requireCurrentExecutionAttempt(stores, claims, false);
        })) return;
        void reject(HTTPStatus status, string message)
        {
            logWarn("[api] Rejected the completion of execution '%s' (HTTP %d): %s", executionId, cast(int) status, message);
            writeError(res, status, message);
        }

        TaskExecutionResult result;
        try result = deserializeJson!TaskExecutionResult(req.json);
        catch (Exception e)
        {
            reject(HTTPStatus.badRequest, format("Malformed completion: %s", e.msg));
            return;
        }
        try
        {
            if (!requireStores(res)) return;
            const finished = completeExecution(stores, claims.fingerprint, executionId, result, clock());
            logInfo("[api] Execution '%s' (task '%s', fingerprint %s) finished %s (exit code %d, %d ms)",
                executionId, finished.taskId, finished.fingerprint, finished.status, finished.exitCode, result.durationMs);

            Json resp = Json.emptyObject;
            resp["status"] = Json("recorded");
            resp["execution_id"] = Json(executionId);
            res.writeJsonBody(resp);
        }
        catch (StaleCompletionException e) reject(HTTPStatus.conflict, e.msg);
        catch (UnknownExecutionException e) reject(HTTPStatus.notFound, e.msg);
        catch (InvalidCompletionException e) reject(HTTPStatus.unprocessableEntity, e.msg);
        catch (OutcomeNotFoldedException e)
        {
            // The execution is finished and final; only the ledger fold failed. Say
            // so loudly (500) rather than report success: resending is answered 409, and the next
            // read of the ledger completes the fold.
            logError("[api] The completion of execution '%s' was recorded but not folded: %s", executionId, e.msg);
            writeError(res, HTTPStatus.internalServerError, e.msg);
        }
        catch (Exception e)
        {
            logError("[api] Could not record the completion of execution '%s': %s", executionId, e.msg);
            writeError(res, HTTPStatus.internalServerError, format("Could not record the completion of execution '%s': %s", executionId, e.msg));
        }
    });

    // Starts a build of a project: records a request on a new chain or an existing one and reconciles
    // it (see confector.core.intake). The body is a JSON object:
    //
    //     {
    //       "project_id": "<project id>",
    //       "targets": ["<task id>", ...],
    //       "intent": "build" | "retry" | "rerun",       optional, default "build"
    //       "chain": "<chain id>" | <chain number>,      optional; without it a new chain is created
    //       "refs": {"<repository id>": "<ref name>"}    optional; other repositories use the inputs' defaults
    //     }
    //
    // A retry or a rerun needs a chain, and a rerun exactly one target. Answers 201 with
    // {"request_id", "chain_id", "chain_number"}. A malformed body is 400, an unknown project or chain
    // 404, a supplied pin that disagrees with the chain 409, a request that cannot be bound or resolved
    // (an input without a ref, a ref that does not exist, an unknown target) 422, and a request that
    // was recorded but could not be reconciled 201 with a "warning" field (the sweep reconciles it).
    // The scheduler calls the second route for cron trigger rules.
    postRoute("/projects/run", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        if (!requireStores(res)) return;
        if (intake is null)
        {
            writeError(res, HTTPStatus.internalServerError, "This route needs request intake, which is not configured");
            return;
        }
        auto caller = authenticator.authenticate(req);
        try
        {
            Json body;
            try body = req.json;
            catch (Exception e) throw new IntakeException(IntakeFailure.invalid, format("The body is not JSON: %s", e.msg), e);
            IntakeRequest request = parseRunRequest(body);
            request.requestedBy = caller.isNull ? "" : caller.get.subject;
            const result = intake.intake(request);
            res.statusCode = HTTPStatus.created;
            res.writeJsonBody(runAnswer(result));
        }
        catch (IntakeException e)
        {
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            final switch (e.failure)
            {
                case IntakeFailure.notFound: res.statusCode = HTTPStatus.notFound; break;
                case IntakeFailure.invalid: res.statusCode = HTTPStatus.badRequest; break;
                case IntakeFailure.refused: res.statusCode = HTTPStatus.unprocessableEntity; break;
                case IntakeFailure.conflict: res.statusCode = HTTPStatus.conflict; break;
                case IntakeFailure.reconcileFailed:
                    // Recorded: answering an error would invite a duplicate request
                    res.statusCode = HTTPStatus.created;
                    err = runAnswer(e.recorded);
                    err["warning"] = Json("reconcile pending; the sweep will retry");
                    logError("[api] %s", e.msg);
                    break;
            }
            res.writeJsonBody(err);
        }
        catch (Exception e)
        {
            logError("[api] Could not start a build: %s", e.toString());
            writeError(res, HTTPStatus.internalServerError, format("Could not start a build: %s", e.msg));
        }
    });

    schedulerRoute("/projects/:id/run", (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, scheduledBuildsNotImplemented());
    });

    // One tick of the coordination sweep, which the server registers to run every minute (see
    // confector.core.sweep). The summary answers the call. A tick that logged an error answers 500,
    // and keeps doing so until the failing item is fixed: a permanently broken request is seen on
    // every tick. Ticks are idempotent, so the scheduler's retries are safe.
    schedulerRoute("/sweeps/coordination", (HTTPServerRequest req, HTTPServerResponse res) {
        if (!requireStores(res)) return;
        auto summary = sweepCoordination(stores, maxAttempts, clock());
        if (summary.errors > 0) res.statusCode = HTTPStatus.internalServerError;
        res.writeJsonBody(summary);
    });

    // Projects REST API
    getRoute("/projects", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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

    postRoute("/projects", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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

    getRoute("/projects/:id", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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

    deleteRoute("/projects/:id", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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
    getRoute("/projects/:id/tasks", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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

    postRoute("/projects/:id/tasks", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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

    getRoute("/projects/:id/tasks/:taskId", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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

    deleteRoute("/projects/:id/tasks/:taskId", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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

    return router;
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.server.authenticator : FixedAuthenticator, Identity, testIdentity;
    import confector.core.work_orders : defaultMaxAttempts;
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    import std.typecons : Nullable;

    string testDir = "test_api_controller_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto stores = new StateStores(new InMemoryDocumentStore());

    enum workerTokenKey = "0123456789abcdef0123456789abcdef";
    enum workerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
    auto admin = new FixedAuthenticator(testIdentity(Role.admin));
    auto router = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts);
    assert(router !is null);

    // A router needs an authenticator, a signing key and a worker pool credential of a usable length
    import std.exception : assertThrown;
    assertThrown!Exception(apiRouter(null, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", "", workerPoolCredential, defaultMaxAttempts));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", workerTokenKey, "", defaultMaxAttempts));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", workerTokenKey, "too-short", defaultMaxAttempts));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, 0));

    // A user route refuses a request without an identity, and one whose role is too low
    auto nobodyRouter = apiRouter(new FixedAuthenticator(Nullable!Identity.init), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts);
    auto unidentifiedRes = createTestHTTPServerResponse();
    nobodyRouter.handleRequest(createTestHTTPServerRequest(URL("http://localhost/api/v1/projects"), HTTPMethod.GET), unidentifiedRes);
    assert(unidentifiedRes.statusCode == HTTPStatus.unauthorized);

    auto viewerRouter = apiRouter(new FixedAuthenticator(testIdentity(Role.viewer)), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts);
    auto tooLowRes = createTestHTTPServerResponse();
    viewerRouter.handleRequest(createTestHTTPServerRequest(URL("http://localhost/api/v1/projects"), HTTPMethod.POST), tooLowRes);
    assert(tooLowRes.statusCode == HTTPStatus.forbidden);

    // A scheduler callback without the scheduler secret is refused before its handler runs
    auto unauthReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/proj_api_1/run"), HTTPMethod.POST);
    auto unauthRes = createTestHTTPServerResponse();
    router.handleRequest(unauthReq, unauthRes);
    assert(unauthRes.statusCode == HTTPStatus.unauthorized);

    // With the secret the callback reaches its handler, which fails loudly
    auto authReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/proj_api_1/run"), HTTPMethod.POST);
    authReq.headers["X-Confector-Scheduler-Secret"] = "test-scheduler-secret";
    auto authRes = createTestHTTPServerResponse();
    router.handleRequest(authReq, authRes);
    assert(authRes.statusCode == HTTPStatus.notImplemented);

    // Test Projects and Tasks via repo
    ProjectRecord proj;
    proj.id = "proj_api_1";
    proj.name = "API Project";
    TaskNode node;
    node.id = "n1";
    node.steps = [BuildStep("Echo", "bash", Json(["script": Json("echo hi")]))];
    proj.tasks = [node];
    stores.projects.put(proj);
    assert(stores.projects.list().length == 1);

    ProjectRecord fetchedProj;
    assert(stores.projects.get("proj_api_1").tryValue(fetchedProj));
    assert(fetchedProj.name == "API Project");
    assert(fetchedProj.tasks.length == 1);
    assert(fetchedProj.tasks[0].id == "n1");

    // Starting a build fails loudly with the reason, through the API as through the scheduler
    import vibe.inet.message : InetHeaderMap;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;
    import std.algorithm.searching : canFind;
    import std.array : replace;
    import std.string : indexOf;

    auto routerWithStores = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, stores);

    import confector.core.worker_token : WorkerTokenClaims, mintWorkerToken, verifyWorkerToken, workerTokenHeader;
    import confector.core.worker_pool_credential : workerPoolCredentialHeader;
    import confector.core.work_orders : currentAttempt;

    // The fingerprint of each execution the test queued, by execution id
    string[string] fingerprintOf;

    // The token of the execution a /executions/<id>/... path names, which every execution route
    // below presents unless a test says otherwise
    string tokenForPath(string path, StateStores of = null)
    {
        import std.algorithm.searching : startsWith;
        import std.string : split;

        if (!path.startsWith("/executions/")) return null;
        WorkerTokenClaims claims;
        claims.executionId = path.split("/")[2];
        claims.fingerprint = fingerprintOf.get(claims.executionId, "fp_n1");
        auto attempt = currentAttempt(of is null ? stores : of, claims.fingerprint, claims.executionId);
        claims.attempt = attempt.isNull ? 0 : attempt.get;
        claims.expiresAt = Clock.currTime.toUnixTime() + 600;
        return mintWorkerToken(workerTokenKey, claims);
    }

    struct Reply { int status; string body; }

    // Posts `body` to `path` with `token` (and the pool credential, for receiving work)
    Reply postReply(string token, string path, string body)
    {
        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        if (token.length > 0) headers[workerTokenHeader] = token;
        if (path == "/queue/receive") headers[workerPoolCredentialHeader] = workerPoolCredential;
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path),
            HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) body.dup, false));
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        routerWithStores.handleRequest(req, res);
        res.finalize();
        return Reply(res.statusCode, cast(string) sink.data.idup);
    }

    int postWith(string token, string path, string body)
    {
        return postReply(token, path, body).status;
    }

    int post(string path, string body)
    {
        return postWith(tokenForPath(path), path, body);
    }

    // The body a request to `path` is answered with
    string answer(HTTPMethod method, string path, string body = null)
    {
        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        if (tokenForPath(path).length > 0) headers[workerTokenHeader] = tokenForPath(path);
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path), method, headers,
            createMemoryStream(cast(ubyte[]) body.dup, false));
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        routerWithStores.handleRequest(req, res);
        res.finalize();
        return cast(string) sink.data.idup;
    }

    // The JSON a reply to a route that answers an object holds
    Json bodyOf(Reply reply)
    {
        return parseJsonString(reply.body[reply.body.indexOf('{') .. $]);
    }

    // Without request intake configured the run route fails loudly instead of doing nothing
    assert(post("/projects/run", `{"project_id": "proj_api_1", "targets": ["n1"]}`) == HTTPStatus.internalServerError);

    import confector.api.model : ActiveExecution;
    import confector.core.fingerprint_ledger : ClaimOutcome;
    import confector.core.work_orders : claimWork, startExecution;
    import core.time : hours;

    // Claims the fingerprint's ledger for task "n1" of a stored definition of `definition` (and
    // `others`, the tasks it depends on), as a dispatch does: the execution is queued under the
    // claimed id
    string queueExecution(StateStores into, string fingerprint, TaskNode definition = node,
        string createdAt = "2026-10-16T10:00:00Z", TaskNode[] others = null)
    {
        ActiveExecution proposed;
        proposed.projectId = "proj_api_1";
        proposed.taskId = "n1";
        proposed.definitionId = into.definitions.put(ProjectDefinition([definition] ~ others));
        proposed.createdAt = createdAt;
        const claimed = into.ledgers.claim(fingerprint, 0, proposed);
        assert(claimed.outcome == ClaimOutcome.won);
        fingerprintOf[claimed.executionId] = fingerprint;
        return claimed.executionId;
    }

    // The active execution at `fingerprint`
    ActiveExecution activeAt(StateStores of, string fingerprint)
    {
        return of.ledgers.get(fingerprint).get.active.get;
    }

    // Receiving needs the worker pool credential, checked before anything else: without it, or
    // with a wrong one, the receive is refused with 401, names only the header, and hands out
    // nothing; the queued execution stays queued
    {
        Reply receiveWithCredential(string credential, string body = `{"worker_id": "w-pool", "lease_seconds": 30}`)
        {
            InetHeaderMap headers;
            headers["Content-Type"] = "application/json";
            if (credential.length > 0) headers[workerPoolCredentialHeader] = credential;
            auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1/queue/receive"),
                HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) body.dup, false));
            auto sink = createMemoryOutputStream();
            auto res = createTestHTTPServerResponse(sink);
            routerWithStores.handleRequest(req, res);
            res.finalize();
            return Reply(res.statusCode, cast(string) sink.data.idup);
        }

        assert(receiveWithCredential(workerPoolCredential).status == HTTPStatus.noContent, "Nothing queued: nothing to receive");

        const pending = queueExecution(stores, "fp_pool");
        const missing = receiveWithCredential(null);
        assert(missing.status == HTTPStatus.unauthorized && missing.body.canFind(workerPoolCredentialHeader ~ " header"), missing.body);
        const wrong = receiveWithCredential(workerPoolCredential ~ "x");
        assert(wrong.status == HTTPStatus.unauthorized && wrong.body.canFind("Invalid " ~ workerPoolCredentialHeader), wrong.body);
        assert(!wrong.body.canFind(workerPoolCredential), "A refusal never repeats the credential");
        const sameLength = receiveWithCredential(workerPoolCredential[0 .. $ - 1] ~ "X");
        assert(sameLength.status == HTTPStatus.unauthorized && sameLength.body.canFind("Invalid " ~ workerPoolCredentialHeader),
            sameLength.body);
        assert(activeAt(stores, "fp_pool").status == ExecutionStatus.queued, "A refused receive hands out nothing");

        // A receive names its worker and its lease; a malformed one claims nothing
        assert(receiveWithCredential(workerPoolCredential, `{"lease_seconds": 30}`).status == HTTPStatus.badRequest);
        assert(receiveWithCredential(workerPoolCredential, `{"worker_id": "w-pool"}`).status == HTTPStatus.badRequest);
        assert(receiveWithCredential(workerPoolCredential, `{"worker_id": "w-pool", "lease_seconds": 0}`).status == HTTPStatus.badRequest);
        foreach (malformed; [`{"worker_id": 5, "lease_seconds": 30}`, `{"worker_id": "w-pool", "lease_seconds": "soon"}`,
            `{"worker_id": "w-pool", "lease_seconds": 30.5}`, `{"worker_id": "w-pool", "lease_seconds": 9223372036854775807}`,
            `{"worker_id": "w-pool", "lease_seconds": -1}`, `[1]`])
        {
            assert(receiveWithCredential(workerPoolCredential, malformed).status == HTTPStatus.badRequest, malformed);
        }
        assert(activeAt(stores, "fp_pool").status == ExecutionStatus.queued);

        // With the credential, the same receive claims the queued execution and answers with its
        // attempt and work order
        const accepted = receiveWithCredential(workerPoolCredential);
        assert(accepted.status == HTTPStatus.ok, accepted.body);
        const handed = bodyOf(accepted);
        assert(handed["attempt"].get!long == 1 && handed["work_order"]["execution_id"].get!string == pending, accepted.body);
        const claimedExecution = activeAt(stores, "fp_pool");
        assert(claimedExecution.status == ExecutionStatus.running && claimedExecution.worker == "w-pool" && claimedExecution.attempt == 1);
        assert(receiveWithCredential(workerPoolCredential).status == HTTPStatus.noContent, "Two workers cannot claim one execution");
    }

    const executionId = queueExecution(stores, "fp_n1");
    auto received = claimWork(stores, "test-worker", 1.hours);
    assert(!received.isNull && received.get.workOrder.executionId == executionId && received.get.attempt == 1);

    // Receiving a work order mints the token for that execution, fingerprint and attempt; the
    // heartbeat and release routes accept only that execution's token
    {
        const tokenExecutionId = queueExecution(stores, "fp_token");

        const response = postReply(null, "/queue/receive", `{"worker_id": "w-token", "lease_seconds": 30}`);
        assert(response.status == HTTPStatus.ok, response.body);
        const issued = bodyOf(response)["work_order"]["worker_token"].get!string;
        const issuedClaims = verifyWorkerToken(workerTokenKey, issued, Clock.currTime.toUnixTime());
        assert(issuedClaims.executionId == tokenExecutionId && issuedClaims.fingerprint == "fp_token" && issuedClaims.attempt == 1);

        const heartbeat = "/executions/" ~ tokenExecutionId ~ "/heartbeat";
        const release = "/executions/" ~ tokenExecutionId ~ "/release";
        const body = `{"attempt": 1, "lease_seconds": 60}`;
        auto lapsed = cast() issuedClaims;
        lapsed.expiresAt = 1;
        const lapsedToken = mintWorkerToken(workerTokenKey, lapsed);
        const alteredToken = issued[0 .. 10] ~ (issued[10] == 'A' ? "B" : "A") ~ issued[11 .. $];
        foreach (route; [heartbeat, release])
        {
            assert(postWith(null, route, body) == HTTPStatus.unauthorized, route ~ " without a token");
            assert(postWith("garbage", route, body) == HTTPStatus.unauthorized, route ~ " with a malformed token");
            assert(postWith(lapsedToken, route, body) == HTTPStatus.unauthorized, route ~ " with an expired token");
            assert(postWith(alteredToken, route, body) == HTTPStatus.unauthorized, route ~ " with an altered token");
            assert(postWith(issued, route.replace(tokenExecutionId, executionId), body) == HTTPStatus.forbidden,
                route ~ " with another execution's token");
        }
        assert(activeAt(stores, "fp_token").status == ExecutionStatus.running, "A refused request changes nothing");

        // A token for a superseded attempt may not complete or log, even though it is genuine and
        // unexpired
        auto superseded = cast() issuedClaims;
        superseded.attempt = issuedClaims.attempt + 1;
        const supersededToken = mintWorkerToken(workerTokenKey, superseded);
        foreach (route; ["/logs", "/complete"])
        {
            assert(postWith(supersededToken, "/executions/" ~ tokenExecutionId ~ route, `{}`) == HTTPStatus.forbidden, route);
        }
        assert(activeAt(stores, "fp_token").status == ExecutionStatus.running);

        // The execution routes accept the execution's own token only
        auto expired = cast() issuedClaims;
        expired.expiresAt = 1;
        const expiredToken = mintWorkerToken(workerTokenKey, expired);
        const tampered = issued[0 .. 10] ~ (issued[10] == 'A' ? "B" : "A") ~ issued[11 .. $];
        foreach (route; ["/logs", "/complete"])
        {
            const path = "/executions/" ~ tokenExecutionId ~ route;
            assert(postWith(null, path, `{}`) == HTTPStatus.unauthorized, path ~ " without a token");
            assert(postWith(expiredToken, path, `{}`) == HTTPStatus.unauthorized, path ~ " with an expired token");
            assert(postWith(tampered, path, `{}`) == HTTPStatus.unauthorized, path ~ " with an altered token");
            assert(postWith(issued, "/executions/" ~ executionId ~ route, `{}`) == HTTPStatus.forbidden, path ~ " with another execution's token");
        }
        assert(postWith(issued, "/executions/" ~ tokenExecutionId ~ "/logs", `{"lines": []}`) == HTTPStatus.notImplemented);
        assert(activeAt(stores, "fp_n1").status == ExecutionStatus.running && stores.executions.get(executionId).isNull,
            "A refused completion records nothing");
    }

    // Heartbeat and release carry the attempt and answer what the worker is to do. An attempt
    // that no longer holds the execution is superseded, and a release requeues it at once for
    // the next receive; the superseded attempt's completion is refused
    {
        const leasedId = queueExecution(stores, "fp_lease");
        const first = bodyOf(postReply(null, "/queue/receive", `{"worker_id": "w-one", "lease_seconds": 30}`));
        assert(first["work_order"]["execution_id"].get!string == leasedId && first["attempt"].get!long == 1);
        const firstToken = first["work_order"]["worker_token"].get!string;
        const heartbeat = "/executions/" ~ leasedId ~ "/heartbeat";
        const release = "/executions/" ~ leasedId ~ "/release";

        string answerOf(string token, string path, string body)
        {
            const reply = postReply(token, path, body);
            assert(reply.status == HTTPStatus.ok, reply.body);
            return bodyOf(reply)["answer"].get!string;
        }

        assert(answerOf(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 3600}`) == "continue");
        assert(activeAt(stores, "fp_lease").leaseExpiresAt.length > 0);
        // The body's attempt must be the token's, as for completion and logs
        assert(postWith(firstToken, heartbeat, `{"attempt": 2, "lease_seconds": 30}`) == HTTPStatus.forbidden);
        assert(postWith(firstToken, release, `{"attempt": 2}`) == HTTPStatus.forbidden);
        assert(activeAt(stores, "fp_lease").status == ExecutionStatus.running);
        assert(postWith(firstToken, heartbeat, `{"lease_seconds": 30}`) == HTTPStatus.badRequest, "A heartbeat carries the attempt");
        assert(postWith(firstToken, heartbeat, `{"attempt": 1}`) == HTTPStatus.badRequest, "A heartbeat carries the lease");
        assert(postWith(firstToken, release, `{}`) == HTTPStatus.badRequest, "A release carries the attempt");
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 0}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": "soon"}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 9223372036854775807}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": "one", "lease_seconds": 30}`) == HTTPStatus.badRequest);

        assert(answerOf(firstToken, release, `{"attempt": 1}`) == "released");
        assert(activeAt(stores, "fp_lease").status == ExecutionStatus.queued);
        assert(answerOf(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 30}`) == "superseded");

        const second = bodyOf(postReply(null, "/queue/receive", `{"worker_id": "w-two", "lease_seconds": 30}`));
        assert(second["work_order"]["execution_id"].get!string == leasedId && second["attempt"].get!long == 2);
        const secondToken = second["work_order"]["worker_token"].get!string;
        assert(activeAt(stores, "fp_lease").worker == "w-two");

        // The first attempt can neither heartbeat, release nor complete, whether it names its own
        // attempt or the current one; the second completes
        assert(postWith(firstToken, heartbeat, `{"attempt": 2, "lease_seconds": 30}`) == HTTPStatus.forbidden,
            "A token for attempt 1 cannot heartbeat attempt 2");
        assert(postWith(firstToken, release, `{"attempt": 2}`) == HTTPStatus.forbidden, "A token for attempt 1 cannot release attempt 2");
        assert(activeAt(stores, "fp_lease").status == ExecutionStatus.running);
        assert(answerOf(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 30}`) == "superseded");
        const completeLeased = "/executions/" ~ leasedId ~ "/complete";
        assert(postWith(firstToken, completeLeased, `{"status": "succeeded", "attempt": 1}`) == HTTPStatus.forbidden);
        assert(postWith(secondToken, completeLeased, `{"status": "succeeded", "attempt": 1}`) == HTTPStatus.conflict);
        assert(activeAt(stores, "fp_lease").status == ExecutionStatus.running);
        assert(postWith(secondToken, completeLeased, `{"status": "succeeded", "attempt": 2}`) == HTTPStatus.ok);
        assert(answerOf(secondToken, release, `{"attempt": 2}`) == "superseded", "A finished execution is not released");

        // An unknown execution is a 404 for a token that names it
        WorkerTokenClaims unknown;
        unknown.executionId = "exe_unknown";
        unknown.fingerprint = "fp_n1";
        unknown.attempt = 1;
        unknown.expiresAt = Clock.currTime.toUnixTime() + 600;
        const unknownToken = mintWorkerToken(workerTokenKey, unknown);
        assert(postWith(unknownToken, "/executions/exe_unknown/heartbeat", `{"attempt": 1, "lease_seconds": 30}`) == HTTPStatus.notFound);
        assert(postWith(unknownToken, "/executions/exe_unknown/release", `{"attempt": 1}`) == HTTPStatus.notFound);
    }

    // An execution that cannot be given a token (its input has no resolved value) is failed,
    // with the reason; the receive goes on to the next queued execution
    {
        TaskNode needy = node;
        needy.inputs["up"] = taskOutputInput("up-task", "a.zip");
        TaskNode upstream;
        upstream.id = "up-task";
        const brokenId = queueExecution(stores, "fp_broken", needy, "2026-10-16T10:00:01Z", [upstream]);
        const healthyId = queueExecution(stores, "fp_healthy", node, "2026-10-16T10:00:02Z");
        const batch = postReply(null, "/queue/receive", `{"worker_id": "w-batch", "lease_seconds": 30}`);
        assert(batch.status == HTTPStatus.ok && bodyOf(batch)["work_order"]["execution_id"].get!string == healthyId, batch.body);
        const broken = stores.executions.get(brokenId).get;
        assert(broken.status == ExecutionStatus.failed && broken.errorMessage.canFind("could not be dispatched")
            && broken.errorMessage.canFind("up"), broken.errorMessage);
        assert(postReply(null, "/queue/receive", `{"worker_id": "w-batch", "lease_seconds": 30}`).status == HTTPStatus.noContent);
    }

    // Build logs fail loudly until the log store exists: uploading lines and reading a log both
    // answer 501
    {
        assert(post("/executions/" ~ executionId ~ "/logs", `{"lines": ["compiling", "linking"]}`) == HTTPStatus.notImplemented);
        foreach (method; [HTTPMethod.POST, HTTPMethod.GET])
        {
            const written = answer(method, "/executions/" ~ executionId ~ "/logs", `{"lines": ["compiling"]}`);
            assert(written.canFind(logsNotImplemented().msg), written);
        }
    }

    // A worker's completion names its execution in the route. An unknown execution, a cache hit
    // or a completion naming another task is rejected and records nothing. A fingerprint in the
    // body is not part of the completion and cannot choose the cache key
    const completion = `{"task_id": "n1", "status": "succeeded", "attempt": 1, "exit_code": 0, "duration_ms": 85,`
        ~ ` "fingerprint": "fp_chosen_by_the_worker"}`;
    assert(post("/executions/exe_unknown/complete", completion) == HTTPStatus.notFound, "An unknown execution is rejected");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "cached", "attempt": 1}`) == HTTPStatus.badRequest,
        "A cache hit is not an execution status");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "attempt": 1}`) == HTTPStatus.badRequest, "A completion needs a status");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "succeeded"}`) == HTTPStatus.badRequest,
        "A completion needs the attempt it was given");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "running", "attempt": 1}`) == HTTPStatus.unprocessableEntity);
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n2", "status": "succeeded", "attempt": 1}`) == HTTPStatus.unprocessableEntity);
    assert(post("/executions/" ~ executionId ~ "/complete",
        `{"task_id": "n1", "status": "succeeded", "attempt": 1, "produced_artifacts": [{"artifact_id": "a", "task_fingerprint": "fp_other"}]}`)
        == HTTPStatus.unprocessableEntity, "Artifacts under another fingerprint are rejected for good");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"status": `) == HTTPStatus.badRequest, "Malformed JSON");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "succeeded", "attempt": 2}`) == HTTPStatus.conflict,
        "A completion from another attempt is rejected");
    assert(activeAt(stores, "fp_n1").status == ExecutionStatus.running && stores.executions.get(executionId).isNull);

    // The completion finishes the execution under its own fingerprint
    assert(post("/executions/" ~ executionId ~ "/complete", completion) == HTTPStatus.ok);
    const finished = stores.executions.get(executionId).get;
    assert(finished.status == ExecutionStatus.succeeded && finished.fingerprint == "fp_n1");
    assert(stores.executions.get("fp_chosen_by_the_worker").isNull);
    assert(post("/executions/" ~ executionId ~ "/complete", completion) == HTTPStatus.conflict, "A duplicate completion is rejected");
    assert(stores.executions.get(executionId).get.status == ExecutionStatus.succeeded);

    // A store failure is a server error, not a rejection: the worker's completion is not recorded
    // and it may report again
    import confector.testing.memory_document_store : InterleavingDocumentStore;
    auto failingDocuments = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto failingStores = new StateStores(failingDocuments);
    const anotherId = queueExecution(failingStores, "fp_n1_again");
    assert(!claimWork(failingStores, "w-failing", 1.hours).isNull);
    failingDocuments.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failingRouter = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, failingStores);
    InetHeaderMap failingHeaders;
    failingHeaders["Content-Type"] = "application/json";
    failingHeaders[workerTokenHeader] = tokenForPath("/executions/" ~ anotherId ~ "/complete", failingStores);
    auto failingReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ anotherId ~ "/complete"),
        HTTPMethod.POST, failingHeaders, createMemoryStream(cast(ubyte[]) completion.dup, false));
    auto failingRes = createTestHTTPServerResponse();
    failingRouter.handleRequest(failingReq, failingRes);
    assert(failingRes.statusCode == HTTPStatus.internalServerError);
    failingDocuments.beforeNextWrite = null;
    assert(activeAt(failingStores, "fp_n1_again").status == ExecutionStatus.running);
    assert(failingStores.executions.get(anotherId).isNull, "The failed completion recorded nothing");

    // A completion whose fold fails after the execution finished is a server error that says so;
    // the execution stays finished and a resent completion is a conflict
    auto unfoldedDocuments = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto unfoldedStores = new StateStores(unfoldedDocuments);
    const unfoldedId = queueExecution(unfoldedStores, "fp_n1_unfolded");
    assert(!claimWork(unfoldedStores, "w-unfolded", 1.hours).isNull);
    auto unfoldedRouter = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, unfoldedStores);
    int completeUnfolded()
    {
        InetHeaderMap unfoldedHeaders;
        unfoldedHeaders["Content-Type"] = "application/json";
        unfoldedHeaders[workerTokenHeader] = tokenForPath("/executions/" ~ unfoldedId ~ "/complete", unfoldedStores);
        auto unfoldedReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ unfoldedId ~ "/complete"),
            HTTPMethod.POST, unfoldedHeaders, createMemoryStream(cast(ubyte[]) completion.dup, false));
        auto unfoldedRes = createTestHTTPServerResponse();
        unfoldedRouter.handleRequest(unfoldedReq, unfoldedRes);
        return unfoldedRes.statusCode;
    }
    // The completion's writes: 1 the execution's record, 2 the fold, which is lost
    unfoldedDocuments.beforeNextWrite = () { unfoldedDocuments.beforeNextWrite = () { throw new Exception("The fold's write is lost"); }; };
    assert(completeUnfolded() == HTTPStatus.internalServerError);
    assert(unfoldedStores.executions.get(unfoldedId).get.status == ExecutionStatus.succeeded);
    assert(!unfoldedStores.ledgers.get("fp_n1_unfolded").get.active.isNull, "The fold did not happen");
    assert(completeUnfolded() == HTTPStatus.conflict);
    assert(unfoldedStores.ledgers.get("fp_n1_unfolded").get.active.isNull, "The resent completion completed the fold");

    // Without the state stores the execution routes fail loudly rather than drop the report
    InetHeaderMap headers;
    headers["Content-Type"] = "application/json";
    headers[workerTokenHeader] = tokenForPath("/executions/" ~ executionId ~ "/complete");
    foreach (route; ["/complete", "/heartbeat", "/release"])
    {
        auto noStoresReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ executionId ~ route),
            HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) completion.dup, false));
        auto noStoresRes = createTestHTTPServerResponse();
        router.handleRequest(noStoresReq, noStoresRes);
        assert(noStoresRes.statusCode == HTTPStatus.internalServerError, route);
    }
}

unittest
{
    // The coordination sweep is a scheduler route: it runs one tick, on the server's clock, only
    // with the scheduler secret. A tick expires a lease that ran out long ago, and the summary of
    // what it did answers the call
    import confector.api.model : ActiveExecution, ExecutionStatus;
    import confector.api.scheduler : schedulerSecretHeader;
    import confector.core.work_orders : defaultMaxAttempts, startExecution;
    import confector.server.authenticator : FixedAuthenticator, testIdentity;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import core.time : minutes;
    import std.algorithm.searching : findSplit;
    import vibe.data.json : parseJsonString;
    import vibe.stream.memory : createMemoryOutputStream;

    enum workerTokenKey = "0123456789abcdef0123456789abcdef";
    enum workerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto router = apiRouter(new FixedAuthenticator(testIdentity(Role.admin)), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts, stores);

    ActiveExecution execution;
    execution.projectId = "proj";
    execution.taskId = "compile";
    execution.definitionId = "def_sweep";
    execution.createdAt = "2000-01-01T00:00:00Z";
    stores.ledgers.claim("fp_sweep", 0, execution);
    assert(!startExecution(stores, "fp_sweep", "w1", 1.minutes, "2000-01-01T00:00:00Z").isNull);

    // Without the secret, or with another one, the tick does not run
    assert(sweepTick(router, "").status == HTTPStatus.unauthorized);
    assert(sweepTick(router, "wrong-secret").status == HTTPStatus.unauthorized);
    assert(stores.ledgers.get("fp_sweep").get.active.get.status == ExecutionStatus.running, "A refused tick changes nothing");

    // With the secret it runs: the expired lease is requeued and the summary says so
    auto answered = sweepTick(router, "test-scheduler-secret");
    assert(answered.status == HTTPStatus.ok, answered.body);
    assert(parseJsonString(answered.body)["leasesRequeued"].get!long == 1, answered.body);
    assert(parseJsonString(answered.body)["errors"].get!long == 0, answered.body);
    assert(stores.ledgers.get("fp_sweep").get.active.get.status == ExecutionStatus.queued);
}

unittest
{
    // A tick that logged an error answers 500 with its summary. Here an open request whose record
    // is missing cannot be reconciled, so every tick answers 500 until it is fixed
    import confector.api.model : BuildRequest, ProjectRecord;
    import confector.core.work_orders : defaultMaxAttempts;
    import confector.server.authenticator : FixedAuthenticator, testIdentity;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import vibe.data.json : parseJsonString;

    enum workerTokenKey = "0123456789abcdef0123456789abcdef";
    enum workerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
    auto stores = new StateStores(new InMemoryDocumentStore());
    ProjectRecord proj;
    proj.id = "proj";
    stores.projects.put(proj);
    BuildRequest ghost;
    ghost.id = "ghost";
    ghost.projectId = "proj";
    stores.requestStates.createFor(ghost);
    auto router = apiRouter(new FixedAuthenticator(testIdentity(Role.admin)), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts, stores);

    auto answered = sweepTick(router, "test-scheduler-secret");
    assert(answered.status == HTTPStatus.internalServerError, answered.body);
    assert(parseJsonString(answered.body)["errors"].get!long == 1, answered.body);
    assert(parseJsonString(answered.body)["requestsReconciled"].get!long == 0, answered.body);
    assert(sweepTick(router, "test-scheduler-secret").status == HTTPStatus.internalServerError, "It stays 500 until fixed");
}

version (unittest)
{
    /// What the sweep route answered: its status and its JSON body.
    private struct SweepAnswer { int status; string body; }

    /// Calls the sweep route of `router` as the scheduler, presenting `secret` (none when empty).
    private SweepAnswer sweepTick(AuthorizedRoutes router, string secret)
    {
        import std.algorithm.searching : findSplit;
        import vibe.stream.memory : createMemoryOutputStream;
        import confector.api.scheduler : schedulerSecretHeader;

        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1/sweeps/coordination"), HTTPMethod.POST);
        if (secret.length > 0) req.headers[schedulerSecretHeader] = secret;
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        router.handleRequest(req, res);
        res.finalize();
        // The sink holds the status line and headers before the body
        auto written = cast(string) sink.data.idup;
        return SweepAnswer(res.statusCode, written.findSplit("\r\n\r\n")[2]);
    }
}

unittest
{
    // Starting a build through the API: the statuses, the roles, and what is recorded
    import confector.api.model : ProjectRecord, RepositoryRecord;
    import confector.core.work_orders : defaultMaxAttempts;
    import confector.server.authenticator : FixedAuthenticator, Identity, testIdentity;
    import confector.testing.fake_repository_resolver : FakeRepositoryResolver;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import std.algorithm.searching : canFind;
    import std.string : indexOf;
    import std.typecons : Nullable;
    import vibe.inet.message : InetHeaderMap;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    enum workerTokenKey = "0123456789abcdef0123456789abcdef";
    enum workerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
    auto stores = new StateStores(new InMemoryDocumentStore());
    RepositoryRecord game;
    game.name = "game";
    game.address = "https://example.test/game.git";
    stores.repositories.put(game);
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
    compile.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
    TaskNode test;
    test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile");
    ProjectRecord project;
    project.id = "game";
    project.tasks = [compile, test];
    stores.projects.put(project);

    auto resolver = new FakeRepositoryResolver();
    resolver.add("game", "main", "aaa111");
    resolver.add("game", "release", "rel111");
    auto intake = new RequestIntake(stores, resolver);

    // Runs `action` just before the `n`th write (1 for the next one) through `store`
    void beforeWrite(InterleavingDocumentStore store, size_t n, void delegate() action)
    {
        store.beforeNextWrite = n == 1 ? action : () { beforeWrite(store, n - 1, action); };
    }

    AuthorizedRoutes routerFor(Nullable!Identity identity)
    {
        return apiRouter(new FixedAuthenticator(identity), "test-scheduler-secret", workerTokenKey, workerPoolCredential,
            defaultMaxAttempts, stores, intake);
    }

    struct Reply { int status; string body; }
    Reply run(AuthorizedRoutes router, string body)
    {
        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/run"), HTTPMethod.POST, headers,
            createMemoryStream(cast(ubyte[]) body.dup, false));
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        router.handleRequest(req, res);
        res.finalize();
        const written = cast(string) sink.data.idup;
        return Reply(res.statusCode, written.indexOf('{') < 0 ? "" : written[written.indexOf('{') .. $]);
    }

    // Roles: a member may start builds; a viewer is refused and nobody is not let in
    assert(run(routerFor(Nullable!Identity.init), `{"project_id": "game", "targets": ["compile"]}`).status == HTTPStatus.unauthorized);
    assert(run(routerFor(testIdentity(Role.viewer)), `{"project_id": "game", "targets": ["compile"]}`).status == HTTPStatus.forbidden);
    assert(stores.chains.listForProject("game", 10).length == 0, "Refused requests record nothing");

    auto member = routerFor(testIdentity(Role.member));
    auto created = run(member, `{"project_id": "game", "targets": ["test"]}`);
    assert(created.status == HTTPStatus.created, created.body);
    auto answer = parseJsonString(created.body);
    assert(answer["chain_number"].get!long == 1 && answer["chain_id"].get!string.length > 0 && answer["request_id"].get!string.length > 0);
    auto recorded = stores.requests.get(answer["request_id"].get!string).get.value;
    assert(recorded.requestedBy == "test-user" && recorded.chainId == answer["chain_id"].get!string && recorded.targets == ["test"]);
    assert(recorded.intent == BuildIntent.build, "The intent defaults to build");

    // A recorded request whose reconcile failed is still a 201, with a warning, so it is not repeated
    {
        auto failing = new InterleavingDocumentStore(new InMemoryDocumentStore());
        auto failingStores = new StateStores(failing);
        failingStores.repositories.put(game);
        failingStores.projects.put(project);
        auto failingRouter = apiRouter(new FixedAuthenticator(testIdentity(Role.member)), "test-scheduler-secret", workerTokenKey,
            workerPoolCredential, defaultMaxAttempts, failingStores, new RequestIntake(failingStores, resolver));
        // The writes of a first build: its definition, number, chain, request and state; then the claim
        beforeWrite(failing, 6, () { throw new Exception("store unavailable"); });
        auto pending = run(failingRouter, `{"project_id": "game", "targets": ["compile"]}`);
        assert(pending.status == HTTPStatus.created, pending.body);
        auto pendingAnswer = parseJsonString(pending.body);
        assert(pendingAnswer["warning"].get!string.canFind("reconcile pending") && pendingAnswer["chain_number"].get!long == 1, pending.body);
        assert(failingStores.requests.listForProject("game", 10).length == 1);
    }

    // A later request on the chain, by number or by id, with a ref for the repository
    auto byNumber = run(member, `{"project_id": "game", "targets": ["compile"], "chain": 1, "refs": {"game": "release"}}`);
    assert(byNumber.status == HTTPStatus.created, byNumber.body);
    assert(parseJsonString(byNumber.body)["chain_id"] == answer["chain_id"] && parseJsonString(byNumber.body)["chain_number"].get!long == 1);
    assert(stores.chains.get(answer["chain_id"].get!string).get.pins.length == 2, "Another ref is another pin");
    const byId = run(member, `{"project_id": "game", "targets": ["compile"], "intent": "retry", "chain": "` ~ answer["chain_id"].get!string ~ `"}`);
    assert(byId.status == HTTPStatus.created, byId.body);
    assert(stores.requests.get(parseJsonString(byId.body)["request_id"].get!string).get.intent == BuildIntent.retry);
    const rerun = run(member, `{"project_id": "game", "targets": ["compile"], "intent": "rerun", "chain": 1}`);
    assert(rerun.status == HTTPStatus.created, rerun.body);

    // A malformed body is 400, with a message
    foreach (malformed; [`[]`, `not json`, `{"targets": ["compile"]}`, `{"project_id": "game", "targets": "compile"}`,
        `{"project_id": "game", "targets": [1]}`, `{"project_id": "game", "targets": []}`, `{"project_id": "game", "targets": ["compile"], "intent": "fly"}`,
        `{"project_id": "game", "targets": ["compile"], "chain": 0}`, `{"project_id": "game", "targets": ["compile"], "chain": ""}`, `{"project_id": "game", "targets": ["compile"], "chain": true}`,
        `{"project_id": "game", "targets": ["compile"], "refs": {"game": 1}}`, `{"project_id": "game", "targets": ["compile"], "extra": 1}`,
        `{"project_id": "game", "targets": ["compile"], "intent": "rerun"}`])
    {
        const reply = run(member, malformed);
        assert(reply.status == HTTPStatus.badRequest && parseJsonString(reply.body)["error"].get!string.length > 0, malformed ~ ": " ~ reply.body);
    }

    // Unknown project and chain are 404; a request that cannot be bound or resolved is 422
    assert(run(member, `{"project_id": "nope", "targets": ["compile"]}`).status == HTTPStatus.notFound);
    assert(run(member, `{"project_id": "game", "targets": ["compile"], "chain": 99}`).status == HTTPStatus.notFound);
    assert(run(member, `{"project_id": "game", "targets": ["compile"], "chain": "nope"}`).status == HTTPStatus.notFound);
    const unknownTarget = run(member, `{"project_id": "game", "targets": ["nope"]}`);
    assert(unknownTarget.status == HTTPStatus.unprocessableEntity && parseJsonString(unknownTarget.body)["error"].get!string.canFind("'nope'"));
    const unresolvable = run(member, `{"project_id": "game", "targets": ["compile"], "refs": {"game": "missing"}}`);
    assert(unresolvable.status == HTTPStatus.unprocessableEntity && parseJsonString(unresolvable.body)["error"].get!string.canFind("game/missing"), unresolvable.body);
    assert(stores.chains.listForProject("game", 10).length == 1, "A refused request created no chain");
}
