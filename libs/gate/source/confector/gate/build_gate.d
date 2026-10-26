module confector.gate.build_gate;

/**
 * The Milestone 1 gate: caching and dispatch end to end. Every build is started through
 * POST /api/v1/projects/run, and every worker acts through the worker routes (queue receive,
 * heartbeat, completion), on the real apiRouter. Only time is controlled: the routes read it from
 * a GateClock, and the coordination sweep is the scheduler route, called with its secret.
 *
 * The scenarios are written once and run over each document store: in-memory always, and MongoDB
 * when the `unittest-mongo` configuration is used (it needs CONFECTOR_TEST_MONGO_URI).
 */
version (unittest):

import confector.api.document_store : DocumentStore;
import confector.api.model;
import confector.api.scheduler : schedulerSecretHeader;
import confector.core.intake : RequestIntake;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : defaultMaxAttempts;
import confector.core.worker_pool_credential : workerPoolCredentialHeader;
import confector.core.worker_token : workerTokenHeader;
import confector.server.authenticator : Authenticator, Identity;
import confector.server.controller.api_controller : apiRouter;
import confector.server.route_access : AuthorizedRoutes;
import confector.testing.fake_repository_resolver : FakeRepositoryResolver;
import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

import std.algorithm.searching : canFind;
import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable;
import core.time : Duration, seconds;

import vibe.vibe;

private enum schedulerSecret = "gate-scheduler-secret";
private enum workerTokenKey = "0123456789abcdef0123456789abcdef";
private enum poolCredential = "pool-credential-0123456789abcdef0123456789abcdef";
private enum startTime = "2026-10-26T12:00:00Z";

/// Makes an empty document store for one scenario.
alias FreshStore = DocumentStore delegate();

/// The clock the routes and the intake read. A scenario moves it forward instead of sleeping.
final class GateClock
{
    private SysTime m_now;

    this(string start)
    {
        m_now = SysTime.fromISOExtString(start);
    }

    string now()
    {
        return m_now.toISOExtString();
    }

    void advance(Duration by)
    {
        m_now += by;
    }
}

/// Authenticates every request as a member, the role the run route needs.
private final class MemberAuthenticator : Authenticator
{
    Nullable!Identity authenticate(HTTPServerRequest req)
    {
        Identity identity;
        identity.subject = "gate-member";
        identity.roles = [Role.member];
        return Nullable!Identity(identity);
    }
}

/// What the route answered: its status and its JSON body, undefined when the body is empty.
private struct Reply
{
    int status;
    Json body;
}

/// An execution a worker holds: the attempt and token its requests present, and the work order.
private struct Held
{
    string workerId;
    string executionId;
    string fingerprint;
    ulong attempt;
    string token;
    Json workOrder;
}

/// The stores, the router as a member and as a worker, and the time of one scenario.
private final class GateEnvironment
{
    StateStores stores;
    FakeRepositoryResolver resolver;
    GateClock clock;
    private AuthorizedRoutes m_routes;

    /// A project "game" with one task "compile" over repository "game" at ref "main", which
    /// resolves to "c1". Its ref can be moved with `resolver.add`.
    this(DocumentStore documents)
    {
        stores = new StateStores(documents);
        clock = new GateClock(startTime);
        resolver = new FakeRepositoryResolver();
        resolver.add("game", "main", "c1");

        RepositoryRecord game;
        game.name = "game";
        game.address = "https://example.test/game.git";
        stores.repositories.put(game);

        ProjectRecord project;
        project.id = "game";
        project.tasks = [compileTask()];
        stores.projects.put(project);

        m_routes = apiRouter(new MemberAuthenticator(), schedulerSecret, workerTokenKey, poolCredential,
            defaultMaxAttempts, stores, new RequestIntake(stores, resolver, &clock.now), &clock.now);
    }

    static TaskNode compileTask()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
        compile.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
        return compile;
    }

    /// Starts a build as a member: POST /api/v1/projects/run, which must answer 201. Returns the answer.
    Json build(string payload)
    {
        auto reply = send(HTTPMethod.POST, "/api/v1/projects/run",
            headers("Content-Type", "application/json"), payload);
        assert(reply.status == HTTPStatus.created, format("A build was refused (HTTP %s): %s", reply.status, reply.body.toString()));
        return reply.body;
    }

    /// Adds `task` to project "game" as a member: POST /api/v1/projects/game/tasks, which must answer 200.
    void addTask(TaskNode task)
    {
        auto reply = send(HTTPMethod.POST, "/api/v1/projects/game/tasks",
            headers("Content-Type", "application/json"), serializeToJson(task).toString());
        assert(reply.status == HTTPStatus.ok, format("The task was refused (HTTP %s): %s", reply.status, reply.body.toString()));
    }

    /// Asks for work as `workerId` under a lease of `leaseSeconds`. Null when nothing is queued (204).
    Nullable!Held receive(string workerId, long leaseSeconds)
    {
        Json payload = Json.emptyObject;
        payload["worker_id"] = Json(workerId);
        payload["lease_seconds"] = Json(leaseSeconds);
        auto reply = send(HTTPMethod.POST, "/api/v1/queue/receive",
            headers("Content-Type", "application/json", workerPoolCredentialHeader, poolCredential), payload.toString());
        if (reply.status == HTTPStatus.noContent) return Nullable!Held.init;
        assert(reply.status == HTTPStatus.ok, format("Receiving work failed (HTTP %s): %s", reply.status, reply.body.toString()));

        Held held;
        held.workerId = workerId;
        held.workOrder = reply.body["work_order"];
        held.executionId = held.workOrder["execution_id"].get!string;
        held.fingerprint = held.workOrder["fingerprint"].get!string;
        held.token = held.workOrder["worker_token"].get!string;
        held.attempt = cast(ulong) reply.body["attempt"].get!long;
        return Nullable!Held(held);
    }

    /// Extends `held`'s lease by `leaseSeconds` from now. Answers what the worker is told.
    string heartbeat(in Held held, long leaseSeconds)
    {
        Json payload = Json.emptyObject;
        payload["attempt"] = Json(cast(long) held.attempt);
        payload["lease_seconds"] = Json(leaseSeconds);
        auto reply = send(HTTPMethod.POST, "/api/v1/executions/" ~ held.executionId ~ "/heartbeat",
            headers("Content-Type", "application/json", workerTokenHeader, held.token), payload.toString());
        assert(reply.status == HTTPStatus.ok, format("The heartbeat was refused (HTTP %s): %s", reply.status, reply.body.toString()));
        return reply.body["answer"].get!string;
    }

    /// Reports `held` finished with `status`. The completion must be recorded (200).
    void complete(in Held held, ExecutionStatus status)
    {
        TaskExecutionResult result;
        result.status = status;
        result.attempt = held.attempt;
        auto reply = send(HTTPMethod.POST, "/api/v1/executions/" ~ held.executionId ~ "/complete",
            headers("Content-Type", "application/json", workerTokenHeader, held.token), serializeToJson(result).toString());
        assert(reply.status == HTTPStatus.ok, format("The completion was refused (HTTP %s): %s", reply.status, reply.body.toString()));
    }

    /// One tick of the coordination sweep, as the scheduler calls it. Answers the summary, which
    /// must be a clean tick (200).
    Json sweep()
    {
        auto reply = send(HTTPMethod.POST, "/api/v1/sweeps/coordination",
            headers(schedulerSecretHeader, schedulerSecret), null);
        assert(reply.status == HTTPStatus.ok, format("The sweep failed (HTTP %s): %s", reply.status, reply.body.toString()));
        return reply.body;
    }

    /// The fingerprint `taskId` was built at for request `requestId`.
    string fingerprintOf(string requestId, string taskId)
    {
        foreach (demand; stores.requests.get(requestId).get.value.demands)
        {
            if (demand.taskId == taskId) return demand.fingerprint;
        }
        assert(false, format("Request '%s' has no demand for task '%s'", requestId, taskId));
    }

    RequestOutcome outcomeOf(string requestId)
    {
        return stores.requestStates.get(requestId).get.value.outcome;
    }

    TaskExecution[] executionsOf(string fingerprint)
    {
        return stores.executions.listForFingerprint(fingerprint);
    }

    /// The execution recorded at `fingerprint`, which must be the only one.
    TaskExecution onlyExecutionAt(string fingerprint)
    {
        auto executions = executionsOf(fingerprint);
        assert(executions.length == 1, format("Expected one execution at '%s', found %s", fingerprint, executions.length));
        return executions[0];
    }

    /// The pinned revision of the work order's input `name`.
    static string revisionOf(in Held held, string name)
    {
        foreach (input; held.workOrder["payload"]["inputs"])
        {
            if (input["name"].get!string == name) return input["pinned"].get!string;
        }
        assert(false, format("The work order has no input '%s'", name));
    }

    private Reply send(HTTPMethod method, string path, InetHeaderMap headerMap, string payload)
    {
        import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method, headerMap,
            createMemoryStream(cast(ubyte[]) payload.dup, false));
        m_routes.handleRequest(req, res);
        assert(res.headerWritten, "No route answered " ~ path);
        const text = cast(string) sink.data.idup;
        return Reply(res.statusCode, text.length == 0 ? Json.undefined : parseJsonString(text));
    }
}

/// A header map of the alternating names and values in `pairs`.
private InetHeaderMap headers(string[] pairs...)
{
    InetHeaderMap map;
    for (size_t i = 0; i + 1 < pairs.length; i += 2) map[pairs[i]] = pairs[i + 1];
    return map;
}

private string requestIdOf(Json answer)
{
    return answer["request_id"].get!string;
}

private void newCommitGetsNewFingerprint(FreshStore fresh)
{
    auto env = new GateEnvironment(fresh());
    auto first = env.build(`{"project_id": "game", "targets": ["compile"]}`);
    const firstRequest = requestIdOf(first);
    const firstFingerprint = env.fingerprintOf(firstRequest, "compile");
    auto runFirst = env.receive("worker-a", 60);
    assert(!runFirst.isNull && runFirst.get.fingerprint == firstFingerprint, "The first commit's execution is handed out");
    env.complete(runFirst.get, ExecutionStatus.succeeded);
    assert(env.outcomeOf(firstRequest) == RequestOutcome.succeeded);

    env.resolver.add("game", "main", "c2");
    auto second = env.build(`{"project_id": "game", "targets": ["compile"]}`);
    const secondRequest = requestIdOf(second);
    const secondFingerprint = env.fingerprintOf(secondRequest, "compile");
    assert(secondFingerprint != firstFingerprint, "A new commit gets a new fingerprint");
    assert(second["chain_number"].get!long == 2, "The new commit is a new build, with its own chain");
    assert(env.outcomeOf(secondRequest) == RequestOutcome.open, "The new commit is not a cache hit");

    auto runSecond = env.receive("worker-a", 60);
    assert(!runSecond.isNull && runSecond.get.fingerprint == secondFingerprint, "The new commit's execution runs again");
    assert(GateEnvironment.revisionOf(runSecond.get, "src") == "c2", "The new commit's execution builds the new revision");
    env.complete(runSecond.get, ExecutionStatus.succeeded);
    assert(env.outcomeOf(secondRequest) == RequestOutcome.succeeded);
    assert(env.executionsOf(firstFingerprint).length == 1 && env.executionsOf(secondFingerprint).length == 1,
        "Each commit has exactly one execution");
}

private void sameCommitIsCacheHit(FreshStore fresh)
{
    auto env = new GateEnvironment(fresh());
    auto first = env.build(`{"project_id": "game", "targets": ["compile"]}`);
    const firstRequest = requestIdOf(first);
    const fingerprint = env.fingerprintOf(firstRequest, "compile");
    auto run = env.receive("worker-a", 60);
    assert(!run.isNull);
    env.complete(run.get, ExecutionStatus.succeeded);

    // A new build of the same commit: its task is answered from the cache
    const request = requestIdOf(env.build(`{"project_id": "game", "targets": ["compile"]}`));
    assert(env.fingerprintOf(request, "compile") == fingerprint, "The same commit has the same fingerprint");
    assert(env.outcomeOf(request) == RequestOutcome.succeeded, "The same commit is answered from the cache, without a worker");
    assert(env.executionsOf(fingerprint).length == 1, "The same commit makes no new execution");
    assert(env.receive("worker-b", 60).isNull, "Nothing is queued for a worker");
}

private void taskAddedToChainBuildsFromChainRevision(FreshStore fresh)
{
    auto env = new GateEnvironment(fresh());
    auto first = env.build(`{"project_id": "game", "targets": ["compile"]}`);
    auto run = env.receive("worker-a", 60);
    assert(!run.isNull);
    env.complete(run.get, ExecutionStatus.succeeded);

    TaskNode lint;
    lint.id = "lint";
    lint.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
    lint.steps = [BuildStep("Lint", "bash", Json(["script": Json("make lint")]))];
    env.addTask(lint);
    env.resolver.add("game", "main", "c2");

    auto answer = env.build(`{"project_id": "game", "targets": ["lint"], "chain": 1}`);
    assert(answer["chain_id"].get!string == first["chain_id"].get!string, "The request joins the existing build");
    const request = requestIdOf(answer);
    auto lintRun = env.receive("worker-b", 60);
    assert(!lintRun.isNull && lintRun.get.workOrder["task_node"]["id"].get!string == "lint", "The added task is handed out");
    assert(lintRun.get.fingerprint == env.fingerprintOf(request, "lint"));
    assert(GateEnvironment.revisionOf(lintRun.get, "src") == "c1",
        "The added task builds from the chain's revision, not from the ref's new commit");
    env.complete(lintRun.get, ExecutionStatus.succeeded);
    assert(env.outcomeOf(request) == RequestOutcome.succeeded);
}

private void requestsNeedingOneFingerprintShareOneExecution(FreshStore fresh)
{
    auto env = new GateEnvironment(fresh());
    const first = requestIdOf(env.build(`{"project_id": "game", "targets": ["compile"]}`));
    const second = requestIdOf(env.build(`{"project_id": "game", "targets": ["compile"]}`));
    const fingerprint = env.fingerprintOf(first, "compile");
    assert(env.fingerprintOf(second, "compile") == fingerprint, "Both requests need the same fingerprint");
    assert(env.outcomeOf(first) == RequestOutcome.open && env.outcomeOf(second) == RequestOutcome.open);

    auto claimed = env.receive("worker-a", 60);
    assert(!claimed.isNull && claimed.get.fingerprint == fingerprint, "The shared execution is handed out");
    assert(env.receive("worker-b", 60).isNull, "The second request made no second execution to hand out");
    assert(env.executionsOf(fingerprint).length == 1, "One execution exists for the fingerprint");

    env.complete(claimed.get, ExecutionStatus.succeeded);
    assert(env.outcomeOf(first) == RequestOutcome.succeeded, "The first request succeeds with the shared execution");
    assert(env.outcomeOf(second) == RequestOutcome.succeeded, "The second request succeeds with the shared execution");
    assert(env.onlyExecutionAt(fingerprint).attempts == 1 && env.onlyExecutionAt(fingerprint).status == ExecutionStatus.succeeded);
}

private void twoWorkersCannotClaimOneExecution(FreshStore fresh)
{
    // Worker B's receive runs inside worker A's claim, just before A's compare-and-set write
    auto interleaving = new InterleavingDocumentStore(fresh());
    auto env = new GateEnvironment(interleaving);
    const request = requestIdOf(env.build(`{"project_id": "game", "targets": ["compile"]}`));
    const fingerprint = env.fingerprintOf(request, "compile");

    Nullable!Held raced;
    interleaving.beforeNextWrite = () { raced = env.receive("worker-b", 60); };
    auto claimed = env.receive("worker-a", 60);

    assert(interleaving.beforeNextWrite is null, "Worker B's receive ran before the first claim's write");
    // B's claim writes first, so A's compare-and-set loses and A is answered 204
    assert(!raced.isNull && claimed.isNull, "Only the second worker's claim lands");
    assert(raced.get.attempt == 1 && raced.get.fingerprint == fingerprint, "The winner is given the first attempt");
    auto held = env.onlyExecutionAt(fingerprint);
    assert(held.status == ExecutionStatus.running && held.attempts == 1, "The execution records one claim");
    assert(held.worker == "worker-b", "The record names the worker that was given it");
}

private void lostWorkerIsRetriedThenFails(FreshStore fresh)
{
    auto env = new GateEnvironment(fresh());
    const request = requestIdOf(env.build(`{"project_id": "game", "targets": ["compile"]}`));
    const fingerprint = env.fingerprintOf(request, "compile");

    // The first worker takes the execution at T0 with a 30 second lease, heartbeats at T0+10s,
    // which runs the lease to T0+40s, then goes silent
    auto first = env.receive("worker-a", 30);
    assert(!first.isNull && first.get.attempt == 1);
    env.clock.advance(10.seconds);
    assert(env.heartbeat(first.get, 30) == "continue", "A heartbeat from the holder extends the lease");

    // T0+35s: past the lease the claim started with, but before the extended one runs out
    env.clock.advance(25.seconds);
    assert(env.sweep()["leasesRequeued"].get!long == 0, "A heartbeat extends the lease past the original expiry");
    assert(env.onlyExecutionAt(fingerprint).status == ExecutionStatus.running);

    // T0+50s: the extended lease has run out. Each sweep after an expiry requeues the execution,
    // until the attempt limit fails it
    env.clock.advance(15.seconds);
    auto requeued = env.sweep();
    assert(requeued["leasesRequeued"].get!long == 1 && requeued["leasesFailed"].get!long == 0 && requeued["errors"].get!long == 0,
        requeued.toString());
    assert(env.onlyExecutionAt(fingerprint).status == ExecutionStatus.queued, "The lost execution is queued again");
    assert(env.outcomeOf(request) == RequestOutcome.open, "The request waits for another attempt");

    auto second = env.receive("worker-b", 30);
    assert(!second.isNull && second.get.attempt == 2 && second.get.executionId == first.get.executionId,
        "Another worker is given the lost execution, on its second attempt");
    env.clock.advance(40.seconds);
    requeued = env.sweep();
    assert(requeued["leasesRequeued"].get!long == 1 && requeued["leasesFailed"].get!long == 0, requeued.toString());

    auto third = env.receive("worker-c", 30);
    assert(!third.isNull && third.get.attempt == 3, "The third worker is given the execution, on its third attempt");
    env.clock.advance(40.seconds);
    auto failed = env.sweep();
    assert(failed["leasesFailed"].get!long == 1 && failed["leasesRequeued"].get!long == 0 && failed["errors"].get!long == 0,
        failed.toString());

    auto settled = env.onlyExecutionAt(fingerprint);
    assert(settled.status == ExecutionStatus.failed && settled.errorMessage.canFind("lease lost 3 times"), settled.errorMessage);
    assert(settled.expiredLeases == 3, format("The failed execution counts its three lost leases, found %s", settled.expiredLeases));
    assert(env.outcomeOf(request) == RequestOutcome.failed, "The request fails once the attempts are used up");
    assert(env.receive("worker-d", 30).isNull, "A failed execution is not handed out again");
}

/// Every scenario, over the store `fresh` makes for each one.
private void runGate(FreshStore fresh)
{
    newCommitGetsNewFingerprint(fresh);
    sameCommitIsCacheHit(fresh);
    taskAddedToChainBuildsFromChainRevision(fresh);
    requestsNeedingOneFingerprintShareOneExecution(fresh);
    twoWorkersCannotClaimOneExecution(fresh);
    lostWorkerIsRetriedThenFails(fresh);
}

unittest
{
    runGate(() => cast(DocumentStore) new InMemoryDocumentStore());
}

version (ConfectorGateMongo)
{
    import confector.backends.document_store.mongo : MongoDocumentStore;
    import kaleidic.mongo_standalone : MongoConnection, bson_value, document;
    import std.process : environment;

    /// An empty gate database on the MongoDB at `uri`, dropped and recreated for each scenario.
    /// The connection the store uses is added to `opened`, to be closed when the run is over.
    private DocumentStore freshMongoStore(string uri, ref MongoConnection[] opened)
    {
        enum database = "confector_gate_test";
        auto admin = new MongoConnection(uri);
        admin.runCommand(database, document([bson_value("dropDatabase", 1)]), true, "drop the gate test database");
        admin.socket.close();
        auto connection = new MongoConnection(uri);
        opened ~= connection;
        return new MongoDocumentStore(connection, database);
    }

    unittest
    {
        const uri = environment.get("CONFECTOR_TEST_MONGO_URI", null);
        if (uri.length == 0)
            throw new Exception("The gate's MongoDB variant needs CONFECTOR_TEST_MONGO_URI set to a MongoDB it may write to.");
        MongoConnection[] opened;
        scope (exit)
        {
            foreach (connection; opened) connection.socket.close();
        }
        runGate(() => freshMongoStore(uri, opened));
    }
}
