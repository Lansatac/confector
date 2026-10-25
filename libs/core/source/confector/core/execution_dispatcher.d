module confector.core.execution_dispatcher;

/**
 * The execution dispatcher (AGENTS.md, "Coordinating builds" and "Workers and capacity"): the
 * shell that turns a fingerprint the request evaluator says needs an execution into a queued
 * execution record, which a worker later claims (confector.core.work_orders). It holds no lock
 * and keeps no state between calls: it reads only by id and writes only by single-document
 * compare-and-set (through LedgerStore and ExecutionStore), so any number of dispatchers may run
 * at once, and every step is idempotent.
 *
 * Dispatching a needed fingerprint F for a request (`dispatch`), in the order the ledger's
 * protocol fixes (confector.core.fingerprint_ledger):
 *
 * 1. Build the execution record from the request's definition, the task's resolved inputs and
 *    the registered repository addresses. A task that cannot be recorded (its repository is not
 *    registered or has no address) fails loudly here, before anything is written, so it never
 *    holds the fingerprint.
 * 2. `LedgerStore.claim(F, seen)`, with `seen` the ledger's `executionSeq` as the evaluation read
 *    it (NeededExecution.seenExecutionSeq), so a decision made before another execution started
 *    and ended never builds F twice. Losing (another execution is active, or one was claimed
 *    since the evaluation read the ledger) writes nothing more: the caller evaluates again and
 *    waits on, or reuses, what it finds.
 * 3. `ExecutionStore.createIfAbsent` the queued execution under the claimed id. A repairer may
 *    have recorded it first, from its own request; the stored record wins.
 *
 * Repair, at the execution level, never in the evaluator: if a dispatcher crashed after 2, the
 * ledger names an active execution with no record, and the evaluator reports the task as waiting
 * on it. `repair` records it under that id from the request that awaits it
 * (AwaitedExecution.inputs and the request's definition; the ledger cannot, it has no
 * definition). Concurrent repairers and a slow original dispatcher converge on the first record
 * written.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.request_evaluator : AwaitedExecution, DefinedRequest, NeededExecution;
import confector.core.definition_hash : recordDefinition;
import confector.core.fingerprint_ledger : ClaimOutcome;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : utcNow;
import confector.api.model;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * An execution cannot be recorded for a task: the request's definition lacks the task, or a
 * repository input names a repository that is not registered or has no address to check out
 * from. Nothing was written.
 */
class UndispatchableExecutionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The result of `ExecutionDispatcher.dispatch`.
struct Dispatched
{
    /// What the claim found: won (this dispatcher claimed and recorded the execution), active
    /// (another execution is active) or superseded (an execution was claimed since the evaluation
    /// read the ledger). On every outcome the caller evaluates again.
    ClaimOutcome claim;
    /// won and active: the fingerprint's active execution; superseded: empty.
    string executionId;
}

/**
 * The queued execution `executionId` of task `taskId` at `fingerprint`, recorded from `request`:
 * the task as `request`'s definition declares it (its build configuration and hash),
 * `inputs`, the address of each repository input from `repositories` (keyed by repository id),
 * and `createdAt` = `now`. Pure.
 *
 * Throws: UndispatchableExecutionException if the definition lacks the task, or a repository
 * input names a repository missing from `repositories` or without an address.
 */
TaskExecution executionFor(string executionId, string taskId, string fingerprint, in ResolvedInput[] inputs,
    in DefinedRequest request, in RepositoryRecord[string] repositories, string now) @trusted
{
    const(TaskNode)* task;
    foreach (ref node; request.definition.tasks)
    {
        if (node.id == taskId) task = &node;
    }
    if (task is null)
    {
        throw new UndispatchableExecutionException(format("Task '%s' is not in the definition '%s' of request '%s'", taskId,
            request.request.definitionId, request.request.id));
    }

    TaskExecution execution;
    execution.id = executionId;
    execution.projectId = request.request.projectId;
    execution.taskId = taskId;
    execution.fingerprint = fingerprint;
    execution.status = ExecutionStatus.queued;
    recordDefinition(execution, *task);
    execution.inputs = (cast(ResolvedInput[]) inputs).dup;
    foreach (name; task.inputs.keys.sort().release)
    {
        const decl = task.inputs[name];
        if (decl.kind != InputKind.repository) continue;
        auto repository = decl.spec.repository in repositories;
        if (repository is null)
        {
            throw new UndispatchableExecutionException(format(
                "Input '%s' of task '%s' (request '%s') names repository '%s', which is not registered", name, taskId,
                request.request.id, decl.spec.repository));
        }
        if (repository.address.length == 0)
        {
            throw new UndispatchableExecutionException(format(
                "Input '%s' of task '%s' (request '%s'): repository '%s' has no address to check out from", name, taskId,
                request.request.id, decl.spec.repository));
        }
        execution.repositoryAddresses[name] = repository.address;
    }
    execution.createdAt = now;
    return execution;
}

/**
 * Claims fingerprints and records executions, and repairs executions that were claimed but not
 * recorded. See the module documentation.
 */
final class ExecutionDispatcher
{
    private StateStores m_stores;
    private string delegate() m_now;

    /**
     * Dispatches through `stores`. `now` gives the current time for `createdAt` (default
     * `utcNow`); tests pass a fixed clock.
     *
     * Throws: Exception if `stores` is null.
     */
    this(StateStores stores, string delegate() now = null)
    {
        if (stores is null) throw new Exception("The execution dispatcher requires the state stores");
        m_stores = stores;
        m_now = now !is null ? now : () => utcNow();
    }

    /**
     * Dispatches the execution `needed` asks for, for `request` (with its definition): builds its
     * record, claims the fingerprint at the `executionSeq` the evaluation saw, and if the claim
     * wins records the execution. See Dispatched; whatever the outcome, the caller evaluates
     * again before committing.
     *
     * Throws: UndispatchableExecutionException (nothing written) if the execution cannot be
     * recorded; whatever the stores throw.
     */
    Dispatched dispatch(in NeededExecution needed, in DefinedRequest request)
    {
        // Built before claiming, so a task that cannot be recorded never holds the fingerprint
        auto execution = executionFor(null, needed.taskId, needed.fingerprint, needed.inputs, request,
            repositoriesOf(needed.taskId, request), m_now());
        auto claimed = m_stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq);
        final switch (claimed.outcome)
        {
            case ClaimOutcome.won:
                execution.id = claimed.executionId;
                m_stores.executions.createIfAbsent(execution);
                return Dispatched(ClaimOutcome.won, claimed.executionId);
            case ClaimOutcome.active:
                return Dispatched(ClaimOutcome.active, claimed.executionId);
            case ClaimOutcome.superseded:
                return Dispatched(ClaimOutcome.superseded, null);
        }
    }

    /**
     * Makes sure the active execution a request awaits is recorded: if it has no record (its
     * dispatcher crashed between claiming and recording it), records it under its id from
     * `request` (with its definition). Returns whether the execution has ended, so the request
     * must be evaluated again.
     *
     * Throws: UndispatchableExecutionException (nothing written) if it has no record and cannot be
     * recorded from `request`; Exception if the stored record is of another fingerprint; whatever
     * the stores throw.
     */
    bool repair(in AwaitedExecution awaited, in DefinedRequest request)
    {
        auto found = m_stores.executions.get(awaited.executionId);
        if (found.isNull)
        {
            auto execution = executionFor(awaited.executionId, awaited.taskId, awaited.fingerprint, awaited.inputs, request,
                repositoriesOf(awaited.taskId, request), m_now());
            return !ExecutionStore.isActive(m_stores.executions.createIfAbsent(execution).status);
        }
        if (found.get.fingerprint != awaited.fingerprint)
        {
            throw new Exception(format("Execution '%s', awaited at fingerprint %s, is recorded at fingerprint %s",
                awaited.executionId, awaited.fingerprint, found.get.fingerprint));
        }
        return !ExecutionStore.isActive(found.get.status);
    }

    /// The registered repositories the repository inputs of task `taskId` in `request`'s
    /// definition name, read by id; missing ones are left out (`executionFor` reports them).
    private RepositoryRecord[string] repositoriesOf(string taskId, in DefinedRequest request)
    {
        RepositoryRecord[string] repositories;
        foreach (ref task; request.definition.tasks)
        {
            if (task.id != taskId) continue;
            foreach (decl; task.inputs.byValue)
            {
                if (decl.kind != InputKind.repository || decl.spec.repository in repositories) continue;
                auto found = m_stores.repositories.get(decl.spec.repository);
                if (!found.isNull) repositories[decl.spec.repository] = found.get.value;
            }
        }
        return repositories;
    }
}

version (unittest)
{
    import confector.core.request_evaluator : RequestEvaluation;
    import confector.core.request_fixtures;
    import confector.core.definition_hash : computeDefinitionHash;
    import confector.core.fingerprint_ledger : executionIdFor;
    import confector.core.work_orders : startExecution;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import core.time : seconds;
    import std.algorithm.searching : canFind;

    /// A request's evaluation with the request it was made for.
    private struct Requested
    {
        RequestEvaluation evaluation;
        DefinedRequest request;
    }

    /// Creates chain `chainId` (unless it exists) with request "r_<chainId>" for `targets`, and
    /// evaluates it as stored now.
    private Requested requested(StateStores stores, string[] targets, string chainId = "c1")
    {
        if (stores.chains.get(chainId).isNull) createChain(stores, chainId);
        const requestId = "r_" ~ chainId;
        intake(stores, chainId, requestId, targets, "2026-10-20T10:00:00Z");
        return Requested(evaluateFrom(stores, requestId), definedRequest(stores, requestId));
    }

    /// The one awaited execution of chain `chainId`'s request "r_<chainId>" as stored now.
    private AwaitedExecution awaitedNow(StateStores stores, string chainId)
    {
        auto evaluation = evaluateFrom(stores, "r_" ~ chainId);
        assert(evaluation.awaited.length == 1 && evaluation.needed.length == 0);
        return evaluation.awaited[0];
    }
}

unittest
{
    // A needed fingerprint is claimed at the executionSeq the evaluation saw and recorded, queued,
    // with the request's definition, inputs and repository addresses
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = dispatcherOf(stores);
    auto at = requested(stores, ["test"]);
    assert(at.evaluation.needed.length == 1);
    const needed = at.evaluation.needed[0];
    assert(needed.taskId == "compile" && needed.seenExecutionSeq == 0);

    const dispatched = dispatcher.dispatch(needed, at.request);
    assert(dispatched.claim == ClaimOutcome.won);
    assert(dispatched.executionId == executionIdFor(needed.fingerprint, 1));
    auto recorded = stores.executions.get(dispatched.executionId).get;
    assert(recorded.status == ExecutionStatus.queued && recorded.projectId == "game" && recorded.taskId == "compile");
    assert(recorded.fingerprint == needed.fingerprint && recorded.inputs == needed.inputs);
    assert(recorded.definition.steps.length == 1 && recorded.definition.steps[0].type == "bash");
    assert(recorded.definitionHash == computeDefinitionHash(recorded.definition));
    assert(recorded.repositoryAddresses == ["src": gameAddress]);
    assert(recorded.createdAt == fixedNow() && recorded.attempts == 0 && recorded.worker.length == 0);

    // The same decision again finds the execution active: nothing more is recorded
    const again = dispatcher.dispatch(needed, at.request);
    assert(again.claim == ClaimOutcome.active && again.executionId == dispatched.executionId);

    // It ends; a decision made before it started is superseded (it would build compile twice)
    finish(stores, stores.chains.get("c1").get.value, "compile", ExecutionStatus.failed);
    const stale = dispatcher.dispatch(needed, at.request);
    assert(stale.claim == ClaimOutcome.superseded && stale.executionId.length == 0);
    assert(stores.ledgers.get(needed.fingerprint).get.executionSeq == 1);
}

unittest
{
    // A task that cannot be recorded fails loudly before anything is written, so it never holds
    // its fingerprint: a repository without an address, one that is not registered, a task the
    // request's definition lacks
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = dispatcherOf(stores);
    auto at = requested(stores, ["test"]);
    const needed = at.evaluation.needed[0];

    RepositoryRecord addressless;
    addressless.name = "game";
    stores.repositories.put(addressless);
    try
    {
        dispatcher.dispatch(needed, at.request);
        assert(false, "A repository without an address must fail the dispatch");
    }
    catch (UndispatchableExecutionException e)
    {
        assert(e.msg.canFind("'game'") && e.msg.canFind("no address"));
    }
    stores.repositories.remove("game");
    try
    {
        dispatcher.dispatch(needed, at.request);
        assert(false, "An unregistered repository must fail the dispatch");
    }
    catch (UndispatchableExecutionException e)
    {
        assert(e.msg.canFind("'game'") && e.msg.canFind("not registered"));
    }
    auto missingTask = cast(NeededExecution) needed;
    missingTask.taskId = "deploy";
    assert(throwsA!UndispatchableExecutionException({ dispatcher.dispatch(missingTask, at.request); }));
    assert(stores.ledgers.get(needed.fingerprint).isNull, "Nothing was claimed");
}

unittest
{
    // Two dispatchers of one fingerprint at once: exactly one claims and records; the other
    // finds the winner's execution active and writes nothing more
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto at = requested(direct, ["test"]);
    const needed = at.evaluation.needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    Dispatched first;
    interleaving.beforeNextWrite = () { first = dispatcherOf(direct).dispatch(needed, at.request); };
    const second = dispatcherOf(racing).dispatch(needed, at.request);
    assert(first.claim == ClaimOutcome.won);
    assert(second.claim == ClaimOutcome.active && second.executionId == first.executionId);
    assert(direct.ledgers.get(needed.fingerprint).get.executionSeq == 1);
    assert(direct.executions.listActive(ExecutionStatus.queued, 10).length == 1);
}

unittest
{
    // Crash after the claim, before the record: the ledger names an execution with no record, and
    // the request awaits it. After a restart, repair records it under that id from the request;
    // repairing again changes nothing. The original dispatcher, resuming, finds it recorded
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto at = requested(stores, ["test"]);
    const needed = at.evaluation.needed[0];
    const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq); // and crashed

    auto restarted = new StateStores(documents.restart());
    auto dispatcher = dispatcherOf(restarted);
    const awaited = awaitedNow(restarted, "c1");
    assert(awaited.executionId == claimed.executionId);
    assert(restarted.executions.get(awaited.executionId).isNull);
    assert(!dispatcher.repair(awaited, at.request), "Recorded queued, so not ended");
    auto recorded = restarted.executions.get(awaited.executionId).get;
    assert(recorded.status == ExecutionStatus.queued && recorded.createdAt == fixedNow());
    assert(recorded.repositoryAddresses == ["src": gameAddress] && recorded.inputs == needed.inputs);
    assert(!dispatcher.repair(awaited, at.request));

    // The original dispatcher resumes after its claim: createIfAbsent returns the repaired record
    auto resumed = executionFor(claimed.executionId, needed.taskId, needed.fingerprint, needed.inputs, at.request,
        ["game": RepositoryRecord("game", gameAddress)], "2026-10-20T10:09:00Z");
    assert(restarted.executions.createIfAbsent(resumed).createdAt == fixedNow());

    // An awaited execution recorded at another fingerprint is refused
    auto elsewhere = cast(AwaitedExecution) awaited;
    elsewhere.fingerprint = "fp_other";
    assert(throwsA!Exception({ dispatcher.repair(elsewhere, at.request); }));
}

unittest
{
    // A slow dispatcher whose record lost to a repairer's, after a worker ran and failed the
    // execution, leaves the finished execution alone; repairing it then reports it ended
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto at = requested(direct, ["test"]);
    const needed = at.evaluation.needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    auto slow = dispatcherOf(new StateStores(interleaving));
    // Write 1 is the slow dispatcher's claim; before write 2 (its record) the repairer records
    // the execution, a worker claims it and it fails
    beforeWrite(interleaving, 2, () {
        assert(!dispatcherOf(direct).repair(awaitedNow(direct, "c1"), at.request));
        const id = direct.ledgers.get(needed.fingerprint).get.activeExecutionId;
        assert(!startExecution(direct.executions, id, "w1", 60.seconds, fixedNow()).isNull);
        finish(direct, direct.chains.get("c1").get.value, "compile", ExecutionStatus.failed);
    });
    const dispatched = slow.dispatch(needed, at.request);
    assert(interleaving.beforeNextWrite is null, "The repair ran between the claim and the record");
    assert(dispatched.claim == ClaimOutcome.won);
    const id = dispatched.executionId;
    assert(direct.executions.get(id).get.status == ExecutionStatus.failed, "The slow dispatcher left the finished execution alone");
    AwaitedExecution awaited;
    awaited.taskId = needed.taskId;
    awaited.fingerprint = needed.fingerprint;
    awaited.executionId = id;
    awaited.inputs = cast(ResolvedInput[]) needed.inputs;
    assert(dispatcherOf(direct).repair(awaited, at.request));
}
