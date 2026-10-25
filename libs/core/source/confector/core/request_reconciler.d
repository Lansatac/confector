module confector.core.request_reconciler;

/**
 * The request reconciler (AGENTS.md, "Coordinating builds"): the imperative shell that brings one
 * request up to date. It reads everything by id, evaluates with the pure request evaluator
 * (confector.core.request_evaluator), has the execution dispatcher
 * (confector.core.execution_dispatcher) dispatch what is needed and repair what the request waits
 * on, and commits the evaluation to the request's RequestState (confector.core.request_state). It
 * keeps no state between calls, so it works the same after a restart, in a short-lived function,
 * and with any number of reconcilers of one request at once. Reconciling is level-triggered: it
 * does not matter what made it run, only what the stores hold now, and every step is idempotent.
 *
 * One pass, repeated until a pass commits:
 *
 * 1. Read the RequestState by id. If the request is settled, nothing more can change: stop. The
 *    state is read before anything else, so a concurrent reconcile that commits after this read
 *    changes its version and makes step 5 fail.
 * 2. Read by id the request, its definition, its chain, the rerun generations, and each
 *    fingerprint's ledger, settled (completing a half-finished fold), with the executions it
 *    names. Evaluate.
 * 3. If anything is needed, dispatch each (whatever a claim finds) and start the next pass: an
 *    evaluation that still needs executions is never committed.
 * 4. For each execution the request awaits, have the dispatcher record it if it was never
 *    recorded. If one has ended since the evaluation, start the next pass.
 * 5. Commit the evaluation by compare-and-set at the RequestState version read in step 1, which
 *    settles the request once every target has. If the state changed since
 *    (DocumentConflictException), start the next pass.
 *
 * A needed execution that cannot be recorded (UndispatchableExecutionException: say, a repository
 * input without an address) settles the request failed, with the error in its RequestState,
 * instead of being retried on every look: the user fixes the cause and requests again. Every other
 * needed execution is dispatched first.
 *
 * Other failures leave the state as it was, so the request is reconciled again later and the
 * error stays visible:
 *
 * - A needed execution that cannot be dispatched does not stop the others: every other needed
 *   execution is dispatched first, then RequestReconcileException names each failure, and nothing
 *   is committed. The same holds for awaited executions that cannot be recorded.
 * - A request without a RequestState fails with RequestStateMissingException: create it
 *   (`RequestStateStore.createFor`), then reconcile.
 */

import confector.core.document_collection : Versioned;
import confector.core.execution_dispatcher : ExecutionDispatcher, UndispatchableExecutionException;
import confector.core.request_evaluator;
import confector.core.request_state : RequestStateMissingException;
import confector.core.state_stores : StateStores;
import confector.api.document_store : DocumentConflictException;
import confector.api.model;

import std.format : format;
import vibe.core.log : logError;

/**
 * A reconcile could not finish: some executions could not be dispatched or recorded. Every
 * other one was handled first; nothing was committed.
 */
class RequestReconcileException : Exception
{
    string requestId;
    /// One line per execution that failed, naming its task, fingerprint and the cause.
    string[] failures;

    /// `cause`, when exactly one execution failed, is that failure, chained so its type and trace
    /// are kept.
    this(string requestId, string[] failures, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(format("Request '%s' could not be reconciled:\n- %-(%s\n- %)", requestId, failures), file, line, cause);
        this.requestId = requestId;
        this.failures = failures;
    }
}

/// The result of `RequestReconciler.reconcile`.
struct Reconciled
{
    /// The RequestState as committed, or as read when nothing changed.
    Versioned!RequestState state;
    /// How many passes it took (each pass after the first was forced by something the previous one
    /// found or lost: a dispatch, an ended execution, a conflicting RequestState).
    size_t passes;
    /// Whether this call wrote the RequestState; false when the request was settled when read or
    /// the evaluation changed nothing.
    bool committed;
}

/**
 * Reconciles requests. See the module documentation.
 */
final class RequestReconciler
{
    /// How many passes one reconcile makes before failing. Each pass after the first was forced by
    /// a write that landed (a dispatch, which happens at most once per task and rerun generation,
    /// an execution ending or a concurrent reconcile), so this is reached only under sustained
    /// contention on one request.
    enum maxPasses = 100;

    private StateStores m_stores;
    private ExecutionDispatcher m_dispatcher;

    /// Reconciles requests in `stores`, dispatching through `dispatcher`.
    this(StateStores stores, ExecutionDispatcher dispatcher)
    {
        if (stores is null) throw new Exception("The request reconciler requires the state stores");
        if (dispatcher is null) throw new Exception("The request reconciler requires the execution dispatcher");
        m_stores = stores;
        m_dispatcher = dispatcher;
    }

    /**
     * Reconciles request `requestId` until a pass commits or finds it settled. See the module
     * documentation.
     *
     * Throws: RequestStateMissingException if the request has no RequestState;
     * RequestReconcileException if executions could not be dispatched; Exception if the request, its
     * definition or its chain does not exist, or maxPasses passes did not commit; whatever the
     * evaluator and the stores throw.
     */
    Reconciled reconcile(string requestId)
    {
        foreach (pass; 1 .. maxPasses + 1)
        {
            auto found = m_stores.requestStates.get(requestId);
            if (found.isNull)
            {
                throw new RequestStateMissingException(format(
                    "Request '%s' has no request state, so it cannot be reconciled; create it from the request", requestId), requestId);
            }
            auto read = found.get;
            if (read.outcome != RequestOutcome.open) return Reconciled(read, pass, false);

            auto entry = definedRequest(requestId);
            auto chain = m_stores.chains.get(entry.request.chainId);
            if (chain.isNull) throw new Exception(format("Request '%s' belongs to chain '%s', which does not exist", requestId, entry.request.chainId));
            auto evaluation = evaluate(chain.get.value, entry);

            Handled handled;
            if (evaluation.needed.length > 0) dispatchNeeded(evaluation, entry, handled);
            else repairAwaited(evaluation, entry, handled);

            if (handled.unrecordable.length == 0)
            {
                if (handled.failures.length > 0)
                {
                    throw new RequestReconcileException(requestId, handled.failures, handled.failures.length == 1 ? handled.cause : null);
                }
                // What was dispatched or has ended is evaluated again before anything is committed
                if (evaluation.needed.length > 0 || handled.ended) continue;
            }

            try
            {
                if (handled.unrecordable.length > 0)
                {
                    // Cache what this pass left behind (claimed executions), and keep the
                    // dispatch failures in the error beside the unrecordable ones
                    auto settled = evaluate(chain.get.value, entry);
                    const error = format("%-(%s
%)", handled.unrecordable ~ handled.failures);
                    return Reconciled(m_stores.requestStates.fail(read, settled, error), pass, true);
                }
                auto committed = m_stores.requestStates.commit(read, evaluation);
                return Reconciled(committed, pass, committed.version_ != read.version_);
            }
            catch (DocumentConflictException)
            {
                // Another reconcile committed since the state was read: reconcile again.
            }
        }
        throw new Exception(format("Request '%s' was not reconciled: %s passes in a row were overtaken by other writes",
            requestId, maxPasses));
    }

    /// What dispatching and repairing found.
    private struct Handled
    {
        /// Executions that can never be recorded as the request stands: one line each.
        string[] unrecordable;
        /// Executions that could not be dispatched or recorded, one line each, and the last cause.
        string[] failures;
        Exception cause;
        /// Whether an awaited execution has ended since the evaluation.
        bool ended;
    }

    /// Dispatches every execution `evaluation` needs; a failure does not stop the others.
    private void dispatchNeeded(in RequestEvaluation evaluation, in DefinedRequest entry, ref Handled handled)
    {
        foreach (ref needed; evaluation.needed)
        {
            try m_dispatcher.dispatch(needed, entry);
            catch (UndispatchableExecutionException e)
            {
                handled.unrecordable ~= format("task '%s' at fingerprint %s: %s", needed.taskId, needed.fingerprint, e.msg);
            }
            catch (Exception e)
            {
                handled.failures ~= format("task '%s' at fingerprint %s: %s", needed.taskId, needed.fingerprint, e.msg);
                handled.cause = e;
            }
        }
    }

    /// Has the dispatcher record each execution `evaluation` awaits that has no record; a failure
    /// does not stop the others.
    private void repairAwaited(in RequestEvaluation evaluation, in DefinedRequest entry, ref Handled handled)
    {
        foreach (ref awaited; evaluation.awaited)
        {
            try
            {
                if (m_dispatcher.repair(awaited, entry)) handled.ended = true;
            }
            catch (UndispatchableExecutionException e)
            {
                handled.unrecordable ~= format("task '%s' at fingerprint %s (execution '%s'): %s", awaited.taskId, awaited.fingerprint,
                    awaited.executionId, e.msg);
            }
            catch (Exception e)
            {
                handled.failures ~= format("task '%s' at fingerprint %s (execution '%s'): %s", awaited.taskId, awaited.fingerprint,
                    awaited.executionId, e.msg);
                handled.cause = e;
            }
        }
    }

    /// Request `requestId` with the definition it runs with, read by id.
    private DefinedRequest definedRequest(string requestId)
    {
        auto request = m_stores.requests.get(requestId);
        if (request.isNull) throw new Exception(format("Request '%s' has a request state but does not exist", requestId));
        auto definition = m_stores.definitions.get(request.get.definitionId);
        if (definition.isNull)
        {
            throw new Exception(format("Definition '%s' of request '%s' does not exist", request.get.definitionId, requestId));
        }
        return DefinedRequest(request.get.value, definition.get);
    }

    /// Evaluates `entry` on `chain` from the generations and ledgers, read by id now.
    private RequestEvaluation evaluate(in BuildChain chain, in DefinedRequest entry)
    {
        auto generations = readRequestGenerations(chain, entry, (in string[] bases) => m_stores.rerunGenerations.read(bases));
        LedgerSummary[string] summaries;
        foreach (fingerprint; requestFingerprints(chain, entry, generations))
        {
            summaries[fingerprint] = readLedgerSummary(m_stores.ledgers, m_stores.executions, fingerprint);
        }
        return evaluateRequest(chain, entry, generations, summaries);
    }
}

/// What reconciling the open requests of one project did.
struct ProjectReconciliation
{
    /// Requests reconciled without error, whether or not the reconcile changed them.
    size_t reconciled;
    /// Requests whose reconcile failed, and one for a listing of the project's open requests that failed.
    size_t errors;
}

/**
 * Reconciles every open request of `projectId` at the clock `now`, each on its own. A request
 * whose reconcile fails is logged with its error and counted, and the others are still reconciled;
 * a request left open is reconciled again by a later call. Used when an execution of the project
 * ends, and by the coordination sweep.
 */
ProjectReconciliation reconcileOpenRequests(StateStores stores, string projectId, string now)
{
    ProjectReconciliation result;
    RequestState[] open;
    try open = stores.requestStates.listOpen(projectId);
    catch (Exception e)
    {
        logError("[reconcile] Could not list the open requests of project '%s': %s", projectId, e.toString());
        result.errors += 1;
        return result;
    }
    auto reconciler = new RequestReconciler(stores, new ExecutionDispatcher(stores, () => now));
    foreach (state; open)
    {
        try
        {
            reconciler.reconcile(state.requestId);
            result.reconciled += 1;
        }
        catch (Exception e)
        {
            logError("[reconcile] Could not reconcile request '%s' of project '%s': %s", state.requestId, projectId, e.toString());
            result.errors += 1;
        }
    }
    return result;
}

version (unittest)
{
    import confector.core.request_fixtures;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import std.algorithm.searching : canFind;

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

    /// The ids of the queued executions, as the active index lists them.
    private string[] queuedIds(StateStores stores)
    {
        string[] ids;
        foreach (execution; stores.executions.listActive(ExecutionStatus.queued, 100)) ids ~= execution.id;
        return ids;
    }
}

unittest
{
    // A request is reconciled to the end by repeated reconciles: each dispatches what is needed
    // (then evaluates again) and commits what it found; a reconcile that finds nothing new writes
    // nothing; a settled request is left alone
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto reconciler = reconcilerOf(stores);
    auto chain = createChain(stores, "c1");
    intake(stores, "c1", "r1", ["report"], "2026-10-20T10:00:00Z");

    auto first = reconciler.reconcile("r1");
    assert(first.committed && first.passes == 2 && first.state.outcome == RequestOutcome.open);
    assert(taskOf(first.state, "compile").status == RequestTaskStatus.queued);
    assert(taskOf(first.state, "test").status == RequestTaskStatus.waitingUpstream);
    assert(queuedIds(stores) == [activeOf(stores, "c1", "compile")]);

    auto unchanged = reconciler.reconcile("r1");
    assert(!unchanged.committed && unchanged.passes == 1 && unchanged.state.version_ == first.state.version_,
        "Nothing new, nothing written");

    foreach (taskId; ["compile", "test", "report"])
    {
        if (taskId != "compile")
        {
            auto next = reconciler.reconcile("r1");
            assert(next.committed && taskOf(next.state, taskId).status == RequestTaskStatus.queued);
            assert(queuedIds(stores) == [activeOf(stores, "c1", taskId)]);
        }
        finish(stores, chain, taskId, ExecutionStatus.succeeded);
    }
    auto done = reconciler.reconcile("r1");
    assert(done.committed && done.state.outcome == RequestOutcome.succeeded);
    foreach (taskId; ["compile", "test", "report"]) assert(taskOf(done.state, taskId).status == RequestTaskStatus.succeeded);
    assert(stores.requestStates.listOpen("game").length == 0, "A settled request leaves the open index");

    auto settled = reconciler.reconcile("r1");
    assert(!settled.committed && settled.passes == 1 && settled.state.version_ == done.state.version_);
    assert(queuedIds(stores).length == 0);

    // A request without a state fails loudly; so does a reconciler without its parts
    recordRequest(stores, "c1", "r2", ["lint"], "2026-10-20T10:00:01Z");
    assert(throwsA!RequestStateMissingException({ reconciler.reconcile("r2"); }));
    assert(throwsA!Exception({ new RequestReconciler(null, dispatcherOf(stores)); }));
    assert(throwsA!Exception({ new RequestReconciler(stores, null); }));
}

unittest
{
    // The RequestState compare-and-set loop. A reconcile that loses the commit to another
    // reconcile of the same request reads again and evaluates again; whichever write of the first
    // reconcile the second overtakes, the request ends with one execution per fingerprint
    foreach (overtakenAt; [1, 2, 3])
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        Reconciled other;
        // The first reconciler's writes: 1 claim, 2 record, 3 commit; the second reconciles
        // completely just before the chosen one
        beforeWrite(interleaving, overtakenAt, () { other = reconcilerOf(direct).reconcile("r1"); });
        auto reconciled = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
        assert(interleaving.beforeNextWrite is null);
        assert(other.committed, format("overtaken at write %s: the second reconciler commits", overtakenAt));
        assert(!reconciled.committed, format("overtaken at write %s: the first finds nothing new", overtakenAt));

        auto state = direct.requestStates.get("r1").get;
        assert(state.outcome == RequestOutcome.open && taskOf(state, "compile").status == RequestTaskStatus.queued);
        auto compile = ledgerOf(direct, "c1", "compile");
        assert(compile.executionSeq == 1, format("overtaken at write %s", overtakenAt));
        assert(queuedIds(direct) == [compile.activeExecutionId], format("overtaken at write %s", overtakenAt));
    }
}

unittest
{
    // An execution that ends between the evaluation and the commit does not make the commit
    // fail: the committed state is a little stale and the next reconcile moves on from the
    // ledger, which is what the stores guarantee fresh
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto chain = createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    auto interleaving = new InterleavingDocumentStore(documents);
    // Writes: 1 claim, 2 record, 3 commit
    beforeWrite(interleaving, 3, () { finish(direct, chain, "compile", ExecutionStatus.succeeded); });
    auto reconciled = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
    assert(interleaving.beforeNextWrite is null);
    assert(reconciled.committed && taskOf(reconciled.state, "compile").status == RequestTaskStatus.queued);

    auto next = reconcilerOf(direct).reconcile("r1");
    assert(taskOf(next.state, "compile").status == RequestTaskStatus.succeeded);
    assert(taskOf(next.state, "test").status == RequestTaskStatus.queued, "The request must not end stuck");
}

unittest
{
    // Reconcilers of one request on several threads at once (as several server instances would)
    // converge: each needed fingerprint is claimed and recorded once
    import core.thread : Thread;
    import core.atomic : atomicOp;

    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test", "lint"], "2026-10-20T10:00:00Z");

    Thread[] threads;
    shared int failures;
    foreach (i; 0 .. 4)
    {
        threads ~= new Thread({
            try reconcilerOf(new StateStores(documents.restart())).reconcile("r1");
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

    foreach (taskId; ["compile", "lint"]) assert(ledgerOf(direct, "c1", taskId).executionSeq == 1);
    auto queued = queuedIds(direct);
    assert(queued.length == 2 && queued.canFind(activeOf(direct, "c1", "compile")) && queued.canFind(activeOf(direct, "c1", "lint")));
}

unittest
{
    // A reconcile after a restart needs nothing from the process that crashed, whichever step it
    // crashed after: the claim or the record
    import confector.core.execution_dispatcher : executionFor;

    foreach (crashedAfter; ["claim", "record"])
    {
        auto documents = new InMemoryDocumentStore();
        auto stores = new StateStores(documents);
        createChain(stores, "c1");
        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
        const needed = evaluateFrom(stores, "r1").needed[0];

        const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq);
        if (crashedAfter == "record")
        {
            stores.executions.createIfAbsent(executionFor(claimed.executionId, needed.taskId, needed.fingerprint, needed.inputs,
                definedRequest(stores, "r1"), ["game": RepositoryRecord("game", gameAddress)], fixedNow()));
        }

        // A new process: new stores over the same database, a new reconciler, nothing else
        auto restarted = new StateStores(documents.restart());
        auto reconciled = reconcilerOf(restarted).reconcile("r1");
        assert(reconciled.committed && reconciled.passes == 1, crashedAfter);
        assert(taskOf(reconciled.state, "compile").status == RequestTaskStatus.queued, crashedAfter);
        assert(ledgerOf(restarted, "c1", "compile").executionSeq == 1, crashedAfter);
        assert(restarted.executions.get(claimed.executionId).get.status == ExecutionStatus.queued, crashedAfter);
        assert(queuedIds(restarted) == [claimed.executionId], crashedAfter);
    }
}

unittest
{
    // Two requests sharing one execution. 1. Request r2 claimed compile and crashed before
    // recording it. Request r1, needing compile too, records it from its own request; r2,
    // reconciled later, finds it recorded. Both then advance on the one execution's outcome
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        auto c1 = createChain(stores, "c1");
        createChain(stores, "c2");
        intake(stores, "c2", "r2", ["test"], "2026-10-20T10:00:00Z");
        const needed = evaluateFrom(stores, "r2").needed[0];
        const claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq); // r2's dispatcher crashed

        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:01Z");
        auto first = reconcilerOf(stores).reconcile("r1");
        assert(first.committed && first.passes == 1 && taskOf(first.state, "compile").status == RequestTaskStatus.queued);
        assert(stores.executions.get(claimed.executionId).get.status == ExecutionStatus.queued);
        assert(queuedIds(stores) == [claimed.executionId]);

        auto second = reconcilerOf(stores).reconcile("r2");
        assert(second.committed && taskOf(second.state, "compile").executionId == claimed.executionId);
        assert(ledgerOf(stores, "c1", "compile").executionSeq == 1 && queuedIds(stores) == [claimed.executionId]);

        finish(stores, c1, "compile", ExecutionStatus.succeeded);
        foreach (requestId; ["r1", "r2"])
        {
            auto advanced = reconcilerOf(stores).reconcile(requestId);
            assert(taskOf(advanced.state, "compile").status == RequestTaskStatus.succeeded, requestId);
            assert(taskOf(advanced.state, "test").status == RequestTaskStatus.queued, requestId);
        }
        assert(ledgerOf(stores, "c1", "test").executionSeq == 1, "test is built once for both requests");
    }
    // 2. Request r1 decides compile is needed; before its claim, request r2 builds compile to
    //    success. r1's claim is superseded (it saw no execution), so compile is built once and r1
    //    reuses it
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        auto c2 = createChain(direct, "c2");
        createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        beforeWrite(interleaving, 1, () {
            intake(direct, "c2", "r2", ["compile"], "2026-10-20T10:00:01Z");
            reconcilerOf(direct).reconcile("r2");
            finish(direct, c2, "compile", ExecutionStatus.succeeded);
        });
        auto reconciled = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
        assert(interleaving.beforeNextWrite is null);
        auto compile = ledgerOf(direct, "c1", "compile");
        assert(compile.executionSeq == 1 && compile.lastSuccessExecutionId.length > 0, "compile was built once");
        assert(taskOf(reconciled.state, "compile").status == RequestTaskStatus.succeeded);
        assert(taskOf(reconciled.state, "test").status == RequestTaskStatus.queued);
        assert(queuedIds(direct) == [activeOf(direct, "c1", "test")]);
    }
}

unittest
{
    // Executions that cannot be dispatched do not stop the others: every other one is dispatched,
    // then the failures are reported together and nothing is committed; the next reconcile
    // dispatches what is still needed
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test", "lint"], "2026-10-20T10:00:00Z");

    // The first write, compile's claim, fails: the store is unavailable for it
    auto interleaving = new InterleavingDocumentStore(documents);
    beforeWrite(interleaving, 1, () { throw new Exception("The store is unavailable"); });
    const before = stores.requestStates.get("r1").get;
    try
    {
        reconcilerOf(new StateStores(interleaving)).reconcile("r1");
        assert(false, "A failed dispatch must be reported");
    }
    catch (RequestReconcileException e)
    {
        assert(e.requestId == "r1" && e.failures.length == 1 && e.msg.canFind("unavailable"));
        assert(e.next !is null && e.next.msg == "The store is unavailable", "The one failure is chained as the cause");
    }
    assert(stores.requestStates.get("r1").get.version_ == before.version_, "Nothing was committed");
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull, "compile was not claimed");
    assert(activeOf(stores, "c1", "lint").length > 0, "The other needed execution was dispatched");

    auto reconciled = reconcilerOf(new StateStores(documents.restart())).reconcile("r1");
    assert(reconciled.committed && reconciled.state.outcome == RequestOutcome.open);
    assert(taskOf(reconciled.state, "compile").status == RequestTaskStatus.queued);
    assert(taskOf(reconciled.state, "lint").status == RequestTaskStatus.queued);
}

unittest
{
    // A needed execution that cannot be recorded (its repository has no address) settles the
    // request failed, with the error in its RequestState; nothing is claimed for it and it is
    // not retried by later reconciles. A new request, once the repository is fixed, runs
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    RepositoryRecord addressless;
    addressless.name = "game";
    stores.repositories.put(addressless);
    auto failed = reconcilerOf(stores).reconcile("r1");
    assert(failed.committed && failed.state.outcome == RequestOutcome.failed);
    assert(failed.state.error.canFind("compile") && failed.state.error.canFind("no address"), failed.state.error);
    assert(taskOf(failed.state, "compile").status == RequestTaskStatus.needed);
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull, "Nothing was claimed");
    assert(stores.requestStates.listOpen("game").length == 0);

    addressless.address = gameAddress;
    stores.repositories.put(addressless);
    auto again = reconcilerOf(stores).reconcile("r1");
    assert(!again.committed && again.state.outcome == RequestOutcome.failed, "A failed request is not retried by the next look");
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull);

    intake(stores, "c1", "r2", ["test"], "2026-10-20T10:00:01Z");
    auto retry = reconcilerOf(stores).reconcile("r2");
    assert(retry.state.outcome == RequestOutcome.open && retry.state.error.length == 0);
    assert(taskOf(retry.state, "compile").status == RequestTaskStatus.queued);

    // An unregistered repository fails an awaited execution the same way: it was claimed by a
    // dispatcher that crashed before recording it, and cannot be recorded from this request
    auto other = new StateStores(new InMemoryDocumentStore());
    createChain(other, "c1");
    intake(other, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    const needed = evaluateFrom(other, "r1").needed[0];
    const claimed = other.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq);
    other.repositories.remove("game");
    auto unrecorded = reconcilerOf(other).reconcile("r1");
    assert(unrecorded.state.outcome == RequestOutcome.failed);
    assert(unrecorded.state.error.canFind(claimed.executionId) && unrecorded.state.error.canFind("not registered"), unrecorded.state.error);
}

unittest
{
    // An unrecordable execution and a failed dispatch in one pass: the request fails with both
    // in its error, and its cached tasks show what the pass did (compile, whose claim failed, and
    // lint, which cannot be recorded, both still need an execution)
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto chain = sampleChain("c1");
    chain.pins ~= RepositoryPin("tools", chain.pins[0].ref_, chain.pins[0].pin);
    RepositoryRecord game;
    game.name = "game";
    game.address = gameAddress;
    stores.repositories.put(game);
    RepositoryRecord tools;
    tools.name = "tools";
    stores.repositories.put(tools);
    stores.chains.create(chain);
    auto definition = sampleDefinition();
    definition.tasks[3].inputs["src"] = repositoryInput("tools");
    intake(stores, "c1", "r1", ["test", "lint"], "2026-10-20T10:00:00Z", definition);

    // The first write, compile's claim, fails: the store is unavailable for it
    auto interleaving = new InterleavingDocumentStore(documents);
    beforeWrite(interleaving, 1, () { throw new Exception("The store is unavailable"); });
    auto failed = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
    assert(failed.state.outcome == RequestOutcome.failed);
    assert(failed.state.error.canFind("no address") && failed.state.error.canFind("unavailable"), failed.state.error);
    assert(taskOf(failed.state, "compile").status == RequestTaskStatus.needed, "compile was not claimed");
    assert(taskOf(failed.state, "lint").status == RequestTaskStatus.needed);
}
