module confector.server.controller.api_controller;

import vibe.vibe;
import confector.api.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
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
    finishExecution, heartbeatExecution, leaseOfSeconds, releaseExecution, requireAttemptLimit;

import std.format : format;
import std.uuid : randomUUID;
import std.datetime.systime : Clock;

/**
 * Why the routes that start builds fail: starting a build waits for request intake (bead
 * confector-z7z.23.7), the first part of the chain path to accept a request. The routes answer
 * 501 Not Implemented with this exception's message.
 */
NotImplementedException buildsNotImplemented()
{
    return new NotImplementedException("Starting builds", "confector-z7z.23.7");
}

/**
 * Why the build log routes fail: build logs live in the log store, which is bead
 * confector-z7z.31.12. The routes answer 501 Not Implemented with this exception's message; a
 * worker only warns when its log lines are refused.
 */
NotImplementedException logsNotImplemented()
{
    return new NotImplementedException("Build logs", "confector-z7z.31.12");
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
 */
AuthorizedRoutes apiRouter(Authenticator authenticator, string schedulerCallbackSecret, string workerTokenKey, string workerPoolCredential,
    uint maxAttempts, StateStores stores = null)
{
    requireSigningKey(workerTokenKey);
    requireWorkerPoolCredential(workerPoolCredential);
    requireAttemptLimit(maxAttempts);
    auto router = new AuthorizedRoutes(authenticator);

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

    // A stub route answers 501 Not Implemented, naming the bead that implements it.
    void writeNotImplemented(HTTPServerResponse res, NotImplementedException e)
    {
        res.statusCode = HTTPStatus.notImplemented;
        Json err = Json.emptyObject;
        err["error"] = Json(e.msg);
        err["bead"] = Json(e.bead);
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
                auto claimed = claimWork(stores, workerId, lease);
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
                    // This execution's record cannot be run (say, an input without a resolved
                    // value), and would fail every receive that meets it. Fail it, recording why,
                    // and hand out the next one.
                    logError("[api] Failing execution '%s': it cannot be given a worker token: %s", work.workOrder.executionId, e.msg);
                    finishExecution(stores, work.workOrder.executionId, ExecutionStatus.failed, 1,
                        "The execution could not be dispatched: " ~ e.msg, null);
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
            writeLeaseAnswer(res, heartbeatExecution(stores, executionId, attempt, lease));
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
            writeLeaseAnswer(res, releaseExecution(stores, executionId, attempt));
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

    // A worker's completion of an execution. It names the execution only: the fingerprint and
    // task come from the execution record (design record: bead confector-z7z.2), and anything
    // that does not match it is rejected. A completion finishes the execution, folds it into its
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
            const finished = completeExecution(stores, executionId, result);
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

    // Starting a build of a project fails loudly until request intake lands (see
    // buildsNotImplemented). The scheduler calls the second route for cron trigger rules.
    postRoute("/projects/run", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, buildsNotImplemented());
    });

    schedulerRoute("/projects/:id/run", (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, buildsNotImplemented());
    });

    // One tick of the coordination sweep, which the server registers to run every minute (see
    // confector.core.sweep). The summary answers the call. A tick that logged an error answers 500,
    // and keeps doing so until the failing item is fixed: a permanently broken request is seen on
    // every tick. Ticks are idempotent, so the scheduler's retries are safe.
    schedulerRoute("/sweeps/coordination", (HTTPServerRequest req, HTTPServerResponse res) {
        if (!requireStores(res)) return;
        auto summary = sweepCoordination(stores, maxAttempts);
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

    // With the secret the callback reaches its handler, which fails loudly: starting builds waits
    // for request intake
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

    // The token of the execution a /executions/<id>/... path names, which every execution route
    // below presents unless a test says otherwise
    string tokenForPath(string path, StateStores of = null)
    {
        import std.algorithm.searching : startsWith;
        import std.string : split;

        if (!path.startsWith("/executions/")) return null;
        WorkerTokenClaims claims;
        claims.executionId = path.split("/")[2];
        claims.fingerprint = "fp_n1";
        auto recorded = (of is null ? stores : of).executions.get(claims.executionId);
        claims.attempt = recorded.isNull ? 0 : recorded.get.value.attempts;
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

    assert(post("/projects/run", `{"project_id": "proj_api_1"}`) == HTTPStatus.notImplemented);
    {
        InetHeaderMap runHeaders;
        runHeaders["Content-Type"] = "application/json";
        auto runReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/run"),
            HTTPMethod.POST, runHeaders, createMemoryStream(cast(ubyte[]) `{"project_id": "proj_api_1"}`.dup, false));
        auto sink = createMemoryOutputStream();
        auto runRes = createTestHTTPServerResponse(sink);
        routerWithStores.handleRequest(runReq, runRes);
        runRes.finalize();
        const written = cast(string) sink.data;
        assert(written.canFind(`"bead":"confector-z7z.23.7"`), written);
        assert(written.canFind(buildsNotImplemented().msg), written);
    }

    import confector.core.fingerprint_ledger : ClaimOutcome;
    import confector.core.work_orders : claimWork, startExecution;
    import core.time : hours;

    // Dispatches as the dispatcher does: claims the fingerprint's ledger and records the queued
    // execution under the claimed id
    string queueExecution(StateStores into, string fingerprint, TaskNode definition = node,
        string createdAt = "2026-10-16T10:00:00Z")
    {
        const claimed = into.ledgers.claim(fingerprint, 0);
        assert(claimed.outcome == ClaimOutcome.won);
        const id = claimed.executionId;
        TaskExecution execution;
        execution.id = id;
        execution.projectId = "proj_api_1";
        execution.taskId = "n1";
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.definition = definition;
        execution.createdAt = createdAt;
        into.executions.createIfAbsent(execution);
        return id;
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
        assert(stores.executions.get(pending).get.status == ExecutionStatus.queued, "A refused receive hands out nothing");

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
        assert(stores.executions.get(pending).get.status == ExecutionStatus.queued);

        // With the credential, the same receive claims the queued execution and answers with its
        // attempt and work order
        const accepted = receiveWithCredential(workerPoolCredential);
        assert(accepted.status == HTTPStatus.ok, accepted.body);
        const handed = bodyOf(accepted);
        assert(handed["attempt"].get!long == 1 && handed["work_order"]["execution_id"].get!string == pending, accepted.body);
        const claimedRecord = stores.executions.get(pending).get;
        assert(claimedRecord.status == ExecutionStatus.running && claimedRecord.worker == "w-pool" && claimedRecord.attempts == 1);
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
        assert(stores.executions.get(tokenExecutionId).get.status == ExecutionStatus.running, "A refused request changes nothing");

        // A token for a superseded attempt may not complete or log, even though it is genuine and
        // unexpired
        auto superseded = cast() issuedClaims;
        superseded.attempt = issuedClaims.attempt + 1;
        const supersededToken = mintWorkerToken(workerTokenKey, superseded);
        foreach (route; ["/logs", "/complete"])
        {
            assert(postWith(supersededToken, "/executions/" ~ tokenExecutionId ~ route, `{}`) == HTTPStatus.forbidden, route);
        }
        assert(stores.executions.get(tokenExecutionId).get.status == ExecutionStatus.running);

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
        assert(stores.executions.get(executionId).get.status == ExecutionStatus.running,
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
        assert(stores.executions.get(leasedId).get.leaseExpiresAt.length > 0);
        // The body's attempt must be the token's, as for completion and logs
        assert(postWith(firstToken, heartbeat, `{"attempt": 2, "lease_seconds": 30}`) == HTTPStatus.forbidden);
        assert(postWith(firstToken, release, `{"attempt": 2}`) == HTTPStatus.forbidden);
        assert(stores.executions.get(leasedId).get.status == ExecutionStatus.running);
        assert(postWith(firstToken, heartbeat, `{"lease_seconds": 30}`) == HTTPStatus.badRequest, "A heartbeat carries the attempt");
        assert(postWith(firstToken, heartbeat, `{"attempt": 1}`) == HTTPStatus.badRequest, "A heartbeat carries the lease");
        assert(postWith(firstToken, release, `{}`) == HTTPStatus.badRequest, "A release carries the attempt");
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 0}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": "soon"}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 9223372036854775807}`) == HTTPStatus.badRequest);
        assert(postWith(firstToken, heartbeat, `{"attempt": "one", "lease_seconds": 30}`) == HTTPStatus.badRequest);

        assert(answerOf(firstToken, release, `{"attempt": 1}`) == "released");
        assert(stores.executions.get(leasedId).get.status == ExecutionStatus.queued);
        assert(answerOf(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 30}`) == "superseded");

        const second = bodyOf(postReply(null, "/queue/receive", `{"worker_id": "w-two", "lease_seconds": 30}`));
        assert(second["work_order"]["execution_id"].get!string == leasedId && second["attempt"].get!long == 2);
        const secondToken = second["work_order"]["worker_token"].get!string;
        assert(stores.executions.get(leasedId).get.worker == "w-two");

        // The first attempt can neither heartbeat, release nor complete, whether it names its own
        // attempt or the current one; the second completes
        assert(postWith(firstToken, heartbeat, `{"attempt": 2, "lease_seconds": 30}`) == HTTPStatus.forbidden,
            "A token for attempt 1 cannot heartbeat attempt 2");
        assert(postWith(firstToken, release, `{"attempt": 2}`) == HTTPStatus.forbidden, "A token for attempt 1 cannot release attempt 2");
        assert(stores.executions.get(leasedId).get.status == ExecutionStatus.running);
        assert(answerOf(firstToken, heartbeat, `{"attempt": 1, "lease_seconds": 30}`) == "superseded");
        const completeLeased = "/executions/" ~ leasedId ~ "/complete";
        assert(postWith(firstToken, completeLeased, `{"status": "succeeded", "attempt": 1}`) == HTTPStatus.forbidden);
        assert(postWith(secondToken, completeLeased, `{"status": "succeeded", "attempt": 1}`) == HTTPStatus.conflict);
        assert(stores.executions.get(leasedId).get.status == ExecutionStatus.running);
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
        const brokenId = queueExecution(stores, "fp_broken", needy, "2026-10-16T10:00:01Z");
        const healthyId = queueExecution(stores, "fp_healthy", node, "2026-10-16T10:00:02Z");
        const batch = postReply(null, "/queue/receive", `{"worker_id": "w-batch", "lease_seconds": 30}`);
        assert(batch.status == HTTPStatus.ok && bodyOf(batch)["work_order"]["execution_id"].get!string == healthyId, batch.body);
        const broken = stores.executions.get(brokenId).get;
        assert(broken.status == ExecutionStatus.failed && broken.errorMessage.canFind("could not be dispatched")
            && broken.errorMessage.canFind("up"), broken.errorMessage);
        assert(postReply(null, "/queue/receive", `{"worker_id": "w-batch", "lease_seconds": 30}`).status == HTTPStatus.noContent);
    }

    // Build logs fail loudly until the log store lands, naming its bead: uploading lines and
    // reading a log both answer 501
    {
        assert(post("/executions/" ~ executionId ~ "/logs", `{"lines": ["compiling", "linking"]}`) == HTTPStatus.notImplemented);
        foreach (method; [HTTPMethod.POST, HTTPMethod.GET])
        {
            const written = answer(method, "/executions/" ~ executionId ~ "/logs", `{"lines": ["compiling"]}`);
            assert(written.canFind(`"bead":"confector-z7z.31.12"`), written);
            assert(written.canFind(logsNotImplemented().msg), written);
        }
    }

    // A worker's completion names its execution in the route. An unknown execution, a cache hit
    // or a completion naming another task is rejected and records nothing. A fingerprint in the
    // body is not part of the completion and cannot choose the cache key (bug confector-1oj)
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
    assert(stores.executions.get(executionId).get.status == ExecutionStatus.running);

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
    assert(failingStores.executions.get(anotherId).get.status == ExecutionStatus.running);

    // A completion whose fold fails after the execution finished (the execution was never
    // claimed on a ledger) is a server error that says so; the execution stays finished and a
    // resent completion is a conflict
    const unfoldedId = "exe_unclaimed";
    TaskExecution unclaimed;
    unclaimed.id = unfoldedId;
    unclaimed.projectId = "proj_api_1";
    unclaimed.taskId = "n1";
    unclaimed.fingerprint = "fp_n1_unfolded";
    unclaimed.status = ExecutionStatus.queued;
    unclaimed.definition = node;
    unclaimed.createdAt = "2026-10-16T10:00:00Z";
    stores.executions.createIfAbsent(unclaimed);
    assert(!startExecution(stores.executions, unfoldedId, "w-unfolded", 1.hours, "2026-10-16T10:00:00Z").isNull);
    assert(post("/executions/" ~ unfoldedId ~ "/complete", completion) == HTTPStatus.internalServerError);
    assert(stores.executions.get(unfoldedId).get.status == ExecutionStatus.succeeded);
    assert(post("/executions/" ~ unfoldedId ~ "/complete", completion) == HTTPStatus.conflict);

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
    import confector.api.model : ExecutionStatus, TaskExecution;
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

    TaskExecution execution;
    execution.id = "exe_sweep";
    execution.projectId = "proj";
    execution.taskId = "compile";
    execution.fingerprint = "fp_sweep";
    execution.status = ExecutionStatus.queued;
    execution.createdAt = "2000-01-01T00:00:00Z";
    stores.executions.create(execution);
    assert(!startExecution(stores.executions, "exe_sweep", "w1", 1.minutes, "2000-01-01T00:00:00Z").isNull);

    // Without the secret, or with another one, the tick does not run
    assert(sweepTick(router, "").status == HTTPStatus.unauthorized);
    assert(sweepTick(router, "wrong-secret").status == HTTPStatus.unauthorized);
    assert(stores.executions.get("exe_sweep").get.status == ExecutionStatus.running, "A refused tick changes nothing");

    // With the secret it runs: the expired lease is requeued and the summary says so
    auto answered = sweepTick(router, "test-scheduler-secret");
    assert(answered.status == HTTPStatus.ok, answered.body);
    assert(parseJsonString(answered.body)["leasesRequeued"].get!long == 1, answered.body);
    assert(parseJsonString(answered.body)["errors"].get!long == 0, answered.body);
    assert(stores.executions.get("exe_sweep").get.status == ExecutionStatus.queued);
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
