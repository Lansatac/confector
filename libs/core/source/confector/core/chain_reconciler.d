module confector.core.chain_reconciler;

/**
 * The chain reconciler (design records: beads confector-z7z.2 and confector-z7z.48; AGENTS.md,
 * "Coordinating builds"): the imperative shell that brings one chain up to date. It reads
 * everything by id, evaluates with the pure chain evaluator (confector.core.chain_evaluator),
 * has the execution dispatcher (confector.core.execution_dispatcher) dispatch what is needed and
 * repair what it waits on, subscribes the chain on the ledgers of the executions it waits on, and
 * commits the evaluation to the chain's ChainState (confector.core.chain_state), clearing its
 * dirty marker. It keeps no state between calls, so it works the same after a restart, in a
 * short-lived function, and with any number of reconcilers of one chain at once.
 *
 * One pass, repeated until a pass commits:
 *
 * 1. Read the ChainState by id. If it is clean, nothing changed since the last commit: stop. The
 *    ChainState is read before anything else, so a signal (a request added, an awaited execution
 *    ending, a rerun reaching the chain) that lands after this read changes its version and makes
 *    step 6 fail.
 * 2. Read by id the chain, the requests the state names and their definitions, the rerun
 *    generations, and each fingerprint's ledger, settled (completing a half-finished fold), with
 *    the executions it names. Evaluate.
 * 3. If anything is needed, dispatch each (whatever a claim finds) and start the next pass: an
 *    evaluation that still needs executions is never committed.
 * 4. For each execution the chain awaits, have the dispatcher record it if it was never recorded
 *    and send it if it was never sent. If one has ended since the evaluation, start the next pass.
 * 5. Subscribe the chain on each awaited execution's ledger at the version the evaluation read it
 *    at. If a ledger changed since (DocumentConflictException) or has no active execution any more
 *    (notActive), the execution may have ended without noticing this chain: start the next pass
 *    rather than commit a chain waiting on an end it will never hear of.
 * 6. Commit the evaluation by compare-and-set at the ChainState version read in step 1. If the
 *    state changed since (DocumentConflictException), start the next pass.
 *
 * Failures leave the chain dirty, so it is reconciled again (by the sweep, bead
 * confector-z7z.49.5, or the next signal) and the error stays visible:
 *
 * - LedgerWaiterLimitException from a subscribe propagates, and nothing is committed.
 * - A needed execution that cannot be dispatched (UndispatchableExecutionException, a send that
 *   fails) does not stop the others: every other needed execution is dispatched first, then
 *   ChainReconcileException names each failure, and nothing is committed. The same holds for
 *   awaited executions that cannot be recorded or sent.
 * - A chain without a ChainState fails with ChainStateMissingException: repair it
 *   (`ChainStateStore.repair`) from the chain and its requests, then reconcile.
 */

import confector.core.chain_evaluator;
import confector.core.chain_state : ChainStateMissingException;
import confector.core.document_collection : Versioned;
import confector.core.execution_dispatcher : Delivery, ExecutionDispatcher;
import confector.core.fingerprint_ledger : SubscribeOutcome;
import confector.core.state_stores : StateStores;
import confector.api.document_store : DocumentConflictException;
import confector.api.model;

import std.format : format;

/**
 * A reconcile could not finish: some executions could not be dispatched, recorded or sent. Every
 * other one was handled first; the chain stays dirty and nothing was committed.
 */
class ChainReconcileException : Exception
{
    string chainId;
    /// One line per execution that failed, naming its task, fingerprint and the cause.
    string[] failures;

    /// `cause`, when exactly one execution failed, is that failure, chained so its type and trace
    /// are kept.
    this(string chainId, string[] failures, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(format("Chain '%s' could not be reconciled; it stays dirty:\n- %-(%s\n- %)", chainId, failures), file, line, cause);
        this.chainId = chainId;
        this.failures = failures;
    }
}

/// The result of `ChainReconciler.reconcile`.
struct Reconciled
{
    /// The ChainState as committed, or as read when it was already clean.
    Versioned!ChainState state;
    /// How many passes it took (each pass after the first was forced by something the previous one
    /// found or lost: a dispatch, an ended execution, a conflicting ledger or ChainState).
    size_t passes;
    /// Whether this call committed an evaluation; false when the state was clean when read.
    bool committed;
}

/**
 * Reconciles chains. See the module documentation.
 */
final class ChainReconciler
{
    /// How many passes one reconcile makes before failing. Each pass after the first was forced by
    /// a write that landed (a dispatch, which happens at most once per task and rerun generation,
    /// an execution ending, a signal or a concurrent reconcile), so this is reached only under
    /// sustained contention on one chain.
    enum maxPasses = 100;

    private StateStores m_stores;
    private ExecutionDispatcher m_dispatcher;

    /// Reconciles chains in `stores`, dispatching through `dispatcher`.
    this(StateStores stores, ExecutionDispatcher dispatcher)
    {
        if (stores is null) throw new Exception("The chain reconciler requires the state stores");
        if (dispatcher is null) throw new Exception("The chain reconciler requires the execution dispatcher");
        m_stores = stores;
        m_dispatcher = dispatcher;
    }

    /**
     * Reconciles chain `chainId` until a pass commits or finds it clean. See the module
     * documentation.
     *
     * Throws: ChainStateMissingException if the chain has no ChainState; ChainReconcileException
     * if executions could not be dispatched, recorded or sent; LedgerWaiterLimitException if the
     * chain cannot wait on an execution; Exception if the chain does not exist, a request or
     * definition the state names is missing, or maxPasses passes did not commit; whatever the
     * evaluator and the stores throw. In every case the chain stays dirty.
     */
    Reconciled reconcile(string chainId)
    {
        foreach (pass; 1 .. maxPasses + 1)
        {
            auto found = m_stores.chainStates.get(chainId);
            if (found.isNull)
            {
                throw new ChainStateMissingException(format(
                    "Chain '%s' has no chain state, so it cannot be reconciled; repair it from the chain and its requests", chainId),
                    chainId);
            }
            auto read = found.get;
            if (!read.dirty) return Reconciled(read, pass, false);

            auto chain = m_stores.chains.get(chainId);
            if (chain.isNull) throw new Exception(format("Chain '%s' has a chain state but does not exist", chainId));
            auto requests = requestsOf(read.value);
            auto evaluation = evaluate(chain.get.value, requests);

            if (evaluation.needed.length > 0)
            {
                string[] failures;
                Exception cause;
                foreach (ref needed; evaluation.needed)
                {
                    try m_dispatcher.dispatch(needed, requestNamed(requests, needed.requestId));
                    catch (Exception e)
                    {
                        // Reported below, after every other needed execution is dispatched
                        failures ~= format("task '%s' at fingerprint %s: %s", needed.taskId, needed.fingerprint, e.msg);
                        cause = e;
                    }
                }
                if (failures.length > 0) throw new ChainReconcileException(chainId, failures, failures.length == 1 ? cause : null);
                continue;
            }

            if (!deliverAwaited(chainId, evaluation, requests)) continue;

            bool waiting = true;
            try
            {
                foreach (ref awaited; evaluation.awaited)
                {
                    if (m_stores.ledgers.subscribe(awaited.ledger, chainId).outcome == SubscribeOutcome.notActive)
                    {
                        waiting = false;
                        break;
                    }
                }
            }
            catch (DocumentConflictException)
            {
                // The ledger changed since the evaluation read it: the execution may have ended.
                waiting = false;
            }
            if (!waiting) continue;

            try
            {
                return Reconciled(m_stores.chainStates.commit(read, evaluation), pass, true);
            }
            catch (DocumentConflictException)
            {
                // A request or signal landed since the state was read: reconcile again.
            }
        }
        throw new Exception(format("Chain '%s' was not reconciled: %s passes in a row were overtaken by other writes; it stays dirty",
            chainId, maxPasses));
    }

    /// Has the dispatcher record and send each execution `evaluation` awaits. Returns false if one
    /// has ended since the evaluation (evaluate again).
    private bool deliverAwaited(string chainId, in ChainEvaluation evaluation, in ChainRequest[] requests)
    {
        string[] failures;
        Exception cause;
        bool ended = false;
        foreach (ref awaited; evaluation.awaited)
        {
            try
            {
                if (m_dispatcher.repair(awaited, requestNamed(requests, awaited.requestId)) == Delivery.ended) ended = true;
            }
            catch (Exception e)
            {
                // Reported below, after every other awaited execution is delivered
                failures ~= format("task '%s' at fingerprint %s (execution '%s'): %s", awaited.taskId, awaited.fingerprint,
                    awaited.executionId, e.msg);
                cause = e;
            }
        }
        if (failures.length > 0) throw new ChainReconcileException(chainId, failures, failures.length == 1 ? cause : null);
        return !ended;
    }

    /// The requests `state` names, in its order, each with its definition, read by id.
    private ChainRequest[] requestsOf(in ChainState state)
    {
        ChainRequest[] requests;
        foreach (id; state.requestIds)
        {
            auto request = m_stores.requests.get(id);
            if (request.isNull) throw new Exception(format("Request '%s' of chain '%s' does not exist", id, state.chainId));
            auto definition = m_stores.definitions.get(request.get.definitionId);
            if (definition.isNull)
            {
                throw new Exception(format("Definition '%s' of request '%s' (chain '%s') does not exist", request.get.definitionId, id,
                    state.chainId));
            }
            requests ~= ChainRequest(request.get.value, definition.get);
        }
        return requests;
    }

    /// Evaluates `chain` with `requests` from the generations and ledgers, read by id now.
    private ChainEvaluation evaluate(in BuildChain chain, in ChainRequest[] requests)
    {
        auto generations = readChainGenerations(chain, requests, (in string[] bases) => m_stores.rerunGenerations.read(bases));
        LedgerSummary[string] summaries;
        foreach (fingerprint; chainFingerprints(chain, requests, generations))
        {
            summaries[fingerprint] = readLedgerSummary(m_stores.ledgers, m_stores.executions, fingerprint);
        }
        return evaluateChain(chain, requests, generations, summaries);
    }

    private static const(ChainRequest) requestNamed(in ChainRequest[] requests, string requestId)
    {
        foreach (ref entry; requests)
        {
            if (entry.request.id == requestId) return entry;
        }
        throw new Exception(format("The evaluation names request '%s', which it was not given", requestId));
    }
}

version (unittest)
{
    import confector.core.chain_fixtures;
    import confector.core.execution_dispatcher : UndispatchableExecutionException;
    import confector.core.fingerprint_ledger : LedgerWaiterLimitException, maxLedgerWaiters;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import std.algorithm.searching : canFind, count;

    /// The active execution of task `taskId` of chain `chainId`, as its ledger names it now.
    private string activeOf(StateStores stores, string chainId, string taskId)
    {
        return stores.ledgers.get(fingerprintNow(stores, chainId, taskId)).get.activeExecutionId;
    }

    /// The ledger of task `taskId` of chain `chainId` now.
    private FingerprintLedger ledgerOf(StateStores stores, string chainId, string taskId)
    {
        return stores.ledgers.get(fingerprintNow(stores, chainId, taskId)).get.value;
    }
}

unittest
{
    // A chain is reconciled to the end through its signals alone: each reconcile dispatches what
    // is needed (then evaluates again), subscribes on what it waits on and commits clean; each
    // end it waits on marks it dirty; a clean chain is left alone
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto reconciler = reconcilerOf(stores, queue);
    auto chain = createChain(stores, "c1");
    intake(stores, "c1", "r1", ["report"], "2026-10-20T10:00:00Z");

    auto first = reconciler.reconcile("c1");
    assert(first.committed && first.passes == 2 && !first.state.dirty);
    assert(taskOf(first.state, "compile").status == ChainTaskStatus.queued);
    assert(taskOf(first.state, "test").status == ChainTaskStatus.waitingUpstream);
    assert(ledgerOf(stores, "c1", "compile").subscribers == ["c1"]);
    assert(messagesIn(queue) == [activeOf(stores, "c1", "compile")]);

    auto clean = reconciler.reconcile("c1");
    assert(!clean.committed && clean.passes == 1 && clean.state.version_ == first.state.version_, "A clean chain is not touched");

    foreach (taskId; ["compile", "test", "report"])
    {
        assert(stores.chainStates.get("c1").get.dirty == (taskId != "compile"), "Only the end it waits on marks the chain dirty");
        if (taskId != "compile")
        {
            auto next = reconciler.reconcile("c1");
            assert(next.committed && taskOf(next.state, taskId).status == ChainTaskStatus.queued);
            assert(messagesIn(queue) == [activeOf(stores, "c1", taskId)]);
        }
        finish(stores, chain, taskId, ExecutionStatus.succeeded);
        assert(stores.chainStates.get("c1").get.dirty);
    }
    auto done = reconciler.reconcile("c1");
    assert(done.committed && !done.state.dirty);
    foreach (taskId; ["compile", "test", "report"]) assert(taskOf(done.state, taskId).status == ChainTaskStatus.succeeded);
    assert(!reconciler.reconcile("c1").committed);

    // A chain without a state fails loudly; so does a reconciler without its parts
    createChainOnly(stores, "c2");
    assert(throwsA!ChainStateMissingException({ reconciler.reconcile("c2"); }));
    assert(throwsA!Exception({ new ChainReconciler(null, dispatcherOf(stores)); }));
    assert(throwsA!Exception({ new ChainReconciler(stores, null); }));
}

unittest
{
    // A dirty mark landing mid-reconcile forces a repeat: a request added, or a bare signal,
    // between the reconcile's evaluation and its commit makes the commit conflict, and the
    // reconcile evaluates again and handles it before committing
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = reconcilerOf(new StateStores(interleaving), queue);
    // Pass 1 dispatches compile (writes 1-3: claim, record, stamp); pass 2 subscribes (4) and
    // would commit (5): the request lands just before
    beforeWrite(interleaving, 5, () { intake(direct, "c1", "r2", ["lint"], "2026-10-20T10:00:01Z"); });
    auto reconciled = racing.reconcile("c1");
    assert(interleaving.beforeNextWrite is null, "The request landed mid-reconcile");
    assert(reconciled.committed && reconciled.passes == 4 && !reconciled.state.dirty);
    assert(reconciled.state.requestIds == ["r1", "r2"]);
    assert(taskOf(reconciled.state, "lint").status == ChainTaskStatus.queued, "The late request was evaluated, not lost");
    assert(ledgerOf(direct, "c1", "lint").subscribers == ["c1"] && ledgerOf(direct, "c1", "compile").subscribers == ["c1"]);
    assert(messagesIn(queue).length == 2);

    // A bare signal (say a rerun reached it) between the evaluation and the commit of a chain
    // that was already dirty: the commit conflicts and the reconcile repeats
    direct.chainStates.markDirty("c1");
    // Pass 1 subscribes twice (writes 1, 2) and would commit (3)
    beforeWrite(interleaving, 3, () { direct.chainStates.markDirty("c1"); });
    auto signalled = racing.reconcile("c1");
    assert(interleaving.beforeNextWrite is null);
    assert(signalled.committed && signalled.passes == 2 && !signalled.state.dirty);
    assert(messagesIn(queue).length == 0, "Nothing was dispatched twice");
}

unittest
{
    // Two reconcilers of one chain converge, whichever of their writes interleave: one execution
    // per fingerprint, one message, the chain subscribed once and committed clean
    foreach (overtakenAt; [1, 2, 3, 4, 5])
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        auto queue = new InMemoryDispatchQueue();
        createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        Reconciled other;
        // The first reconciler's writes: 1 claim, 2 record, 3 stamp, 4 subscribe, 5 commit; the
        // second reconciles completely just before the chosen one
        beforeWrite(interleaving, overtakenAt, () { other = reconcilerOf(direct, queue).reconcile("c1"); });
        auto reconciled = reconcilerOf(new StateStores(interleaving), queue).reconcile("c1");
        assert(interleaving.beforeNextWrite is null);
        assert(other.committed, format("overtaken at write %s: the second reconciler commits", overtakenAt));
        assert(!reconciled.committed, format("overtaken at write %s: the first finds the chain clean", overtakenAt));

        auto state = direct.chainStates.get("c1").get;
        assert(!state.dirty && taskOf(state, "compile").status == ChainTaskStatus.queued);
        auto compile = ledgerOf(direct, "c1", "compile");
        assert(compile.executionSeq == 1 && compile.subscribers == ["c1"], format("overtaken at write %s", overtakenAt));
        // Overtaken between its send and its stamp, the first reconciler's message is out but not yet
        // recorded as sent, so the second sends it again: a duplicate, which receiving drops
        const messages = overtakenAt == 3 ? 2 : 1;
        auto sent = messagesIn(queue);
        assert(sent.length == messages && sent.count(compile.activeExecutionId) == messages,
            format("overtaken at write %s: messages %s", overtakenAt, sent));
        assert(direct.executions.get(compile.activeExecutionId).get.sentAt == fixedNow());
    }
}

unittest
{
    // Reconcilers of one chain on several threads at once (as several server instances would)
    // converge: each needed fingerprint is claimed, recorded and sent once
    import core.thread : Thread;
    import core.atomic : atomicOp;

    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto queue = new InMemoryDispatchQueue();
    createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test", "lint"], "2026-10-20T10:00:00Z");

    Thread[] threads;
    shared int failures;
    foreach (i; 0 .. 4)
    {
        threads ~= new Thread({
            try reconcilerOf(new StateStores(documents.restart()), queue).reconcile("c1");
            catch (Throwable e)
            {
                atomicOp!"+="(failures, 1);
                throw e;
            }
        });
    }
    foreach (thread; threads) thread.start();
    foreach (thread; threads) thread.join(false);
    assert(failures == 0);

    assert(!direct.chainStates.get("c1").get.dirty);
    foreach (taskId; ["compile", "lint"])
    {
        auto ledger = ledgerOf(direct, "c1", taskId);
        assert(ledger.executionSeq == 1 && ledger.subscribers == ["c1"]);
    }
    auto messages = messagesIn(queue);
    assert(messages.length == 2 && messages.canFind(activeOf(direct, "c1", "compile")) && messages.canFind(activeOf(direct, "c1", "lint")));
}

unittest
{
    // A reconcile after a restart needs nothing from the process that crashed, whichever step it
    // crashed after: the claim, the record, the send, or the subscribe
    import confector.core.execution_dispatcher : executionFor;

    foreach (crashedAfter; ["claim", "record", "send", "subscribe"])
    {
        auto documents = new InMemoryDocumentStore();
        auto stores = new StateStores(documents);
        auto queue = new InMemoryDispatchQueue();
        createChain(stores, "c1");
        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
        const needed = evaluateFrom(stores, stores.chainStates.get("c1").get).needed[0];

        const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq);
        if (crashedAfter != "claim")
        {
            stores.executions.createIfAbsent(executionFor(claimed.executionId, needed.taskId, needed.fingerprint, needed.inputs,
                chainRequest(stores, "r1"), ["game": RepositoryRecord("game", gameAddress)], fixedNow()));
        }
        if (crashedAfter == "send" || crashedAfter == "subscribe")
        {
            dispatcherOf(stores, queue).deliver(claimed.executionId);
            assert(messagesIn(queue).length == 1);
        }
        if (crashedAfter == "subscribe") stores.ledgers.subscribe(stores.ledgers.get(needed.fingerprint).get, "c1");

        // A new process: new stores over the same database, a new reconciler, nothing else
        auto restarted = new StateStores(documents.restart());
        assert(restarted.chainStates.get("c1").get.dirty, crashedAfter);
        auto reconciled = reconcilerOf(restarted, queue).reconcile("c1");
        assert(reconciled.committed && reconciled.passes == 1 && !reconciled.state.dirty, crashedAfter);
        assert(taskOf(reconciled.state, "compile").status == ChainTaskStatus.queued, crashedAfter);
        auto ledger = ledgerOf(restarted, "c1", "compile");
        assert(ledger.executionSeq == 1 && ledger.subscribers == ["c1"], crashedAfter);
        auto execution = restarted.executions.get(claimed.executionId).get;
        assert(execution.status == ExecutionStatus.queued && execution.sentAt == fixedNow(), crashedAfter);
        string[] expected;
        if (crashedAfter == "claim" || crashedAfter == "record") expected = [claimed.executionId];
        assert(messagesIn(queue) == expected, crashedAfter ~ ": sent exactly when it was not");
    }
}

unittest
{
    // Subscribe racing the fold of the execution the chain waits on, in each order.
    // 1. The execution ends after the evaluation read its ledger, before the chain subscribes:
    //    nobody was subscribed, so its fold notices nobody; the subscribe at the version read
    //    conflicts, and the reconcile evaluates again and goes on to the next task
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        auto queue = new InMemoryDispatchQueue();
        auto chain = createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        // Writes: 1-3 dispatch compile, 4 the subscribe
        beforeWrite(interleaving, 4, () { finish(direct, chain, "compile", ExecutionStatus.succeeded); });
        auto reconciled = reconcilerOf(new StateStores(interleaving), queue).reconcile("c1");
        assert(interleaving.beforeNextWrite is null);
        assert(ledgerOf(direct, "c1", "compile").pendingNotify.length == 0, "The fold noticed nobody");
        assert(reconciled.committed && !reconciled.state.dirty);
        assert(taskOf(reconciled.state, "compile").status == ChainTaskStatus.succeeded);
        assert(taskOf(reconciled.state, "test").status == ChainTaskStatus.queued, "The chain must not end clean and stuck");
        assert(ledgerOf(direct, "c1", "test").subscribers == ["c1"]);
    }
    // 2. The execution ends after the chain subscribed, before it commits: the fold takes the
    //    subscriber, its drain marks the chain dirty, the commit conflicts and the reconcile repeats
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        auto queue = new InMemoryDispatchQueue();
        auto chain = createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        bool noticed = false;
        // Writes: 1-3 dispatch compile, 4 the subscribe, 5 the commit
        beforeWrite(interleaving, 5, () {
            noticed = ledgerOf(direct, "c1", "compile").subscribers == ["c1"];
            finish(direct, chain, "compile", ExecutionStatus.succeeded);
        });
        auto reconciled = reconcilerOf(new StateStores(interleaving), queue).reconcile("c1");
        assert(interleaving.beforeNextWrite is null && noticed, "The chain was subscribed when compile ended");
        assert(reconciled.committed && reconciled.passes == 4 && !reconciled.state.dirty);
        assert(taskOf(reconciled.state, "test").status == ChainTaskStatus.queued);
    }
    // 3. The execution ended and its ender crashed before folding: the reconcile's read settles the
    //    ledger (completing the fold) and goes on; the notice the fold wrote waits for a drain
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        auto queue = new InMemoryDispatchQueue();
        createChain(stores, "c1");
        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
        reconcilerOf(stores, queue).reconcile("c1");
        auto current = stores.executions.get(activeOf(stores, "c1", "compile")).get;
        TaskExecution ended = current.value;
        ended.status = ExecutionStatus.succeeded;
        ended.finishedAt = "2026-10-20T11:00:00Z";
        stores.executions.update(current, ended); // and crashed before the fold
        stores.chainStates.markDirty("c1"); // say the sweep found it
        auto reconciled = reconcilerOf(stores, queue).reconcile("c1");
        assert(taskOf(reconciled.state, "compile").status == ChainTaskStatus.succeeded);
        assert(taskOf(reconciled.state, "test").status == ChainTaskStatus.queued);
        assert(ledgerOf(stores, "c1", "compile").pendingNotify == [LedgerNotice("c1", ended.id)]);
    }
}

unittest
{
    // Claim crash windows across chains sharing a fingerprint.
    // 1. Chain c2 claimed compile and crashed before recording it. Chain c1, needing compile too,
    //    records it from its own request and sends it; c2, reconciled later, finds it recorded and
    //    sent, and sends nothing more
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        auto queue = new InMemoryDispatchQueue();
        createChain(stores, "c1");
        createChain(stores, "c2");
        intake(stores, "c2", "r2", ["test"], "2026-10-20T10:00:00Z");
        const needed = evaluateFrom(stores, stores.chainStates.get("c2").get).needed[0];
        const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq); // c2's dispatcher crashed

        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:01Z");
        auto c1 = reconcilerOf(stores, queue).reconcile("c1");
        assert(c1.committed && c1.passes == 1 && taskOf(c1.state, "compile").status == ChainTaskStatus.queued);
        auto execution = stores.executions.get(claimed.executionId).get;
        assert(execution.status == ExecutionStatus.queued && execution.sentAt == fixedNow());
        assert(messagesIn(queue) == [claimed.executionId]);

        auto c2 = reconcilerOf(stores, queue).reconcile("c2");
        assert(c2.committed && taskOf(c2.state, "compile").executionId == claimed.executionId);
        auto compile = ledgerOf(stores, "c1", "compile");
        assert(compile.subscribers == ["c1", "c2"] && compile.executionSeq == 1);
        assert(messagesIn(queue).length == 0);
    }
    // 2. Chain c1 decides compile is needed; before its claim, chain c2 builds compile to success.
    //    c1's claim is superseded (it saw no execution), so compile is built once and c1 reuses it
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        auto queue = new InMemoryDispatchQueue();
        auto c2Chain = createChain(direct, "c2");
        createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        beforeWrite(interleaving, 1, () {
            intake(direct, "c2", "r2", ["compile"], "2026-10-20T10:00:01Z");
            reconcilerOf(direct, queue).reconcile("c2");
            finish(direct, c2Chain, "compile", ExecutionStatus.succeeded);
        });
        auto reconciled = reconcilerOf(new StateStores(interleaving), queue).reconcile("c1");
        assert(interleaving.beforeNextWrite is null);
        auto compile = ledgerOf(direct, "c1", "compile");
        assert(compile.executionSeq == 1 && compile.lastSuccessExecutionId.length > 0, "compile was built once");
        assert(taskOf(reconciled.state, "compile").status == ChainTaskStatus.succeeded);
        assert(taskOf(reconciled.state, "test").status == ChainTaskStatus.queued);
        assert(messagesIn(queue).length == 2, "compile (c2's) and test");
    }
}

unittest
{
    // A chain that cannot wait on an execution (its ledger is at the waiter limit) does not
    // commit: the error propagates and the chain stays dirty, for the sweep to retry
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    createChain(stores, "c1");
    createChain(stores, "c2");
    intake(stores, "c2", "r2", ["test"], "2026-10-20T10:00:00Z");
    reconcilerOf(stores, queue).reconcile("c2");
    const fingerprint = fingerprintNow(stores, "c2", "compile");
    foreach (i; 1 .. maxLedgerWaiters)
    {
        stores.ledgers.subscribe(stores.ledgers.get(fingerprint).get, format("w%s", i));
    }
    assert(stores.ledgers.get(fingerprint).get.subscribers.length == maxLedgerWaiters);

    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:01Z");
    const before = stores.chainStates.get("c1").get;
    assert(throwsA!LedgerWaiterLimitException({ reconcilerOf(stores, queue).reconcile("c1"); }));
    const after = stores.chainStates.get("c1").get;
    assert(after.dirty && after.version_ == before.version_ && after.tasks.length == 0, "Nothing was committed");
    assert(stores.ledgers.get(fingerprint).get.executionSeq == 1, "compile was not dispatched again");
    assert(messagesIn(queue).length == 1);
}

unittest
{
    // Executions that cannot be dispatched do not stop the others: every other one is dispatched,
    // then the failures are reported together and the chain stays dirty; the next reconcile sends
    // what was recorded but not sent
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto queue = new FlakyDispatchQueue();
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test", "lint"], "2026-10-20T10:00:00Z");

    queue.failSends = 1;
    const before = stores.chainStates.get("c1").get;
    try
    {
        reconcilerOf(stores, queue).reconcile("c1");
        assert(false, "A failed send must be reported");
    }
    catch (ChainReconcileException e)
    {
        assert(e.chainId == "c1" && e.failures.length == 1 && e.msg.canFind("unavailable") && e.msg.canFind("stays dirty"));
        assert(e.next !is null && e.next.msg == "The dispatch queue is unavailable", "The one failure is chained as the cause");
    }
    assert(stores.chainStates.get("c1").get.version_ == before.version_);
    auto sent = messagesIn(queue);
    assert(sent.length == 1, "The other needed execution was dispatched");
    string[] active = [activeOf(stores, "c1", "compile"), activeOf(stores, "c1", "lint")];
    assert(active[0].length > 0 && active[1].length > 0, "Both were claimed and recorded");

    auto reconciled = reconcilerOf(new StateStores(documents.restart()), queue).reconcile("c1");
    assert(reconciled.committed && reconciled.passes == 1 && !reconciled.state.dirty);
    auto resent = messagesIn(queue);
    assert(resent.length == 1 && !sent.canFind(resent[0]) && active.canFind(resent[0]));

    // A task that cannot be recorded (its repository has no address) is reported before anything
    // is claimed for it, and the chain stays dirty until the repository is fixed
    RepositoryRecord addressless;
    addressless.name = "game";
    stores.repositories.put(addressless);
    stores.rerunGenerations.bump(closureNow(stores, stores.chains.get("c1").get.value, ["compile"]).bases["compile"]);
    stores.chainStates.markDirty("c1"); // the rerun reaches the chain
    try
    {
        reconcilerOf(stores, queue).reconcile("c1");
        assert(false, "An undispatchable task must be reported");
    }
    catch (ChainReconcileException e)
    {
        assert(e.failures.length == 1 && e.failures[0].canFind("compile") && e.failures[0].canFind("no address"));
        assert(cast(UndispatchableExecutionException) e.next !is null, "The cause keeps its type");
    }
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull && stores.chainStates.get("c1").get.dirty);
    addressless.address = gameAddress;
    stores.repositories.put(addressless);
    auto fixed = reconcilerOf(stores, queue).reconcile("c1");
    assert(fixed.committed && taskOf(fixed.state, "compile").status == ChainTaskStatus.queued);
}
