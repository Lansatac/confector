module confector.core.chain_evaluator;

/**
 * The chain evaluator (design records: beads confector-z7z.2, confector-z7z.14 and
 * confector-z7z.15; AGENTS.md, "Coordinating builds", "What a build is" and "Re-running a task"):
 * the pure core of build coordination. Given a build chain, the requests made on it, the current
 * rerun generations and the executions recorded for its fingerprints, it derives every task's
 * state and the fingerprints that need an execution. It performs no I/O and reads no clock; the
 * shell loads its inputs (rerun generations with
 * confector.core.rerun_generations.readChainResolution, executions by fingerprint from the state
 * store) and hands the needed fingerprints to the execution dispatcher.
 *
 * Rules:
 *
 * - **Requested** means the task is a target of one of the chain's requests or upstream of one.
 *   A request never covers tasks downstream of its targets.
 * - **A success is always reused** (a cache hit), whichever chain produced it, and whether or not
 *   the task is requested. With several successes at one fingerprint, the latest is used.
 * - **An active execution is attached to**, never duplicated: at most one execution per
 *   fingerprint is queued or running.
 * - **Failures and cancellations are never cache hits, and are never retried automatically.** A
 *   failed or cancelled execution settles every request made before it finished, including
 *   requests that attached to it in flight; a request made after it finished (a retry, or any
 *   later request covering the task) asks for the task again, at the same fingerprint.
 * - **A task needs an execution** when it is requested, has no success and no active execution,
 *   no failure or cancellation settles its latest request, and every upstream task has
 *   succeeded. A task whose upstream task failed or was cancelled is blocked.
 * - **A requested task whose active execution was never sent** (`TaskExecution.sentAt` is empty)
 *   is needed too, so the dispatcher sends it: this is how a dispatcher that failed or crashed
 *   between recording an execution and sending it is repaired by the next evaluation.
 * - **Reruns are strict.** Fingerprints are computed from the chain and the current rerun
 *   generations (`chainResolution`), so after a rerun the rerun task and everything downstream
 *   of it have new fingerprints, and earlier successes are not used: downstream tasks wait for
 *   the new generation to succeed and are blocked if it fails.
 *
 * Infrastructure failures (a lost worker, an expired lease) do not appear here: they retry within
 * the same execution, which stays queued until a worker claims it again or its attempts run out
 * and it fails (`TaskExecution.attempts`). The evaluator reports the attempt count.
 *
 * Timestamps are compared as times, not as text: `SysTime.toISOExtString` leaves out zero
 * fractional seconds, so ISO 8601 strings of one second do not sort as text.
 */

import confector.core.dag : TaskGraph;
import confector.core.input_resolution : GraphResolution, RerunGenerations, chainGraph, chainResolution;
import confector.core.model;

import std.algorithm.searching : endsWith;
import std.algorithm.sorting : sort;
import std.datetime.systime : SysTime;
import std.format : format;

/**
 * The chain evaluator was given inputs that contradict each other or the persisted model.
 */
class ChainEvaluationException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * A chain task's derived state. Never stored.
 */
enum ChainTaskStatus : string
{
    /// No request on the chain covers the task, and no execution at its fingerprint succeeded.
    notRequested = "not_requested",
    /// Requested and not finished: see `ChainTaskState.waitingFor`.
    waiting = "waiting",
    /// Its active execution is held by a worker.
    running = "running",
    /// An execution at its fingerprint succeeded, in this chain or another.
    succeeded = "succeeded",
    /// Its latest execution failed after the latest request covering it was made.
    failed = "failed",
    /// Its latest execution was cancelled after the latest request covering it was made.
    cancelled = "cancelled",
    /// An upstream task failed or was cancelled, so it cannot run.
    blocked = "blocked"
}

/**
 * Why a waiting task is waiting.
 */
enum WaitReason : string
{
    /// The task is not waiting.
    none = "",
    /// It needs dispatching: the dispatcher has not yet recorded an execution for it, or recorded
    /// one (`ChainTaskState.executionId`) but never sent it to the dispatch queue.
    dispatch = "dispatch",
    /// Its execution is queued and was sent to the dispatch queue: not yet claimed by a worker,
    /// or waiting for another attempt after its worker was lost.
    queued = "queued",
    /// An upstream task has not succeeded yet.
    upstream = "upstream"
}

/**
 * One chain task's derived state.
 */
struct ChainTaskState
{
    string taskId;
    /// The task's fingerprint, its base and the base's rerun generation.
    string fingerprint;
    string base;
    ulong generation;
    /// Whether a request on the chain covers the task (as a target or upstream of one).
    bool requested;
    ChainTaskStatus status;
    /// Set when `status` is waiting.
    WaitReason waitingFor;
    /// The execution the state comes from: the success used, the active execution, or the latest
    /// failed or cancelled one. Empty when the state comes from none (waiting for dispatch or
    /// upstream, blocked, or not requested with no execution).
    string executionId;
    /// How many times a worker has claimed `executionId`; 0 without one. More than 1 means
    /// infrastructure failures were retried.
    ulong attempts;
    /// How many executions were recorded at the fingerprint, including earlier failures and
    /// retries.
    size_t executionCount;
    /// When `status` is blocked: the upstream tasks that failed or were cancelled and block it,
    /// sorted.
    string[] blockedBy;
}

/**
 * A fingerprint that needs dispatching: it has no active execution, or its active execution was
 * recorded but never sent. The execution dispatcher (confector.core.execution_dispatcher) claims
 * it, records the execution with the task's resolved inputs (`ChainEvaluation.resolution`) and
 * sends it, or sends the unsent execution it finds holding the claim.
 */
struct NeededExecution
{
    string taskId;
    string fingerprint;
}

/**
 * The result of evaluating a chain.
 */
struct ChainEvaluation
{
    /// Every task's resolved inputs, base and fingerprint at the current rerun generations.
    GraphResolution resolution;
    /// Every task's derived state, keyed by task id.
    ChainTaskState[string] tasks;
    /// The fingerprints that need an execution, in topological order of their tasks.
    NeededExecution[] needed;
}

/**
 * Derives the state of every task of `chain` and the fingerprints that need an execution, from
 * the requests made on the chain, the current rerun `generations` (which must cover every base of
 * the chain, as `chainResolution` requires) and `executionsByFingerprint`, every execution
 * recorded at each of the chain's fingerprints. Executions at fingerprints the chain does not
 * have are ignored. Pure: performs no I/O and reads no clock.
 *
 * Throws: ChainEvaluationException if a request belongs to another chain or project, has no
 * targets (or, for a rerun, more than one), targets a task the chain does not have, or has a
 * timestamp that is not an ISO 8601 UTC time; if an execution is filed under another
 * fingerprint, task or project, has no id or a bad timestamp, or is failed or cancelled without a
 * `finishedAt`; or if a fingerprint has more than one active execution. InputResolutionException
 * if a generation is missing or the chain is inconsistent (see `chainResolution`).
 */
ChainEvaluation evaluateChain(
    in BuildChain chain,
    in BuildRequest[] requests,
    in RerunGenerations generations,
    in TaskExecution[][string] executionsByFingerprint
) @trusted
{
    if (chain.id.length == 0 || chain.projectId.length == 0)
    {
        throw new ChainEvaluationException("A chain to evaluate needs an id and a project id");
    }

    ChainEvaluation result;
    result.resolution = chainResolution(chain.projectId, chain.tasks, generations);
    auto graph = chainGraph(chain.tasks);
    const demandedAt = latestDemands(chain, graph, requests);

    foreach (taskId; graph.topologicalSort())
    {
        ChainTaskState state;
        state.taskId = taskId;
        state.fingerprint = result.resolution.fingerprints[taskId];
        state.base = result.resolution.bases[taskId];
        state.generation = generations[state.base];

        const executions = executionsByFingerprint.get(state.fingerprint, null);
        const summary = summarize(chain.projectId, taskId, state.fingerprint, executions);
        state.executionCount = executions.length;
        auto demand = taskId in demandedAt;
        state.requested = demand !is null;

        void use(const(TaskExecution)* execution)
        {
            if (execution is null) return;
            state.executionId = execution.id;
            state.attempts = execution.attempts;
        }

        if (summary.success !is null)
        {
            state.status = ChainTaskStatus.succeeded;
            use(summary.success);
        }
        else if (!state.requested)
        {
            state.status = ChainTaskStatus.notRequested;
        }
        else if (summary.active !is null)
        {
            use(summary.active);
            if (summary.active.status == ExecutionStatus.running)
            {
                state.status = ChainTaskStatus.running;
            }
            else if (summary.active.sentAt.length == 0)
            {
                // Recorded but never sent: its dispatcher failed or crashed before sending it.
                // The dispatcher sends the execution it finds holding the claim.
                state.status = ChainTaskStatus.waiting;
                state.waitingFor = WaitReason.dispatch;
                result.needed ~= NeededExecution(taskId, state.fingerprint);
            }
            else
            {
                state.status = ChainTaskStatus.waiting;
                state.waitingFor = WaitReason.queued;
            }
        }
        else if (summary.stopped !is null && summary.stoppedAt >= *demand)
        {
            // A failure or cancellation that ended after the latest request settles it, whether
            // the request dispatched the execution or attached to it in flight; only a later
            // request asks for the task again.
            use(summary.stopped);
            state.status = summary.stopped.status == ExecutionStatus.failed
                ? ChainTaskStatus.failed : ChainTaskStatus.cancelled;
        }
        else
        {
            bool upstreamPending = false;
            bool[string] blockers;
            foreach (upstream; graph.getDependencies(taskId))
            {
                const upstreamState = result.tasks[upstream];
                final switch (upstreamState.status)
                {
                    case ChainTaskStatus.succeeded:
                        break;
                    case ChainTaskStatus.failed:
                    case ChainTaskStatus.cancelled:
                        blockers[upstream] = true;
                        break;
                    case ChainTaskStatus.blocked:
                        foreach (root; upstreamState.blockedBy) blockers[root] = true;
                        break;
                    case ChainTaskStatus.waiting:
                    case ChainTaskStatus.running:
                        upstreamPending = true;
                        break;
                    case ChainTaskStatus.notRequested:
                        throw new ChainEvaluationException(format(
                            "Task '%s' of chain '%s' is requested but its upstream task '%s' is not", taskId, chain.id, upstream));
                }
            }

            if (blockers.length > 0)
            {
                state.status = ChainTaskStatus.blocked;
                state.blockedBy = blockers.keys.sort().release;
            }
            else if (upstreamPending)
            {
                state.status = ChainTaskStatus.waiting;
                state.waitingFor = WaitReason.upstream;
            }
            else
            {
                state.status = ChainTaskStatus.waiting;
                state.waitingFor = WaitReason.dispatch;
                result.needed ~= NeededExecution(taskId, state.fingerprint);
            }
        }

        result.tasks[taskId] = state;
    }
    return result;
}

/// For every task some request covers, the time of the latest request covering it: each
/// request covers its targets and their upstream tasks, never downstream ones.
private SysTime[string] latestDemands(in BuildChain chain, const TaskGraph graph, in BuildRequest[] requests)
{
    bool[string] chainTasks;
    foreach (ref task; chain.tasks) chainTasks[task.id] = true;

    SysTime[string] demandedAt;
    foreach (ref request; requests)
    {
        if (request.chainId != chain.id || request.projectId != chain.projectId)
        {
            throw new ChainEvaluationException(format(
                "Request '%s' (project '%s', chain '%s') does not belong to chain '%s' of project '%s'",
                request.id, request.projectId, request.chainId, chain.id, chain.projectId));
        }
        if (request.targets.length == 0)
        {
            throw new ChainEvaluationException(format("Request '%s' on chain '%s' has no targets", request.id, chain.id));
        }
        if (request.intent == BuildIntent.rerun && request.targets.length != 1)
        {
            throw new ChainEvaluationException(format(
                "Rerun request '%s' on chain '%s' names %s targets; a rerun names exactly one", request.id, chain.id, request.targets.length));
        }
        const requestedAt = parseTimestamp(request.requestedAt, format("request '%s' requested_at", request.id));
        foreach (target; request.targets)
        {
            if (target !in chainTasks)
            {
                throw new ChainEvaluationException(format(
                    "Request '%s' targets task '%s', which chain '%s' does not have", request.id, target, chain.id));
            }
            foreach (taskId; graph.resolveSubgraph(target))
            {
                auto existing = taskId in demandedAt;
                if (existing is null || *existing < requestedAt) demandedAt[taskId] = requestedAt;
            }
        }
    }
    return demandedAt;
}

/// The executions at one fingerprint that decide a task's state.
private struct ExecutionSummary
{
    /// The latest succeeded execution.
    const(TaskExecution)* success;
    /// The queued or running execution.
    const(TaskExecution)* active;
    /// The failed or cancelled execution that finished last, and when it finished.
    const(TaskExecution)* stopped;
    SysTime stoppedAt;
}

/// Validates the executions recorded at `fingerprint` for task `taskId` and summarizes them.
/// "Latest" is by creation time (finish time for failures and cancellations), then by id, so the
/// choice is deterministic.
private ExecutionSummary summarize(string projectId, string taskId, string fingerprint, const(TaskExecution)[] executions)
{
    ExecutionSummary summary;
    SysTime successCreatedAt;
    foreach (ref execution; executions)
    {
        if (execution.id.length == 0)
        {
            throw new ChainEvaluationException(format("An execution recorded at fingerprint %s has no id", fingerprint));
        }
        if (execution.fingerprint != fingerprint || execution.taskId != taskId || execution.projectId != projectId)
        {
            throw new ChainEvaluationException(format(
                "Execution '%s' (project '%s', task '%s', fingerprint %s) was given as an execution of task '%s' of project '%s' at fingerprint %s",
                execution.id, execution.projectId, execution.taskId, execution.fingerprint, taskId, projectId, fingerprint));
        }
        const createdAt = parseTimestamp(execution.createdAt, format("execution '%s' created_at", execution.id));

        bool later(const(TaskExecution)* current, SysTime currentAt, SysTime at)
        {
            return current is null || at > currentAt || (at == currentAt && execution.id > current.id);
        }

        final switch (execution.status)
        {
            case ExecutionStatus.queued:
            case ExecutionStatus.running:
                if (summary.active !is null)
                {
                    throw new ChainEvaluationException(format(
                        "Fingerprint %s of task '%s' has more than one active execution ('%s' and '%s'); its claim allows one",
                        fingerprint, taskId, summary.active.id, execution.id));
                }
                summary.active = &execution;
                break;
            case ExecutionStatus.succeeded:
                if (later(summary.success, successCreatedAt, createdAt))
                {
                    summary.success = &execution;
                    successCreatedAt = createdAt;
                }
                break;
            case ExecutionStatus.failed:
            case ExecutionStatus.cancelled:
                const finishedAt = parseTimestamp(execution.finishedAt, format("execution '%s' finished_at", execution.id));
                if (later(summary.stopped, summary.stoppedAt, finishedAt))
                {
                    summary.stopped = &execution;
                    summary.stoppedAt = finishedAt;
                }
                break;
        }
    }
    return summary;
}

/// Parses an ISO 8601 UTC timestamp (`SysTime.toISOExtString` of a UTC time). A time without the
/// UTC designator is rejected: it would be read in the local time zone.
private SysTime parseTimestamp(string text, string what)
{
    if (!text.endsWith("Z"))
    {
        throw new ChainEvaluationException(format("The %s '%s' is not an ISO 8601 UTC time", what, text));
    }
    try
    {
        return SysTime.fromISOExtString(text);
    }
    catch (Exception ex)
    {
        throw new ChainEvaluationException(format("The %s '%s' is not an ISO 8601 UTC time: %s", what, text, ex.msg));
    }
}

version (unittest)
{
    import confector.core.fingerprinter : computeFingerprint;
    import confector.core.input_resolution : InputResolutionException, freezeChain, resolveGraphInputs, unreadRerunBases;

    import std.algorithm.searching : canFind;
    import vibe.data.json : Json;

    /// compile -> test -> report, compile -> package, and an independent lint, at revision `sha`,
    /// as chain `id` of project "p".
    private BuildChain sampleChain(string id = "c1", string sha = "aaa111")
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
        TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
        TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
        TaskNode package_; package_.id = "package"; package_.inputs["bin"] = taskOutputInput("compile");
        TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game", "main");
        auto graph = new TaskGraph([compile, test, report, package_, lint]);
        InputPin[InputDecl] none;
        InputPin[InputDecl] pins = [repositoryInput("game", "main"): InputPin(Json(sha))];

        BuildChain chain;
        chain.id = id;
        chain.projectId = "p";
        chain.number = 1;
        chain.snapshotHash = "snapshot-" ~ sha;
        chain.tasks = freezeChain(graph, resolveGraphInputs(graph, none, pins));
        chain.createdAt = "2026-10-15T10:00:00Z";
        return chain;
    }

    /// The generations of every base of `chain`: `bumped[base]` where given, 0 otherwise.
    private RerunGenerations generationsOf(in BuildChain chain, RerunGenerations bumped = null)
    {
        RerunGenerations generations;
        for (auto unread = unreadRerunBases(chain.projectId, chain.tasks, generations); unread.length > 0;
            unread = unreadRerunBases(chain.projectId, chain.tasks, generations))
        {
            foreach (base; unread) generations[base] = bumped.get(base, 0);
        }
        return generations;
    }

    private BuildRequest request(string id, string[] targets, string at, BuildIntent intent = BuildIntent.build, string chainId = "c1")
    {
        BuildRequest r;
        r.id = id;
        r.projectId = "p";
        r.chainId = chainId;
        r.targets = targets;
        r.intent = intent;
        r.trigger.type = TriggerType.manual;
        r.requestedBy = "jason";
        r.requestedAt = at;
        return r;
    }

    /// Executions recorded in a test, filed by fingerprint as the shell would load them.
    private struct Executions
    {
        TaskExecution[][string] byFingerprint;

        void add(string id, string taskId, string fingerprint, ExecutionStatus status, string createdAt, ulong attempts = 1)
        {
            TaskExecution e;
            e.id = id;
            e.projectId = "p";
            e.taskId = taskId;
            e.fingerprint = fingerprint;
            e.status = status;
            e.attempts = attempts;
            e.definition.id = taskId;
            e.definitionHash = "def";
            e.createdAt = createdAt;
            e.sentAt = createdAt;
            if (status != ExecutionStatus.queued && status != ExecutionStatus.running) e.finishedAt = createdAt;
            byFingerprint[fingerprint] ~= e;
        }
    }

    private ChainEvaluation evaluate(in BuildChain chain, in BuildRequest[] requests, in Executions executions,
        RerunGenerations bumped = null)
    {
        return evaluateChain(chain, requests, generationsOf(chain, bumped), executions.byFingerprint);
    }

    private string[] neededTasks(in ChainEvaluation evaluation)
    {
        string[] ids;
        foreach (ref n; evaluation.needed)
        {
            assert(n.fingerprint == evaluation.resolution.fingerprints[n.taskId]);
            ids ~= n.taskId;
        }
        return ids;
    }

    private bool throwsEvaluation(void delegate() run, string fragment)
    {
        try run();
        catch (ChainEvaluationException ex) return ex.msg.canFind(fragment);
        return false;
    }
}

unittest
{
    // With no requests nothing is requested or needed, and every task is fingerprinted
    auto chain = sampleChain();
    Executions none;
    auto e = evaluate(chain, [], none);
    assert(e.needed.length == 0);
    assert(e.tasks.length == 5);
    foreach (id, state; e.tasks)
    {
        assert(state.taskId == id);
        assert(state.status == ChainTaskStatus.notRequested && !state.requested, id);
        assert(state.fingerprint == e.resolution.fingerprints[id] && state.base == e.resolution.bases[id]);
        assert(state.generation == 0 && state.fingerprint == computeFingerprint(state.base, 0));
        assert(state.executionId.length == 0 && state.executionCount == 0 && state.waitingFor == WaitReason.none);
    }
}

unittest
{
    // A request covers its targets and their upstream closure, never downstream tasks; only
    // tasks whose upstream tasks have all succeeded are needed
    auto chain = sampleChain();
    Executions none;
    auto e = evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z")], none);

    assert(neededTasks(e) == ["compile"]);
    assert(e.tasks["compile"].status == ChainTaskStatus.waiting && e.tasks["compile"].waitingFor == WaitReason.dispatch);
    assert(e.tasks["test"].requested && e.tasks["test"].status == ChainTaskStatus.waiting
        && e.tasks["test"].waitingFor == WaitReason.upstream);
    foreach (id; ["report", "package", "lint"])
    {
        assert(!e.tasks[id].requested && e.tasks[id].status == ChainTaskStatus.notRequested, id);
    }

    // Several targets and several requests add up; independent roots are needed together
    auto both = evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z"),
        request("r2", ["lint", "package"], "2026-10-15T10:00:02Z")], none);
    assert(neededTasks(both) == ["compile", "lint"]);
    assert(both.tasks["package"].requested && both.tasks["package"].waitingFor == WaitReason.upstream);
    assert(!both.tasks["report"].requested);
}

unittest
{
    // Cache hits: a success at a fingerprint is used whichever chain produced it, and whether or
    // not the task is requested; downstream tasks then become needed
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    Executions executions;
    executions.add("e-compile", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-14T09:00:00Z");
    executions.add("e-lint", "lint", fp["lint"], ExecutionStatus.succeeded, "2026-10-14T09:00:00Z");

    auto e = evaluate(chain, [request("r1", ["report"], "2026-10-15T10:00:01Z")], executions);
    assert(e.tasks["compile"].status == ChainTaskStatus.succeeded && e.tasks["compile"].executionId == "e-compile");
    assert(e.tasks["compile"].executionCount == 1 && e.tasks["compile"].attempts == 1);
    assert(neededTasks(e) == ["test"]);
    assert(e.tasks["report"].waitingFor == WaitReason.upstream);
    assert(e.tasks["lint"].status == ChainTaskStatus.succeeded && !e.tasks["lint"].requested,
        "A success is shown even for a task nobody requested in this chain");

    // Everything requested has succeeded: nothing is needed
    executions.add("e-test", "test", fp["test"], ExecutionStatus.succeeded, "2026-10-15T10:01:00Z");
    executions.add("e-report", "report", fp["report"], ExecutionStatus.succeeded, "2026-10-15T10:02:00Z");
    auto done = evaluate(chain, [request("r1", ["report"], "2026-10-15T10:00:01Z")], executions);
    assert(done.needed.length == 0);
    foreach (id; ["compile", "test", "report"]) assert(done.tasks[id].status == ChainTaskStatus.succeeded, id);

    // A success is reused even after an earlier failure at the same fingerprint, and with
    // several successes (only possible through races) the latest is used
    Executions raced;
    raced.add("e-fail", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T09:00:00Z");
    raced.add("e-b", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T09:30:00Z");
    raced.add("e-a", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T09:45:00Z");
    auto r = evaluate(chain, [request("r1", ["compile"], "2026-10-15T10:00:01Z")], raced);
    assert(r.tasks["compile"].status == ChainTaskStatus.succeeded && r.tasks["compile"].executionId == "e-a");
    assert(r.tasks["compile"].executionCount == 3);
    // Same creation time: the id decides, deterministically
    raced.add("e-c", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T09:45:00Z");
    assert(evaluate(chain, [request("r1", ["compile"], "2026-10-15T10:00:01Z")], raced).tasks["compile"].executionId == "e-c");
}

unittest
{
    // In-flight attach: a queued or running execution at the fingerprint is attached to, never
    // duplicated, wherever it was dispatched from; a requeued execution reports its attempts
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    auto requests = [request("r1", ["test", "lint"], "2026-10-15T10:00:01Z")];

    Executions queued;
    queued.add("e-compile", "compile", fp["compile"], ExecutionStatus.queued, "2026-10-15T10:00:02Z", 0);
    queued.add("e-lint", "lint", fp["lint"], ExecutionStatus.running, "2026-10-15T09:00:00Z");
    auto e = evaluate(chain, requests, queued);
    assert(e.needed.length == 0, "Active executions are attached to, not dispatched again");
    assert(e.tasks["compile"].status == ChainTaskStatus.waiting && e.tasks["compile"].waitingFor == WaitReason.queued);
    assert(e.tasks["compile"].executionId == "e-compile" && e.tasks["compile"].attempts == 0);
    assert(e.tasks["lint"].status == ChainTaskStatus.running && e.tasks["lint"].executionId == "e-lint",
        "An execution started before the request (by another chain) is attached to");
    assert(e.tasks["test"].waitingFor == WaitReason.upstream);

    // A lost worker requeues the same execution: still attached, with its attempts counted
    Executions requeued;
    requeued.add("e-compile", "compile", fp["compile"], ExecutionStatus.queued, "2026-10-15T10:00:02Z", 2);
    auto lost = evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z")], requeued);
    assert(lost.needed.length == 0);
    assert(lost.tasks["compile"].waitingFor == WaitReason.queued && lost.tasks["compile"].attempts == 2);

    // An active execution for a task this chain has not requested is not attached to
    auto unrequested = evaluate(chain, [], queued);
    assert(unrequested.tasks["lint"].status == ChainTaskStatus.notRequested && unrequested.tasks["lint"].executionId.length == 0);

    // A retry while an execution is active attaches to it too
    auto retry = evaluate(chain, requests ~ request("r2", ["compile"], "2026-10-15T11:00:00Z", BuildIntent.retry), queued);
    assert(retry.needed.length == 0 && retry.tasks["compile"].executionId == "e-compile");

    // A queued execution that was recorded but never sent (its dispatcher failed or crashed
    // before sending) needs dispatching again, naming the execution to send; a running one
    // never does
    Executions unsent;
    unsent.add("e-compile", "compile", fp["compile"], ExecutionStatus.queued, "2026-10-15T10:00:02Z", 0);
    unsent.byFingerprint[fp["compile"]][0].sentAt = null;
    unsent.add("e-lint", "lint", fp["lint"], ExecutionStatus.running, "2026-10-15T09:00:00Z");
    unsent.byFingerprint[fp["lint"]][0].sentAt = null;
    auto repair = evaluate(chain, requests, unsent);
    assert(neededTasks(repair) == ["compile"]);
    assert(repair.tasks["compile"].status == ChainTaskStatus.waiting && repair.tasks["compile"].waitingFor == WaitReason.dispatch);
    assert(repair.tasks["compile"].executionId == "e-compile");
    assert(repair.tasks["lint"].status == ChainTaskStatus.running);
    assert(evaluate(chain, [], unsent).needed.length == 0, "An unrequested task is never dispatched");
}

unittest
{
    // An execution attached to in flight (created before the request, say by another chain)
    // that then fails or is cancelled settles the request: it is not retried automatically
    {
        auto chain = sampleChain();
        auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
        foreach (status; [ExecutionStatus.failed, ExecutionStatus.cancelled])
        {
            Executions shared_;
            shared_.add("e-other", "compile", fp["compile"], status, "2026-10-15T09:00:00Z");
            shared_.byFingerprint[fp["compile"]][0].finishedAt = "2026-10-15T10:30:00Z";
            auto e = evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z")], shared_);
            assert(e.needed.length == 0, "A shared execution's failure is not retried automatically");
            assert(e.tasks["compile"].executionId == "e-other" && e.tasks["test"].status == ChainTaskStatus.blocked);

            // A request made after it finished asks for the task again
            auto later = evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z"),
                request("r2", ["test"], "2026-10-15T10:30:01Z")], shared_);
            assert(neededTasks(later) == ["compile"]);
        }
    }
}

unittest
{
    // Upstream failure blocks: a failure or cancellation after the latest request settles the
    // task, blocks everything requested downstream of it, and is never retried automatically
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    auto requests = [request("r1", ["report", "package", "lint"], "2026-10-15T10:00:01Z")];

    foreach (status; [ExecutionStatus.failed, ExecutionStatus.cancelled])
    {
        Executions executions;
        executions.add("e-compile", "compile", fp["compile"], status, "2026-10-15T10:00:02Z");
        executions.add("e-lint", "lint", fp["lint"], ExecutionStatus.running, "2026-10-15T10:00:02Z");
        auto e = evaluate(chain, requests, executions);

        const expected = status == ExecutionStatus.failed ? ChainTaskStatus.failed : ChainTaskStatus.cancelled;
        assert(e.tasks["compile"].status == expected && e.tasks["compile"].executionId == "e-compile");
        foreach (id; ["test", "report", "package"])
        {
            assert(e.tasks[id].status == ChainTaskStatus.blocked, id);
            assert(e.tasks[id].blockedBy == ["compile"], id);
            assert(e.tasks[id].executionId.length == 0);
        }
        assert(e.tasks["lint"].status == ChainTaskStatus.running, "Independent tasks are unaffected");
        assert(e.needed.length == 0, "A failure is never retried automatically");
    }

    // A task blocked by two independent failures names both roots, through blocked tasks too
    TaskNode a; a.id = "a";
    TaskNode b; b.id = "b";
    TaskNode c; c.id = "c"; c.inputs["a"] = taskOutputInput("a");
    TaskNode d; d.id = "d"; d.inputs["c"] = taskOutputInput("c"); d.inputs["b"] = taskOutputInput("b");
    auto graph = new TaskGraph([a, b, c, d]);
    InputPin[InputDecl] noPins;
    BuildChain diamond = chain;
    diamond.tasks = freezeChain(graph, resolveGraphInputs(graph, noPins, noPins));
    auto dfp = evaluate(diamond, [], Executions.init).resolution.fingerprints;
    Executions failures;
    failures.add("e-a", "a", dfp["a"], ExecutionStatus.failed, "2026-10-15T10:00:02Z");
    failures.add("e-b", "b", dfp["b"], ExecutionStatus.cancelled, "2026-10-15T10:00:02Z");
    auto de = evaluate(diamond, [request("r1", ["d"], "2026-10-15T10:00:01Z")], failures);
    assert(de.tasks["c"].blockedBy == ["a"]);
    assert(de.tasks["d"].status == ChainTaskStatus.blocked && de.tasks["d"].blockedBy == ["a", "b"]);

    // A task with one upstream failed and another still running is blocked, not waiting
    Executions mixed;
    mixed.add("e-a", "a", dfp["a"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    mixed.add("e-c", "c", dfp["c"], ExecutionStatus.running, "2026-10-15T10:00:03Z");
    mixed.add("e-b", "b", dfp["b"], ExecutionStatus.failed, "2026-10-15T10:00:02Z");
    auto me = evaluate(diamond, [request("r1", ["d"], "2026-10-15T10:00:01Z")], mixed);
    assert(me.tasks["d"].status == ChainTaskStatus.blocked && me.tasks["d"].blockedBy == ["b"]);
}

unittest
{
    // Retry: a request made after a failure asks for the task again at the same fingerprint, a
    // retry of a blocked task retries its failed upstream task, and once the retry's execution
    // is recorded it is the one that counts
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    auto original = request("r1", ["test"], "2026-10-15T10:00:01Z");

    Executions executions;
    executions.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:02Z");
    assert(evaluate(chain, [original], executions).needed.length == 0);

    auto retryTest = request("r2", ["test"], "2026-10-15T11:00:00Z", BuildIntent.retry);
    auto e = evaluate(chain, [original, retryTest], executions);
    assert(neededTasks(e) == ["compile"], "Retrying a blocked task retries its failed upstream task");
    assert(e.tasks["compile"].fingerprint == fp["compile"], "A retry does not change the fingerprint");
    assert(e.tasks["compile"].status == ChainTaskStatus.waiting && e.tasks["compile"].waitingFor == WaitReason.dispatch);
    assert(e.tasks["compile"].executionId.length == 0 && e.tasks["compile"].executionCount == 1);
    assert(e.tasks["test"].status == ChainTaskStatus.waiting && e.tasks["test"].waitingFor == WaitReason.upstream);

    // The retry's execution is attached to, and when it fails too, the task is failed again
    executions.add("e2", "compile", fp["compile"], ExecutionStatus.running, "2026-10-15T11:00:01Z");
    auto running = evaluate(chain, [original, retryTest], executions);
    assert(running.needed.length == 0 && running.tasks["compile"].executionId == "e2");

    executions.byFingerprint[fp["compile"]][1].status = ExecutionStatus.failed;
    executions.byFingerprint[fp["compile"]][1].finishedAt = "2026-10-15T11:05:00Z";
    auto failedAgain = evaluate(chain, [original, retryTest], executions);
    assert(failedAgain.needed.length == 0);
    assert(failedAgain.tasks["compile"].status == ChainTaskStatus.failed && failedAgain.tasks["compile"].executionId == "e2");
    assert(failedAgain.tasks["compile"].executionCount == 2);
    assert(failedAgain.tasks["test"].status == ChainTaskStatus.blocked);

    // Failures are never cache hits: any later request covering the task, not only a retry,
    // asks for it again
    auto later = request("r3", ["report"], "2026-10-15T12:00:00Z");
    assert(neededTasks(evaluate(chain, [original, retryTest, later], executions)) == ["compile"]);

    // A retry of a task that already succeeded needs nothing
    executions.add("e3", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T12:00:01Z");
    auto retryDone = evaluate(chain, [original, request("r4", ["compile"], "2026-10-15T13:00:00Z", BuildIntent.retry)], executions);
    assert(retryDone.tasks["compile"].status == ChainTaskStatus.succeeded);
    assert(neededTasks(retryDone) == ["test"]);

    // A cancelled task is retried the same way
    Executions cancelled;
    cancelled.add("e1", "compile", fp["compile"], ExecutionStatus.cancelled, "2026-10-15T10:00:02Z");
    assert(evaluate(chain, [original], cancelled).tasks["test"].status == ChainTaskStatus.blocked);
    assert(neededTasks(evaluate(chain, [original, retryTest], cancelled)) == ["compile"]);
}

unittest
{
    // Request and execution times are compared as times, not text: toISOExtString leaves out
    // zero fractional seconds, so "10:00:00.5Z" sorts before "10:00:00Z" as text
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    Executions executions;
    executions.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:00.5Z");
    auto settled = evaluate(chain, [request("r1", ["compile"], "2026-10-15T10:00:00Z")], executions);
    assert(settled.tasks["compile"].status == ChainTaskStatus.failed && settled.needed.length == 0);

    // A failure finished at the very time of the request settles it
    Executions sameTime;
    sameTime.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:00Z");
    assert(evaluate(chain, [request("r1", ["compile"], "2026-10-15T10:00:00Z")], sameTime).needed.length == 0);

    // The latest of several failures is the one shown, whatever order they are listed in
    Executions several;
    several.add("e2", "compile", fp["compile"], ExecutionStatus.cancelled, "2026-10-15T10:00:00.25Z");
    several.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:00Z");
    auto latest = evaluate(chain, [request("r1", ["compile"], "2026-10-15T09:00:00Z")], several);
    assert(latest.tasks["compile"].status == ChainTaskStatus.cancelled && latest.tasks["compile"].executionId == "e2");
}

unittest
{
    // Rerun generations: after a rerun the task and everything downstream have new fingerprints
    // and earlier successes are not used. A rerun must pass: downstream waits on the new
    // generation and is blocked, with no fallback, if it fails
    auto chain = sampleChain();
    auto before = evaluate(chain, [], Executions.init).resolution;
    auto requests = [request("r1", ["report", "lint"], "2026-10-15T10:00:01Z")];

    Executions executions;
    executions.add("c0", "compile", before.fingerprints["compile"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    executions.add("t0", "test", before.fingerprints["test"], ExecutionStatus.succeeded, "2026-10-15T10:01:00Z");
    executions.add("r0", "report", before.fingerprints["report"], ExecutionStatus.succeeded, "2026-10-15T10:02:00Z");
    executions.add("l0", "lint", before.fingerprints["lint"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    assert(evaluate(chain, requests, executions).needed.length == 0);

    // compile is rerun: its generation is bumped and the rerun request targets it
    RerunGenerations bumped = [before.bases["compile"]: 1];
    auto withRerun = requests ~ request("r2", ["compile"], "2026-10-15T12:00:00Z", BuildIntent.rerun);
    auto e = evaluate(chain, withRerun, executions, bumped);
    assert(e.tasks["compile"].generation == 1 && e.tasks["compile"].base == before.bases["compile"]);
    foreach (id; ["compile", "test", "report"])
    {
        assert(e.tasks[id].fingerprint != before.fingerprints[id], id);
        assert(e.tasks[id].executionCount == 0, "Superseded executions are not at the new fingerprints");
    }
    assert(e.tasks["lint"].status == ChainTaskStatus.succeeded && e.tasks["lint"].executionId == "l0");
    assert(neededTasks(e) == ["compile"]);
    assert(e.tasks["test"].status == ChainTaskStatus.waiting && e.tasks["test"].waitingFor == WaitReason.upstream,
        "Downstream waits on the new generation instead of using the superseded success");
    assert(e.tasks["report"].waitingFor == WaitReason.upstream);

    // The new generation fails: downstream is blocked, never falling back to the earlier success
    executions.add("c1", "compile", e.tasks["compile"].fingerprint, ExecutionStatus.failed, "2026-10-15T12:00:01Z");
    auto failed = evaluate(chain, withRerun, executions, bumped);
    assert(failed.tasks["compile"].status == ChainTaskStatus.failed && failed.tasks["compile"].executionId == "c1");
    assert(failed.tasks["test"].status == ChainTaskStatus.blocked && failed.tasks["report"].blockedBy == ["compile"]);
    assert(failed.needed.length == 0);

    // A retry of the rerun runs the new generation again; once it succeeds, downstream tasks
    // covered by the chain's requests run at their new fingerprints
    auto retried = withRerun ~ request("r3", ["compile"], "2026-10-15T13:00:00Z", BuildIntent.retry);
    assert(neededTasks(evaluate(chain, retried, executions, bumped)) == ["compile"]);
    executions.add("c2", "compile", e.tasks["compile"].fingerprint, ExecutionStatus.succeeded, "2026-10-15T13:00:01Z");
    auto passed = evaluate(chain, retried, executions, bumped);
    assert(passed.tasks["compile"].status == ChainTaskStatus.succeeded && passed.tasks["compile"].executionId == "c2");
    assert(neededTasks(passed) == ["test"]);
    assert(!passed.tasks["package"].requested, "A rerun never makes unrequested downstream tasks requested");

    // Another chain sharing compile's base (say, another branch at the same revision) sees the
    // rerun too; a chain at another revision does not
    auto sibling = sampleChain("c2");
    auto siblingEval = evaluate(sibling, [request("s1", ["test"], "2026-10-15T09:00:00Z", BuildIntent.build, "c2")], executions, bumped);
    assert(siblingEval.tasks["compile"].fingerprint == e.tasks["compile"].fingerprint);
    assert(siblingEval.tasks["compile"].executionId == "c2", "The rerun's success is shared");
    assert(neededTasks(siblingEval) == ["test"]);
    auto other = sampleChain("c3", "bbb222");
    assert(evaluate(other, [], executions, bumped).tasks["compile"].generation == 0);
}

unittest
{
    // A downstream task can be rerun on its own: only it and its downstream tasks move
    auto chain = sampleChain();
    auto before = evaluate(chain, [], Executions.init).resolution;
    Executions executions;
    foreach (id; ["compile", "test", "report"])
    {
        executions.add(id ~ "0", id, before.fingerprints[id], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    }
    RerunGenerations bumped = [before.bases["test"]: 1];
    auto e = evaluate(chain, [request("r1", ["report"], "2026-10-15T10:00:01Z"),
        request("r2", ["test"], "2026-10-15T12:00:00Z", BuildIntent.rerun)], executions, bumped);
    assert(e.tasks["compile"].status == ChainTaskStatus.succeeded && e.tasks["compile"].executionId == "compile0");
    assert(neededTasks(e) == ["test"]);
    assert(e.tasks["test"].generation == 1);
    assert(e.tasks["report"].waitingFor == WaitReason.upstream && e.tasks["report"].generation == 0);
}

unittest
{
    // Inconsistent input fails loudly
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    Executions none;
    auto ok = request("r1", ["test"], "2026-10-15T10:00:01Z");

    assert(throwsEvaluation(() { evaluate(chain, [request("r1", ["test"], "2026-10-15T10:00:01Z", BuildIntent.build, "other")], none); },
        "does not belong"), "A request on another chain");
    auto otherProject = ok;
    otherProject.projectId = "q";
    assert(throwsEvaluation(() { evaluate(chain, [otherProject], none); }, "does not belong"));
    assert(throwsEvaluation(() { evaluate(chain, [request("r1", [], "2026-10-15T10:00:01Z")], none); }, "no targets"));
    assert(throwsEvaluation(() { evaluate(chain, [request("r1", ["ghost"], "2026-10-15T10:00:01Z")], none); }, "'ghost'"));
    foreach (bad; ["", "yesterday", "2026-10-15T10:00:01", "2026-10-15 10:00:01Z"])
    {
        assert(throwsEvaluation(() { evaluate(chain, [request("r1", ["test"], bad)], none); }, "requested_at"), bad);
    }

    Executions misfiled;
    misfiled.add("e1", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    misfiled.byFingerprint[fp["lint"]] = misfiled.byFingerprint[fp["compile"]];
    assert(throwsEvaluation(() { evaluate(chain, [ok], misfiled); }, "'e1'"), "An execution filed under another fingerprint");

    Executions wrongTask;
    wrongTask.add("e1", "lint", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    assert(throwsEvaluation(() { evaluate(chain, [ok], wrongTask); }, "'e1'"));

    Executions wrongProject;
    wrongProject.add("e1", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    wrongProject.byFingerprint[fp["compile"]][0].projectId = "q";
    assert(throwsEvaluation(() { evaluate(chain, [ok], wrongProject); }, "'e1'"));

    Executions noId;
    noId.add("", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    assert(throwsEvaluation(() { evaluate(chain, [ok], noId); }, "no id"));

    Executions badTime;
    badTime.add("e1", "compile", fp["compile"], ExecutionStatus.succeeded, "2026-13-45T10:00:02Z");
    assert(throwsEvaluation(() { evaluate(chain, [ok], badTime); }, "created_at"));

    Executions unfinished;
    unfinished.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:02Z");
    unfinished.byFingerprint[fp["compile"]][0].finishedAt = "";
    assert(throwsEvaluation(() { evaluate(chain, [ok], unfinished); }, "finished_at"), "A failure must record when it finished");

    assert(throwsEvaluation(() { evaluate(chain, [request("r1", ["compile", "lint"], "2026-10-15T10:00:01Z", BuildIntent.rerun)], none); },
        "exactly one"));

    Executions twoActive;
    twoActive.add("e1", "compile", fp["compile"], ExecutionStatus.queued, "2026-10-15T10:00:02Z");
    twoActive.add("e2", "compile", fp["compile"], ExecutionStatus.running, "2026-10-15T10:00:03Z");
    assert(throwsEvaluation(() { evaluate(chain, [ok], twoActive); }, "more than one active"));
    assert(throwsEvaluation(() { evaluate(chain, [], twoActive); }, "more than one active"),
        "Checked even for tasks nobody requested");

    BuildChain anonymous = chain;
    anonymous.id = "";
    assert(throwsEvaluation(() { evaluateChain(anonymous, [], generationsOf(chain), none.byFingerprint); }, "needs an id"));

    // A generation that was not read is an error, never generation 0
    RerunGenerations partial;
    partial[evaluate(chain, [], none).resolution.bases["compile"]] = 0;
    bool threw = false;
    try evaluateChain(chain, [ok], partial, none.byFingerprint);
    catch (InputResolutionException) threw = true;
    assert(threw);

    // Executions at fingerprints the chain does not have are ignored
    Executions unrelated;
    unrelated.add("e1", "compile", "not-this-chain", ExecutionStatus.succeeded, "2026-10-15T10:00:02Z");
    assert(neededTasks(evaluate(chain, [ok], unrelated)) == ["compile"]);
}

unittest
{
    // Evaluation is a pure function of its inputs: evaluating twice gives the same result, and
    // the order requests are listed in does not matter
    auto chain = sampleChain();
    auto fp = evaluate(chain, [], Executions.init).resolution.fingerprints;
    Executions executions;
    executions.add("e1", "compile", fp["compile"], ExecutionStatus.failed, "2026-10-15T10:00:02Z");
    auto a = request("r1", ["test"], "2026-10-15T10:00:01Z");
    auto b = request("r2", ["report"], "2026-10-15T11:00:00Z");
    auto forward = evaluate(chain, [a, b], executions);
    auto backward = evaluate(chain, [b, a], executions);
    assert(forward.needed == backward.needed && neededTasks(forward) == ["compile"]);
    foreach (id, state; forward.tasks) assert(backward.tasks[id] == state, id);
    assert(evaluate(chain, [a, b], executions).tasks == forward.tasks);
}
