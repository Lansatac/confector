module confector.server.controller.api_controller;

import vibe.vibe;
import confector.api.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
import confector.core.not_implemented : NotImplementedException;
import confector.core.state_stores : StateStores;
import confector.api.dispatch_queue;
import confector.core.worker_token : WorkerTokenClaims, mintWorkerToken, requireExecution, requireReceipt, requireSigningKey, workerTokenClaimsFor;
import confector.core.worker_pool_credential : requireWorkerPoolCredential;
import confector.server.scheduler_callback : schedulerCallback;
import confector.server.worker_auth : authenticateWorker, authenticateWorkerPool, permitWorker, requireCurrentExecutionAttempt;
import confector.server.authenticator : Authenticator;
import confector.server.route_access : AuthorizedRoutes, ExcludedBy;
import confector.core.work_orders : completeExecution, defaultMaxAttempts, defaultPoolQueue, finishExecution;

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
 * is checked before anything else. Receiving mints the worker token of each execution it hands out;
 * the routes a worker calls once it holds a work order (lease extension, release and
 * acknowledgement, logs, completion) need that token, signed with `workerTokenKey`. Neither is
 * reached by a user identity.
 */
AuthorizedRoutes apiRouter(Authenticator authenticator, string schedulerCallbackSecret, string workerTokenKey, string workerPoolCredential, uint maxExecutionAttempts, DispatchQueue queue = null, StateStores stores = null)
{
    requireSigningKey(workerTokenKey);
    requireWorkerPoolCredential(workerPoolCredential);
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

    // Dispatch queue endpoints, for workers that receive work through the control plane. The
    // dispatch queue is internal delivery only; it is never listed or counted for display.
    if (queue !is null)
    {
        void writeQueueError(HTTPServerResponse res, Exception e)
        {
            // A lost lease is a conflict the worker must react to (stop or skip the work); a usage
            // error is a malformed request; anything else is a server-side failure.
            if (cast(LeaseLostException) e)
                res.statusCode = HTTPStatus.conflict;
            else if (cast(DispatchQueueUsageException) e)
                res.statusCode = HTTPStatus.badRequest;
            else
                res.statusCode = HTTPStatus.internalServerError;
            Json err = Json.emptyObject;
            err["error"] = Json(e.msg);
            res.writeJsonBody(err);
        }

        poolRoute("/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
            if (!authenticateWorkerPool(workerPoolCredential, req, res)) return;
            try
            {
                import core.time : seconds;
                import confector.core.work_orders : giveBackUnstarted, receiveWork;

                if (stores is null)
                {
                    throw new Exception("Receiving work needs the state stores: the dispatch queue carries only execution ids");
                }
                auto pMax = "max_messages" in req.json;
                auto pVis = "visibility_timeout" in req.json;
                auto pWorker = "worker_id" in req.json;
                size_t maxMsgs = pMax !is null ? pMax.get!size_t : 1;
                long visibility = pVis !is null ? pVis.get!long : 30;
                // Required: the execution records which worker holds it (receiveWork rejects an
                // empty id)
                string workerId = pWorker !is null ? pWorker.get!string : null;
                // The queue carries execution ids; the work order is built from the execution's
                // record, which receiving starts
                auto received = receiveWork(stores, queue, defaultPoolQueue, maxMsgs, visibility.seconds, workerId, maxExecutionAttempts);
                try
                {
                    Json leases = Json.emptyArray;
                    foreach (ref item; received)
                    {
                        try
                        {
                            item.workOrder.workerToken = mintWorkerToken(workerTokenKey,
                                workerTokenClaimsFor(item.workOrder, item.receipt, item.attempt, Clock.currTime.toUnixTime()));
                        }
                        catch (Exception e)
                        {
                            // This execution's record cannot be run (say, an input without a resolved
                            // value), and would fail every receive that meets it. Fail it, recording
                            // why, drop its message and hand out the rest.
                            logError("[api] Failing execution '%s': it cannot be given a worker token: %s", item.workOrder.executionId, e.msg);
                            finishExecution(stores, item.workOrder.executionId, ExecutionStatus.failed, 1,
                                "The execution could not be dispatched: " ~ e.msg, null);
                            queue.ack(defaultPoolQueue, item.receipt);
                            continue;
                        }
                        Json lease = Json.emptyObject;
                        lease["receipt"] = Json(item.receipt);
                        lease["receive_count"] = Json(item.receiveCount);
                        lease["work_order"] = serializeToJson(item.workOrder);
                        leases ~= lease;
                    }
                    res.writeJsonBody(leases);
                }
                catch (Exception e)
                {
                    // The worker will never see these leases; give them back rather than leave the
                    // work invisible until the leases expire. The executions were started but no
                    // worker ran them, so the starts are undone and redelivery does not count as
                    // another attempt. Best effort: the original error is what the caller needs.
                    giveBackUnstarted(stores, queue, defaultPoolQueue, received);
                    throw e;
                }
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        // A lease's routes need the token issued with that lease
        workerRoute(HTTPMethod.POST, "/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
            WorkerTokenClaims claims;
            if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
            try
            {
                const receipt = req.json["receipt"].get!string;
                if (!permitWorker(req, res, { requireReceipt(claims, receipt); })) return;
                queue.ack(defaultPoolQueue, receipt);
                Json resp = Json.emptyObject;
                resp["status"] = Json("acknowledged");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        workerRoute(HTTPMethod.POST, "/queue/extend", (HTTPServerRequest req, HTTPServerResponse res) {
            WorkerTokenClaims claims;
            if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
            try
            {
                import core.time : seconds;

                const receipt = req.json["receipt"].get!string;
                if (!permitWorker(req, res, { requireReceipt(claims, receipt); })) return;
                auto pVis = "visibility_timeout" in req.json;
                long visibility = pVis !is null ? pVis.get!long : 30;
                queue.extend(defaultPoolQueue, receipt, visibility.seconds);
                Json resp = Json.emptyObject;
                resp["status"] = Json("extended");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        workerRoute(HTTPMethod.POST, "/queue/release", (HTTPServerRequest req, HTTPServerResponse res) {
            WorkerTokenClaims claims;
            if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
            try
            {
                import core.time : seconds;

                const receipt = req.json["receipt"].get!string;
                if (!permitWorker(req, res, { requireReceipt(claims, receipt); })) return;
                auto pDelay = "delay" in req.json;
                long delay = pDelay !is null ? pDelay.get!long : 0;
                queue.release(defaultPoolQueue, receipt, delay.seconds);
                Json resp = Json.emptyObject;
                resp["status"] = Json("released");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });
    }

    // The execution routes answer with a status that tells a worker what to do: 400 for a
    // malformed request, 404 for an unknown execution, 409 for a report that came too late (the
    // execution already finished), 422 for a completion that can never be recorded as reported,
    // and 500 for anything else (a store failure), which the worker may retry. A worker
    // acknowledges its work order on 409 and 422, since running it again would be rejected again.
    void writeError(HTTPServerResponse res, HTTPStatus status, string message)
    {
        res.statusCode = status;
        Json err = Json.emptyObject;
        err["error"] = Json(message);
        res.writeJsonBody(err);
    }

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
    // fingerprint's ledger and wakes the chains waiting on it; see
    // confector.core.work_orders.completeExecution. The worker acknowledges its own work order.
    workerRoute(HTTPMethod.POST, "/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        import confector.core.work_orders : InvalidCompletionException, OutcomeNotFoldedException, StaleCompletionException,
            UnknownExecutionException;

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
            // The execution is finished and final; only the ledger fold or the wake failed. Say
            // so loudly (500) rather than report success: resending is answered 409, and the fold
            // is repaired by a sweep that settles ledgers and wakes their waiters (not yet built).
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
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.server.authenticator : FixedAuthenticator, Identity, testIdentity;
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    import std.typecons : Nullable;

    string testDir = "test_api_controller_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();

    enum workerTokenKey = "0123456789abcdef0123456789abcdef";
    enum workerPoolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
    auto admin = new FixedAuthenticator(testIdentity(Role.admin));
    auto router = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue);
    assert(router !is null);

    // A router needs an authenticator, a signing key and a worker pool credential of a usable length
    import std.exception : assertThrown;
    assertThrown!Exception(apiRouter(null, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", "", workerPoolCredential, defaultMaxAttempts, queue));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", workerTokenKey, "", defaultMaxAttempts, queue));
    assertThrown!Exception(apiRouter(admin, "test-scheduler-secret", workerTokenKey, "too-short", defaultMaxAttempts, queue));

    // A user route refuses a request without an identity, and one whose role is too low
    auto nobodyRouter = apiRouter(new FixedAuthenticator(Nullable!Identity.init), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue);
    auto unidentifiedRes = createTestHTTPServerResponse();
    nobodyRouter.handleRequest(createTestHTTPServerRequest(URL("http://localhost/api/v1/projects"), HTTPMethod.GET), unidentifiedRes);
    assert(unidentifiedRes.statusCode == HTTPStatus.unauthorized);

    auto viewerRouter = apiRouter(new FixedAuthenticator(testIdentity(Role.viewer)), "test-scheduler-secret",
        workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue);
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
    import vibe.stream.memory : createMemoryStream;

    auto routerWithStores = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue, stores);

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
        claims.receipt = "receipt_test";
        auto recorded = (of is null ? stores : of).executions.get(claims.executionId);
        claims.attempt = recorded.isNull ? 0 : recorded.get.value.attempts;
        claims.expiresAt = Clock.currTime.toUnixTime() + 600;
        return mintWorkerToken(workerTokenKey, claims);
    }

    int postWith(string token, string path, string body)
    {
        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        if (token.length > 0) headers[workerTokenHeader] = token;
        if (path == "/queue/receive") headers[workerPoolCredentialHeader] = workerPoolCredential;
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path),
            HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) body.dup, false));
        auto res = createTestHTTPServerResponse();
        routerWithStores.handleRequest(req, res);
        return res.statusCode;
    }

    int post(string path, string body)
    {
        return postWith(tokenForPath(path), path, body);
    }

    // The body a request to `path` is answered with
    string answer(HTTPMethod method, string path, string body = null)
    {
        import vibe.stream.memory : createMemoryOutputStream;

        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        if (tokenForPath(path).length > 0) headers[workerTokenHeader] = tokenForPath(path);
        if (path == "/queue/receive") headers[workerPoolCredentialHeader] = workerPoolCredential;
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path), method, headers,
            createMemoryStream(cast(ubyte[]) body.dup, false));
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        routerWithStores.handleRequest(req, res);
        res.finalize();
        return cast(string) sink.data.idup;
    }

    assert(post("/projects/run", `{"project_id": "proj_api_1"}`) == HTTPStatus.notImplemented);
    {
        import std.algorithm.searching : canFind;
        import vibe.stream.memory : createMemoryOutputStream;

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

    // An execution recorded and sent to the dispatch queue, received by a worker
    import confector.core.fingerprint_ledger : ClaimOutcome;
    import confector.core.work_orders : dispatchMessageFor, receiveWork;
    import core.time : hours;

    // Dispatches as the dispatcher does: claims the fingerprint's ledger, records the execution
    // under the claimed id and sends its message
    string queueExecution(StateStores into, string fingerprint, TaskNode definition = node)
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
        execution.createdAt = "2026-10-16T10:00:00Z";
        into.executions.createIfAbsent(execution);
        queue.ensureQueue(defaultPoolQueue);
        queue.send(defaultPoolQueue, serializeToJson(dispatchMessageFor(id)));
        return id;
    }

    // Receiving needs the worker pool credential, checked before anything else: without it, or
    // with a wrong one, the receive is refused with 401, names only the header, and hands out
    // nothing; the queued execution stays queued
    {
        import vibe.stream.memory : createMemoryOutputStream;
        import std.algorithm.searching : canFind;

        struct Refusal { int status; string body; }
        Refusal receiveWithCredential(string credential)
        {
            InetHeaderMap headers;
            headers["Content-Type"] = "application/json";
            if (credential.length > 0) headers[workerPoolCredentialHeader] = credential;
            auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1/queue/receive"),
                HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) `{"worker_id": "w-pool", "max_messages": 10}`.dup, false));
            auto sink = createMemoryOutputStream();
            auto res = createTestHTTPServerResponse(sink);
            routerWithStores.handleRequest(req, res);
            res.finalize();
            return Refusal(res.statusCode, cast(string) sink.data.idup);
        }

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

        // With the credential, the same receive delivers the queued execution
        const accepted = receiveWithCredential(workerPoolCredential);
        assert(accepted.status == HTTPStatus.ok && accepted.body.canFind(pending), accepted.body);
        assert(stores.executions.get(pending).get.status == ExecutionStatus.running);
    }

    const executionId = queueExecution(stores, "fp_n1");
    auto received = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "test-worker", defaultMaxAttempts);
    assert(received.length == 1 && received[0].workOrder.executionId == executionId);

    // A poison message on the queue fails the receive that meets it loudly, and is gone for the
    // next one instead of being delivered forever
    queue.send(defaultPoolQueue, serializeToJson(dispatchMessageFor("exe_missing")));
    import std.algorithm.searching : canFind;
    assert(post("/queue/receive", `{"worker_id": "w-route", "max_messages": 5}`) == HTTPStatus.internalServerError,
        "A poison message fails its receive");
    queue.send(defaultPoolQueue, serializeToJson(dispatchMessageFor("exe_missing")));
    const poisonAnswer = answer(HTTPMethod.POST, "/queue/receive", `{"worker_id": "w-route", "max_messages": 5}`);
    assert(poisonAnswer.canFind("acknowledged and dropped"), poisonAnswer);
    assert(post("/queue/receive", `{"worker_id": "w-route", "max_messages": 5}`) == HTTPStatus.ok);

    // Receiving a work order mints the token for that execution, fingerprint and lease; the lease
    // routes accept only that token, and only for that lease
    {
        const tokenExecutionId = queueExecution(stores, "fp_token");
        import std.string : indexOf;

        const response = answer(HTTPMethod.POST, "/queue/receive", `{"worker_id": "w-token", "max_messages": 10}`);
        auto leases = parseJsonString(response[response.indexOf('[') .. $]);
        assert(leases.length == 1, leases.toString());
        const receipt = leases[0]["receipt"].get!string;
        const issued = leases[0]["work_order"]["worker_token"].get!string;
        const issuedClaims = verifyWorkerToken(workerTokenKey, issued, Clock.currTime.toUnixTime());
        assert(issuedClaims.executionId == tokenExecutionId && issuedClaims.fingerprint == "fp_token" && issuedClaims.receipt == receipt);

        auto other = cast() issuedClaims;
        other.receipt = "another_receipt";
        const otherLeaseToken = mintWorkerToken(workerTokenKey, other);
        const body = `{"receipt": "` ~ receipt ~ `"}`;
        foreach (route; ["/queue/extend", "/queue/release", "/queue/ack"])
        {
            assert(postWith(null, route, body) == HTTPStatus.unauthorized, route ~ " without a token");
            assert(postWith("garbage", route, body) == HTTPStatus.unauthorized, route ~ " with a malformed token");
            assert(postWith(otherLeaseToken, route, body) == HTTPStatus.forbidden, route ~ " with another lease's token");
        }
        auto lapsed = cast() issuedClaims;
        lapsed.expiresAt = 1;
        const lapsedToken = mintWorkerToken(workerTokenKey, lapsed);
        const alteredToken = issued[0 .. 10] ~ (issued[10] == 'A' ? "B" : "A") ~ issued[11 .. $];
        foreach (route; ["/queue/extend", "/queue/release", "/queue/ack"])
        {
            assert(postWith(lapsedToken, route, body) == HTTPStatus.unauthorized, route ~ " with an expired token");
            assert(postWith(alteredToken, route, body) == HTTPStatus.unauthorized, route ~ " with an altered token");
        }
        assert(postWith(issued, "/queue/extend", body) == HTTPStatus.ok);

        // A token for a superseded attempt may not complete, log or upload, even though it is
        // genuine and unexpired
        auto superseded = cast() issuedClaims;
        superseded.attempt = issuedClaims.attempt + 1;
        const supersededToken = mintWorkerToken(workerTokenKey, superseded);
        foreach (route; ["/logs", "/complete"])
        {
            assert(postWith(supersededToken, "/executions/" ~ tokenExecutionId ~ route, `{}`) == HTTPStatus.forbidden, route);
        }
        assert(stores.executions.get(tokenExecutionId).get.status == ExecutionStatus.running);
        assert(postWith(issued, "/queue/ack", body) == HTTPStatus.ok);

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

    // An execution that cannot be given a token (its input has no resolved value) is failed,
    // with the reason, and its message dropped; the rest of the batch is handed out
    {
        import std.string : indexOf;

        TaskNode needy = node;
        needy.inputs["up"] = taskOutputInput("up-task", "a.zip");
        const brokenId = queueExecution(stores, "fp_broken", needy);
        const healthyId = queueExecution(stores, "fp_healthy");
        const batch = answer(HTTPMethod.POST, "/queue/receive", `{"worker_id": "w-batch", "max_messages": 10}`);
        auto handedOut = parseJsonString(batch[batch.indexOf('[') .. $]);
        assert(handedOut.length == 1 && handedOut[0]["work_order"]["execution_id"].get!string == healthyId, batch);
        const broken = stores.executions.get(brokenId).get;
        assert(broken.status == ExecutionStatus.failed && broken.errorMessage.canFind("could not be dispatched")
            && broken.errorMessage.canFind("up"), broken.errorMessage);
        const nothingLeft = answer(HTTPMethod.POST, "/queue/receive", `{"worker_id": "w-batch", "max_messages": 10}`);
        assert(nothingLeft.canFind("[]"), nothingLeft);
    }

    // Build logs fail loudly until the log store lands, naming its bead: uploading lines and
    // reading a log both answer 501
    {
        import std.algorithm.searching : canFind;

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
    const completion = `{"task_id": "n1", "status": "succeeded", "exit_code": 0, "duration_ms": 85,`
        ~ ` "fingerprint": "fp_chosen_by_the_worker"}`;
    assert(post("/executions/exe_unknown/complete", completion) == HTTPStatus.notFound, "An unknown execution is rejected");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "cached"}`) == HTTPStatus.badRequest,
        "A cache hit is not an execution status");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1"}`) == HTTPStatus.badRequest, "A completion needs a status");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "running"}`) == HTTPStatus.unprocessableEntity);
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n2", "status": "succeeded"}`) == HTTPStatus.unprocessableEntity);
    assert(post("/executions/" ~ executionId ~ "/complete",
        `{"task_id": "n1", "status": "succeeded", "produced_artifacts": [{"artifact_id": "a", "task_fingerprint": "fp_other"}]}`)
        == HTTPStatus.unprocessableEntity, "Artifacts under another fingerprint are rejected for good");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"status": `) == HTTPStatus.badRequest, "Malformed JSON");
    assert(stores.executions.get(executionId).get.status == ExecutionStatus.running);

    // The completion finishes the execution under its own fingerprint
    assert(post("/executions/" ~ executionId ~ "/complete", completion) == HTTPStatus.ok);
    const finished = stores.executions.get(executionId).get;
    assert(finished.status == ExecutionStatus.succeeded && finished.fingerprint == "fp_n1");
    assert(stores.executions.get("fp_chosen_by_the_worker").isNull);
    assert(post("/executions/" ~ executionId ~ "/complete", completion) == HTTPStatus.conflict, "A duplicate completion is rejected");
    assert(stores.executions.get(executionId).get.status == ExecutionStatus.succeeded);

    // A store failure is a server error, not a rejection: the worker keeps its lease and the
    // work order is delivered again
    import confector.testing.memory_document_store : InterleavingDocumentStore;
    auto failingDocuments = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto failingStores = new StateStores(failingDocuments);
    const anotherId = queueExecution(failingStores, "fp_n1_again");
    failingDocuments.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failingRouter = apiRouter(admin, "test-scheduler-secret", workerTokenKey, workerPoolCredential, defaultMaxAttempts, queue, failingStores);
    InetHeaderMap failingHeaders;
    failingHeaders["Content-Type"] = "application/json";
    failingHeaders[workerTokenHeader] = tokenForPath("/executions/" ~ anotherId ~ "/complete", failingStores);
    auto failingReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ anotherId ~ "/complete"),
        HTTPMethod.POST, failingHeaders, createMemoryStream(cast(ubyte[]) completion.dup, false));
    auto failingRes = createTestHTTPServerResponse();
    failingRouter.handleRequest(failingReq, failingRes);
    assert(failingRes.statusCode == HTTPStatus.internalServerError);
    failingDocuments.beforeNextWrite = null;
    assert(failingStores.executions.get(anotherId).get.status == ExecutionStatus.queued);

    // A completion whose fold fails after the execution finished (a chain waiting on the
    // fingerprint has no chain state) is a server error that says so; the execution stays finished
    // and a resent completion is a conflict
    const unfoldedId = queueExecution(stores, "fp_n1_unfolded");
    stores.ledgers.subscribe(stores.ledgers.get("fp_n1_unfolded").get, "chain_without_state");
    assert(post("/executions/" ~ unfoldedId ~ "/complete", completion) == HTTPStatus.internalServerError);
    assert(stores.executions.get(unfoldedId).get.status == ExecutionStatus.succeeded);
    assert(post("/executions/" ~ unfoldedId ~ "/complete", completion) == HTTPStatus.conflict);

    // Without the state stores the execution routes fail loudly rather than drop the report
    InetHeaderMap headers;
    headers["Content-Type"] = "application/json";
    headers[workerTokenHeader] = tokenForPath("/executions/" ~ executionId ~ "/complete");
    auto noStoresReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ executionId ~ "/complete"),
        HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) completion.dup, false));
    auto noStoresRes = createTestHTTPServerResponse();
    router.handleRequest(noStoresReq, noStoresRes);
    assert(noStoresRes.statusCode == HTTPStatus.internalServerError);
}
