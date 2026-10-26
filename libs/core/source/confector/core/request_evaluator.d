module confector.core.request_evaluator;

/**
 * The request evaluator (AGENTS.md, "Coordinating builds", "What a build is" and "Re-running a
 * task"): the pure core of build coordination. Given one request, the definition it runs with, its
 * pins, the current rerun generations and a summary of the ledger of each of its
 * fingerprints, it derives the state of every task the request covers, the fingerprints that need
 * an execution and the request's outcome. It performs no I/O
 * and reads no clock. A request is evaluated on its own: its graph is the closure of its targets
 * in its own definition, and other requests only matter through the ledgers they share.
 *
 * The shell (the request reconciler) loads its inputs, all by id: the request and its definition,
 * its chain, the rerun generations (`readRequestGenerations`), and, for every fingerprint
 * (`requestFingerprints`), the ledger settled and its last success and last stop (`readLedgerSummary`).
 *
 * Rules:
 *
 * - **Covered** means the task is a target of the request or upstream of one, in the request's
 *   definition. A request never covers tasks downstream of its targets. Only covered tasks are
 *   evaluated; a task the request does not cover may not even have its inputs pinned.
 * - **Demands are settled by sequence numbers, never by time.** The request records, per task it
 *   covers, the task's fingerprint and the ledger's `stopSeq` there when it was made
 *   (BuildRequest.demands). A failure or cancellation settles the task only when the ledger's
 *   `stopSeq` is greater: it ended after the request was made, including when the request attached
 *   to the execution in flight. A request made after a stop, such as a retry, recorded the higher
 *   `stopSeq`, so it asks for the task again, at the same fingerprint, whatever any clock says. A
 *   demand recorded at another fingerprint (a rerun moved the task since) counts as having seen no
 *   stop at the new one: the new generation did not exist when the request was made. Each demand
 *   also records the task's base and rerun generation, and a moved fingerprint must be explained
 *   by a higher generation of the task or an upstream task; otherwise the evaluation fails
 *   loudly, since a wrongly recorded fingerprint would silently ignore a retry.
 * - **A success is always reused** (a cache hit), whichever request produced it: the ledger's
 *   latest success, unless retention removed its artifacts (TaskExecution.artifactsExpiredAt),
 *   which makes it a miss, not a cache hit (AGENTS.md, "The caching contract").
 * - **An active execution is attached to**, never duplicated: the ledger holds at most one, and
 *   the request waits on it, whichever definition it runs with.
 * - **Failures and cancellations are never cache hits, and are never retried automatically.**
 * - **A task must run** when it is a target, or upstream of a task that must run, and it has no
 *   usable success, no active execution and no stop settling its demand. A covered task that is
 *   none of these, and that no task that must run depends on, is notNeeded: a downstream cache
 *   hit never forces an upstream task to run.
 * - **A task needs an execution** when it must run and every upstream task has succeeded. A task
 *   whose upstream task failed or was cancelled is blocked. The needed execution carries the
 *   ledger's `executionSeq`, which the reconciler passes to `LedgerStore.claim` so a decision made
 *   before another execution started and ended never builds the fingerprint twice.
 * - **Reruns are strict.** Fingerprints come from the request's definition, its pins and
 *   the current rerun generations, so after a rerun the rerun task and everything downstream of
 *   it have new fingerprints, earlier successes are not used, and downstream tasks wait for the
 *   new generation to succeed and are blocked if it fails.
 * - **The request is open until every target is settled** (succeeded, failed, cancelled or
 *   blocked); see RequestEvaluation.outcome.
 *
 * Infrastructure failures retry within one execution, which stays active meanwhile
 * (ActiveExecution.attempt). Stale index copies cannot confuse it: it reads no index.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.chain_pins : bindingMap, pinMap;
import confector.core.dag : TaskGraph;
import confector.core.definition_store : definitionId;
import confector.core.fingerprint_ledger : LedgerStore;
import confector.core.input_resolution : GraphResolution, RerunGenerations, completeGraphResolution;
import confector.core.rerun_generations : RerunGenerationReader, readGraphResolution;
import confector.api.model;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;
import std.typecons : Nullable, nullable;

/**
 * The request evaluator was given inputs that contradict each other or the persisted model.
 */
class RequestEvaluationException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * A request with the definition it runs with (read by `request.definitionId`).
 */
struct DefinedRequest
{
    BuildRequest request;
    ProjectDefinition definition;
}

/**
 * What the request evaluator needs to know about one fingerprint: its ledger, settled
 * (`LedgerStore.settle`, so a half-finished fold never looks like a running execution), and the
 * finished executions it names, each read by id (`readLedgerSummary`).
 */
struct LedgerSummary
{
    /// The ledger; null if no execution was ever claimed at the fingerprint.
    Nullable!FingerprintLedger ledger;
    /// The records of `ledger.lastSuccessExecutionId` and `ledger.lastStoppedExecutionId`; null
    /// exactly when the ledger names none.
    Nullable!TaskExecution lastSuccess;
    Nullable!TaskExecution lastStopped;
}

/**
 * A fingerprint that needs an execution. The reconciler claims it with `LedgerStore.claim(
 * fingerprint, seenExecutionSeq, ...)`, carrying `inputs` and the request's definition.
 */
struct NeededExecution
{
    string taskId;
    string fingerprint;
    /// The ledger's `executionSeq` as the evaluation saw it; 0 when it has no ledger.
    ulong seenExecutionSeq;
    /// The task's resolved inputs, task outputs included, as its work order carries them.
    ResolvedInput[] inputs;
}

/**
 * The result of evaluating a request.
 */
struct RequestEvaluation
{
    string requestId;
    /// The state of every task the request covers, in topological order.
    RequestTaskState[] tasks;
    /// The fingerprints that need an execution, in topological order of their tasks.
    NeededExecution[] needed;
    /// open until every target is settled; then failed if some target failed or was cancelled,
    /// else blocked if some target is blocked, else succeeded.
    RequestOutcome outcome;
}

/**
 * The graph of the tasks a request with `targets` covers in `definition`: the targets and their
 * upstream tasks, never downstream ones.
 *
 * Throws: RequestEvaluationException if a target is not a task of the definition;
 * DAGValidationException if the definition's tasks do not form a valid graph.
 */
TaskGraph closureGraph(in ProjectDefinition definition, in string[] targets) @trusted
{
    auto graph = new TaskGraph(definition.tasks);
    bool[string] covered;
    foreach (target; targets)
    {
        if (!definition.tasks.canFind!(t => t.id == target))
        {
            throw new RequestEvaluationException(format("Target '%s' is not a task of the definition", target));
        }
        foreach (taskId; graph.resolveSubgraph(target)) covered[taskId] = true;
    }
    TaskNode[] closure;
    foreach (taskId; graph.topologicalSort())
    {
        if (taskId in covered) closure ~= graph.getTask(taskId);
    }
    return new TaskGraph(closure);
}

/**
 * The demands a request covering the tasks of `closure` records (BuildRequest.demands): each
 * task's fingerprint, base and rerun generation, with the `stopSeq` of that fingerprint's ledger
 * in `stopSeqs` (keyed by fingerprint, read after settling the ledger; 0 for a fingerprint with no
 * ledger). Sorted by task id. For request intake.
 *
 * Throws: RequestEvaluationException if `closure` lacks a task's fingerprint (its generations
 * were not all read) or `stopSeqs` lacks one of the fingerprints.
 */
TaskDemand[] requestDemands(in GraphResolution closure, in ulong[string] stopSeqs) @trusted
{
    TaskDemand[] demands;
    foreach (taskId; closure.bases.keys.sort().release)
    {
        auto fingerprint = taskId in closure.fingerprints;
        if (fingerprint is null)
        {
            throw new RequestEvaluationException(format("Task '%s' has no fingerprint: its rerun generation was not read", taskId));
        }
        auto stopSeq = *fingerprint in stopSeqs;
        if (stopSeq is null)
        {
            throw new RequestEvaluationException(format("The stop sequence of task '%s' at fingerprint %s was not read", taskId, *fingerprint));
        }
        demands ~= TaskDemand(taskId, *fingerprint, closure.bases[taskId], closure.generations[taskId], *stopSeq);
    }
    return demands;
}

/**
 * Every fingerprint the request covers at `generations` (which must hold every base), sorted: the
 * ledgers the shell summarizes for `evaluateRequest`.
 *
 * Throws: as `evaluateRequest` for a request that does not fit the chain or a missing generation.
 */
string[] requestFingerprints(in BuildChain chain, in DefinedRequest entry, in RerunGenerations generations) @trusted
{
    const resolution = completeGraphResolution(chain.projectId, closureOf(chain, entry), bindingMap(entry.request.bindings),
        pinMap(entry.request.pins), generations);
    string[] fingerprints;
    foreach (fingerprint; resolution.fingerprints.byValue) fingerprints ~= fingerprint;
    return fingerprints.sort().release;
}

/**
 * Reads, with `read`, the rerun generation of every base the request covers, a level of its graph
 * at a time, and returns them all.
 *
 * Throws: Exception if `read` returns no generation for a base it was asked for; as
 * `evaluateRequest` for a request that does not fit the chain.
 */
RerunGenerations readRequestGenerations(in BuildChain chain, in DefinedRequest entry, scope RerunGenerationReader read) @trusted
{
    const resolution = readGraphResolution(chain.projectId, closureOf(chain, entry), bindingMap(entry.request.bindings),
        pinMap(entry.request.pins), read);
    RerunGenerations generations;
    foreach (taskId, base; resolution.bases) generations[base] = resolution.generations[taskId];
    return generations;
}

/**
 * Reads what `evaluateRequest` needs to know about `fingerprint`: settles its ledger (completing a
 * half-finished fold) and reads by id the finished executions it names. Part of the shell, next to
 * the core it feeds.
 *
 * Throws: whatever `LedgerStore.settle` and `ExecutionStore.get` throw.
 */
LedgerSummary readLedgerSummary(LedgerStore ledgers, ExecutionStore executions, string fingerprint)
{
    auto settled = ledgers.settle(fingerprint);
    LedgerSummary summary;
    if (settled.isNull) return summary;
    summary.ledger = settled.get.value;

    Nullable!TaskExecution named(string id)
    {
        if (id.length == 0) return Nullable!TaskExecution.init;
        auto found = executions.get(id);
        return found.isNull ? Nullable!TaskExecution.init : nullable(found.get.value);
    }
    summary.lastSuccess = named(summary.ledger.get.lastSuccessExecutionId);
    summary.lastStopped = named(summary.ledger.get.lastStoppedExecutionId);
    return summary;
}

/**
 * Derives the state of every task `entry` covers, the fingerprints that need an execution and its
 * outcome (see the module documentation for the rules), from
 * the pins of the request, the current rerun `generations` (which must hold every base the request
 * covers) and `ledgers`, a summary for every fingerprint it covers (`requestFingerprints`).
 * Summaries of other fingerprints are ignored. Pure: performs no I/O and reads no clock; no
 * timestamp is ever compared.
 *
 * Throws: RequestEvaluationException if the request has no id, belongs to another chain or
 * project, runs with a definition other than the one given (its id is not the definition's hash),
 * targets a task its definition lacks, or records demands for other tasks than its targets and
 * their upstream tasks; if a covered fingerprint has no summary, or its summary contradicts itself
 * or the task (see `LedgerSummary`), including an active execution that has already ended (the
 * ledger was not settled). InputResolutionException if a generation is missing or the request lacks
 * a pin it needs.
 */
RequestEvaluation evaluateRequest(
    in BuildChain chain,
    in DefinedRequest entry,
    in RerunGenerations generations,
    in LedgerSummary[string] ledgers
) @trusted
{
    const request = entry.request;
    auto graph = closureOf(chain, entry);
    const resolution = completeGraphResolution(chain.projectId, graph, bindingMap(request.bindings), pinMap(request.pins), generations);

    string[] demanded;
    foreach (ref demand; request.demands) demanded ~= demand.taskId;
    requireEvaluable(demanded == graph.allTaskIds(), format(
        "Request '%s' records demands for tasks [%-(%s, %)], but its targets and their upstream tasks are [%-(%s, %)]",
        request.id, demanded, graph.allTaskIds()));

    TaskDemand[string] demandOf;
    foreach (ref demand; request.demands) demandOf[demand.taskId] = demand;
    foreach (ref demand; request.demands) requireMovedByRerun(chain.id, request.id, graph, resolution, demandOf, demand);

    const order = graph.topologicalSort();
    LedgerFacts[string] facts;
    ulong[string] stopSeqAtDemand;
    foreach (taskId; order)
    {
        const fingerprint = resolution.fingerprints[taskId];
        auto summary = fingerprint in ledgers;
        requireEvaluable(summary !is null, format("Task '%s' of request '%s' is at fingerprint %s, whose ledger was not summarized",
            taskId, request.id, fingerprint));
        facts[taskId] = factsOf(chain.projectId, taskId, fingerprint, *summary);
        // A demand recorded at another fingerprint saw no stop at this one: a rerun created it
        // since (requireMovedByRerun checked that)
        const demand = demandOf[taskId];
        stopSeqAtDemand[taskId] = demand.fingerprint == fingerprint ? demand.stopSeq : 0;
    }

    // Decided from the downstream end: a task must run when it is a target or upstream of a task
    // that must run, and nothing satisfies it already
    bool[string] mustRun;
    foreach_reverse (taskId; order)
    {
        if (facts[taskId].satisfies(stopSeqAtDemand[taskId])) continue;
        bool must = request.targets.canFind(taskId);
        foreach (dependent; graph.getDependents(taskId)) must = must || (dependent in mustRun) !is null;
        if (must) mustRun[taskId] = true;
    }

    RequestEvaluation result;
    result.requestId = request.id;
    RequestTaskStatus[string] statuses;
    string[][string] blockers;
    foreach (taskId; order)
    {
        const fingerprint = resolution.fingerprints[taskId];
        const fact = facts[taskId];
        RequestTaskState state;
        state.taskId = taskId;
        state.fingerprint = fingerprint;
        state.target = request.targets.canFind(taskId);

        if (fact.successId.length > 0)
        {
            state.status = RequestTaskStatus.succeeded;
            state.executionId = fact.successId;
        }
        else if (fact.activeId.length > 0)
        {
            state.status = fact.running ? RequestTaskStatus.running : RequestTaskStatus.queued;
            state.executionId = fact.activeId;
        }
        else if (fact.settles(stopSeqAtDemand[taskId]))
        {
            // A stop that ended after the request was made settles it; only a later request asks
            // for the task again
            state.status = fact.stoppedStatus == ExecutionStatus.failed ? RequestTaskStatus.failed : RequestTaskStatus.cancelled;
            state.executionId = fact.stoppedId;
        }
        else if (taskId !in mustRun)
        {
            // Covered only for downstream tasks that are already satisfied: not worth running
            state.status = RequestTaskStatus.notNeeded;
            state.executionId = fact.expiredSuccessId;
        }
        else
        {
            bool upstreamPending = false;
            bool[string] blockedBy;
            foreach (upstream; graph.getDependencies(taskId))
            {
                final switch (statuses[upstream])
                {
                    case RequestTaskStatus.succeeded:
                        break;
                    case RequestTaskStatus.failed:
                    case RequestTaskStatus.cancelled:
                        blockedBy[upstream] = true;
                        break;
                    case RequestTaskStatus.blocked:
                        foreach (root; blockers[upstream]) blockedBy[root] = true;
                        break;
                    case RequestTaskStatus.waitingUpstream:
                    case RequestTaskStatus.needed:
                    case RequestTaskStatus.queued:
                    case RequestTaskStatus.running:
                        upstreamPending = true;
                        break;
                    case RequestTaskStatus.notNeeded:
                        throw new RequestEvaluationException(format(
                            "Task '%s' of request '%s' must run but its upstream task '%s' is not needed", taskId, request.id, upstream));
                }
            }

            if (blockedBy.length > 0)
            {
                state.status = RequestTaskStatus.blocked;
                state.blockedBy = blockedBy.keys.sort().release;
            }
            else if (upstreamPending)
            {
                state.status = RequestTaskStatus.waitingUpstream;
            }
            else
            {
                state.status = RequestTaskStatus.needed;
                result.needed ~= NeededExecution(taskId, fingerprint, fact.executionSeq, (cast(ResolvedInput[]) resolution.inputs[taskId]).dup);
            }
        }

        statuses[taskId] = state.status;
        blockers[taskId] = state.blockedBy;
        result.tasks ~= state;
    }
    result.outcome = outcomeOf(result.tasks);
    return result;
}

/// open until every target is settled; then failed, blocked or succeeded (see RequestEvaluation).
private RequestOutcome outcomeOf(in RequestTaskState[] tasks) pure @safe
{
    bool failed = false;
    bool blocked = false;
    foreach (ref task; tasks)
    {
        if (!task.target) continue;
        final switch (task.status)
        {
            case RequestTaskStatus.succeeded:
                break;
            case RequestTaskStatus.failed:
            case RequestTaskStatus.cancelled:
                failed = true;
                break;
            case RequestTaskStatus.blocked:
                blocked = true;
                break;
            case RequestTaskStatus.notNeeded:
                throw new RequestEvaluationException(format("Target '%s' is not needed, but a target must run unless it is satisfied", task.taskId));
            case RequestTaskStatus.waitingUpstream:
            case RequestTaskStatus.needed:
            case RequestTaskStatus.queued:
            case RequestTaskStatus.running:
                return RequestOutcome.open;
        }
    }
    return failed ? RequestOutcome.failed : blocked ? RequestOutcome.blocked : RequestOutcome.succeeded;
}

/// The facts of one fingerprint's ledger that decide a task's state, checked against the task.
private struct LedgerFacts
{
    /// The usable latest success, or empty.
    string successId;
    /// The latest success whose artifacts expired (a miss), or empty.
    string expiredSuccessId;
    /// The active execution, or empty; whether a worker holds it.
    string activeId;
    bool running;
    /// The latest stopped execution and how it ended, or empty.
    string stoppedId;
    ExecutionStatus stoppedStatus;
    ulong stopSeq;
    ulong executionSeq;

    /// Whether a stop settles a demand that saw `stopSeqAtDemand` stops.
    bool settles(ulong stopSeqAtDemand) const pure nothrow @safe
    {
        return stopSeq > stopSeqAtDemand;
    }

    /// Whether the task needs nothing more for a demand that saw `stopSeqAtDemand` stops: it has a
    /// usable success, an active execution, or a stop settling the demand.
    bool satisfies(ulong stopSeqAtDemand) const pure nothrow @safe
    {
        return successId.length > 0 || activeId.length > 0 || settles(stopSeqAtDemand);
    }
}

/// Checks `summary` of `fingerprint` (task `taskId` of project `projectId`) and extracts its facts.
private LedgerFacts factsOf(string projectId, string taskId, string fingerprint, in LedgerSummary summary) @trusted
{
    LedgerFacts facts;
    if (summary.ledger.isNull)
    {
        requireEvaluable(summary.lastSuccess.isNull && summary.lastStopped.isNull, format(
            "The summary of fingerprint %s (task '%s') names executions but no ledger", fingerprint, taskId));
        return facts;
    }
    const ledger = summary.ledger.get;
    requireEvaluable(ledger.fingerprint == fingerprint, format("The summary of fingerprint %s (task '%s') holds the ledger of fingerprint %s",
        fingerprint, taskId, ledger.fingerprint));
    requireEvaluable((ledger.stopSeq > 0) == (ledger.lastStoppedExecutionId.length > 0), format(
        "The ledger of fingerprint %s (task '%s') counts %s stops but names %s as the last",
        fingerprint, taskId, ledger.stopSeq, ledger.lastStoppedExecutionId.length > 0 ? "'" ~ ledger.lastStoppedExecutionId ~ "'" : "none"));
    facts.stopSeq = ledger.stopSeq;
    facts.executionSeq = ledger.executionSeq;

    // Each record named must be the one the ledger names, of this task at this fingerprint
    void requireRecord(in Nullable!TaskExecution record, string id, string what)
    {
        if (id.length == 0)
        {
            requireEvaluable(record.isNull, format("The summary of fingerprint %s (task '%s') has %s execution, but its ledger names none",
                fingerprint, taskId, what));
            return;
        }
        requireEvaluable(!record.isNull, format("The %s execution '%s' of fingerprint %s (task '%s') was not read", what, id,
            fingerprint, taskId));
        const execution = record.get;
        requireEvaluable(execution.id == id && execution.fingerprint == fingerprint && execution.taskId == taskId
            && execution.projectId == projectId, format(
            "The %s execution of fingerprint %s (task '%s' of project '%s') is '%s' at fingerprint %s for task '%s' of project '%s', not '%s'",
            what, fingerprint, taskId, projectId, execution.id, execution.fingerprint, execution.taskId, execution.projectId, id));
    }

    requireRecord(summary.lastSuccess, ledger.lastSuccessExecutionId, "last succeeded");
    requireRecord(summary.lastStopped, ledger.lastStoppedExecutionId, "last stopped");

    if (!ledger.active.isNull)
    {
        facts.activeId = ledger.active.get.id;
        facts.running = ledger.active.get.status == ExecutionStatus.running;
    }
    if (!summary.lastSuccess.isNull)
    {
        const success = summary.lastSuccess.get;
        requireEvaluable(success.status == ExecutionStatus.succeeded, format(
            "The last success '%s' of fingerprint %s (task '%s') is %s", success.id, fingerprint, taskId, success.status));
        if (success.artifactsExpiredAt.length > 0) facts.expiredSuccessId = success.id;
        else facts.successId = success.id;
    }
    if (!summary.lastStopped.isNull)
    {
        const stopped = summary.lastStopped.get;
        requireEvaluable(stopped.status == ExecutionStatus.failed || stopped.status == ExecutionStatus.cancelled, format(
            "The last stopped execution '%s' of fingerprint %s (task '%s') is %s", stopped.id, fingerprint, taskId, stopped.status));
        facts.stoppedId = stopped.id;
        facts.stoppedStatus = stopped.status;
    }
    return facts;
}

/**
 * Checks that `demand`'s recorded fingerprint agrees with the task's current one in `resolution`,
 * or that a rerun moved it: pins and a request's definition never change, so a fingerprint moves
 * only when the task or a task upstream of it (in `graph`, the request's closure) has a higher
 * rerun generation at the base the request recorded. Anything else (a fingerprint recorded wrong,
 * or a generation that went down) would silently turn the demand into one that saw no stops, so it
 * fails loudly.
 */
private void requireMovedByRerun(string chainId, string requestId, const TaskGraph graph, in GraphResolution resolution,
    in TaskDemand[string] demandOf, in TaskDemand demand) @trusted
{
    const taskId = demand.taskId;
    if (demand.fingerprint == resolution.fingerprints[taskId])
    {
        requireEvaluable(demand.base == resolution.bases[taskId] && demand.generation == resolution.generations[taskId], format(
            "Request '%s' on chain '%s' recorded task '%s' at fingerprint %s with base %s generation %s, but that fingerprint is base %s generation %s",
            requestId, chainId, taskId, demand.fingerprint, demand.base, demand.generation, resolution.bases[taskId],
            resolution.generations[taskId]));
        return;
    }
    bool rerun = false;
    foreach (upstream; graph.resolveSubgraph(taskId))
    {
        const recorded = demandOf[upstream];
        if (recorded.base != resolution.bases[upstream]) continue;
        const current = resolution.generations[upstream];
        requireEvaluable(current >= recorded.generation, format(
            "Request '%s' on chain '%s' recorded task '%s' at rerun generation %s of base %s, which is now at generation %s: generations never go down",
            requestId, chainId, upstream, recorded.generation, recorded.base, current));
        if (current > recorded.generation) rerun = true;
    }
    requireEvaluable(rerun, format(
        "Request '%s' on chain '%s' recorded task '%s' at fingerprint %s, but it is now at %s and neither it nor any task upstream of it was rerun",
        requestId, chainId, taskId, demand.fingerprint, resolution.fingerprints[taskId]));
}

/// Checks that `entry` is a request on `chain` running with the definition given, and returns the
/// graph of the tasks it covers.
private TaskGraph closureOf(in BuildChain chain, in DefinedRequest entry) @trusted
{
    const request = entry.request;
    requireEvaluable(chain.id.length > 0 && chain.projectId.length > 0, "A chain to evaluate needs an id and a project id");
    requireEvaluable(request.id.length > 0, format("A request on chain '%s' has no id", chain.id));
    requireEvaluable(request.chainId == chain.id && request.projectId == chain.projectId, format(
        "Request '%s' (project '%s', chain '%s') does not belong to chain '%s' of project '%s'",
        request.id, request.projectId, request.chainId, chain.id, chain.projectId));
    requireEvaluable(request.targets.length > 0, format("Request '%s' on chain '%s' has no targets", request.id, chain.id));
    const actual = definitionId(entry.definition);
    requireEvaluable(actual == request.definitionId, format(
        "Request '%s' runs with definition '%s', but the definition given for it is '%s'", request.id, request.definitionId, actual));
    try return closureGraph(entry.definition, request.targets);
    catch (RequestEvaluationException e)
    {
        throw new RequestEvaluationException(format("Request '%s' on chain '%s': %s", request.id, chain.id, e.msg));
    }
}

private void requireEvaluable(bool condition, lazy string message) @trusted
{
    if (!condition) throw new RequestEvaluationException(message);
}

version (unittest)
{
    import confector.core.fingerprint_ledger : endedExecution, withClaim, withFold, withStart;
    import confector.core.chain_pins : inputKeyLess, refsOf, selectPins;
    import confector.core.input_resolution : InputResolutionException, requiredPins;

    import vibe.data.json : Json;

    import std.algorithm.sorting : sort;

    /// Every repository input of `graph` bound to branch main, sorted by input, as a request records them.
    private InputBinding[] mainBindings(const TaskGraph graph)
    {
        InputBinding[] bindings;
        foreach (taskId; graph.allTaskIds())
        {
            foreach (name, decl; graph.getTask(taskId).inputs)
            {
                if (decl.kind == InputKind.repository) bindings ~= InputBinding(taskId, name, RepositoryRef(RefKind.branch, "main"));
            }
        }
        bindings.sort!((a, b) => inputKeyLess(inputKey(a), inputKey(b)));
        return bindings;
    }

    /// compile -> test -> report, compile -> package, and lint; compile and lint build repository game.
    private ProjectDefinition sampleDefinition()
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
        TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
        TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
        TaskNode package_; package_.id = "package"; package_.inputs["bin"] = taskOutputInput("compile");
        TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game");
        return ProjectDefinition([compile, test, report, package_, lint]);
    }

    private BuildChain sampleChain()
    {
        BuildChain chain;
        chain.id = "c1";
        chain.projectId = "p";
        chain.number = 1;
        chain.headline = HeadlineRef(HeadlineKind.branch, "main");
        chain.pins = [RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111")))];
        chain.createdAt = "2026-10-20T10:00:00Z";
        return chain;
    }

    /// What the shell would read: the chain, its requests, rerun generations (bases not listed are
    /// at 0), ledgers by fingerprint and finished executions by id. The ledgers move with the pure ledger
    /// transitions the LedgerStore uses. Requests of one chain share ledgers, as requests do.
    private struct World
    {
        BuildChain chain;
        DefinedRequest[string] requests;
        RerunGenerations bumped;
        FingerprintLedger[string] ledgers;
        TaskExecution[string] executions;
    }

    private World world()
    {
        World w;
        w.chain = sampleChain();
        return w;
    }

    private RerunGenerationReader readerOf(ref World w)
    {
        auto bumped = w.bumped.dup;
        return (in string[] bases) {
            RerunGenerations result;
            foreach (base; bases) result[base] = bumped.get(base, 0);
            return result;
        };
    }

    /// The fingerprints of the tasks a request with `targets` covers in `definition`, now.
    private GraphResolution closureAt(ref World w, in string[] targets, ProjectDefinition definition = sampleDefinition())
    {
        auto graph = closureGraph(definition, targets);
        return readGraphResolution(w.chain.projectId, graph, bindingMap(mainBindings(graph)), pinMap(w.chain.pins), readerOf(w));
    }

    private string fingerprintOf(ref World w, string taskId)
    {
        return closureAt(w, [taskId]).fingerprints[taskId];
    }

    /// Makes request `id` for `targets`, recording the demands an intake would: each covered
    /// task's fingerprint and its ledger's stop sequence now.
    private BuildRequest makeRequest(ref World w, string id, string[] targets, ProjectDefinition definition = sampleDefinition())
    {
        auto closure = closureAt(w, targets, definition);
        ulong[string] stopSeqs;
        foreach (fingerprint; closure.fingerprints.byValue)
        {
            auto ledger = fingerprint in w.ledgers;
            stopSeqs[fingerprint] = ledger is null ? 0 : ledger.stopSeq;
        }
        BuildRequest request;
        request.id = id;
        request.projectId = w.chain.projectId;
        request.chainId = w.chain.id;
        request.targets = targets;
        const graph = closureGraph(definition, targets);
        request.bindings = mainBindings(graph);
        request.pins = selectPins(w.chain.pins, refsOf(requiredPins(graph, bindingMap(request.bindings))));
        request.intent = BuildIntent.build;
        request.trigger.type = TriggerType.manual;
        request.definitionId = definitionId(definition);
        request.definitionSource = DefinitionSource(DefinitionLocation.confector);
        request.demands = requestDemands(closure, stopSeqs);
        request.requestedBy = "jason";
        request.requestedAt = "2026-10-20T10:00:00Z";
        return request;
    }

    /// Makes request `id` and adds it to the world.
    private void request(ref World w, string id, string[] targets, ProjectDefinition definition = sampleDefinition())
    {
        w.requests[id] = DefinedRequest(makeRequest(w, id, targets, definition), definition);
    }

    /// Claims the next execution at `fingerprint` and records it, queued.
    private string start(ref World w, string fingerprint, string taskId)
    {
        auto ledger = w.ledgers.get(fingerprint, FingerprintLedger(fingerprint));
        ActiveExecution proposed;
        proposed.projectId = w.chain.projectId;
        proposed.taskId = taskId;
        proposed.definitionId = "def1";
        proposed.createdAt = "2026-10-20T10:00:00Z";
        auto claimed = withClaim(ledger, proposed);
        w.ledgers[fingerprint] = claimed;
        return claimed.active.get.id;
    }

    /// Has a worker start the active execution at `fingerprint`.
    private void begin(ref World w, string fingerprint)
    {
        w.ledgers[fingerprint] = withStart(w.ledgers[fingerprint], "w1", "2026-10-20T10:10:00Z", "2026-10-20T10:00:00Z");
    }

    /// Ends the active execution at `fingerprint` with `status`, and folds it into its ledger.
    private string end(ref World w, string fingerprint, ExecutionStatus status)
    {
        auto ledger = w.ledgers[fingerprint];
        auto execution = endedExecution(fingerprint, ledger.active.get, status, "2026-10-20T10:05:00Z");
        w.executions[execution.id] = execution;
        w.ledgers[fingerprint] = withFold(ledger, execution);
        return execution.id;
    }

    /// Runs task `taskId` at its current fingerprint to the end, with `status`.
    private string run(ref World w, string taskId, ExecutionStatus status)
    {
        const fingerprint = fingerprintOf(w, taskId);
        start(w, fingerprint, taskId);
        return end(w, fingerprint, status);
    }

    private LedgerSummary summaryOf(ref World w, string fingerprint)
    {
        LedgerSummary summary;
        auto ledger = fingerprint in w.ledgers;
        if (ledger is null) return summary;
        summary.ledger = *ledger;
        Nullable!TaskExecution named(string id)
        {
            auto execution = id in w.executions;
            return execution is null ? Nullable!TaskExecution.init : nullable(*execution);
        }
        summary.lastSuccess = named(ledger.lastSuccessExecutionId);
        summary.lastStopped = named(ledger.lastStoppedExecutionId);
        return summary;
    }

    private LedgerSummary[string] summariesOf(ref World w, in DefinedRequest entry, in RerunGenerations generations)
    {
        LedgerSummary[string] summaries;
        foreach (fingerprint; requestFingerprints(w.chain, entry, generations)) summaries[fingerprint] = summaryOf(w, fingerprint);
        return summaries;
    }

    /// Evaluates request `id` as the shell would: generations, then a summary of every fingerprint.
    private RequestEvaluation evaluate(ref World w, string id)
    {
        const entry = w.requests[id];
        const generations = readRequestGenerations(w.chain, entry, readerOf(w));
        return evaluateRequest(w.chain, entry, generations, summariesOf(w, entry, generations));
    }

    private RequestTaskState stateOf(in RequestEvaluation evaluation, string taskId)
    {
        foreach (ref state; evaluation.tasks)
        {
            if (state.taskId == taskId) return cast(RequestTaskState) state;
        }
        assert(false, format("task '%s' was not evaluated", taskId));
    }

    private RequestTaskStatus statusOf(in RequestEvaluation evaluation, string taskId)
    {
        return stateOf(evaluation, taskId).status;
    }

    private string[] neededTasks(in RequestEvaluation evaluation)
    {
        string[] tasks;
        foreach (ref needed; evaluation.needed) tasks ~= needed.taskId;
        return tasks;
    }

    private string[] evaluatedTasks(in RequestEvaluation evaluation)
    {
        string[] tasks;
        foreach (ref state; evaluation.tasks) tasks ~= state.taskId;
        return tasks;
    }

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    /// Whether `action` throws E with a message containing `text`.
    private bool throwsWith(E)(string text, scope void delegate() action)
    {
        try action();
        catch (E e) return e.msg.canFind(text);
        return false;
    }
}

unittest
{
    // A cache miss: only the target and its upstream tasks are evaluated, in topological order;
    // the task with no upstream needs an execution, at a ledger never claimed
    auto w = world();
    request(w, "r1", ["report"]);
    auto evaluation = evaluate(w, "r1");
    assert(evaluation.requestId == "r1" && evaluation.outcome == RequestOutcome.open);
    assert(evaluatedTasks(evaluation) == ["compile", "test", "report"], "package and lint are not covered");
    assert(statusOf(evaluation, "compile") == RequestTaskStatus.needed);
    assert(statusOf(evaluation, "test") == RequestTaskStatus.waitingUpstream && statusOf(evaluation, "report") == RequestTaskStatus.waitingUpstream);
    assert(evaluation.needed.length == 1);
    const needed = evaluation.needed[0];
    assert(needed.taskId == "compile" && needed.fingerprint == fingerprintOf(w, "compile"));
    assert(needed.seenExecutionSeq == 0);
    assert(needed.inputs == [ResolvedInput("src", InputKind.repository, Json("aaa111"))]);

    auto report = stateOf(evaluation, "report");
    assert(report.target && !stateOf(evaluation, "compile").target && report.fingerprint == fingerprintOf(w, "report"));
}

unittest
{
    // An active execution is attached to, never duplicated: queued, then running
    auto w = world();
    request(w, "r1", ["test"]);
    const compileAt = fingerprintOf(w, "compile");
    const id = start(w, compileAt, "compile");

    auto queued = evaluate(w, "r1");
    assert(statusOf(queued, "compile") == RequestTaskStatus.queued && stateOf(queued, "compile").executionId == id);
    assert(queued.needed.length == 0 && queued.outcome == RequestOutcome.open);
    assert(statusOf(queued, "test") == RequestTaskStatus.waitingUpstream);

    begin(w, compileAt);
    auto running = evaluate(w, "r1");
    assert(statusOf(running, "compile") == RequestTaskStatus.running && stateOf(running, "compile").executionId == id);
    assert(running.needed.length == 0);
}

unittest
{
    // A cache hit: a success is reused, whichever request produced it; the next task then needs
    // an execution, at the ledger's executionSeq as seen
    auto w = world();
    const success = run(w, "compile", ExecutionStatus.succeeded); // another request built it
    request(w, "r1", ["report"]);
    auto evaluation = evaluate(w, "r1");
    assert(statusOf(evaluation, "compile") == RequestTaskStatus.succeeded && stateOf(evaluation, "compile").executionId == success);
    assert(neededTasks(evaluation) == ["test"] && evaluation.needed[0].seenExecutionSeq == 0);
    assert(evaluation.needed[0].inputs == [ResolvedInput("bin", InputKind.taskOutput, Json(fingerprintOf(w, "compile")))]);

    run(w, "test", ExecutionStatus.succeeded);
    run(w, "report", ExecutionStatus.succeeded);
    auto done = evaluate(w, "r1");
    foreach (taskId; ["compile", "test", "report"]) assert(statusOf(done, taskId) == RequestTaskStatus.succeeded, taskId);
    assert(done.needed.length == 0);
    assert(done.outcome == RequestOutcome.succeeded, "Every target succeeded");
}

unittest
{
    // Expired artifacts: a success whose artifacts expired is a miss: a target runs again
    // (claiming after the ledger's executionSeq); an upstream task whose dependents are satisfied
    // is not needed
    auto w = world();
    const expired = run(w, "compile", ExecutionStatus.succeeded);
    w.executions[expired].artifactsExpiredAt = "2026-10-21T00:00:00Z";
    request(w, "r1", ["compile"]);
    auto evaluation = evaluate(w, "r1");
    assert(statusOf(evaluation, "compile") == RequestTaskStatus.needed);
    assert(evaluation.needed[0].seenExecutionSeq == 1, "The claim must expect the expired execution");

    auto other = world();
    const old = run(other, "compile", ExecutionStatus.succeeded);
    other.executions[old].artifactsExpiredAt = "2026-10-21T00:00:00Z";
    run(other, "test", ExecutionStatus.succeeded);
    request(other, "r1", ["test"]);
    auto satisfied = evaluate(other, "r1");
    assert(statusOf(satisfied, "test") == RequestTaskStatus.succeeded);
    assert(statusOf(satisfied, "compile") == RequestTaskStatus.notNeeded && stateOf(satisfied, "compile").executionId == old);
    assert(satisfied.needed.length == 0, "A downstream cache hit never forces an upstream task to run");
    assert(satisfied.outcome == RequestOutcome.succeeded);
}

unittest
{
    // A requested upstream task that never ran is not needed when its dependent target already
    // succeeded, whichever request built it
    auto w = world();
    const compileAt = fingerprintOf(w, "compile");
    run(w, "test", ExecutionStatus.succeeded); // built when its compile result was still around
    request(w, "r1", ["test"]);
    auto evaluation = evaluate(w, "r1");
    assert(statusOf(evaluation, "compile") == RequestTaskStatus.notNeeded && stateOf(evaluation, "compile").executionId.length == 0);
    assert(evaluation.needed.length == 0 && compileAt !in w.ledgers);
}

unittest
{
    // Retry after failure, settled by sequence numbers: a failure after the request settles it
    // (failed; downstream blocked; nothing is retried automatically). A retry made after the
    // failure recorded the new stopSeq and runs again, at the same fingerprint; the earlier
    // request stays settled
    auto w = world();
    request(w, "r1", ["report"]);
    const compileAt = fingerprintOf(w, "compile");
    const failure = run(w, "compile", ExecutionStatus.failed);

    auto settled = evaluate(w, "r1");
    assert(statusOf(settled, "compile") == RequestTaskStatus.failed && stateOf(settled, "compile").executionId == failure);
    assert(statusOf(settled, "test") == RequestTaskStatus.blocked && stateOf(settled, "test").blockedBy == ["compile"]);
    assert(statusOf(settled, "report") == RequestTaskStatus.blocked && stateOf(settled, "report").blockedBy == ["compile"]);
    assert(settled.needed.length == 0, "A failure is never retried automatically");
    assert(settled.outcome == RequestOutcome.blocked, "The only target is blocked by the failure");

    request(w, "r2", ["compile"]);
    auto retried = evaluate(w, "r2");
    assert(statusOf(retried, "compile") == RequestTaskStatus.needed, "A retry after a failure is never ignored");
    assert(retried.needed == [NeededExecution("compile", compileAt, 1, [ResolvedInput("src", InputKind.repository, Json("aaa111"))])]);
    assert(retried.outcome == RequestOutcome.open);
    assert(statusOf(evaluate(w, "r1"), "compile") == RequestTaskStatus.failed, "The retry does not reopen the earlier request");

    // The retry's execution fails too: settled again
    start(w, compileAt, "compile");
    end(w, compileAt, ExecutionStatus.failed);
    auto failedAgain = evaluate(w, "r2");
    assert(statusOf(failedAgain, "compile") == RequestTaskStatus.failed && failedAgain.outcome == RequestOutcome.failed);
}

unittest
{
    // A request that attached to an execution in flight is settled by its failure: only sequence
    // numbers count
    auto w = world();
    const compileAt = fingerprintOf(w, "compile");
    start(w, compileAt, "compile"); // another request's execution
    request(w, "r1", ["test"]);
    assert(statusOf(evaluate(w, "r1"), "compile") == RequestTaskStatus.queued);
    end(w, compileAt, ExecutionStatus.failed);

    auto evaluation = evaluate(w, "r1");
    assert(statusOf(evaluation, "compile") == RequestTaskStatus.failed && statusOf(evaluation, "test") == RequestTaskStatus.blocked);
    assert(evaluation.needed.length == 0 && evaluation.outcome == RequestOutcome.blocked);
}

unittest
{
    // Blocked upstream: a cancellation settles like a failure and blocks downstream; blocking
    // reaches through blocked tasks to the stops that cause it
    auto w = world();
    request(w, "r1", ["report"]);
    run(w, "compile", ExecutionStatus.succeeded);
    const cancelled = run(w, "test", ExecutionStatus.cancelled);
    auto evaluation = evaluate(w, "r1");
    assert(statusOf(evaluation, "test") == RequestTaskStatus.cancelled && stateOf(evaluation, "test").executionId == cancelled);
    assert(statusOf(evaluation, "report") == RequestTaskStatus.blocked && stateOf(evaluation, "report").blockedBy == ["test"]);

    auto upstream = world();
    request(upstream, "r1", ["report"]);
    run(upstream, "compile", ExecutionStatus.failed);
    auto through = evaluate(upstream, "r1");
    assert(stateOf(through, "report").blockedBy == ["compile"], "Blocking names the stop, not the blocked task between");

    // A later success at the fingerprint (another request retried it) is reused
    const success = run(w, "test", ExecutionStatus.succeeded);
    auto reused = evaluate(w, "r1");
    assert(statusOf(reused, "test") == RequestTaskStatus.succeeded && stateOf(reused, "test").executionId == success);
    assert(neededTasks(reused) == ["report"]);
}

unittest
{
    // The outcome stays open until every target settles, and a failed target outweighs a
    // blocked one
    auto w = world();
    request(w, "r1", ["package", "lint"]);
    run(w, "compile", ExecutionStatus.succeeded);
    assert(evaluate(w, "r1").outcome == RequestOutcome.open);
    run(w, "package", ExecutionStatus.succeeded);
    assert(evaluate(w, "r1").outcome == RequestOutcome.open, "lint has not settled");
    run(w, "lint", ExecutionStatus.failed);
    auto failed = evaluate(w, "r1");
    assert(statusOf(failed, "package") == RequestTaskStatus.succeeded && failed.outcome == RequestOutcome.failed);

    auto mixed = world();
    request(mixed, "r1", ["report", "lint"]);
    run(mixed, "compile", ExecutionStatus.failed);
    assert(evaluate(mixed, "r1").outcome == RequestOutcome.open, "lint has not settled");
    run(mixed, "lint", ExecutionStatus.failed);
    auto result = evaluate(mixed, "r1");
    assert(statusOf(result, "report") == RequestTaskStatus.blocked && result.outcome == RequestOutcome.failed);
}

unittest
{
    // Two requests sharing one execution: both need compile; once one claims it the other
    // attaches to the same execution, and both see its success. A request is evaluated alone,
    // whatever the other asks for
    auto w = world();
    request(w, "r1", ["test"]);
    request(w, "r2", ["package"]);
    auto first = evaluate(w, "r1");
    auto second = evaluate(w, "r2");
    assert(neededTasks(first) == ["compile"] && neededTasks(second) == ["compile"]);
    assert(first.needed[0].fingerprint == second.needed[0].fingerprint && first.needed[0].seenExecutionSeq == 0);
    assert(evaluatedTasks(first) == ["compile", "test"] && evaluatedTasks(second) == ["compile", "package"]);

    const id = start(w, first.needed[0].fingerprint, "compile");
    foreach (requestId; ["r1", "r2"])
    {
        auto attached = evaluate(w, requestId);
        assert(statusOf(attached, "compile") == RequestTaskStatus.queued && stateOf(attached, "compile").executionId == id, requestId);
        assert(attached.needed.length == 0, requestId);
    }

    end(w, first.needed[0].fingerprint, ExecutionStatus.succeeded);
    assert(neededTasks(evaluate(w, "r1")) == ["test"] && neededTasks(evaluate(w, "r2")) == ["package"]);
    foreach (requestId; ["r1", "r2"]) assert(stateOf(evaluate(w, requestId), "compile").executionId == id);
}

unittest
{
    // Reruns are strict: bumping compile's generation gives compile and everything downstream new
    // fingerprints; the earlier successes are not used and downstream waits for the new
    // generation. The request carries over to the new fingerprints, having seen no stop there, so
    // a failed rerun blocks rather than falling back to the earlier success
    auto w = world();
    request(w, "r1", ["report"]);
    request(w, "r2", ["lint"]);
    foreach (taskId; ["compile", "test", "report", "lint"]) run(w, taskId, ExecutionStatus.succeeded);
    auto before = evaluate(w, "r1");
    assert(before.needed.length == 0 && before.outcome == RequestOutcome.succeeded);
    auto lintBefore = evaluate(w, "r2");

    const base = closureAt(w, ["compile"]).bases["compile"];
    w.bumped[base] = 1;
    auto after = evaluate(w, "r1");
    foreach (taskId; ["compile", "test", "report"])
    {
        assert(stateOf(after, taskId).fingerprint != stateOf(before, taskId).fingerprint, taskId);
    }
    assert(evaluate(w, "r2") == lintBefore, "Tasks not downstream are unaffected");
    assert(statusOf(after, "compile") == RequestTaskStatus.needed && after.needed.length == 1);
    assert(after.needed[0].seenExecutionSeq == 0 && after.outcome == RequestOutcome.open);
    assert(statusOf(after, "test") == RequestTaskStatus.waitingUpstream && statusOf(after, "report") == RequestTaskStatus.waitingUpstream);

    // The new generation fails: this request is settled too, and its downstream tasks block
    run(w, "compile", ExecutionStatus.failed);
    auto failed = evaluate(w, "r1");
    assert(statusOf(failed, "compile") == RequestTaskStatus.failed);
    assert(statusOf(failed, "test") == RequestTaskStatus.blocked && statusOf(failed, "report") == RequestTaskStatus.blocked);
    assert(failed.needed.length == 0);

    // A retry at the new generation runs it again
    request(w, "r3", ["compile"]);
    auto retried = evaluate(w, "r3");
    assert(statusOf(retried, "compile") == RequestTaskStatus.needed && retried.needed[0].seenExecutionSeq == 1);
}

unittest
{
    // A demand that saw stops at the old generation saw none at the new one: after a failure, a
    // retry and a rerun, a failure of the new generation settles the retry's demand too, rather
    // than counting as a stop the retry had already seen
    auto w = world();
    request(w, "r1", ["compile"]);
    run(w, "compile", ExecutionStatus.failed);
    request(w, "r2", ["compile"]); // the retry saw one stop
    run(w, "compile", ExecutionStatus.succeeded);
    assert(statusOf(evaluate(w, "r2"), "compile") == RequestTaskStatus.succeeded);

    w.bumped[closureAt(w, ["compile"]).bases["compile"]] = 1;
    auto rerun = evaluate(w, "r2");
    assert(statusOf(rerun, "compile") == RequestTaskStatus.needed);
    run(w, "compile", ExecutionStatus.failed);
    auto failed = evaluate(w, "r2");
    assert(statusOf(failed, "compile") == RequestTaskStatus.failed && failed.needed.length == 0,
        "A failed rerun is never retried automatically");
}

unittest
{
    // Each request runs over its own definition. Definitions that differ only in build
    // configuration agree on every fingerprint, and a later definition may add a task the chain
    // never built; a definition that gives a task other inputs gives it another fingerprint, with
    // no conflict between the requests
    auto w = world();
    request(w, "r1", ["test"]);
    auto changed = sampleDefinition();
    changed.tasks[0].steps = [BuildStep("Build", "bash", Json(["script": Json("make release")]))];
    TaskNode external; external.id = "external"; external.inputs["bin"] = taskOutputInput("compile");
    changed.tasks ~= external;
    request(w, "r2", ["external"], changed);

    auto first = evaluate(w, "r1");
    auto second = evaluate(w, "r2");
    assert(evaluatedTasks(first) == ["compile", "test"] && evaluatedTasks(second) == ["compile", "external"]);
    assert(stateOf(first, "compile").fingerprint == stateOf(second, "compile").fingerprint);
    assert(neededTasks(first) == ["compile"] && neededTasks(second) == ["compile"]);

    auto moved = sampleDefinition();
    moved.tasks[0].inputs["flavor"] = valueInput("external");
    request(w, "r3", ["compile"], moved);
    auto third = evaluate(w, "r3");
    assert(stateOf(third, "compile").fingerprint != stateOf(first, "compile").fingerprint);
    assert(neededTasks(third) == ["compile"] && neededTasks(evaluate(w, "r1")) == ["compile"]);
}

unittest
{
    // Inconsistent inputs fail loudly: a request of another chain, with another definition than
    // it names, targeting a task its definition lacks, or with demands for other tasks than it
    // covers; a missing generation, pin or ledger summary
    auto w = world();
    request(w, "r1", ["test"]);
    const generations = readRequestGenerations(w.chain, w.requests["r1"], readerOf(w));
    auto summaries = summariesOf(w, w.requests["r1"], generations);
    evaluateRequest(w.chain, w.requests["r1"], generations, summaries);

    RequestEvaluation evaluateWith(DefinedRequest entry)
    {
        return evaluateRequest(w.chain, entry, generations, summaries);
    }
    DefinedRequest altered(void delegate(ref DefinedRequest) change)
    {
        auto entry = DefinedRequest(w.requests["r1"].request, w.requests["r1"].definition);
        entry.definition.tasks = entry.definition.tasks.dup;
        change(entry);
        return entry;
    }

    assert(throwsWith!RequestEvaluationException("does not belong", { evaluateWith(altered((ref e) { e.request.chainId = "c2"; })); }));
    assert(throwsWith!RequestEvaluationException("does not belong", { evaluateWith(altered((ref e) { e.request.projectId = "q"; })); }));
    assert(throwsWith!RequestEvaluationException("has no id", { evaluateWith(altered((ref e) { e.request.id = null; })); }));
    assert(throwsWith!RequestEvaluationException("the definition given for it", { evaluateWith(altered((ref e) {
        e.definition.tasks[0].steps = [BuildStep("Build", "bash", Json(["script": Json("other")]))]; })); }));
    assert(throwsWith!RequestEvaluationException("'package'", { evaluateWith(altered((ref e) {
        e.definition = ProjectDefinition([e.definition.tasks[0], e.definition.tasks[1]]);
        e.request.definitionId = definitionId(e.definition);
        e.request.targets = ["package"]; })); }));
    assert(throwsWith!RequestEvaluationException("records demands", { evaluateWith(altered((ref e) { e.request.demands = e.request.demands[0 .. 1]; })); }));
    assert(throwsWith!RequestEvaluationException("records demands", { evaluateWith(altered((ref e) { e.request.targets = ["compile"]; })); }));
    assert(throwsWith!RequestEvaluationException("no targets", { evaluateWith(altered((ref e) { e.request.targets = null; })); }));

    RerunGenerations none;
    assert(throwsA!InputResolutionException({ evaluateRequest(w.chain, w.requests["r1"], none, summaries); }), "A missing generation is never 0");
    auto unpinned = DefinedRequest(w.requests["r1"].request, w.requests["r1"].definition);
    unpinned.request.pins = null;
    assert(throwsA!InputResolutionException({ evaluateRequest(w.chain, unpinned, generations, summaries); }), "A request without its pins is not evaluated");
    LedgerSummary[string] missing;
    assert(throwsWith!RequestEvaluationException("not summarized", { evaluateRequest(w.chain, w.requests["r1"], generations, missing); }));
}

unittest
{
    // The evaluator reads the request's pins, never its chain's: a chain whose pins change after
    // the request was recorded gives the request the same fingerprints and the same evaluation
    auto w = world();
    request(w, "r1", ["report"]);
    const entry = w.requests["r1"];
    auto generations = readRequestGenerations(w.chain, entry, readerOf(w));
    const summaries = summariesOf(w, entry, generations);
    const fingerprints = requestFingerprints(w.chain, entry, generations);
    const evaluated = evaluateRequest(w.chain, entry, generations, summaries);

    auto moved = w.chain;
    moved.pins = [RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("bbb222")))];
    assert(readRequestGenerations(moved, entry, readerOf(w)) == generations);
    assert(requestFingerprints(moved, entry, generations) == fingerprints);
    assert(evaluateRequest(moved, entry, generations, summaries) == evaluated);
    moved.pins = null;
    assert(evaluateRequest(moved, entry, generations, summaries) == evaluated);
}

unittest
{
    // Ledger summaries that contradict themselves or the task fail loudly
    auto w = world();
    request(w, "r1", ["compile"]);
    const compileAt = fingerprintOf(w, "compile");
    run(w, "compile", ExecutionStatus.failed);
    const succeeded = run(w, "compile", ExecutionStatus.succeeded);
    start(w, compileAt, "compile");
    const entry = w.requests["r1"];
    const generations = readRequestGenerations(w.chain, entry, readerOf(w));
    auto good = summaryOf(w, compileAt);
    assert(statusOf(evaluateRequest(w.chain, entry, generations, [compileAt: good]), "compile") == RequestTaskStatus.succeeded);

    bool refused(string text, void delegate(ref LedgerSummary) change)
    {
        LedgerSummary summary = good;
        change(summary);
        return throwsWith!RequestEvaluationException(text, { evaluateRequest(w.chain, entry, generations, [compileAt: summary]); });
    }

    assert(refused("was not read", (ref s) { s.lastSuccess.nullify(); }));
    assert(refused("was not read", (ref s) { s.lastStopped.nullify(); }));
    assert(refused("is failed", (ref s) { auto e = s.lastSuccess.get; e.status = ExecutionStatus.failed; s.lastSuccess = e; }));
    assert(refused("is succeeded", (ref s) { auto e = s.lastStopped.get; e.status = ExecutionStatus.succeeded; s.lastStopped = e; }));
    assert(refused("not '" ~ succeeded ~ "'", (ref s) { s.lastSuccess = s.lastStopped; }));
    assert(refused("holds the ledger", (ref s) { auto l = s.ledger.get; l.fingerprint = "other"; s.ledger = l; }));
    assert(refused("counts 0 stops", (ref s) { auto l = s.ledger.get; l.stopSeq = 0; s.ledger = l; }));
    assert(refused("but no ledger", (ref s) { s.ledger.nullify(); }));
    assert(refused("its ledger names none", (ref s) { auto l = s.ledger.get; l.lastSuccessExecutionId = null; s.ledger = l; }));
}

unittest
{
    // The shell's helpers: demands as an intake records them, the fingerprints to summarize, and
    // generations read a level at a time across the request's graph
    import confector.core.input_resolution : graphResolution;

    auto w = world();
    const closure = closureAt(w, ["test"]);
    const compileAt = closure.fingerprints["compile"];
    const testAt = closure.fingerprints["test"];
    assert(requestDemands(closure, [compileAt: 2UL, testAt: 0UL]) == [TaskDemand("compile", compileAt, closure.bases["compile"], 0, 2),
        TaskDemand("test", testAt, closure.bases["test"], 0, 0)]);
    assert(throwsWith!RequestEvaluationException("was not read", { requestDemands(closure, [compileAt: 2UL]); }));
    string[string] unread;
    RerunGenerations none;
    auto testGraph = closureGraph(sampleDefinition(), ["test"]);
    auto partial = graphResolution("p", testGraph, bindingMap(mainBindings(testGraph)),
        pinMap([RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111")))]), none, unread);
    assert(throwsWith!RequestEvaluationException("rerun generation", { requestDemands(partial, null); }));
    assert(throwsWith!RequestEvaluationException("'nope'", { closureGraph(sampleDefinition(), ["nope"]); }));

    request(w, "r1", ["report"]);
    size_t reads;
    auto counting = readerOf(w);
    auto generations = readRequestGenerations(w.chain, w.requests["r1"], (in string[] bases) { ++reads; return counting(bases); });
    assert(reads == 3, "compile, then test, then report");
    assert(generations.length == 3);
    auto fingerprints = requestFingerprints(w.chain, w.requests["r1"], generations);
    assert(fingerprints.length == 3 && fingerprints.canFind(compileAt) && fingerprints.canFind(testAt));
    RerunGenerationReader forgetful = (in string[] bases) { RerunGenerations nothing; return nothing; };
    assert(throwsWith!Exception("returned none", { readRequestGenerations(w.chain, w.requests["r1"], forgetful); }));
}

unittest
{
    // A demand's fingerprint moves only through a rerun of the task or an upstream task. A request
    // whose recorded fingerprint differs without one (recorded wrong), or whose generation went
    // down, fails loudly instead of being read as a demand that saw no stops, which would let an
    // earlier failure silently settle a retry
    auto w = world();
    request(w, "r1", ["test"]);
    run(w, "compile", ExecutionStatus.failed);
    request(w, "r2", ["compile"]); // a retry, which saw the stop
    assert(statusOf(evaluate(w, "r2"), "compile") == RequestTaskStatus.needed);

    auto wrong = w;
    wrong.requests = w.requests.dup;
    wrong.requests["r2"].request.demands = wrong.requests["r2"].request.demands.dup;
    wrong.requests["r2"].request.demands[0].fingerprint = "some-other-fingerprint";
    assert(throwsWith!RequestEvaluationException("neither it nor any task upstream of it was rerun", { evaluate(wrong, "r2"); }));

    auto inconsistent = w;
    inconsistent.requests = w.requests.dup;
    inconsistent.requests["r2"].request.demands = inconsistent.requests["r2"].request.demands.dup;
    inconsistent.requests["r2"].request.demands[0].generation = 3;
    assert(throwsWith!RequestEvaluationException("but that fingerprint is base", { evaluate(inconsistent, "r2"); }));

    // A rerun of compile explains both compile's and test's moved fingerprints
    const base = closureAt(w, ["compile"]).bases["compile"];
    w.bumped[base] = 2;
    assert(statusOf(evaluate(w, "r1"), "test") == RequestTaskStatus.waitingUpstream);

    // A request recorded at a later generation than the current one is refused
    auto ahead = world();
    ahead.bumped[base] = 2;
    request(ahead, "r1", ["test"]);
    ahead.bumped[base] = 1;
    assert(throwsWith!RequestEvaluationException("generations never go down", { evaluate(ahead, "r1"); }));
}
