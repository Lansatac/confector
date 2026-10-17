module confector.server.controller.api_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
import confector.core.not_implemented : NotImplementedException;
import confector.core.state_stores : StateStores;
import confector.core.trigger;
import confector.plugin_api.dispatch_queue;
import confector.server.scheduler_callback : schedulerCallback;
import confector.core.work_orders : completeExecution, defaultPoolQueue;

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
 * The REST API, served under /api/v1. Every route is registered once, with the prefix; the route
 * helpers take paths relative to it.
 */
URLRouter apiRouter(string schedulerCallbackSecret, DispatchQueue queue = null, StateStores stores = null)
{
    auto router = new URLRouter();

    enum string apiPrefix = "/api/v1";

    void postRoute(H)(string path, H handler)
    {
        router.post(apiPrefix ~ path, handler);
    }

    // Routes the scheduler calls back into. Each one requires the scheduler secret; see
    // scheduler_callback.d. Add every new scheduler callback through this helper.
    void schedulerRoute(H)(string path, H handler)
    {
        postRoute(path, schedulerCallback(schedulerCallbackSecret, handler));
    }

    void getRoute(H)(string path, H handler)
    {
        router.get(apiPrefix ~ path, handler);
    }

    void deleteRoute(H)(string path, H handler)
    {
        router.delete_(apiPrefix ~ path, handler);
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

        postRoute("/queue/receive", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;
                import confector.core.work_orders : receiveWork;

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
                auto received = receiveWork(stores, queue, defaultPoolQueue, maxMsgs, visibility.seconds, workerId);
                try
                {
                    Json leases = Json.emptyArray;
                    foreach (ref item; received)
                    {
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
                    // work invisible until the leases expire. Best effort: the original error is
                    // what the caller needs. (The executions were started, so redelivery counts
                    // as another attempt.)
                    foreach (ref item; received)
                    {
                        try
                            queue.release(defaultPoolQueue, item.receipt);
                        catch (Exception releaseError)
                            logError("[api] Failed to release receipt '%s' after a failed receive: %s", item.receipt, releaseError.msg);
                    }
                    throw e;
                }
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/ack", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                queue.ack(defaultPoolQueue, req.json["receipt"].get!string);
                Json resp = Json.emptyObject;
                resp["status"] = Json("acknowledged");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/extend", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;

                auto pVis = "visibility_timeout" in req.json;
                long visibility = pVis !is null ? pVis.get!long : 30;
                queue.extend(defaultPoolQueue, req.json["receipt"].get!string, visibility.seconds);
                Json resp = Json.emptyObject;
                resp["status"] = Json("extended");
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeQueueError(res, e);
            }
        });

        postRoute("/queue/release", (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import core.time : seconds;

                auto pDelay = "delay" in req.json;
                long delay = pDelay !is null ? pDelay.get!long : 0;
                queue.release(defaultPoolQueue, req.json["receipt"].get!string, delay.seconds);
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

    // An execution's log, as its worker streams it (`ExecutionLogStore`). Lines are appended only
    // while the execution is active: the worker sends its last lines before its completion. (A
    // completion landing between the check and the append can let one batch in after it.) A
    // finished execution's log stays readable.
    getRoute("/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        string executionId = req.params["execution_id"];
        try
        {
            if (!requireStores(res)) return;
            if (stores.executions.get(executionId).isNull)
            {
                writeError(res, HTTPStatus.notFound, format("Execution '%s' does not exist", executionId));
                return;
            }
            Json resp = Json.emptyObject;
            resp["execution_id"] = Json(executionId);
            resp["logs"] = serializeToJson(stores.logs.read(executionId));
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            writeError(res, HTTPStatus.internalServerError, format("Could not read the log of execution '%s': %s", executionId, e.msg));
        }
    });

    postRoute("/executions/:execution_id/logs", (HTTPServerRequest req, HTTPServerResponse res) {
        import confector.core.build_stores : ExecutionStore;

        string executionId = req.params["execution_id"];
        string[] lines;
        try
        {
            Json bodyJson = req.json;
            if (bodyJson.type != Json.Type.object || "lines" !in bodyJson || bodyJson["lines"].type != Json.Type.array)
            {
                writeError(res, HTTPStatus.badRequest, "A log upload needs a 'lines' array");
                return;
            }
            lines = deserializeJson!(string[])(bodyJson["lines"]);
        }
        catch (Exception e)
        {
            writeError(res, HTTPStatus.badRequest, format("Malformed log upload for execution '%s': %s", executionId, e.msg));
            return;
        }
        try
        {
            if (!requireStores(res)) return;
            auto execution = stores.executions.get(executionId);
            if (execution.isNull)
            {
                writeError(res, HTTPStatus.notFound, format("Execution '%s' does not exist; its log lines are rejected", executionId));
                return;
            }
            if (!ExecutionStore.isActive(execution.get.status))
            {
                writeError(res, HTTPStatus.conflict, format("Execution '%s' already finished (%s); its log lines are rejected",
                    executionId, execution.get.status));
                return;
            }
            foreach (line; lines)
            {
                stores.logs.append(executionId, line);
            }

            Json resp = Json.emptyObject;
            resp["status"] = Json("ok");
            resp["execution_id"] = Json(executionId);
            resp["appended"] = Json(lines.length);
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            writeError(res, HTTPStatus.internalServerError, format("Could not append to the log of execution '%s': %s", executionId, e.msg));
        }
    });

    // A worker's completion of an execution. It names the execution only: the fingerprint and
    // task come from the execution record (design record: bead confector-z7z.2), and anything
    // that does not match it is rejected. Until the fingerprint ledger lands (beads
    // confector-z7z.49.4) a completion only finishes the execution; see
    // confector.core.work_orders.completeExecution. The worker acknowledges its own work order.
    postRoute("/executions/:execution_id/complete", (HTTPServerRequest req, HTTPServerResponse res) {
        import confector.core.work_orders : InvalidCompletionException, StaleCompletionException, UnknownExecutionException;

        string executionId = req.params["execution_id"];
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
        catch (Exception e)
        {
            logError("[api] Could not record the completion of execution '%s': %s", executionId, e.msg);
            writeError(res, HTTPStatus.internalServerError, format("Could not record the completion of execution '%s': %s", executionId, e.msg));
        }
    });

    // Starting a build of a project fails loudly until request intake lands (see
    // buildsNotImplemented). The scheduler calls the second route for cron trigger rules.
    postRoute("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, buildsNotImplemented());
    });

    schedulerRoute("/projects/:id/run", (HTTPServerRequest req, HTTPServerResponse res) {
        writeNotImplemented(res, buildsNotImplemented());
    });

    // Projects REST API
    getRoute("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
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

    postRoute("/projects", (HTTPServerRequest req, HTTPServerResponse res) {
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

    getRoute("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
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

    deleteRoute("/projects/:id", (HTTPServerRequest req, HTTPServerResponse res) {
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
    getRoute("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
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

    postRoute("/projects/:id/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
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

    getRoute("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
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

    deleteRoute("/projects/:id/tasks/:taskId", (HTTPServerRequest req, HTTPServerResponse res) {
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
    import confector.core.plugin;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;

    string testDir = "test_api_controller_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    class MockApiPlugin : Plugin
    {
        @property string name() const { return "mock-api-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock api plugin"; }
        @property PluginCategory category() const { return PluginCategory.definition; }
        ConfigDefinition[] configDefinitions() const { return null; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}
    }

    PluginRegistry.instance.registerPlugin(new MockApiPlugin());
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();

    auto router = apiRouter("test-scheduler-secret", queue);
    assert(router !is null);

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

    // Test Trigger Rules state via repo
    TriggerRuleRecord rule;
    rule.id = "rule1";
    rule.name = "CI Build";
    rule.triggerType = "git_push";
    rule.criteria = "main";
    stores.triggerRules.save(rule);

    assert(stores.triggerRules.list().length == 1);
    assert(stores.triggerRules.list()[0].name == "CI Build");

    // Test Projects and Tasks via repo
    ProjectRecord proj;
    proj.id = "proj_api_1";
    proj.name = "API Project";
    TaskNode node;
    node.id = "n1";
    node.steps = [BuildStep("Echo", "bash", null, "echo hi")];
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

    auto routerWithStores = apiRouter("test-scheduler-secret", queue, stores);

    int post(string path, string body)
    {
        InetHeaderMap headers;
        headers["Content-Type"] = "application/json";
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path),
            HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) body.dup, false));
        auto res = createTestHTTPServerResponse();
        routerWithStores.handleRequest(req, res);
        return res.statusCode;
    }

    int get(string path)
    {
        auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1" ~ path), HTTPMethod.GET);
        auto res = createTestHTTPServerResponse();
        routerWithStores.handleRequest(req, res);
        return res.statusCode;
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
    import confector.core.work_orders : DispatchMessage, receiveWork;
    import core.time : hours;

    string queueExecution(StateStores into, string id, string fingerprint)
    {
        TaskExecution execution;
        execution.id = id;
        execution.projectId = "proj_api_1";
        execution.taskId = "n1";
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.definition = node;
        execution.createdAt = "2026-10-16T10:00:00Z";
        into.executions.create(execution);
        queue.ensureQueue(defaultPoolQueue);
        queue.send(defaultPoolQueue, serializeToJson(DispatchMessage(id)));
        return id;
    }

    const executionId = queueExecution(stores, "exe_n1", "fp_n1");
    auto received = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "test-worker");
    assert(received.length == 1 && received[0].workOrder.executionId == executionId);

    // The worker streams its log lines to the execution's log; lines for an execution that does
    // not exist, or without a lines array, are rejected
    assert(post("/executions/" ~ executionId ~ "/logs", `{"lines": ["compiling", "linking"]}`) == HTTPStatus.ok);
    assert(stores.logs.read(executionId) == ["compiling", "linking"]);
    assert(get("/executions/" ~ executionId ~ "/logs") == HTTPStatus.ok);
    assert(post("/executions/exe_unknown/logs", `{"lines": ["lost"]}`) == HTTPStatus.notFound);
    assert(get("/executions/exe_unknown/logs") == HTTPStatus.notFound);
    assert(post("/executions/" ~ executionId ~ "/logs", `{"line": "old shape"}`) == HTTPStatus.badRequest);
    assert(post("/executions/" ~ executionId ~ "/logs", `not json`) == HTTPStatus.badRequest);
    assert(stores.logs.read("exe_unknown").length == 0 && stores.logs.read(executionId).length == 2);

    // A worker's completion names its execution in the route. An unknown execution, a cache hit
    // or a completion naming another task is rejected and records nothing. A fingerprint in the
    // body is not part of the completion and cannot choose the cache key (bug confector-1oj)
    const completion = `{"task_id": "n1", "status": "succeeded", "exit_code": 0, "duration_ms": 85,`
        ~ ` "fingerprint": "fp_chosen_by_the_worker"}`;
    assert(post("/executions/exe_unknown/complete", completion) == HTTPStatus.notFound, "An unknown execution is rejected");
    assert(post("/executions/" ~ executionId ~ "/complete", `{"task_id": "n1", "status": "cached"}`) == HTTPStatus.unprocessableEntity);
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

    // A finished execution's log takes no more lines but stays readable
    assert(post("/executions/" ~ executionId ~ "/logs", `{"lines": ["too late"]}`) == HTTPStatus.conflict);
    assert(stores.logs.read(executionId) == ["compiling", "linking"]);
    assert(get("/executions/" ~ executionId ~ "/logs") == HTTPStatus.ok);

    // A store failure is a server error, not a rejection: the worker keeps its lease and the
    // work order is delivered again
    import confector.testing.memory_document_store : InterleavingDocumentStore;
    auto failingDocuments = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto failingStores = new StateStores(failingDocuments);
    const anotherId = queueExecution(failingStores, "exe_n1_again", "fp_n1_again");
    failingDocuments.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failingRouter = apiRouter("test-scheduler-secret", queue, failingStores);
    InetHeaderMap failingHeaders;
    failingHeaders["Content-Type"] = "application/json";
    auto failingReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ anotherId ~ "/complete"),
        HTTPMethod.POST, failingHeaders, createMemoryStream(cast(ubyte[]) completion.dup, false));
    auto failingRes = createTestHTTPServerResponse();
    failingRouter.handleRequest(failingReq, failingRes);
    assert(failingRes.statusCode == HTTPStatus.internalServerError);
    failingDocuments.beforeNextWrite = null;
    assert(failingStores.executions.get(anotherId).get.status == ExecutionStatus.queued);

    // Without the state stores the execution routes fail loudly rather than drop the report
    InetHeaderMap headers;
    headers["Content-Type"] = "application/json";
    auto noStoresReq = createTestHTTPServerRequest(URL("http://localhost/api/v1/executions/" ~ executionId ~ "/complete"),
        HTTPMethod.POST, headers, createMemoryStream(cast(ubyte[]) completion.dup, false));
    auto noStoresRes = createTestHTTPServerResponse();
    router.handleRequest(noStoresReq, noStoresRes);
    assert(noStoresRes.statusCode == HTTPStatus.internalServerError);
}
