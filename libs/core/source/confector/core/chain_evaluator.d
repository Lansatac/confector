module confector.core.chain_evaluator;

/**
 * The chain evaluator (design records: beads confector-z7z.2, confector-z7z.14, confector-z7z.15,
 * confector-z7z.48 and confector-z7z.52; AGENTS.md, "Coordinating builds", "What a build is" and
 * "Re-running a task"): the pure core of build coordination. Given a build chain (its pins), the
 * requests on it with the definitions they run with, the current rerun generations and a summary
 * of the ledger of each of its fingerprints, it derives the state of every task a request covers,
 * the fingerprints that need an execution and the active executions the chain waits on. It
 * performs no I/O and reads no clock.
 *
 * The shell (the chain reconciler, bead confector-z7z.49.3) loads its inputs, all by id: the
 * chain's ChainState (confector.core.chain_state), which names its requests; each request and its
 * definition; the rerun generations (`readChainGenerations`); and, for every fingerprint
 * (`chainFingerprints`), the ledger settled and the executions it names (`readLedgerSummary`). It
 * hands the needed fingerprints to the execution dispatcher, subscribes on the ledgers of the
 * awaited executions at the ledger versions the evaluation read (AwaitedExecution.ledger; a
 * conflict or notActive means re-evaluate, not commit), and commits the evaluation to the
 * ChainState.
 *
 * Rules:
 *
 * - **Requested** means the task is a target of one of the chain's requests or upstream of one, in
 *   that request's definition. A request never covers tasks downstream of its targets. Only
 *   requested tasks are evaluated; a task no request covers may not even have its inputs pinned.
 * - **Demands are settled by sequence numbers, never by time.** Each request records, per task it
 *   covers, the task's fingerprint and the ledger's `stopSeq` there when it was made
 *   (BuildRequest.demands). A task's governing demand is the one with the highest `stopSeq` at the
 *   task's current fingerprint, the latest request on ties (ChainTaskState.demandSeq). A failure
 *   or cancellation settles it only when the ledger's `stopSeq` is greater: it ended after every
 *   request covering the task was made, including requests that attached to it in flight. A
 *   request made after a stop, such as a retry, recorded the higher `stopSeq`, so it asks for the
 *   task again, at the same fingerprint, whatever any clock says. A demand recorded at another
 *   fingerprint (a rerun moved the task since) counts as having seen no stop at the new one: the
 *   new generation did not exist when the request was made. Each demand also records the task's
 *   base and rerun generation, and a moved fingerprint must be explained by a higher generation of
 *   the task or an upstream task; otherwise the evaluation fails loudly, since a wrongly recorded
 *   fingerprint would silently ignore a retry.
 * - **A success is always reused** (a cache hit), whichever chain produced it: the ledger's latest
 *   success, unless retention removed its artifacts (TaskExecution.artifactsExpiredAt), which
 *   makes it a miss, not a cache hit (AGENTS.md, "The caching contract").
 * - **An active execution is attached to**, never duplicated: the ledger holds at most one, and
 *   the chain waits on it (ChainEvaluation.awaited), whichever definition it runs with.
 * - **Failures and cancellations are never cache hits, and are never retried automatically.**
 * - **A task must run** when it is a target of a request, or upstream of a task that must run,
 *   and it has no usable success, no active execution and no stop settling its demand. A requested
 *   task that is none of these, and that no task that must run depends on, is notNeeded: a
 *   downstream cache hit never forces an upstream task to run.
 * - **A task needs an execution** when it must run and every upstream task has succeeded. A task
 *   whose upstream task failed or was cancelled is blocked. The needed execution carries the
 *   ledger's `executionSeq`, which the dispatcher passes to `LedgerStore.claim` so a decision made
 *   before another execution started and ended never builds the fingerprint twice, and the
 *   request whose definition it runs with (the governing demand's).
 * - **Reruns are strict.** Fingerprints come from each request's definition, the chain's pins and
 *   the current rerun generations, so after a rerun the rerun task and everything downstream of
 *   it have new fingerprints, earlier successes are not used, and downstream tasks wait for the
 *   new generation to succeed and are blocked if it fails.
 *
 * Unsent and unrecorded executions are not the evaluator's concern: a task whose fingerprint has
 * an active execution is queued (or running) whether or not that execution was ever sent or
 * recorded; the reconciler hands each awaited execution to the dispatcher, which records an
 * unrecorded one from the request it is awaited for (AwaitedExecution.requestId and inputs) and
 * sends an unsent one, and the sweep resends unsent ones (confector.core.execution_dispatcher).
 * Infrastructure failures retry within one execution, which stays active meanwhile
 * (TaskExecution.attempts). Stale index copies cannot confuse it: it reads no index.
 *
 * Requests whose definitions give one task different fingerprints (different inputs for the same
 * task id) are refused loudly for now; evaluating each request over its own graph is bead
 * confector-z7z.53.3. Requests whose definitions differ only in build configuration agree on
 * every fingerprint, and are evaluated together.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.chain_pins : pinMap;
import confector.core.dag : TaskGraph;
import confector.core.definition_store : definitionId;
import confector.core.document_collection : Versioned;
import confector.core.fingerprint_ledger : LedgerStore;
import confector.core.input_resolution : GraphResolution, RerunGenerations, completeGraphResolution, graphResolution;
import confector.core.rerun_generations : RerunGenerationReader;
import confector.api.model;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;
import std.typecons : Nullable, nullable;

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
 * A request on the chain, with the definition it runs with (read by `request.definitionId`).
 */
struct ChainRequest
{
    BuildRequest request;
    ProjectDefinition definition;
}

/**
 * What the chain evaluator needs to know about one fingerprint: its ledger, settled
 * (`LedgerStore.settle`, so a half-finished fold never looks like a running execution), and the
 * executions it names, each read by id (`readLedgerSummary`).
 */
struct LedgerSummary
{
    /// The ledger, with the version it was read at; null if no execution was ever claimed at the
    /// fingerprint. The version is what the shell subscribes at (AwaitedExecution.ledger), so an
    /// execution that ends after this read makes the subscribe fail instead of being missed.
    Nullable!(Versioned!FingerprintLedger) ledger;
    /// The record of `ledger.activeExecutionId`: null when none is active, or when the active
    /// execution was claimed but its record was never written (the dispatcher repairs that).
    Nullable!TaskExecution active;
    /// The records of `ledger.lastSuccessExecutionId` and `ledger.lastStoppedExecutionId`; null
    /// exactly when the ledger names none.
    Nullable!TaskExecution lastSuccess;
    Nullable!TaskExecution lastStopped;
}

/**
 * A fingerprint that needs an execution. The dispatcher claims it with `LedgerStore.claim(
 * fingerprint, seenExecutionSeq)` and records the execution with `inputs` and the definition of
 * request `requestId`.
 */
struct NeededExecution
{
    string taskId;
    string fingerprint;
    /// The ledger's `executionSeq` as the evaluation saw it; 0 when it has no ledger.
    ulong seenExecutionSeq;
    /// The request whose demand governs the task (ChainTaskState.demandSeq).
    string requestId;
    /// The task's resolved inputs, task outputs included, as its work order carries them.
    ResolvedInput[] inputs;
}

/**
 * An active execution the chain waits on. The shell subscribes the chain on `ledger`, the ledger
 * as this evaluation read it, at the version read (`LedgerStore.subscribe(ledger, chainId)`), so
 * the chain is marked dirty when the execution ends. If the subscribe conflicts or reports
 * notActive, the execution may have ended since the evaluation: re-read and evaluate again, and do
 * not commit this evaluation; subscribing on a fresh read instead could lose the wakeup.
 */
struct AwaitedExecution
{
    string taskId;
    string fingerprint;
    string executionId;
    /// The fingerprint's ledger as read for the evaluation, naming `executionId` as active.
    Versioned!FingerprintLedger ledger;
    /// The request whose demand governs the task (ChainTaskState.demandSeq) and the task's resolved
    /// inputs, as for NeededExecution: if the active execution was claimed but never recorded (its
    /// dispatcher crashed), the dispatcher records it from them.
    string requestId;
    ResolvedInput[] inputs;
}

/**
 * The result of evaluating a chain.
 */
struct ChainEvaluation
{
    string chainId;
    /// The requests evaluated, in the order given: a commit checks they are the ChainState's.
    string[] requestIds;
    /// The state of every task a request covers, in topological order.
    ChainTaskState[] tasks;
    /// The fingerprints that need an execution, in topological order of their tasks.
    NeededExecution[] needed;
    /// The active executions the chain waits on, in topological order of their tasks.
    AwaitedExecution[] awaited;
}

/**
 * The graph of the tasks a request with `targets` covers in `definition`: the targets and their
 * upstream tasks, never downstream ones.
 *
 * Throws: ChainEvaluationException if a target is not a task of the definition;
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
            throw new ChainEvaluationException(format("Target '%s' is not a task of the definition", target));
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
 * task's fingerprint, base and rerun generation, with the `stopSeq` of that fingerprint's ledger in `stopSeqs` (keyed by
 * fingerprint, read after settling the ledger; 0 for a fingerprint with no ledger). Sorted by task
 * id. For request intake (bead confector-z7z.53.2).
 *
 * Throws: ChainEvaluationException if `closure` lacks a task's fingerprint (its generations were
 * not all read) or `stopSeqs` lacks one of the fingerprints.
 */
TaskDemand[] requestDemands(in GraphResolution closure, in ulong[string] stopSeqs) @trusted
{
    TaskDemand[] demands;
    foreach (taskId; closure.bases.keys.sort().release)
    {
        auto fingerprint = taskId in closure.fingerprints;
        if (fingerprint is null)
        {
            throw new ChainEvaluationException(format("Task '%s' has no fingerprint: its rerun generation was not read", taskId));
        }
        auto stopSeq = *fingerprint in stopSeqs;
        if (stopSeq is null)
        {
            throw new ChainEvaluationException(format("The stop sequence of task '%s' at fingerprint %s was not read", taskId, *fingerprint));
        }
        demands ~= TaskDemand(taskId, *fingerprint, closure.bases[taskId], closure.generations[taskId], *stopSeq);
    }
    return demands;
}

/**
 * Every fingerprint the requests of `chain` cover at `generations` (which must hold every base),
 * sorted and distinct: the ledgers the shell summarizes for `evaluateChain`.
 *
 * Throws: as `evaluateChain` for a request that does not fit the chain or a missing generation.
 */
string[] chainFingerprints(in BuildChain chain, in ChainRequest[] requests, in RerunGenerations generations) @trusted
{
    bool[string] distinct;
    foreach (ref entry; requests)
    {
        const resolution = completeGraphResolution(chain.projectId, closureOf(chain, entry), pinMap(chain.pins), generations);
        foreach (fingerprint; resolution.fingerprints.byValue) distinct[fingerprint] = true;
    }
    return distinct.keys.sort().release;
}

/**
 * Reads, with `read`, the rerun generation of every base the requests of `chain` cover, a level of
 * their graphs at a time (as confector.core.rerun_generations.readGraphResolution does for one
 * graph), and returns them all.
 *
 * Throws: Exception if `read` returns no generation for a base it was asked for; as
 * `evaluateChain` for a request that does not fit the chain.
 */
RerunGenerations readChainGenerations(in BuildChain chain, in ChainRequest[] requests, scope RerunGenerationReader read) @trusted
{
    TaskGraph[] graphs;
    foreach (ref entry; requests) graphs ~= closureOf(chain, entry);
    const pins = pinMap(chain.pins);

    RerunGenerations generations;
    for (;;)
    {
        bool[string] unreadBases;
        foreach (graph; graphs)
        {
            string[string] unread;
            graphResolution(chain.projectId, graph, pins, generations, unread);
            foreach (base; unread.byValue) unreadBases[base] = true;
        }
        if (unreadBases.length == 0) return generations;

        auto bases = unreadBases.keys.sort().release;
        auto readGenerations = read(bases);
        foreach (base; bases)
        {
            auto generation = base in readGenerations;
            if (generation is null)
            {
                throw new Exception(format("Reading rerun generations returned none for base fingerprint %s", base));
            }
            generations[base] = *generation;
        }
    }
}

/**
 * Reads what `evaluateChain` needs to know about `fingerprint`: settles its ledger (completing a
 * half-finished fold) and reads by id the executions it names. Part of the shell, next to the core
 * it feeds.
 *
 * Throws: whatever `LedgerStore.settle` and `ExecutionStore.get` throw.
 */
LedgerSummary readLedgerSummary(LedgerStore ledgers, ExecutionStore executions, string fingerprint)
{
    auto settled = ledgers.settle(fingerprint);
    LedgerSummary summary;
    if (settled.ledger.isNull) return summary;
    summary.ledger = settled.ledger;
    if (!settled.execution.isNull) summary.active = nullable(settled.execution.get.value);

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
 * Derives the state of every task the requests on `chain` cover, the fingerprints that need an
 * execution and the active executions the chain waits on (see the module documentation for the
 * rules), from the chain's pins, its `requests` in the order its ChainState names them, the current
 * rerun `generations` (which must hold every base the requests cover) and `ledgers`, a summary for
 * every fingerprint they cover (`chainFingerprints`). Summaries of other fingerprints are ignored.
 * Pure: performs no I/O and reads no clock; no timestamp is ever compared.
 *
 * Throws: ChainEvaluationException if a request has no id or the same id as another, belongs to
 * another chain or project, runs with a definition other than the one given (its id is not the
 * definition's hash), targets a task its definition lacks, or records demands for other tasks
 * than its targets and their upstream tasks; if two requests give one task different
 * fingerprints (bead confector-z7z.53.3); if a covered fingerprint has no summary, or its summary
 * contradicts itself or the task (see `LedgerSummary`), including an active execution that has
 * already ended (the ledger was not settled). InputResolutionException if a generation is missing
 * or the chain lacks a pin a request needs.
 */
ChainEvaluation evaluateChain(
    in BuildChain chain,
    in ChainRequest[] requests,
    in RerunGenerations generations,
    in LedgerSummary[string] ledgers
) @trusted
{
    requireEvaluable(chain.id.length > 0 && chain.projectId.length > 0, "A chain to evaluate needs an id and a project id");

    ChainEvaluation result;
    result.chainId = chain.id;
    const pins = pinMap(chain.pins);

    // What the requests covering each task ask of it, in request order
    Coverage[string] coverage;
    foreach (i, ref entry; requests)
    {
        const request = entry.request;
        requireEvaluable(!result.requestIds.canFind(request.id), format("Request '%s' is given twice", request.id));
        result.requestIds ~= request.id;

        auto graph = closureOf(chain, entry);
        const resolution = completeGraphResolution(chain.projectId, graph, pins, generations);
        string[] demanded;
        foreach (ref demand; request.demands) demanded ~= demand.taskId;
        requireEvaluable(demanded == graph.allTaskIds(), format(
            "Request '%s' records demands for tasks [%-(%s, %)], but its targets and their upstream tasks are [%-(%s, %)]",
            request.id, demanded, graph.allTaskIds()));

        TaskDemand[string] demandOf;
        foreach (ref demand; request.demands) demandOf[demand.taskId] = demand;
        foreach (ref demand; request.demands) requireMovedByRerun(chain.id, request.id, graph, resolution, demandOf, demand);

        const seq = i + 1;
        foreach (ref demand; request.demands)
        {
            const fingerprint = resolution.fingerprints[demand.taskId];
            // A demand recorded at another fingerprint saw no stop at this one: a rerun created it
            // since (requireMovedByRerun checked that)
            const stopSeq = demand.fingerprint == fingerprint ? demand.stopSeq : 0;
            const target = request.targets.canFind(demand.taskId);
            auto covered = demand.taskId in coverage;
            if (covered is null)
            {
                coverage[demand.taskId] = Coverage(graph.getTask(demand.taskId), fingerprint,
                    (cast(ResolvedInput[]) resolution.inputs[demand.taskId]).dup, target, seq, stopSeq, request.id);
                continue;
            }
            requireEvaluable(covered.fingerprint == fingerprint, format(
                "Task '%s' of chain '%s' is at fingerprint %s for request '%s' but at %s for request '%s': their definitions give it different inputs, and evaluating each request over its own graph is not implemented yet (bead confector-z7z.53.3)",
                demand.taskId, chain.id, covered.fingerprint, covered.requestId, fingerprint, request.id));
            covered.node = graph.getTask(demand.taskId);
            covered.target = covered.target || target;
            if (stopSeq >= covered.stopSeqAtDemand)
            {
                covered.stopSeqAtDemand = stopSeq;
                covered.demandSeq = seq;
                covered.requestId = request.id;
                covered.inputs = (cast(ResolvedInput[]) resolution.inputs[demand.taskId]).dup;
            }
        }
    }

    // One fingerprint gives one set of inputs, so the requests' graphs agree on every edge
    TaskNode[] nodes;
    foreach (ref covered; coverage.byValue) nodes ~= covered.node;
    auto graph = new TaskGraph(nodes);
    const order = graph.topologicalSort();

    LedgerFacts[string] facts;
    foreach (taskId; order)
    {
        const fingerprint = coverage[taskId].fingerprint;
        auto summary = fingerprint in ledgers;
        requireEvaluable(summary !is null, format("Task '%s' of chain '%s' is at fingerprint %s, whose ledger was not summarized",
            taskId, chain.id, fingerprint));
        facts[taskId] = factsOf(chain.projectId, taskId, fingerprint, *summary);
    }

    // Decided from the downstream end: a task must run when it is a target or upstream of a task
    // that must run, and nothing satisfies it already
    bool[string] mustRun;
    foreach_reverse (taskId; order)
    {
        if (facts[taskId].satisfies(coverage[taskId].stopSeqAtDemand)) continue;
        bool must = coverage[taskId].target;
        foreach (dependent; graph.getDependents(taskId)) must = must || (dependent in mustRun) !is null;
        if (must) mustRun[taskId] = true;
    }

    ChainTaskStatus[string] statuses;
    string[][string] blockers;
    foreach (taskId; order)
    {
        const covered = coverage[taskId];
        const fact = facts[taskId];
        ChainTaskState state;
        state.taskId = taskId;
        state.fingerprint = covered.fingerprint;
        state.target = covered.target;
        state.demandSeq = covered.demandSeq;
        state.stopSeqAtDemand = covered.stopSeqAtDemand;

        if (fact.successId.length > 0)
        {
            state.status = ChainTaskStatus.succeeded;
            state.executionId = fact.successId;
        }
        else if (fact.activeId.length > 0)
        {
            state.status = fact.running ? ChainTaskStatus.running : ChainTaskStatus.queued;
            state.executionId = fact.activeId;
            result.awaited ~= AwaitedExecution(taskId, covered.fingerprint, fact.activeId, cast(Versioned!FingerprintLedger) fact.ledger,
                covered.requestId, (cast(ResolvedInput[]) covered.inputs).dup);
        }
        else if (fact.settles(covered.stopSeqAtDemand))
        {
            // A stop that ended after every request covering the task was made settles them all;
            // only a later request asks for the task again
            state.status = fact.stoppedStatus == ExecutionStatus.failed ? ChainTaskStatus.failed : ChainTaskStatus.cancelled;
            state.executionId = fact.stoppedId;
        }
        else if (taskId !in mustRun)
        {
            // Covered only for downstream tasks that are already satisfied: not worth running
            state.status = ChainTaskStatus.notNeeded;
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
                    case ChainTaskStatus.succeeded:
                        break;
                    case ChainTaskStatus.failed:
                    case ChainTaskStatus.cancelled:
                        blockedBy[upstream] = true;
                        break;
                    case ChainTaskStatus.blocked:
                        foreach (root; blockers[upstream]) blockedBy[root] = true;
                        break;
                    case ChainTaskStatus.waitingUpstream:
                    case ChainTaskStatus.needed:
                    case ChainTaskStatus.queued:
                    case ChainTaskStatus.running:
                        upstreamPending = true;
                        break;
                    case ChainTaskStatus.notNeeded:
                        throw new ChainEvaluationException(format(
                            "Task '%s' of chain '%s' must run but its upstream task '%s' is not needed", taskId, chain.id, upstream));
                }
            }

            if (blockedBy.length > 0)
            {
                state.status = ChainTaskStatus.blocked;
                state.blockedBy = blockedBy.keys.sort().release;
            }
            else if (upstreamPending)
            {
                state.status = ChainTaskStatus.waitingUpstream;
            }
            else
            {
                state.status = ChainTaskStatus.needed;
                result.needed ~= NeededExecution(taskId, covered.fingerprint, fact.executionSeq, covered.requestId,
                    (cast(ResolvedInput[]) covered.inputs).dup);
            }
        }

        statuses[taskId] = state.status;
        blockers[taskId] = state.blockedBy;
        result.tasks ~= state;
    }
    return result;
}

/// What the requests covering one task ask of it.
private struct Coverage
{
    /// The task as the latest request's definition declares it.
    TaskNode node;
    string fingerprint;
    /// The task's resolved inputs, from the governing request's resolution.
    ResolvedInput[] inputs;
    bool target;
    /// The governing demand: its request's position (1-based), the stop sequence it saw at
    /// `fingerprint`, and its request's id.
    size_t demandSeq;
    ulong stopSeqAtDemand;
    string requestId;
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
    /// The ledger as read, with its version (set when the ledger exists).
    Versioned!FingerprintLedger ledger;

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
        requireEvaluable(summary.active.isNull && summary.lastSuccess.isNull && summary.lastStopped.isNull, format(
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
    facts.ledger = cast(Versioned!FingerprintLedger) ledger;

    // Each record named must be the one the ledger names, of this task at this fingerprint
    void requireRecord(in Nullable!TaskExecution record, string id, string what, bool mayBeMissing)
    {
        if (id.length == 0)
        {
            requireEvaluable(record.isNull, format("The summary of fingerprint %s (task '%s') has %s execution, but its ledger names none",
                fingerprint, taskId, what));
            return;
        }
        if (record.isNull)
        {
            requireEvaluable(mayBeMissing, format("The %s execution '%s' of fingerprint %s (task '%s') was not read", what, id,
                fingerprint, taskId));
            return;
        }
        const execution = record.get;
        requireEvaluable(execution.id == id && execution.fingerprint == fingerprint && execution.taskId == taskId
            && execution.projectId == projectId, format(
            "The %s execution of fingerprint %s (task '%s' of project '%s') is '%s' at fingerprint %s for task '%s' of project '%s', not '%s'",
            what, fingerprint, taskId, projectId, execution.id, execution.fingerprint, execution.taskId, execution.projectId, id));
    }

    requireRecord(summary.active, ledger.activeExecutionId, "active", true);
    requireRecord(summary.lastSuccess, ledger.lastSuccessExecutionId, "last succeeded", false);
    requireRecord(summary.lastStopped, ledger.lastStoppedExecutionId, "last stopped", false);

    if (ledger.activeExecutionId.length > 0)
    {
        facts.activeId = ledger.activeExecutionId;
        if (!summary.active.isNull)
        {
            const status = summary.active.get.status;
            requireEvaluable(ExecutionStore.isActive(status), format(
                "The active execution '%s' of fingerprint %s (task '%s') is %s: settle the ledger before evaluating",
                facts.activeId, fingerprint, taskId, status));
            facts.running = status == ExecutionStatus.running;
        }
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
private TaskGraph closureOf(in BuildChain chain, in ChainRequest entry) @trusted
{
    const request = entry.request;
    requireEvaluable(request.id.length > 0, format("A request on chain '%s' has no id", chain.id));
    requireEvaluable(request.chainId == chain.id && request.projectId == chain.projectId, format(
        "Request '%s' (project '%s', chain '%s') does not belong to chain '%s' of project '%s'",
        request.id, request.projectId, request.chainId, chain.id, chain.projectId));
    requireEvaluable(request.targets.length > 0, format("Request '%s' on chain '%s' has no targets", request.id, chain.id));
    const actual = definitionId(entry.definition);
    requireEvaluable(actual == request.definitionId, format(
        "Request '%s' runs with definition '%s', but the definition given for it is '%s'", request.id, request.definitionId, actual));
    try return closureGraph(entry.definition, request.targets);
    catch (ChainEvaluationException e)
    {
        throw new ChainEvaluationException(format("Request '%s' on chain '%s': %s", request.id, chain.id, e.msg));
    }
}

private void requireEvaluable(bool condition, lazy string message) @trusted
{
    if (!condition) throw new ChainEvaluationException(message);
}

version (unittest)
{
    import confector.core.fingerprint_ledger : withClaim, withFold;
    import confector.core.input_resolution : InputResolutionException;
    import confector.core.rerun_generations : readGraphResolution;

    import vibe.data.json : Json;

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
        foreach (task; ["compile", "lint"])
        {
            chain.pins ~= PinnedInput(task, "src", "game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111")));
        }
        chain.createdAt = "2026-10-20T10:00:00Z";
        return chain;
    }

    /// What the shell would read: the chain's requests, rerun generations (bases not listed are
    /// at 0), ledgers by fingerprint and executions by id. The ledgers move with the pure ledger
    /// transitions the LedgerStore uses.
    private struct World
    {
        BuildChain chain;
        ChainRequest[] requests;
        RerunGenerations bumped;
        FingerprintLedger[string] ledgers;
        ulong[string] versions;
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
        return readGraphResolution(w.chain.projectId, closureGraph(definition, targets), pinMap(w.chain.pins), readerOf(w));
    }

    private string fingerprintOf(ref World w, string taskId)
    {
        return closureAt(w, [taskId]).fingerprints[taskId];
    }

    /// Makes request `id` for `targets`, recording the demands an intake would: each covered
    /// task's fingerprint and its ledger's stop sequence now.
    private BuildRequest makeRequest(ref World w, string id, string[] targets, ProjectDefinition definition = sampleDefinition(),
        string requestedAt = "2026-10-20T10:00:00Z")
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
        request.intent = BuildIntent.build;
        request.trigger.type = TriggerType.manual;
        request.definitionId = definitionId(definition);
        request.definitionSource = DefinitionSource(DefinitionLocation.confector);
        request.demands = requestDemands(closure, stopSeqs);
        request.requestedBy = "jason";
        request.requestedAt = requestedAt;
        return request;
    }

    /// Makes request `id` and adds it to the chain.
    private void request(ref World w, string id, string[] targets, ProjectDefinition definition = sampleDefinition(),
        string requestedAt = "2026-10-20T10:00:00Z")
    {
        w.requests ~= ChainRequest(makeRequest(w, id, targets, definition, requestedAt), definition);
    }

    /// Claims the next execution at `fingerprint` and records it, queued.
    private string start(ref World w, string fingerprint, string taskId)
    {
        auto ledger = w.ledgers.get(fingerprint, FingerprintLedger(fingerprint));
        auto claimed = withClaim(ledger);
        w.ledgers[fingerprint] = claimed;
        w.versions[fingerprint] = w.versions.get(fingerprint, 0) + 1;
        TaskExecution execution;
        execution.id = claimed.activeExecutionId;
        execution.projectId = w.chain.projectId;
        execution.taskId = taskId;
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.createdAt = "2026-10-20T10:00:00Z";
        w.executions[execution.id] = execution;
        return execution.id;
    }

    /// Ends the active execution at `fingerprint` with `status`, and folds it into its ledger.
    private string end(ref World w, string fingerprint, ExecutionStatus status, string finishedAt = "2026-10-20T10:05:00Z")
    {
        auto ledger = w.ledgers[fingerprint];
        auto execution = w.executions[ledger.activeExecutionId];
        execution.status = status;
        execution.finishedAt = finishedAt;
        w.executions[execution.id] = execution;
        w.ledgers[fingerprint] = withFold(ledger, execution);
        w.versions[fingerprint] += 1;
        return execution.id;
    }

    /// Runs task `taskId` at its current fingerprint to the end, with `status`.
    private string run(ref World w, string taskId, ExecutionStatus status, string finishedAt = "2026-10-20T10:05:00Z")
    {
        const fingerprint = fingerprintOf(w, taskId);
        start(w, fingerprint, taskId);
        return end(w, fingerprint, status, finishedAt);
    }

    private LedgerSummary summaryOf(ref World w, string fingerprint)
    {
        LedgerSummary summary;
        auto ledger = fingerprint in w.ledgers;
        if (ledger is null) return summary;
        summary.ledger = Versioned!FingerprintLedger(*ledger, w.versions[fingerprint]);
        Nullable!TaskExecution named(string id)
        {
            auto execution = id in w.executions;
            return execution is null ? Nullable!TaskExecution.init : nullable(*execution);
        }
        summary.active = named(ledger.activeExecutionId);
        summary.lastSuccess = named(ledger.lastSuccessExecutionId);
        summary.lastStopped = named(ledger.lastStoppedExecutionId);
        return summary;
    }

    private LedgerSummary[string] summariesOf(ref World w, in RerunGenerations generations)
    {
        LedgerSummary[string] summaries;
        foreach (fingerprint; chainFingerprints(w.chain, w.requests, generations)) summaries[fingerprint] = summaryOf(w, fingerprint);
        return summaries;
    }

    /// Evaluates the chain as the shell would: generations, then a summary of every fingerprint.
    private ChainEvaluation evaluate(ref World w)
    {
        const generations = readChainGenerations(w.chain, w.requests, readerOf(w));
        return evaluateChain(w.chain, w.requests, generations, summariesOf(w, generations));
    }

    private ChainTaskState stateOf(in ChainEvaluation evaluation, string taskId)
    {
        foreach (ref state; evaluation.tasks)
        {
            if (state.taskId == taskId) return cast(ChainTaskState) state;
        }
        assert(false, format("task '%s' was not evaluated", taskId));
    }

    private ChainTaskStatus statusOf(in ChainEvaluation evaluation, string taskId)
    {
        return stateOf(evaluation, taskId).status;
    }

    private string[] neededTasks(in ChainEvaluation evaluation)
    {
        string[] tasks;
        foreach (ref needed; evaluation.needed) tasks ~= needed.taskId;
        return tasks;
    }

    private string[] evaluatedTasks(in ChainEvaluation evaluation)
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
    // A first request: only its target and upstream tasks are evaluated, in topological order;
    // the task with no upstream needs an execution, at a ledger never claimed, for that request
    auto w = world();
    request(w, "r1", ["report"]);
    auto evaluation = evaluate(w);
    assert(evaluation.chainId == "c1" && evaluation.requestIds == ["r1"]);
    assert(evaluatedTasks(evaluation) == ["compile", "test", "report"], "package and lint are not covered");
    assert(statusOf(evaluation, "compile") == ChainTaskStatus.needed);
    assert(statusOf(evaluation, "test") == ChainTaskStatus.waitingUpstream && statusOf(evaluation, "report") == ChainTaskStatus.waitingUpstream);
    assert(evaluation.needed.length == 1 && evaluation.awaited.length == 0);
    const needed = evaluation.needed[0];
    assert(needed.taskId == "compile" && needed.fingerprint == fingerprintOf(w, "compile"));
    assert(needed.seenExecutionSeq == 0 && needed.requestId == "r1");
    assert(needed.inputs == [ResolvedInput("src", InputKind.repository, Json("aaa111"))]);

    auto report = stateOf(evaluation, "report");
    assert(report.target && !stateOf(evaluation, "compile").target);
    assert(report.demandSeq == 1 && report.stopSeqAtDemand == 0 && report.fingerprint == fingerprintOf(w, "report"));
}

unittest
{
    // An active execution is attached to, never duplicated: queued, then running, and awaited;
    // claimed but not yet recorded (a crashed dispatcher, repaired by the dispatcher) is queued too
    auto w = world();
    request(w, "r1", ["test"]);
    const compileAt = fingerprintOf(w, "compile");
    const id = start(w, compileAt, "compile");

    auto queued = evaluate(w);
    assert(statusOf(queued, "compile") == ChainTaskStatus.queued && stateOf(queued, "compile").executionId == id);
    assert(queued.awaited.length == 1 && queued.needed.length == 0);
    const awaited = queued.awaited[0];
    assert(awaited.taskId == "compile" && awaited.fingerprint == compileAt && awaited.executionId == id);
    assert(awaited.ledger.activeExecutionId == id && awaited.ledger.version_ == w.versions[compileAt],
        "The chain subscribes at the version the evaluation read");
    assert(awaited.requestId == "r1" && awaited.inputs == [ResolvedInput("src", InputKind.repository, Json("aaa111"))],
        "An unrecorded execution can be recorded from the governing request");
    assert(statusOf(queued, "test") == ChainTaskStatus.waitingUpstream);

    w.executions[id].status = ExecutionStatus.running;
    assert(statusOf(evaluate(w), "compile") == ChainTaskStatus.running);

    w.executions.remove(id);
    auto unrecorded = evaluate(w);
    assert(statusOf(unrecorded, "compile") == ChainTaskStatus.queued && unrecorded.awaited.length == 1 && unrecorded.needed.length == 0);
}

unittest
{
    // A success is reused, whichever chain produced it; the next task then needs an execution, at
    // the ledger's executionSeq as seen
    auto w = world();
    const success = run(w, "compile", ExecutionStatus.succeeded); // another chain built it
    request(w, "r1", ["report"]);
    auto evaluation = evaluate(w);
    assert(statusOf(evaluation, "compile") == ChainTaskStatus.succeeded && stateOf(evaluation, "compile").executionId == success);
    assert(neededTasks(evaluation) == ["test"] && evaluation.needed[0].seenExecutionSeq == 0);
    assert(evaluation.needed[0].inputs == [ResolvedInput("bin", InputKind.taskOutput, Json(fingerprintOf(w, "compile")))]);

    run(w, "test", ExecutionStatus.succeeded);
    run(w, "report", ExecutionStatus.succeeded);
    auto done = evaluate(w);
    foreach (taskId; ["compile", "test", "report"]) assert(statusOf(done, taskId) == ChainTaskStatus.succeeded, taskId);
    assert(done.needed.length == 0 && done.awaited.length == 0);
}

unittest
{
    // A success whose artifacts expired is a miss: a target runs again (claiming after the
    // ledger's executionSeq); an upstream task whose dependents are satisfied is not needed
    auto w = world();
    const expired = run(w, "compile", ExecutionStatus.succeeded);
    w.executions[expired].artifactsExpiredAt = "2026-10-21T00:00:00Z";
    request(w, "r1", ["compile"]);
    auto evaluation = evaluate(w);
    assert(statusOf(evaluation, "compile") == ChainTaskStatus.needed);
    assert(evaluation.needed[0].seenExecutionSeq == 1, "The claim must expect the expired execution");

    auto other = world();
    const old = run(other, "compile", ExecutionStatus.succeeded);
    other.executions[old].artifactsExpiredAt = "2026-10-21T00:00:00Z";
    run(other, "test", ExecutionStatus.succeeded);
    request(other, "r1", ["test"]);
    auto satisfied = evaluate(other);
    assert(statusOf(satisfied, "test") == ChainTaskStatus.succeeded);
    assert(statusOf(satisfied, "compile") == ChainTaskStatus.notNeeded && stateOf(satisfied, "compile").executionId == old);
    assert(satisfied.needed.length == 0, "A downstream cache hit never forces an upstream task to run");
}

unittest
{
    // A requested upstream task that never ran is not needed when its dependent target already
    // succeeded, whichever chain built it
    auto w = world();
    const compileAt = fingerprintOf(w, "compile");
    run(w, "test", ExecutionStatus.succeeded); // built in a chain whose compile result has since gone
    request(w, "r1", ["test"]);
    auto evaluation = evaluate(w);
    assert(statusOf(evaluation, "compile") == ChainTaskStatus.notNeeded && stateOf(evaluation, "compile").executionId.length == 0);
    assert(evaluation.needed.length == 0 && compileAt !in w.ledgers);
}

unittest
{
    // Settling by sequence numbers: a failure after the request settles it (failed; downstream
    // blocked; nothing is retried automatically). A retry made after the failure recorded the new
    // stopSeq and runs again, at the same fingerprint, even though its clock says it was made
    // before the failure ended
    auto w = world();
    request(w, "r1", ["report"], sampleDefinition(), "2026-10-20T10:00:00Z");
    const compileAt = fingerprintOf(w, "compile");
    const failure = run(w, "compile", ExecutionStatus.failed, "2026-10-20T12:00:00Z");

    auto settled = evaluate(w);
    assert(statusOf(settled, "compile") == ChainTaskStatus.failed && stateOf(settled, "compile").executionId == failure);
    assert(statusOf(settled, "test") == ChainTaskStatus.blocked && stateOf(settled, "test").blockedBy == ["compile"]);
    assert(statusOf(settled, "report") == ChainTaskStatus.blocked && stateOf(settled, "report").blockedBy == ["compile"]);
    assert(settled.needed.length == 0 && settled.awaited.length == 0, "A failure is never retried automatically");

    // The retry's clock is two hours behind the worker's
    request(w, "r2", ["compile"], sampleDefinition(), "2026-10-20T10:30:00Z");
    auto retried = evaluate(w);
    assert(statusOf(retried, "compile") == ChainTaskStatus.needed, "A retry after a failure is never ignored");
    assert(retried.needed == [NeededExecution("compile", compileAt, 1, "r2", [ResolvedInput("src", InputKind.repository, Json("aaa111"))])]);
    auto compile = stateOf(retried, "compile");
    assert(compile.demandSeq == 2 && compile.stopSeqAtDemand == 1 && compile.target);
    assert(statusOf(retried, "test") == ChainTaskStatus.waitingUpstream, "The retry unblocks the tasks downstream of it");

    // A request made before the failure but added after the retry (concurrent intakes) saw no
    // stop: it does not hide the retry's demand
    w.requests ~= ChainRequest(w.requests[0].request, w.requests[0].definition);
    w.requests[$ - 1].request.id = "r3";
    auto late = evaluate(w);
    assert(statusOf(late, "compile") == ChainTaskStatus.needed && late.needed[0].requestId == "r2");
    assert(stateOf(late, "compile").demandSeq == 2 && stateOf(late, "report").demandSeq == 3);

    // The retry's execution fails too: settled again
    start(w, compileAt, "compile");
    end(w, compileAt, ExecutionStatus.failed);
    assert(statusOf(evaluate(w), "compile") == ChainTaskStatus.failed);
}

unittest
{
    // A request that attached to an execution in flight is settled by its failure, even when the
    // request's clock says it was made after the failure ended: only sequence numbers count
    auto w = world();
    const compileAt = fingerprintOf(w, "compile");
    start(w, compileAt, "compile"); // another chain's execution
    request(w, "r1", ["test"], sampleDefinition(), "2026-10-20T15:00:00Z");
    assert(statusOf(evaluate(w), "compile") == ChainTaskStatus.queued);
    end(w, compileAt, ExecutionStatus.failed, "2026-10-20T11:00:00Z");

    auto evaluation = evaluate(w);
    assert(statusOf(evaluation, "compile") == ChainTaskStatus.failed && statusOf(evaluation, "test") == ChainTaskStatus.blocked);
    assert(evaluation.needed.length == 0);
}

unittest
{
    // A cancellation settles like a failure, and blocks downstream; blocking reaches through
    // blocked tasks to the stops that cause it
    auto w = world();
    request(w, "r1", ["report"]);
    run(w, "compile", ExecutionStatus.succeeded);
    const cancelled = run(w, "test", ExecutionStatus.cancelled);
    auto evaluation = evaluate(w);
    assert(statusOf(evaluation, "test") == ChainTaskStatus.cancelled && stateOf(evaluation, "test").executionId == cancelled);
    assert(statusOf(evaluation, "report") == ChainTaskStatus.blocked && stateOf(evaluation, "report").blockedBy == ["test"]);

    auto upstream = world();
    request(upstream, "r1", ["report"]);
    run(upstream, "compile", ExecutionStatus.failed);
    auto through = evaluate(upstream);
    assert(stateOf(through, "report").blockedBy == ["compile"], "Blocking names the stop, not the blocked task between");

    // A later success at the fingerprint (another chain retried it) is reused
    const success = run(w, "test", ExecutionStatus.succeeded);
    auto reused = evaluate(w);
    assert(statusOf(reused, "test") == ChainTaskStatus.succeeded && stateOf(reused, "test").executionId == success);
    assert(neededTasks(reused) == ["report"]);
}

unittest
{
    // Reruns are strict: bumping compile's generation gives compile and everything downstream new
    // fingerprints; the earlier successes are not used and downstream waits for the new generation.
    // The chain's earlier request carries over to the new fingerprints, having seen no stop there,
    // so a failed rerun blocks rather than falling back to the earlier success
    auto w = world();
    request(w, "r1", ["report"]);
    request(w, "r2", ["lint"]);
    foreach (taskId; ["compile", "test", "report", "lint"]) run(w, taskId, ExecutionStatus.succeeded);
    auto before = evaluate(w);
    assert(before.needed.length == 0);

    const base = closureAt(w, ["compile"]).bases["compile"];
    w.bumped[base] = 1;
    auto after = evaluate(w);
    foreach (taskId; ["compile", "test", "report"])
    {
        assert(stateOf(after, taskId).fingerprint != stateOf(before, taskId).fingerprint, taskId);
    }
    assert(stateOf(after, "lint") == stateOf(before, "lint"), "Tasks not downstream are unaffected");
    assert(statusOf(after, "compile") == ChainTaskStatus.needed && after.needed.length == 1);
    assert(after.needed[0].requestId == "r1" && after.needed[0].seenExecutionSeq == 0);
    assert(stateOf(after, "compile").stopSeqAtDemand == 0);
    assert(statusOf(after, "test") == ChainTaskStatus.waitingUpstream && statusOf(after, "report") == ChainTaskStatus.waitingUpstream);

    // The new generation fails (say in the chain the rerun was requested in): this chain is
    // settled too, and its downstream tasks block
    run(w, "compile", ExecutionStatus.failed);
    auto failed = evaluate(w);
    assert(statusOf(failed, "compile") == ChainTaskStatus.failed);
    assert(statusOf(failed, "test") == ChainTaskStatus.blocked && statusOf(failed, "report") == ChainTaskStatus.blocked);
    assert(failed.needed.length == 0);

    // A retry at the new generation runs it again
    request(w, "r3", ["compile"]);
    auto retried = evaluate(w);
    assert(statusOf(retried, "compile") == ChainTaskStatus.needed && retried.needed[0].requestId == "r3");
    assert(retried.needed[0].seenExecutionSeq == 1);
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
    assert(stateOf(evaluate(w), "compile").stopSeqAtDemand == 1);

    w.bumped[closureAt(w, ["compile"]).bases["compile"]] = 1;
    auto rerun = evaluate(w);
    assert(statusOf(rerun, "compile") == ChainTaskStatus.needed && stateOf(rerun, "compile").stopSeqAtDemand == 0);
    run(w, "compile", ExecutionStatus.failed);
    auto failed = evaluate(w);
    assert(statusOf(failed, "compile") == ChainTaskStatus.failed && failed.needed.length == 0,
        "A failed rerun is never retried automatically");
}

unittest
{
    // Requests whose definitions differ only in build configuration agree on every fingerprint and
    // are evaluated together; the latest request's demand governs on ties, so its definition
    // dispatches. A later definition may add a task the chain never built
    auto w = world();
    request(w, "r1", ["test"]);
    auto changed = sampleDefinition();
    changed.tasks[0].steps = [BuildStep("Build", "bash", Json(["script": Json("make release")]))];
    TaskNode external; external.id = "external"; external.inputs["bin"] = taskOutputInput("compile");
    changed.tasks ~= external;
    request(w, "r2", ["external"], changed);

    auto evaluation = evaluate(w);
    assert(evaluatedTasks(evaluation) == ["compile", "external", "test"]);
    assert(evaluation.needed.length == 1 && evaluation.needed[0].requestId == "r2");
    assert(stateOf(evaluation, "compile").demandSeq == 2 && stateOf(evaluation, "test").demandSeq == 1);
    assert(stateOf(evaluation, "compile").fingerprint == fingerprintOf(w, "compile"));

    // A definition that gives compile other inputs gives it another fingerprint: evaluating each
    // request over its own graph is bead confector-z7z.53.3, so it is refused loudly for now
    auto moved = sampleDefinition();
    moved.tasks[0].inputs["flavor"] = valueInput("external");
    request(w, "r3", ["compile"], moved);
    assert(throwsWith!ChainEvaluationException("confector-z7z.53.3", { evaluate(w); }));
}

unittest
{
    // Inconsistent inputs fail loudly: a request of another chain, given twice, with another
    // definition than it names, targeting a task its definition lacks, or with demands for other
    // tasks than it covers; a missing generation, pin or ledger summary
    auto w = world();
    request(w, "r1", ["test"]);
    const generations = readChainGenerations(w.chain, w.requests, readerOf(w));
    auto summaries = summariesOf(w, generations);
    evaluateChain(w.chain, w.requests, generations, summaries);

    ChainEvaluation evaluateWith(ChainRequest[] requests)
    {
        return evaluateChain(w.chain, requests, generations, summaries);
    }
    ChainRequest altered(void delegate(ref ChainRequest) change)
    {
        auto entry = ChainRequest(w.requests[0].request, w.requests[0].definition);
        entry.definition.tasks = entry.definition.tasks.dup;
        change(entry);
        return entry;
    }

    assert(throwsWith!ChainEvaluationException("does not belong", { evaluateWith([altered((ref e) { e.request.chainId = "c2"; })]); }));
    assert(throwsWith!ChainEvaluationException("does not belong", { evaluateWith([altered((ref e) { e.request.projectId = "q"; })]); }));
    assert(throwsWith!ChainEvaluationException("given twice", { evaluateWith([w.requests[0], w.requests[0]]); }));
    assert(throwsWith!ChainEvaluationException("has no id", { evaluateWith([altered((ref e) { e.request.id = null; })]); }));
    assert(throwsWith!ChainEvaluationException("the definition given for it", { evaluateWith([altered((ref e) {
        e.definition.tasks[0].steps = [BuildStep("Build", "bash", Json(["script": Json("other")]))]; })]); }));
    assert(throwsWith!ChainEvaluationException("'package'", { evaluateWith([altered((ref e) {
        e.definition = ProjectDefinition([e.definition.tasks[0], e.definition.tasks[1]]);
        e.request.definitionId = definitionId(e.definition);
        e.request.targets = ["package"]; })]); }));
    assert(throwsWith!ChainEvaluationException("records demands", { evaluateWith([altered((ref e) { e.request.demands = e.request.demands[0 .. 1]; })]); }));
    assert(throwsWith!ChainEvaluationException("records demands", { evaluateWith([altered((ref e) { e.request.targets = ["compile"]; })]); }));
    assert(throwsWith!ChainEvaluationException("no targets", { evaluateWith([altered((ref e) { e.request.targets = null; })]); }));

    RerunGenerations none;
    assert(throwsA!InputResolutionException({ evaluateChain(w.chain, w.requests, none, summaries); }), "A missing generation is never 0");
    auto unpinned = w.chain;
    unpinned.pins = null;
    assert(throwsA!InputResolutionException({ evaluateChain(unpinned, w.requests, generations, summaries); }));
    LedgerSummary[string] missing;
    assert(throwsWith!ChainEvaluationException("not summarized", { evaluateChain(w.chain, w.requests, generations, missing); }));
}

unittest
{
    // Ledger summaries that contradict themselves or the task fail loudly; in particular an
    // active execution that already ended means the shell did not settle the ledger
    auto w = world();
    request(w, "r1", ["compile"]);
    const compileAt = fingerprintOf(w, "compile");
    run(w, "compile", ExecutionStatus.failed);
    const succeeded = run(w, "compile", ExecutionStatus.succeeded);
    start(w, compileAt, "compile");
    const generations = readChainGenerations(w.chain, w.requests, readerOf(w));
    auto good = summaryOf(w, compileAt);
    assert(statusOf(evaluateChain(w.chain, w.requests, generations, [compileAt: good]), "compile") == ChainTaskStatus.succeeded);

    bool refused(string text, void delegate(ref LedgerSummary) change)
    {
        LedgerSummary summary = good;
        change(summary);
        return throwsWith!ChainEvaluationException(text, { evaluateChain(w.chain, w.requests, generations, [compileAt: summary]); });
    }

    assert(refused("settle the ledger", (ref s) { auto e = s.active.get; e.status = ExecutionStatus.failed; s.active = e; }));
    assert(refused("was not read", (ref s) { s.lastSuccess.nullify(); }));
    assert(refused("was not read", (ref s) { s.lastStopped.nullify(); }));
    assert(refused("is failed", (ref s) { auto e = s.lastSuccess.get; e.status = ExecutionStatus.failed; s.lastSuccess = e; }));
    assert(refused("is succeeded", (ref s) { auto e = s.lastStopped.get; e.status = ExecutionStatus.succeeded; s.lastStopped = e; }));
    assert(refused("not '" ~ succeeded ~ "'", (ref s) { s.lastSuccess = s.lastStopped; }));
    assert(refused("for task 'lint'", (ref s) { auto e = s.active.get; e.taskId = "lint"; s.active = e; }));
    assert(refused("holds the ledger", (ref s) { auto l = s.ledger.get; l.fingerprint = "other"; s.ledger = l; }));
    assert(refused("counts 0 stops", (ref s) { auto l = s.ledger.get; l.stopSeq = 0; s.ledger = l; }));
    assert(refused("but no ledger", (ref s) { s.ledger.nullify(); }));
    assert(refused("its ledger names none", (ref s) { auto l = s.ledger.get; l.activeExecutionId = null; s.ledger = l; }));
}

unittest
{
    // The shell's helpers: demands as an intake records them, the fingerprints to summarize, and
    // generations read a level at a time across every request's graph
    auto w = world();
    const closure = closureAt(w, ["test"]);
    const compileAt = closure.fingerprints["compile"];
    const testAt = closure.fingerprints["test"];
    assert(requestDemands(closure, [compileAt: 2UL, testAt: 0UL]) == [TaskDemand("compile", compileAt, closure.bases["compile"], 0, 2),
        TaskDemand("test", testAt, closure.bases["test"], 0, 0)]);
    assert(throwsWith!ChainEvaluationException("was not read", { requestDemands(closure, [compileAt: 2UL]); }));
    string[string] unread;
    RerunGenerations none;
    auto partial = graphResolution("p", closureGraph(sampleDefinition(), ["test"]), pinMap(w.chain.pins), none, unread);
    assert(throwsWith!ChainEvaluationException("rerun generation", { requestDemands(partial, null); }));
    assert(throwsWith!ChainEvaluationException("'nope'", { closureGraph(sampleDefinition(), ["nope"]); }));

    request(w, "r1", ["report"]);
    request(w, "r2", ["lint", "package"]);
    size_t reads;
    auto counting = readerOf(w);
    auto generations = readChainGenerations(w.chain, w.requests, (in string[] bases) { ++reads; return counting(bases); });
    assert(reads == 3, "compile and lint, then test and package, then report");
    assert(generations.length == 5);
    auto fingerprints = chainFingerprints(w.chain, w.requests, generations);
    assert(fingerprints.length == 5 && fingerprints.canFind(compileAt) && fingerprints.canFind(testAt));
    RerunGenerationReader forgetful = (in string[] bases) { RerunGenerations nothing; return nothing; };
    assert(throwsWith!Exception("returned none", { readChainGenerations(w.chain, w.requests, forgetful); }));
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
    assert(statusOf(evaluate(w), "compile") == ChainTaskStatus.needed);

    auto wrong = w;
    wrong.requests = w.requests.dup;
    wrong.requests[1].request.demands = wrong.requests[1].request.demands.dup;
    wrong.requests[1].request.demands[0].fingerprint = "some-other-fingerprint";
    assert(throwsWith!ChainEvaluationException("neither it nor any task upstream of it was rerun", { evaluate(wrong); }));

    auto inconsistent = w;
    inconsistent.requests = w.requests.dup;
    inconsistent.requests[1].request.demands = inconsistent.requests[1].request.demands.dup;
    inconsistent.requests[1].request.demands[0].generation = 3;
    assert(throwsWith!ChainEvaluationException("but that fingerprint is base", { evaluate(inconsistent); }));

    // A rerun of compile explains both compile's and test's moved fingerprints
    const base = closureAt(w, ["compile"]).bases["compile"];
    w.bumped[base] = 2;
    assert(statusOf(evaluate(w), "test") == ChainTaskStatus.waitingUpstream);

    // A request recorded at a later generation than the current one is refused
    auto ahead = world();
    ahead.bumped[base] = 2;
    request(ahead, "r1", ["test"]);
    ahead.bumped[base] = 1;
    assert(throwsWith!ChainEvaluationException("generations never go down", { evaluate(ahead); }));
}
