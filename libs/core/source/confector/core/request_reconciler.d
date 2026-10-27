module confector.core.request_reconciler;

/**
 * The request reconciler (AGENTS.md, "Coordinating builds"): the imperative shell that brings one
 * request up to date. It reads everything by id, evaluates with the pure request evaluator
 * (confector.core.request_evaluator), dispatches what is needed, and commits the evaluation to the
 * request's state (confector.core.request_state). It keeps no state between calls, so it
 * works the same after a restart, in a short-lived function, and with any number of reconcilers of
 * one request at once. Reconciling is level-triggered: it does not matter what made it run, only
 * what the stores hold now, and every step is idempotent.
 *
 * One pass, repeated until a pass commits:
 *
 * 1. Read the request by id. If it is settled, nothing more can change: stop. The request is read
 *    before anything else, so a concurrent reconcile that commits after this read changes its
 *    version and makes step 4 fail.
 * 2. Read by id its definition, the rerun generations, and each fingerprint's ledger, settled
 *    (completing a half-finished fold), with the finished executions it names. Evaluate. A request
 *    that cannot be evaluated as recorded settles failed here (see below).
 * 3. If anything is needed, dispatch each (whatever a claim finds) and start the next pass: an
 *    evaluation that still needs executions is never committed.
 * 4. Commit the evaluation's state by compare-and-set at the version read in step 1
 *    (BuildRequestStore.replaceState), which settles the request once every target has. If the
 *    request changed since (DocumentConflictException), start the next pass.
 *
 * Dispatching a needed fingerprint F (`dispatch`) is one compare-and-set on F's ledger
 * (confector.core.fingerprint_ledger):
 *
 * 1. Build the execution to claim from the request's definition, the task's resolved inputs and
 *    the registered repository addresses. A task that cannot be built (its repository is not
 *    registered or has no address) fails loudly here, before anything is written, so it never
 *    holds the fingerprint.
 * 2. `LedgerStore.claim(F, seen, ...)`, with `seen` the ledger's `executionSeq` as the evaluation
 *    read it (NeededExecution.seenExecutionSeq), so a decision made before another execution
 *    started and ended never builds F twice. Losing (another execution is active, or one was
 *    claimed since the evaluation read the ledger) writes nothing: the next evaluation waits on,
 *    or reuses, what it finds.
 *
 * A needed execution that cannot be built (UndispatchableExecutionException: say, a repository
 * input without an address) settles the request failed, with the error in its state,
 * instead of being retried on every look: the user fixes the cause and requests again. Every other
 * needed execution is dispatched first.
 *
 * A request that can never progress as recorded settles failed the same way, with the error in its
 * state: its definition is missing, or evaluating it fails on what it recorded
 * (RequestEvaluationException, InputResolutionException). It is not retried on every look; the user
 * fixes the cause and requests again. A store error is not of that kind: it leaves the request open,
 * and the next reconcile tries again.
 *
 * Other failures leave the state as it was, so the request is reconciled again later and the
 * error stays visible:
 *
 * - A needed execution that cannot be dispatched does not stop the others: every other needed
 *   execution is dispatched first, then RequestReconcileException names each failure, and nothing
 *   is committed.
 */

import confector.core.document_collection : Page, Versioned;
import confector.core.fingerprint_ledger : ClaimOutcome;
import confector.core.input_resolution : InputResolutionException;
import confector.core.request_evaluator;
import confector.core.request_state : withEvaluation, withFailure;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : utcNow;
import confector.api.document_store : DocumentConflictException;
import confector.api.model;

import std.algorithm.sorting : sort;
import std.format : format;
import vibe.core.log : logError;

/**
 * An execution cannot be built for a task: the request's definition lacks the task, or a
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

/**
 * The definition a request runs with does not exist in the definition store, so the request cannot
 * be evaluated. Nothing was written.
 */
class MissingDefinitionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The result of `RequestReconciler.dispatch`.
struct Dispatched
{
    /// What the claim found: won (this call claimed the execution), active (another execution is
    /// active) or superseded (an execution was claimed since the evaluation read the ledger). On
    /// every outcome the caller evaluates again.
    ClaimOutcome claim;
    /// won and active: the fingerprint's active execution; superseded: empty.
    string executionId;
}

/**
 * The execution to claim for task `taskId` of `request`: the stored definition of the request,
 * `inputs`, the address of each repository input from `repositories` (keyed by repository id), and
 * `createdAt` = `now`. Pure.
 *
 * Throws: UndispatchableExecutionException if the definition lacks the task, or a repository
 * input names a repository missing from `repositories` or without an address.
 */
ActiveExecution activeExecutionFor(string taskId, in ResolvedInput[] inputs, in DefinedRequest request,
    in RepositoryRecord[string] repositories, string now) @trusted
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

    ActiveExecution active;
    active.projectId = request.request.projectId;
    active.taskId = taskId;
    active.definitionId = request.request.definitionId;
    active.inputs = (cast(ResolvedInput[]) inputs).dup;
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
        active.repositoryAddresses[name] = repository.address;
    }
    active.createdAt = now;
    return active;
}

/**
 * A reconcile could not finish: some executions could not be dispatched. Every
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
    /// The request as committed, or as read when nothing changed.
    Versioned!BuildRequest request;
    /// How many passes it took (each pass after the first was forced by something the previous one
    /// found or lost: a dispatch, an ended execution, a conflicting write of the request).
    size_t passes;
    /// Whether this call wrote the request's state; false when the request was settled when read or
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
    private string delegate() m_now;

    /**
     * Reconciles requests in `stores`. `now` gives the current time for the executions it claims
     * (default `utcNow`); tests pass a fixed clock.
     *
     * Throws: Exception if `stores` is null.
     */
    this(StateStores stores, string delegate() now = null)
    {
        if (stores is null) throw new Exception("The request reconciler requires the state stores");
        m_stores = stores;
        m_now = now !is null ? now : () => utcNow();
    }

    /**
     * Reconciles request `requestId` until a pass commits or finds it settled. See the module
     * documentation.
     *
     * Throws: RequestReconcileException if executions could not be dispatched; Exception if the
     * request does not exist or maxPasses passes did not commit; whatever the stores throw; and what
     * the evaluator throws other than the errors that settle an unevaluable request failed (see the
     * module documentation).
     */
    Reconciled reconcile(string requestId)
    {
        foreach (pass; 1 .. maxPasses + 1)
        {
            auto found = m_stores.requests.get(requestId);
            if (found.isNull) throw new Exception(format("Request '%s' does not exist, so it cannot be reconciled", requestId));
            auto read = found.get;
            if (read.outcome != RequestOutcome.open) return Reconciled(read, pass, false);

            auto evaluated = evaluateRecorded(read.value);
            if (evaluated.unevaluable)
            {
                try return Reconciled(m_stores.requests.replaceState(read, withFailure(read.value, evaluated.error)), pass, true);
                catch (DocumentConflictException)
                {
                    // Another reconcile committed since the state was read: reconcile again.
                    continue;
                }
            }
            const entry = evaluated.entry;
            const evaluation = evaluated.evaluation;

            Handled handled;
            if (evaluation.needed.length > 0) dispatchNeeded(evaluation, entry, handled);

            if (handled.undispatchable.length == 0)
            {
                if (handled.failures.length > 0)
                {
                    throw new RequestReconcileException(requestId, handled.failures, handled.failures.length == 1 ? handled.cause : null);
                }
                // What was dispatched is evaluated again before anything is committed
                if (evaluation.needed.length > 0) continue;
            }

            try
            {
                if (handled.undispatchable.length > 0)
                {
                    // Cache what this pass left behind (claimed executions), and keep the
                    // dispatch failures in the error beside the undispatchable ones
                    auto settled = evaluate(entry);
                    const error = format("%-(%s
%)", handled.undispatchable ~ handled.failures);
                    return Reconciled(m_stores.requests.replaceState(read, withFailure(read.value, settled, error)), pass, true);
                }
                auto committed = m_stores.requests.replaceState(read, withEvaluation(read.value, evaluation));
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

    /// What dispatching found.
    private struct Handled
    {
        /// Executions that can never be built as the request stands: one line each.
        string[] undispatchable;
        /// Executions that could not be dispatched, one line each, and the last cause.
        string[] failures;
        Exception cause;
    }

    /**
     * Dispatches the execution `needed` asks for, for `request` (with its definition): builds the
     * execution to claim, then claims the fingerprint at the `executionSeq` the evaluation saw, in
     * one compare-and-set. See Dispatched; whatever the outcome, the caller evaluates again before
     * committing.
     *
     * Throws: UndispatchableExecutionException (nothing written) if the execution cannot be
     * built; whatever the stores throw.
     */
    Dispatched dispatch(in NeededExecution needed, in DefinedRequest request)
    {
        // Built before claiming, so a task that cannot be built never holds the fingerprint
        auto proposed = activeExecutionFor(needed.taskId, needed.inputs, request, repositoriesOf(needed.taskId, request), m_now());
        auto claimed = m_stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq, proposed);
        final switch (claimed.outcome)
        {
            case ClaimOutcome.won:
            case ClaimOutcome.active:
                return Dispatched(claimed.outcome, claimed.executionId);
            case ClaimOutcome.superseded:
                return Dispatched(ClaimOutcome.superseded, null);
        }
    }

    /// The registered repositories the repository inputs of task `taskId` in `request`'s
    /// definition name, read by id; missing ones are left out (`activeExecutionFor` reports them).
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

    /// Dispatches every execution `evaluation` needs; a failure does not stop the others.
    private void dispatchNeeded(in RequestEvaluation evaluation, in DefinedRequest entry, ref Handled handled)
    {
        foreach (ref needed; evaluation.needed)
        {
            try dispatch(needed, entry);
            catch (UndispatchableExecutionException e)
            {
                handled.undispatchable ~= format("task '%s' at fingerprint %s: %s", needed.taskId, needed.fingerprint, e.msg);
            }
            catch (Exception e)
            {
                handled.failures ~= format("task '%s' at fingerprint %s: %s", needed.taskId, needed.fingerprint, e.msg);
                handled.cause = e;
            }
        }
    }

    /// What reading and evaluating a request found: the evaluation, or the error that makes the
    /// request unevaluable (its definition is missing, or evaluating it fails on what it recorded).
    private struct Evaluated
    {
        DefinedRequest entry;
        RequestEvaluation evaluation;
        bool unevaluable;
        string error;
    }

    /// Reads the definition of `request` and evaluates it. Only the errors that can never change
    /// for the request as recorded are caught: they settle it (see the module documentation). Store
    /// errors and anything else propagate, and leave the request open.
    private Evaluated evaluateRecorded(BuildRequest request)
    {
        Evaluated result;
        try
        {
            result.entry = definedRequest(request);
            result.evaluation = evaluate(result.entry);
        }
        catch (MissingDefinitionException e)
        {
            result.unevaluable = true;
            result.error = e.msg;
        }
        catch (RequestEvaluationException e)
        {
            result.unevaluable = true;
            result.error = e.msg;
        }
        catch (InputResolutionException e)
        {
            result.unevaluable = true;
            result.error = e.msg;
        }
        return result;
    }

    /// `request` with the definition it runs with, read by id.
    private DefinedRequest definedRequest(BuildRequest request)
    {
        auto definition = m_stores.definitions.get(request.definitionId);
        if (definition.isNull)
        {
            throw new MissingDefinitionException(format("Definition '%s' of request '%s' does not exist", request.definitionId, request.id));
        }
        return DefinedRequest(request, definition.get);
    }

    /// Evaluates `entry` from the generations and ledgers, read by id now.
    private RequestEvaluation evaluate(in DefinedRequest entry)
    {
        auto generations = readRequestGenerations(entry, (in string[] bases) => m_stores.rerunGenerations.read(bases));
        LedgerSummary[string] summaries;
        foreach (fingerprint; requestFingerprints(entry, generations))
        {
            summaries[fingerprint] = readLedgerSummary(m_stores.ledgers, m_stores.executions, fingerprint);
        }
        return evaluateRequest(entry, generations, summaries);
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
 * Reconciles every open request of `projectId` at the clock `now`, each on its own, one page of
 * open requests at a time (so one page is in memory at once). A request whose reconcile fails is
 * logged with its error and counted, and the others are still reconciled; a request left open is
 * reconciled again by a later call. A page that cannot be listed ends the pass, counted as one
 * error. Used when an execution of the project ends, and by the coordination sweep.
 */
ProjectReconciliation reconcileOpenRequests(StateStores stores, string projectId, string now)
{
    ProjectReconciliation result;
    auto reconciler = new RequestReconciler(stores, () => now);
    string cursor;
    while (true)
    {
        Page!BuildRequest page;
        try page = stores.requests.listOpenPage(projectId, cursor);
        catch (Exception e)
        {
            logError("[reconcile] Could not list the open requests of project '%s': %s", projectId, e.toString());
            result.errors += 1;
            return result;
        }
        foreach (item; page.items)
        {
            const id = item.value.id;
            try
            {
                reconciler.reconcile(id);
                result.reconciled += 1;
            }
            catch (Exception e)
            {
                logError("[reconcile] Could not reconcile request '%s' of project '%s': %s", id, projectId, e.toString());
                result.errors += 1;
            }
        }
        if (page.nextCursor.length == 0) return result;
        cursor = page.nextCursor;
    }
}

version (unittest)
{
    import confector.core.request_fixtures;
    import confector.core.fingerprint_ledger : executionIdFor;
    import confector.api.document_store : Document;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import std.algorithm.searching : canFind;
    import std.typecons : Nullable;

    /// A document store whose reads of collection `failing` throw, as an unavailable store's would.
    private final class ReadFailingStore : InMemoryDocumentStore
    {
        string failing;

        override Nullable!Document get(string collection, string id)
        {
            if (collection == failing) throw new Exception("The store is unavailable");
            return super.get(collection, id);
        }
    }

    /// The active execution of task `taskId` of chain `chainId`, as its ledger names it now.
    private string activeOf(StateStores stores, string chainId, string taskId)
    {
        auto ledger = stores.ledgers.get(fingerprintNow(stores, chainId, taskId)).get;
        return ledger.active.isNull ? "" : ledger.active.get.id;
    }

    /// The ledger of task `taskId` of chain `chainId` now.
    private FingerprintLedger ledgerOf(StateStores stores, string chainId, string taskId)
    {
        return stores.ledgers.get(fingerprintNow(stores, chainId, taskId)).get.value;
    }

    /// The ids of the queued executions, as the ledgers' active index lists them.
    private string[] queuedIds(StateStores stores)
    {
        string[] ids;
        foreach (ledger; stores.ledgers.queuedPage(null).items) ids ~= ledger.active.get.id;
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
    assert(first.committed && first.passes == 2 && first.request.outcome == RequestOutcome.open);
    assert(taskOf(first.request, "compile").status == RequestTaskStatus.queued);
    assert(taskOf(first.request, "test").status == RequestTaskStatus.waitingUpstream);
    assert(queuedIds(stores) == [activeOf(stores, "c1", "compile")]);

    auto unchanged = reconciler.reconcile("r1");
    assert(!unchanged.committed && unchanged.passes == 1 && unchanged.request.version_ == first.request.version_,
        "Nothing new, nothing written");

    foreach (taskId; ["compile", "test", "report"])
    {
        if (taskId != "compile")
        {
            auto next = reconciler.reconcile("r1");
            assert(next.committed && taskOf(next.request, taskId).status == RequestTaskStatus.queued);
            assert(queuedIds(stores) == [activeOf(stores, "c1", taskId)]);
        }
        finish(stores, chain, taskId, ExecutionStatus.succeeded);
    }
    auto done = reconciler.reconcile("r1");
    assert(done.committed && done.request.outcome == RequestOutcome.succeeded);
    foreach (taskId; ["compile", "test", "report"]) assert(taskOf(done.request, taskId).status == RequestTaskStatus.succeeded);
    assert(stores.requests.listOpen("game").length == 0, "A settled request leaves the open index");

    auto settled = reconciler.reconcile("r1");
    assert(!settled.committed && settled.passes == 1 && settled.request.version_ == done.request.version_);
    assert(queuedIds(stores).length == 0);

    // A request that does not exist fails loudly; so does a reconciler without its parts
    try
    {
        reconciler.reconcile("r2");
        assert(false, "A request that does not exist must fail the reconcile");
    }
    catch (Exception e) assert(e.msg.canFind("'r2'") && e.msg.canFind("does not exist"), e.msg);
    assert(throwsA!Exception({ new RequestReconciler(null); }));
}

unittest
{
    // The request's compare-and-set loop. A reconcile that loses the commit to another
    // reconcile of the same request reads again and evaluates again; whichever write of the first
    // reconcile the second overtakes, the request ends with one execution per fingerprint
    foreach (overtakenAt; [1, 2])
    {
        auto documents = new InMemoryDocumentStore();
        auto direct = new StateStores(documents);
        createChain(direct, "c1");
        intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

        auto interleaving = new InterleavingDocumentStore(documents);
        Reconciled other;
        // The first reconciler's writes: 1 claim, 2 commit; the second reconciles
        // completely just before the chosen one
        beforeWrite(interleaving, overtakenAt, () { other = reconcilerOf(direct).reconcile("r1"); });
        auto reconciled = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
        assert(interleaving.beforeNextWrite is null);
        assert(other.committed, format("overtaken at write %s: the second reconciler commits", overtakenAt));
        assert(!reconciled.committed, format("overtaken at write %s: the first finds nothing new", overtakenAt));

        auto state = direct.requests.get("r1").get;
        assert(state.outcome == RequestOutcome.open && taskOf(state, "compile").status == RequestTaskStatus.queued);
        auto compile = ledgerOf(direct, "c1", "compile");
        assert(compile.executionSeq == 1, format("overtaken at write %s", overtakenAt));
        assert(queuedIds(direct) == [compile.active.get.id], format("overtaken at write %s", overtakenAt));
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
    // Writes: 1 claim, 2 commit
    beforeWrite(interleaving, 2, () { finish(direct, chain, "compile", ExecutionStatus.succeeded); });
    auto reconciled = reconcilerOf(new StateStores(interleaving)).reconcile("r1");
    assert(interleaving.beforeNextWrite is null);
    assert(reconciled.committed && taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);

    auto next = reconcilerOf(direct).reconcile("r1");
    assert(taskOf(next.request, "compile").status == RequestTaskStatus.succeeded);
    assert(taskOf(next.request, "test").status == RequestTaskStatus.queued, "The request must not end stuck");
}

unittest
{
    // Reconcilers of one request on several threads at once (as several server instances would)
    // converge: each needed fingerprint is claimed once
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
    // A reconcile after a restart needs nothing from the process that crashed after its claim: the
    // claim carries everything the execution needs, so the new process finds the execution queued
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    const needed = evaluateFrom(stores, "r1").needed[0];
    const dispatched = reconcilerOf(stores).dispatch(needed, definedRequest(stores, "r1")); // and crashed
    assert(dispatched.claim == ClaimOutcome.won);

    // A new process: new stores over the same database, a new reconciler, nothing else
    auto restarted = new StateStores(documents.restart());
    auto reconciled = reconcilerOf(restarted).reconcile("r1");
    assert(reconciled.committed && reconciled.passes == 1);
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);
    assert(ledgerOf(restarted, "c1", "compile").executionSeq == 1);
    assert(restarted.ledgers.get(needed.fingerprint).get.active.get.status == ExecutionStatus.queued);
    assert(queuedIds(restarted) == [dispatched.executionId]);
}

unittest
{
    // Two requests sharing one execution. 1. Request r2 claimed compile and crashed before
    // committing. Request r1, needing compile too, finds it claimed; r2, reconciled later, finds
    // it too. Both then advance on the one execution's outcome
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        auto c1 = createChain(stores, "c1");
        createChain(stores, "c2");
        intake(stores, "c2", "r2", ["test"], "2026-10-20T10:00:00Z");
        const needed = evaluateFrom(stores, "r2").needed[0];
        const claimed = reconcilerOf(stores).dispatch(needed, definedRequest(stores, "r2")); // r2's reconciler crashed

        intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:01Z");
        auto first = reconcilerOf(stores).reconcile("r1");
        assert(first.committed && first.passes == 1 && taskOf(first.request, "compile").status == RequestTaskStatus.queued);
        assert(queuedIds(stores) == [claimed.executionId]);

        auto second = reconcilerOf(stores).reconcile("r2");
        assert(second.committed && taskOf(second.request, "compile").executionId == claimed.executionId);
        assert(ledgerOf(stores, "c1", "compile").executionSeq == 1 && queuedIds(stores) == [claimed.executionId]);

        finish(stores, c1, "compile", ExecutionStatus.succeeded);
        foreach (requestId; ["r1", "r2"])
        {
            auto advanced = reconcilerOf(stores).reconcile(requestId);
            assert(taskOf(advanced.request, "compile").status == RequestTaskStatus.succeeded, requestId);
            assert(taskOf(advanced.request, "test").status == RequestTaskStatus.queued, requestId);
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
        assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.succeeded);
        assert(taskOf(reconciled.request, "test").status == RequestTaskStatus.queued);
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
    const before = stores.requests.get("r1").get;
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
    assert(stores.requests.get("r1").get.version_ == before.version_, "Nothing was committed");
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull, "compile was not claimed");
    assert(activeOf(stores, "c1", "lint").length > 0, "The other needed execution was dispatched");

    auto reconciled = reconcilerOf(new StateStores(documents.restart())).reconcile("r1");
    assert(reconciled.committed && reconciled.request.outcome == RequestOutcome.open);
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);
    assert(taskOf(reconciled.request, "lint").status == RequestTaskStatus.queued);
}

unittest
{
    // A needed execution that cannot be built (its repository has no address) settles the
    // request failed, with the error in its state; nothing is claimed for it and it is
    // not retried by later reconciles. A new request, once the repository is fixed, runs
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    RepositoryRecord addressless;
    addressless.name = "game";
    stores.repositories.put(addressless);
    auto failed = reconcilerOf(stores).reconcile("r1");
    assert(failed.committed && failed.request.outcome == RequestOutcome.failed);
    assert(failed.request.error.canFind("compile") && failed.request.error.canFind("no address"), failed.request.error);
    assert(taskOf(failed.request, "compile").status == RequestTaskStatus.needed);
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull, "Nothing was claimed");
    assert(stores.requests.listOpen("game").length == 0);

    addressless.address = gameAddress;
    stores.repositories.put(addressless);
    auto again = reconcilerOf(stores).reconcile("r1");
    assert(!again.committed && again.request.outcome == RequestOutcome.failed, "A failed request is not retried by the next look");
    assert(stores.ledgers.get(fingerprintNow(stores, "c1", "compile")).isNull);

    intake(stores, "c1", "r2", ["test"], "2026-10-20T10:00:01Z");
    auto retry = reconcilerOf(stores).reconcile("r2");
    assert(retry.request.outcome == RequestOutcome.open && retry.request.error.length == 0);
    assert(taskOf(retry.request, "compile").status == RequestTaskStatus.queued);

    // An unregistered repository fails the request the same way
    auto other = new StateStores(new InMemoryDocumentStore());
    createChain(other, "c1");
    intake(other, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    other.repositories.remove("game");
    auto unregistered = reconcilerOf(other).reconcile("r1");
    assert(unregistered.request.outcome == RequestOutcome.failed);
    assert(unregistered.request.error.canFind("compile") && unregistered.request.error.canFind("not registered"), unregistered.request.error);
    assert(other.ledgers.get(fingerprintNow(other, "c1", "compile")).isNull, "Nothing was claimed");
}

unittest
{
    // The reconciler evaluates a request from its own pins, never its chain's: once the chain's pin
    // of game at main is another revision, the request still dispatches the execution it needs at
    // the fingerprint it was recorded with
    import confector.core.build_stores : buildChainsCollection;
    import vibe.data.json : Json, serializeToJson;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    const needed = evaluateFrom(stores, "r1").needed[0];

    // The chain's document as stored, with its pin changed: the store itself refuses that, so the
    // document is written directly
    auto stored = documents.get(buildChainsCollection.name, "c1");
    Json content = stored.get.content;
    content["pins"] = serializeToJson([RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("bbb222")))]);
    documents.replace(buildChainsCollection.name, "c1", content, stored.get.version_);
    assert(stores.chains.get("c1").get.value.pins[0].pin.pinned == Json("bbb222"));

    auto reconciled = reconcilerOf(stores).reconcile("r1");
    assert(reconciled.request.outcome == RequestOutcome.open);
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);
    auto ledger = stores.ledgers.get(needed.fingerprint);
    assert(!ledger.isNull && !ledger.get.value.active.isNull, "The execution was claimed at the recorded fingerprint");
    assert(queuedIds(stores) == [ledger.get.value.active.get.id]);
}

unittest
{
    // An undispatchable execution and a failed dispatch in one pass: the request fails with both
    // in its error, and its cached tasks show what the pass did (compile, whose claim failed, and
    // lint, which cannot be built, both still need an execution)
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
    assert(failed.request.outcome == RequestOutcome.failed);
    assert(failed.request.error.canFind("no address") && failed.request.error.canFind("unavailable"), failed.request.error);
    assert(taskOf(failed.request, "compile").status == RequestTaskStatus.needed, "compile was not claimed");
    assert(taskOf(failed.request, "lint").status == RequestTaskStatus.needed);
}

unittest
{
    // A needed fingerprint is claimed at the executionSeq the evaluation saw, in one write, as a
    // queued execution with the request's definition, inputs and repository addresses
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = new StateStores(interleaving);
    auto reconciler = reconcilerOf(stores);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto entry = definedRequest(stores, "r1");
    auto evaluation = evaluateFrom(stores, "r1");
    assert(evaluation.needed.length == 1);
    const needed = evaluation.needed[0];
    assert(needed.taskId == "compile" && needed.seenExecutionSeq == 0);

    size_t writes;
    void countWrites()
    {
        interleaving.beforeNextWrite = () { writes += 1; countWrites(); };
    }
    countWrites();
    const dispatched = reconciler.dispatch(needed, entry);
    assert(writes == 1, "A dispatch is one compare-and-set");
    assert(dispatched.claim == ClaimOutcome.won);
    assert(dispatched.executionId == executionIdFor(needed.fingerprint, 1));
    auto claimed = stores.ledgers.get(needed.fingerprint).get;
    auto active = claimed.active.get;
    assert(active.id == dispatched.executionId && active.status == ExecutionStatus.queued);
    assert(active.projectId == "game" && active.taskId == "compile" && active.inputs == needed.inputs);
    assert(active.definitionId == entry.request.definitionId && stores.definitions.get(active.definitionId).get.tasks.length == 4);
    assert(active.repositoryAddresses == ["src": gameAddress]);
    assert(active.createdAt == fixedNow() && active.attempt == 0 && active.worker.length == 0);

    // The same decision again finds the execution active: nothing more is written
    const again = reconciler.dispatch(needed, entry);
    assert(again.claim == ClaimOutcome.active && again.executionId == dispatched.executionId && writes == 1);

    // It ends; a decision made before it started is superseded (it would build compile twice)
    finish(stores, stores.chains.get("c1").get.value, "compile", ExecutionStatus.failed);
    const stale = reconciler.dispatch(needed, entry);
    assert(stale.claim == ClaimOutcome.superseded && stale.executionId.length == 0);
    assert(stores.ledgers.get(needed.fingerprint).get.executionSeq == 1);
}

unittest
{
    // A task that cannot be claimed fails loudly before anything is written, so it never holds
    // its fingerprint: a repository without an address, one that is not registered, a task the
    // request's definition lacks
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto reconciler = reconcilerOf(stores);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto entry = definedRequest(stores, "r1");
    const needed = evaluateFrom(stores, "r1").needed[0];

    RepositoryRecord addressless;
    addressless.name = "game";
    stores.repositories.put(addressless);
    try
    {
        reconciler.dispatch(needed, entry);
        assert(false, "A repository without an address must fail the dispatch");
    }
    catch (UndispatchableExecutionException e)
    {
        assert(e.msg.canFind("'game'") && e.msg.canFind("no address"));
    }
    stores.repositories.remove("game");
    try
    {
        reconciler.dispatch(needed, entry);
        assert(false, "An unregistered repository must fail the dispatch");
    }
    catch (UndispatchableExecutionException e)
    {
        assert(e.msg.canFind("'game'") && e.msg.canFind("not registered"));
    }
    auto missingTask = cast(NeededExecution) needed;
    missingTask.taskId = "deploy";
    assert(throwsA!UndispatchableExecutionException({ reconciler.dispatch(missingTask, entry); }));
    assert(stores.ledgers.get(needed.fingerprint).isNull, "Nothing was claimed");
}

unittest
{
    // Two reconcilers dispatching one fingerprint at once: exactly one claims; the other finds the
    // winner's execution active and writes nothing more
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto entry = definedRequest(direct, "r1");
    const needed = evaluateFrom(direct, "r1").needed[0];

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    Dispatched first;
    interleaving.beforeNextWrite = () { first = reconcilerOf(direct).dispatch(needed, entry); };
    const second = reconcilerOf(racing).dispatch(needed, entry);
    assert(first.claim == ClaimOutcome.won);
    assert(second.claim == ClaimOutcome.active && second.executionId == first.executionId);
    assert(direct.ledgers.get(needed.fingerprint).get.executionSeq == 1);
    assert(queuedIds(direct) == [first.executionId]);
}

unittest
{
    // A request whose definition is missing settles failed with the error in its state, and leaves
    // the open index. Nothing is evaluated or dispatched for it, and a later reconcile finds it settled
    import confector.core.definition_store : projectDefinitionsCollection;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    const definitionId = stores.requests.get("r1").get.value.definitionId;
    documents.remove(projectDefinitionsCollection.name, definitionId,
        documents.get(projectDefinitionsCollection.name, definitionId).get.version_);

    auto failed = reconcilerOf(stores).reconcile("r1");
    assert(failed.committed && failed.request.outcome == RequestOutcome.failed);
    assert(failed.request.error.canFind(definitionId) && failed.request.error.canFind("does not exist"), failed.request.error);
    assert(failed.request.tasks.length == 0, "Nothing was evaluated");
    assert(stores.requests.listOpen("game").length == 0, "A settled request leaves the open index");
    assert(queuedIds(stores).length == 0, "Nothing was dispatched");

    auto again = reconcilerOf(stores).reconcile("r1");
    assert(!again.committed && again.request.outcome == RequestOutcome.failed && again.request.version_ == failed.request.version_);
}

unittest
{
    // A request whose recorded demand no rerun explains cannot be evaluated: it settles failed with
    // the error, and keeps the tasks its last evaluation cached
    import confector.core.build_stores : buildRequestsCollection;
    import vibe.data.json : Json;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto first = reconcilerOf(stores).reconcile("r1");
    assert(taskOf(first.request, "compile").status == RequestTaskStatus.queued);

    auto stored = documents.get(buildRequestsCollection.name, "r1");
    Json content = stored.get.content;
    content["demands"][0]["fingerprint"] = "fp-recorded-wrong";
    documents.replace(buildRequestsCollection.name, "r1", content, stored.get.version_);

    auto failed = reconcilerOf(stores).reconcile("r1");
    assert(failed.committed && failed.request.outcome == RequestOutcome.failed);
    assert(failed.request.error.canFind("was rerun"), failed.request.error);
    assert(taskOf(failed.request, "compile").status == RequestTaskStatus.queued, "The cached tasks are kept");
    assert(stores.requests.listOpen("game").length == 0);
}

unittest
{
    // A request whose recorded pins do not cover its bindings cannot be evaluated: it settles failed
    // with the error, and keeps the tasks its last evaluation cached
    import confector.core.build_stores : buildRequestsCollection;
    import vibe.data.json : Json;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    reconcilerOf(stores).reconcile("r1");

    auto stored = documents.get(buildRequestsCollection.name, "r1");
    Json content = stored.get.content;
    content["pins"] = Json.emptyArray;
    documents.replace(buildRequestsCollection.name, "r1", content, stored.get.version_);

    auto failed = reconcilerOf(stores).reconcile("r1");
    assert(failed.committed && failed.request.outcome == RequestOutcome.failed);
    assert(failed.request.error.canFind("Task 'compile' input 'src'") && failed.request.error.canFind("is not pinned"), failed.request.error);
    assert(taskOf(failed.request, "compile").status == RequestTaskStatus.queued, "The cached tasks are kept");
    assert(stores.requests.listOpen("game").length == 0);
}

unittest
{
    // A store error while the request settles leaves it open: nothing is written, and a reconcile on
    // a store that works settles it
    import confector.core.definition_store : projectDefinitionsCollection;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    const definitionId = stores.requests.get("r1").get.value.definitionId;
    documents.remove(projectDefinitionsCollection.name, definitionId,
        documents.get(projectDefinitionsCollection.name, definitionId).get.version_);
    const before = stores.requests.get("r1").get;

    auto interleaving = new InterleavingDocumentStore(documents);
    beforeWrite(interleaving, 1, () { throw new Exception("The store is unavailable"); });
    try
    {
        reconcilerOf(new StateStores(interleaving)).reconcile("r1");
        assert(false, "A store error while settling must be reported");
    }
    catch (Exception e) assert(e.msg == "The store is unavailable", e.msg);
    const after = stores.requests.get("r1").get;
    assert(after.outcome == RequestOutcome.open && after.version_ == before.version_, "The request is left open");
    assert(stores.requests.listOpen("game").length == 1);

    assert(reconcilerOf(stores).reconcile("r1").request.outcome == RequestOutcome.failed);
}

unittest
{
    // A ledger that names an execution the store does not return is a fault in the store, not in the
    // request: the reconcile throws, and the request stays open for the sweep to try again
    import confector.core.build_stores : taskExecutionsCollection;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    reconcilerOf(stores).reconcile("r1");
    const compileAt = fingerprintNow(stores, "c1", "compile");
    finish(stores, stores.chains.get("c1").get.value, "compile", ExecutionStatus.succeeded);
    const id = ledgerOf(stores, "c1", "compile").lastSuccessExecutionId;
    assert(id == executionIdFor(compileAt, 1) && id.length > 0);
    documents.remove(taskExecutionsCollection.name, id, documents.get(taskExecutionsCollection.name, id).get.version_);

    bool threw;
    try reconcilerOf(stores).reconcile("r1");
    catch (InconsistentStateException e)
    {
        threw = e.msg.canFind(id);
    }
    assert(threw, "The reconcile must throw, naming the execution");
    const still = stores.requests.get("r1").get;
    assert(still.outcome == RequestOutcome.open && stores.requests.listOpen("game").length == 1, "The request stays open");
}

unittest
{
    // A store error while reading the definition is not a definition that is missing: it propagates,
    // the request stays open, and a later reconcile on a store that works evaluates it
    import confector.core.definition_store : projectDefinitionsCollection;

    auto documents = new ReadFailingStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    documents.failing = projectDefinitionsCollection.name;
    try
    {
        reconcilerOf(stores).reconcile("r1");
        assert(false, "A store error while reading must be reported");
    }
    catch (Exception e) assert(e.msg == "The store is unavailable", e.msg);
    assert(stores.requests.get("r1").get.outcome == RequestOutcome.open && stores.requests.listOpen("game").length == 1);

    documents.failing = null;
    auto reconciled = reconcilerOf(stores).reconcile("r1");
    assert(reconciled.request.outcome == RequestOutcome.open && taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);
}

unittest
{
    // The reconciler reads no chain: a request is reconciled after its chain is removed
    import confector.core.build_stores : buildChainsCollection;

    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    documents.remove(buildChainsCollection.name, "c1", documents.get(buildChainsCollection.name, "c1").get.version_);

    auto reconciled = reconcilerOf(stores).reconcile("r1");
    assert(reconciled.committed && reconciled.request.outcome == RequestOutcome.open);
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.queued);
}
