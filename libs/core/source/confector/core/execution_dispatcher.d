module confector.core.execution_dispatcher;

/**
 * The execution dispatcher (AGENTS.md, "Coordinating builds" and "Backend interfaces"): the shell
 * that turns a fingerprint the request evaluator says needs an execution into a queued execution on the
 * dispatch queue, and that makes sure every active execution is recorded and its message sent.
 * It holds no lock and keeps no state between calls: it reads only by id and writes only by
 * single-document compare-and-set (through LedgerStore and ExecutionStore), so any number of
 * dispatchers may run at once, and every step is idempotent.
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
 *    have recorded it first, from its own request; the stored record wins and its status is
 *    checked before sending.
 * 4. Send its DispatchMessage, then stamp `sentAt` by compare-and-set (`deliver`).
 *
 * Repair, at the execution level, never in the evaluator:
 *
 * - **Claimed but never recorded** (a dispatcher crashed after 2): the ledger names an active
 *   execution with no record, and the evaluator reports the task as waiting on it. `repair`
 *   records it under that id from the request that awaits it (AwaitedExecution.inputs and the
 *   request's definition; the ledger cannot, it has no definition), then sends it. Concurrent repairers and
 *   a slow original dispatcher converge on the first record written.
 * - **Recorded but never sent** (a crash after 3, or a send that failed): the execution is queued
 *   with an empty `sentAt`. `repair` (for each execution a request awaits) and `resendUnsent` (the
 *   sweep's half, over executions found through the lagging active-execution index) send it
 *   again.
 *
 * A duplicate message (a repair racing a slow dispatcher, or a stamp that failed after a send) is
 * harmless: receiving starts an execution by compare-and-set and drops a duplicate
 * (confector.core.work_orders). An execution that a worker already holds (running) or whose
 * message was stamped sent is never sent again here: a message lost after its send is the
 * dispatch queue's to redeliver, and an expired lease is the lease sweep's.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.request_evaluator : AwaitedExecution, DefinedRequest, NeededExecution;
import confector.core.definition_hash : recordDefinition;
import confector.core.document_collection : Versioned;
import confector.core.fingerprint_ledger : ClaimOutcome;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : defaultPoolQueue, dispatchMessageFor, maxWriteAttempts, utcNow;
import confector.api.dispatch_queue : DispatchQueue;
import confector.api.document_store : DocumentConflictException;
import confector.api.model;

import std.algorithm.sorting : sort;
import std.format : format;
import vibe.data.json : serializeToJson;

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

/// What `ExecutionDispatcher.deliver` (and `repair`) found and did.
enum Delivery
{
    /// The execution was queued and unsent; its message was sent now and `sentAt` stamped.
    sent,
    /// The execution's message was sent before (`sentAt` is set) or a worker holds it: nothing to do.
    alreadySent,
    /// The execution has ended. Nothing was sent; whoever needs its fingerprint evaluates again
    /// (settling the ledger completes its fold if its ender has not).
    ended
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
    /// won: what delivering the recorded execution did (`ended` if a repairer recorded it first
    /// and it already ran). Otherwise `Delivery.init`, meaningless.
    Delivery delivery;
}

/**
 * The queued execution `executionId` of task `taskId` at `fingerprint`, recorded from `request`:
 * the task as `request`'s definition declares it (its build configuration and hash),
 * `inputs`, the address of each repository input from `repositories` (keyed by repository id),
 * and `createdAt` = `now`. Unsent. Pure.
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
 * Claims fingerprints, records executions and sends them to the dispatch queue, and repairs
 * executions that were claimed but not recorded or recorded but not sent. See the module
 * documentation.
 */
final class ExecutionDispatcher
{
    private StateStores m_stores;
    private DispatchQueue m_queue;
    private string delegate() m_now;

    /**
     * Dispatches through `stores` and `queue`, ensuring the pool's queue exists. `now` gives the
     * current time for `createdAt` and `sentAt` (default `utcNow`); tests pass a fixed clock.
     *
     * Throws: Exception if `stores` or `queue` is null; whatever `DispatchQueue.ensureQueue` throws.
     */
    this(StateStores stores, DispatchQueue queue, string delegate() now = null)
    {
        if (stores is null) throw new Exception("The execution dispatcher requires the state stores");
        if (queue is null) throw new Exception("The execution dispatcher requires a dispatch queue");
        m_stores = stores;
        m_queue = queue;
        m_now = now !is null ? now : () => utcNow();
        m_queue.ensureQueue(defaultPoolQueue);
    }

    /**
     * Dispatches the execution `needed` asks for, for `request` (with its definition): builds its record, claims the fingerprint at the
     * `executionSeq` the evaluation saw, and if the claim wins records the execution and sends
     * it. See Dispatched; whatever the outcome, the caller evaluates again before committing.
     *
     * Throws: UndispatchableExecutionException (nothing written) if the execution cannot be
     * recorded; whatever the stores and the queue throw. A send that fails leaves the execution recorded and unsent, for the next
     * reconcile or the sweep to send.
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
                auto recorded = m_stores.executions.createIfAbsent(execution);
                return Dispatched(ClaimOutcome.won, claimed.executionId, deliverRecord(recorded));
            case ClaimOutcome.active:
                return Dispatched(ClaimOutcome.active, claimed.executionId);
            case ClaimOutcome.superseded:
                return Dispatched(ClaimOutcome.superseded, null);
        }
    }

    /**
     * Makes sure the active execution a request awaits is recorded and sent: if it has no record
     * (its dispatcher crashed between claiming and recording it), records it under its id from
     * `request` (with its definition); then delivers it (`deliver`).
     *
     * Throws: UndispatchableExecutionException (nothing written) if it has no record and cannot be
     * recorded from `request`; Exception if the stored record is of another fingerprint; whatever
     * the stores and the queue throw.
     */
    Delivery repair(in AwaitedExecution awaited, in DefinedRequest request)
    {
        auto found = m_stores.executions.get(awaited.executionId);
        if (found.isNull)
        {
            auto execution = executionFor(awaited.executionId, awaited.taskId, awaited.fingerprint, awaited.inputs, request,
                repositoriesOf(awaited.taskId, request), m_now());
            return deliverRecord(m_stores.executions.createIfAbsent(execution));
        }
        if (found.get.fingerprint != awaited.fingerprint)
        {
            throw new Exception(format("Execution '%s', awaited at fingerprint %s, is recorded at fingerprint %s",
                awaited.executionId, awaited.fingerprint, found.get.fingerprint));
        }
        return deliverRecord(found.get);
    }

    /**
     * Sends execution `executionId` if it is queued and was never sent (`sentAt` empty), then
     * stamps `sentAt`. See Delivery.
     *
     * Throws: Exception if the execution does not exist, or stamping `sentAt` lost
     * maxWriteAttempts compare-and-sets in a row (its message was sent; a later delivery sends a
     * duplicate, which receiving drops); whatever the queue throws (the execution stays unsent).
     */
    Delivery deliver(string executionId)
    {
        auto found = m_stores.executions.get(executionId);
        if (found.isNull) throw new Exception(format("Execution '%s' cannot be delivered: it does not exist", executionId));
        return deliverRecord(found.get);
    }

    /**
     * The sweep's half of resending: walks the queued executions through the active-execution
     * index (discovery, which may lag), oldest first and a page at a time, and delivers each that
     * was never sent, deciding from its record read by id. Executions already sent do not count
     * toward `limit`: the walk stops after `limit` unsent executions have been examined, or at
     * the end of the index. Returns how many were sent.
     *
     * Throws: Exception, after delivering every other execution found, naming each execution
     * that could not be delivered.
     */
    size_t resendUnsent(size_t limit)
    {
        size_t sent = 0;
        size_t examined = 0;
        string[] failures;
        string cursor;
        while (examined < limit)
        {
            auto page = m_stores.executions.listActivePage(ExecutionStatus.queued, cursor);
            foreach (ref item; page.items)
            {
                if (examined == limit) break;
                if (item.sentAt.length > 0) continue;
                ++examined;
                try
                {
                    if (deliver(item.id) == Delivery.sent) ++sent;
                }
                catch (Exception e)
                {
                    // Reported below, after the others were delivered
                    failures ~= format("execution '%s': %s", item.id, e.msg);
                }
            }
            if (page.nextCursor.length == 0) break;
            cursor = page.nextCursor;
        }
        if (failures.length > 0)
        {
            throw new Exception(format("Could not resend %s unsent executions (%s others were sent):\n- %-(%s\n- %)",
                failures.length, sent, failures));
        }
        return sent;
    }

    private Delivery deliverRecord(in Versioned!TaskExecution record)
    {
        if (!ExecutionStore.isActive(record.status)) return Delivery.ended;
        if (record.status == ExecutionStatus.running || record.sentAt.length > 0) return Delivery.alreadySent;
        m_queue.send(defaultPoolQueue, serializeToJson(dispatchMessageFor(record.id)));
        markSent(record.id);
        return Delivery.sent;
    }

    /// Stamps `sentAt` on execution `id`, unless it is no longer queued or was stamped already (by a
    /// concurrent delivery, or a worker receiving it).
    private void markSent(string id)
    {
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = m_stores.executions.get(id);
            if (current.isNull) throw new Exception(format("Execution '%s' was sent, then not found", id));
            if (current.get.status != ExecutionStatus.queued || current.get.sentAt.length > 0) return;
            TaskExecution next = current.get.value;
            next.sentAt = m_now();
            try
            {
                m_stores.executions.update(current.get, next);
                return;
            }
            catch (DocumentConflictException)
            {
                // A worker started it or another delivery stamped it: read it and decide again.
            }
        }
        throw new Exception(format(
            "Execution '%s' was sent, but recording that lost %s compare-and-sets in a row; a later delivery may send a duplicate, which receiving drops",
            id, maxWriteAttempts));
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
    import confector.core.work_orders : StartKind, startExecution;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

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
    // A needed fingerprint is claimed at the executionSeq the evaluation saw, recorded with the
    // request's definition, inputs and repository addresses, sent, and stamped sent
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = dispatcherOf(stores, queue);
    auto at = requested(stores, ["test"]);
    assert(at.evaluation.needed.length == 1);
    const needed = at.evaluation.needed[0];
    assert(needed.taskId == "compile" && needed.seenExecutionSeq == 0);

    const dispatched = dispatcher.dispatch(needed, at.request);
    assert(dispatched.claim == ClaimOutcome.won && dispatched.delivery == Delivery.sent);
    assert(dispatched.executionId == executionIdFor(needed.fingerprint, 1));
    auto recorded = stores.executions.get(dispatched.executionId).get;
    assert(recorded.status == ExecutionStatus.queued && recorded.projectId == "game" && recorded.taskId == "compile");
    assert(recorded.fingerprint == needed.fingerprint && recorded.inputs == needed.inputs);
    assert(recorded.definition.steps.length == 1 && recorded.definition.steps[0].type == "bash");
    assert(recorded.definitionHash == computeDefinitionHash(recorded.definition));
    assert(recorded.repositoryAddresses == ["src": gameAddress]);
    assert(recorded.createdAt == fixedNow() && recorded.sentAt == fixedNow());
    assert(messagesIn(queue) == [dispatched.executionId]);

    // The same decision again finds the execution active: nothing more is recorded or sent
    const again = dispatcher.dispatch(needed, at.request);
    assert(again.claim == ClaimOutcome.active && again.executionId == dispatched.executionId);
    assert(messagesIn(queue).length == 0);

    // It ends; a decision made before it started is superseded (it would build compile twice)
    finish(stores, stores.chains.get("c1").get.value, "compile", ExecutionStatus.failed);
    const stale = dispatcher.dispatch(needed, at.request);
    assert(stale.claim == ClaimOutcome.superseded && stale.executionId.length == 0);
    assert(stores.ledgers.get(needed.fingerprint).get.executionSeq == 1 && messagesIn(queue).length == 0);
}

unittest
{
    // A task that cannot be recorded fails loudly before anything is written, so it never holds
    // its fingerprint: a repository without an address, one that is not registered, a task the
    // request's definition lacks
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = dispatcherOf(stores, queue);
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
    assert(messagesIn(queue).length == 0);
}

unittest
{
    // Two dispatchers of one fingerprint at once: exactly one claims, records and sends; the
    // other finds the winner's execution active and writes nothing more
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    auto at = requested(direct, ["test"]);
    const needed = at.evaluation.needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    Dispatched first;
    interleaving.beforeNextWrite = () { first = dispatcherOf(direct, queue).dispatch(needed, at.request); };
    const second = dispatcherOf(racing, queue).dispatch(needed, at.request);
    assert(first.claim == ClaimOutcome.won && first.delivery == Delivery.sent);
    assert(second.claim == ClaimOutcome.active && second.executionId == first.executionId);
    assert(direct.ledgers.get(needed.fingerprint).get.executionSeq == 1);
    assert(messagesIn(queue) == [first.executionId]);
}

unittest
{
    // Crash after the claim, before the record: the ledger names an execution with no record, and
    // the request awaits it. After a restart, repair records it under that id from the request and sends it; repairing again sends nothing. The original dispatcher, resuming,
    // finds it recorded and sent, and sends no duplicate
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    auto at = requested(stores, ["test"]);
    const needed = at.evaluation.needed[0];
    const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq); // and crashed

    auto restarted = new StateStores(documents.restart());
    auto dispatcher = dispatcherOf(restarted, queue);
    const awaited = awaitedNow(restarted, "c1");
    assert(awaited.executionId == claimed.executionId);
    assert(restarted.executions.get(awaited.executionId).isNull);
    assert(dispatcher.repair(awaited, at.request) == Delivery.sent);
    auto recorded = restarted.executions.get(awaited.executionId).get;
    assert(recorded.status == ExecutionStatus.queued && recorded.sentAt == fixedNow());
    assert(recorded.repositoryAddresses == ["src": gameAddress] && recorded.inputs == needed.inputs);
    assert(dispatcher.repair(awaited, at.request) == Delivery.alreadySent);
    assert(messagesIn(queue) == [awaited.executionId]);

    // The original dispatcher resumes after its claim: createIfAbsent returns the repaired record
    auto resumed = executionFor(claimed.executionId, needed.taskId, needed.fingerprint, needed.inputs, at.request,
        ["game": RepositoryRecord("game", gameAddress)], "2026-10-20T10:09:00Z");
    assert(restarted.executions.createIfAbsent(resumed).sentAt == fixedNow());
    assert(dispatcher.deliver(claimed.executionId) == Delivery.alreadySent);
    assert(messagesIn(queue).length == 0);

    // An awaited execution recorded at another fingerprint is refused
    auto elsewhere = cast(AwaitedExecution) awaited;
    elsewhere.fingerprint = "fp_other";
    assert(throwsA!Exception({ dispatcher.repair(elsewhere, at.request); }));
}

unittest
{
    // Crash after the record, before the send (here: the send fails): the execution is queued and
    // unsent. The sweep's resend sends it, as does repair for a request awaiting it; an execution a
    // worker holds or that ended is never sent
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto queue = new FlakyDispatchQueue();
    auto dispatcher = dispatcherOf(stores, queue);
    auto at = requested(stores, ["test"]);
    const needed = at.evaluation.needed[0];

    queue.failSends = 1;
    assert(throwsA!Exception({ dispatcher.dispatch(needed, at.request); }));
    const id = stores.ledgers.get(needed.fingerprint).get.activeExecutionId;
    assert(stores.executions.get(id).get.sentAt.length == 0 && messagesIn(queue).length == 0);

    // The sweep, after a restart, finds it through the index and sends it; then nothing more
    auto sweeper = dispatcherOf(new StateStores(documents.restart()), queue);
    assert(sweeper.resendUnsent(10) == 1);
    assert(stores.executions.get(id).get.sentAt == fixedNow() && messagesIn(queue) == [id]);
    assert(sweeper.resendUnsent(10) == 0 && messagesIn(queue).length == 0);

    // Through repair, for a request awaiting another unsent execution (lint)
    auto lint = requested(stores, ["lint"], "c2");
    const lintNeeded = lint.evaluation.needed[0];
    queue.failSends = 1;
    assert(throwsA!Exception({ dispatcher.dispatch(lintNeeded, lint.request); }));
    const lintId = stores.ledgers.get(lintNeeded.fingerprint).get.activeExecutionId;
    assert(dispatcher.repair(awaitedNow(stores, "c2"), lint.request) == Delivery.sent);
    assert(messagesIn(queue) == [lintId]);

    // A resend that fails is reported, naming the execution, and the execution stays unsent
    auto report = requested(stores, ["report"], "c3"); // compile is active (c1's); nothing needed yet
    assert(report.evaluation.needed.length == 0);
    finish(stores, stores.chains.get("c1").get.value, "compile", ExecutionStatus.succeeded);
    const testNeeded = evaluateFrom(stores, "r_c3").needed[0];
    queue.failSends = 2;
    assert(throwsA!Exception({ dispatcher.dispatch(testNeeded, definedRequest(stores, "r_c3")); }));
    const testId = stores.ledgers.get(testNeeded.fingerprint).get.activeExecutionId;
    try
    {
        sweeper.resendUnsent(10);
        assert(false, "A failed resend must be reported");
    }
    catch (Exception e)
    {
        assert(e.msg.canFind(testId) && e.msg.canFind("unavailable"));
    }
    assert(stores.executions.get(testId).get.sentAt.length == 0);
    assert(sweeper.resendUnsent(10) == 1 && messagesIn(queue) == [testId]);

    // Running (a worker holds it) or ended: never sent
    assert(startExecution(stores.executions, testId, "m1", 1, "w1", fixedNow()).kind == StartKind.started);
    assert(dispatcher.deliver(testId) == Delivery.alreadySent);
    finish(stores, stores.chains.get("c3").get.value, "test", ExecutionStatus.succeeded);
    assert(dispatcher.deliver(testId) == Delivery.ended && dispatcher.deliver(id) == Delivery.ended);
    assert(messagesIn(queue).length == 0);
    assert(throwsA!Exception({ dispatcher.deliver("exe_missing"); }));
}

unittest
{
    // A slow dispatcher whose createIfAbsent comes back with an execution that already ran: a
    // repairer recorded it first, a worker ran it and it ended. The dispatcher must not send it
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    auto at = requested(direct, ["test"]);
    const needed = at.evaluation.needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    auto slow = dispatcherOf(new StateStores(interleaving), queue);
    // Write 1 is the slow dispatcher's claim; before write 2 (its record) the repairer records and
    // sends it, a worker starts it and it fails
    beforeWrite(interleaving, 2, () {
        assert(dispatcherOf(direct, queue).repair(awaitedNow(direct, "c1"), at.request) == Delivery.sent);
        const id = direct.ledgers.get(needed.fingerprint).get.activeExecutionId;
        assert(startExecution(direct.executions, id, "m1", 1, "w1", fixedNow()).kind == StartKind.started);
        finish(direct, direct.chains.get("c1").get.value, "compile", ExecutionStatus.failed);
    });
    const dispatched = slow.dispatch(needed, at.request);
    assert(interleaving.beforeNextWrite is null, "The repair ran between the claim and the record");
    assert(dispatched.claim == ClaimOutcome.won && dispatched.delivery == Delivery.ended);
    assert(messagesIn(queue).length == 1, "Only the repairer's message was sent");
}

unittest
{
    // Stamping sentAt races a worker that received the message and started it: the stamp loses
    // one compare-and-set, finds it running (stamped by the receipt) and stops
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    auto at = requested(direct, ["test"]);
    const needed = at.evaluation.needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    // Writes: 1 the claim, 2 the record, 3 the stamp
    beforeWrite(interleaving, 3, () {
        const id = direct.ledgers.get(needed.fingerprint).get.activeExecutionId;
        assert(startExecution(direct.executions, id, "m1", 1, "w1", "2026-10-20T10:00:05Z").kind == StartKind.started);
    });
    const dispatched = dispatcherOf(new StateStores(interleaving), queue).dispatch(needed, at.request);
    assert(interleaving.beforeNextWrite is null);
    assert(dispatched.delivery == Delivery.sent);
    auto running = direct.executions.get(dispatched.executionId).get;
    assert(running.status == ExecutionStatus.running && running.sentAt == "2026-10-20T10:00:05Z");
}

unittest
{
    // Queued executions already sent, listed ahead of an unsent one, do not use up the resend
    // limit: with a limit of 1 and 120 sent executions (more than one index page) before it, the
    // unsent one is still resent, and nothing is resent twice
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = dispatcherOf(stores, queue);
    auto at = requested(stores, ["test"]);
    const needed = at.evaluation.needed[0];
    RepositoryRecord[string] repositories = ["game": RepositoryRecord("game", gameAddress)];

    foreach (i; 0 .. 120)
    {
        auto sent = executionFor(format("exe_sent_%03d", i), needed.taskId, needed.fingerprint, needed.inputs,
            at.request, repositories, format("2026-10-20T11:%02d:%02dZ", i / 60, i % 60));
        sent.sentAt = fixedNow();
        stores.executions.createIfAbsent(sent);
    }
    auto unsent = executionFor("exe_unsent", needed.taskId, needed.fingerprint, needed.inputs, at.request,
        repositories, "2026-10-20T12:00:00Z");
    stores.executions.createIfAbsent(unsent);

    assert(dispatcher.resendUnsent(1) == 1);
    assert(messagesIn(queue) == ["exe_unsent"]);
    assert(stores.executions.get("exe_unsent").get.sentAt == fixedNow());
    assert(dispatcher.resendUnsent(1) == 0 && messagesIn(queue).length == 0);
}
