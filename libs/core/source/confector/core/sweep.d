module confector.core.sweep;

/**
 * The coordination sweep (AGENTS.md, "Coordinating builds"): one tick of the fixed schedule that
 * repairs what the event-driven paths may have left undone. A lost wake, a crash between two
 * writes and a lost worker each wait here for at most one tick. A tick needs nothing from the one
 * before it, and running it twice in a row changes nothing the second time.
 *
 * A tick does two things, in order:
 *
 * 1. Expires the leases of running executions whose lease has run out (`expireLease`): each is
 *    queued again, or failed once the attempt limit is reached. They come from the ledgers' active
 *    index, which lists running executions by lease expiry, so an idle tick reads only what is due.
 * 2. Reconciles every open request of every project (`RequestReconciler.reconcile`). That settles
 *    any ledger a half-finished fold left behind, and advances any request whose wake was lost.
 *
 * A failure on one execution or request is logged and counted, and the tick moves on. So is a
 * failure to list what a step works on; the other step still runs.
 */

import confector.api.model : FingerprintLedger, ProjectRecord, RequestState;
import confector.core.document_collection : Page;
import confector.core.request_reconciler : reconcileOpenRequests;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : LostLeaseDisposition, expireLease, requireAttemptLimit, utcNow;

import vibe.core.log : logError;

/// What one tick did.
struct SweepSummary
{
    /// Executions whose lease ran out and that are queued again, for a worker to claim.
    size_t leasesRequeued;
    /// Executions whose lease ran out at the attempt limit, and so failed.
    size_t leasesFailed;
    /// Open requests reconciled without error, whether or not the reconcile changed them.
    size_t requestsReconciled;
    /// Failures logged during the tick: a fingerprint, a request or a listing that could not be
    /// processed.
    size_t errors;
}

/**
 * Runs one tick at `now` (default `utcNow`), with the attempt limit `maxAttempts`
 * (`server.execution.maxAttempts`), and returns what it did. Failures inside the tick are logged and
 * counted in the summary; they do not throw.
 *
 * Throws: Exception if `maxAttempts` is 0.
 */
SweepSummary sweepCoordination(StateStores stores, uint maxAttempts, string now = null)
{
    requireAttemptLimit(maxAttempts);
    if (now.length == 0) now = utcNow();
    SweepSummary summary;
    expireDueLeases(stores, maxAttempts, now, summary);
    reconcileEveryProject(stores, now, summary);
    return summary;
}

private void expireDueLeases(StateStores stores, uint maxAttempts, string now, ref SweepSummary summary)
{
    string cursor;
    while (true)
    {
        Page!FingerprintLedger page;
        try page = stores.ledgers.leaseDuePage(now, cursor);
        catch (Exception e)
        {
            logError("[sweep] Could not list the running executions, so no lease was expired: %s", e.toString());
            summary.errors += 1;
            return;
        }
        foreach (candidate; page.items)
        {
            try
            {
                final switch (expireLease(stores, candidate.fingerprint, maxAttempts, now).disposition)
                {
                    case LostLeaseDisposition.requeued:
                        summary.leasesRequeued += 1;
                        break;
                    case LostLeaseDisposition.failed:
                        summary.leasesFailed += 1;
                        break;
                    case LostLeaseDisposition.nothingToDo:
                        break;
                }
            }
            catch (Exception e)
            {
                logError("[sweep] Could not expire the lease at fingerprint %s: %s", candidate.fingerprint, e.toString());
                summary.errors += 1;
            }
        }
        if (page.nextCursor.length == 0) return;
        cursor = page.nextCursor;
    }
}

private void reconcileEveryProject(StateStores stores, string now, ref SweepSummary summary)
{
    ProjectRecord[] projects;
    try projects = stores.projects.list();
    catch (Exception e)
    {
        logError("[sweep] Could not list the projects, so no open request was reconciled: %s", e.toString());
        summary.errors += 1;
        return;
    }
    foreach (project; projects)
    {
        const done = reconcileOpenRequests(stores, project.id, now);
        summary.requestsReconciled += done.reconciled;
        summary.errors += done.errors;
    }
}

version (unittest)
{
    import confector.api.model : ActiveExecution, BuildRequest, ExecutionStatus, RequestOutcome, RequestTaskStatus, TaskExecutionResult;
    import confector.core.fingerprint_ledger : endedExecution;
    import std.datetime.systime : SysTime;
    import confector.api.document_store : DocumentStore;
    import confector.core.request_fixtures;
    import confector.core.work_orders : claimWork, completeExecution, startExecution;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import core.time : Duration, minutes, seconds;
    import std.algorithm.searching : canFind;

    /// Stores over `documents` with the fixtures' project registered, so that a sweep lists it. The
    /// chains and requests are made by the fixtures.
    private StateStores projectStores(DocumentStore documents)
    {
        auto stores = new StateStores(documents);
        ProjectRecord game;
        game.id = "game";
        game.name = "game";
        stores.projects.put(game);
        return stores;
    }

    /// `fixedNow` plus `by`.
    private string later(Duration by)
    {
        return (SysTime.fromISOExtString(fixedNow()) + by).toISOExtString();
    }

    /// Request "ra" over chain "a", reconciled, with its compile execution running as attempt 1 under a
    /// lease of a minute from `fixedNow`. Returns the fingerprint.
    private string runningRequest(StateStores stores)
    {
        createChain(stores, "a");
        intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
        reconcilerOf(stores).reconcile("ra");
        const fingerprint = fingerprintNow(stores, "a", "compile");
        assert(!startExecution(stores, fingerprint, "w1", 1.minutes, fixedNow()).isNull);
        return fingerprint;
    }

    /// The active execution of `fingerprint`.
    private ActiveExecution activeAt(StateStores stores, string fingerprint)
    {
        return stores.ledgers.get(fingerprint).get.active.get;
    }

    /// A successful completion of attempt 1.
    private TaskExecutionResult succeededFirstAttempt()
    {
        TaskExecutionResult result;
        result.status = ExecutionStatus.succeeded;
        result.attempt = 1;
        return result;
    }
}

unittest
{
    // A crash after the execution's record is written and before the fold and the wake: the
    // execution has finished, its ledger still holds it as active and the request is still open.
    // One tick settles the fold and advances the request
    auto stores = projectStores(new InMemoryDocumentStore());
    const fingerprint = runningRequest(stores);
    const id = activeAt(stores, fingerprint).id;
    stores.executions.create(endedExecution(fingerprint, activeAt(stores, fingerprint), ExecutionStatus.succeeded, fixedNow()));
    assert(activeAt(stores, fingerprint).id == id, "Nothing was folded");

    auto summary = sweepCoordination(stores, 3, fixedNow());
    assert(summary.errors == 0 && summary.requestsReconciled == 1);
    auto ledger = stores.ledgers.get(fingerprint).get;
    assert(ledger.active.isNull && ledger.lastSuccessExecutionId == id);
    auto state = stores.requestStates.get("ra").get.value;
    assert(state.outcome == RequestOutcome.succeeded && taskOf(state, "compile").status == RequestTaskStatus.succeeded);
}

unittest
{
    // A lost wake: a completion is folded, but the reconcile that should advance its request fails.
    // The request stays open until one tick reconciles it
    auto documents = new InMemoryDocumentStore();
    auto stores = projectStores(documents);
    const fingerprint = runningRequest(stores);
    const id = activeAt(stores, fingerprint).id;

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    // The writes of the completion: 1 the execution's record, 2 the fold, 3 the reconcile's commit
    beforeWrite(interleaving, 3, () { throw new Exception("The wake's write is lost"); });
    assert(completeExecution(racing, fingerprint, id, succeededFirstAttempt(), fixedNow()).status == ExecutionStatus.succeeded);
    assert(stores.requestStates.get("ra").get.outcome == RequestOutcome.open, "The lost wake leaves the request open");

    auto summary = sweepCoordination(stores, 3, fixedNow());
    assert(summary.errors == 0 && summary.requestsReconciled == 1);
    auto state = stores.requestStates.get("ra").get.value;
    assert(state.outcome == RequestOutcome.succeeded && taskOf(state, "compile").status == RequestTaskStatus.succeeded);
}

unittest
{
    // An expired lease, with the attempt limit 2: the first tick requeues the execution and leaves the
    // request open. Claimed again, the second expiry reaches the limit and fails the execution, and
    // its request with it, in the same tick
    auto stores = projectStores(new InMemoryDocumentStore());
    const fingerprint = runningRequest(stores);
    const id = activeAt(stores, fingerprint).id;

    auto requeued = sweepCoordination(stores, 2, later(2.minutes));
    assert(requeued.leasesRequeued == 1 && requeued.leasesFailed == 0 && requeued.errors == 0);
    auto queued = activeAt(stores, fingerprint);
    assert(queued.status == ExecutionStatus.queued && queued.expiredLeases == 1);
    assert(stores.requestStates.get("ra").get.outcome == RequestOutcome.open);

    assert(!claimWork(stores, "w2", 1.minutes, later(2.minutes)).isNull);
    auto failed = sweepCoordination(stores, 2, later(4.minutes));
    assert(failed.leasesRequeued == 0 && failed.leasesFailed == 1 && failed.errors == 0);
    assert(stores.executions.get(id).get.status == ExecutionStatus.failed && stores.ledgers.get(fingerprint).get.active.isNull);
    auto state = stores.requestStates.get("ra").get.value;
    assert(state.outcome == RequestOutcome.failed && taskOf(state, "compile").status == RequestTaskStatus.failed);
    assert(stores.executions.get(id).get.errorMessage.canFind("lease lost 2 times"));

    // A second tick finds nothing to do
    auto again = sweepCoordination(stores, 2, later(4.minutes));
    assert(again.leasesRequeued == 0 && again.leasesFailed == 0 && again.requestsReconciled == 0 && again.errors == 0);
}

unittest
{
    // A running execution whose lease has not run out is untouched by a tick, and an open request
    // that needs nothing is reconciled without a write. Two ticks in a row change nothing
    auto stores = projectStores(new InMemoryDocumentStore());
    const fingerprint = runningRequest(stores);
    const before = activeAt(stores, fingerprint);
    // The first tick sees the execution running, which changes the request's cached state once
    auto first = sweepCoordination(stores, 1, later(30.seconds));
    assert(first.leasesRequeued == 0 && first.leasesFailed == 0 && first.errors == 0 && first.requestsReconciled == 1);
    const version_ = stores.requestStates.get("ra").get.version_;

    foreach (tick; 0 .. 2)
    {
        auto summary = sweepCoordination(stores, 1, later(30.seconds));
        assert(summary.leasesRequeued == 0 && summary.leasesFailed == 0 && summary.errors == 0);
        assert(summary.requestsReconciled == 1);
        auto held = activeAt(stores, fingerprint);
        assert(held.status == ExecutionStatus.running && held.attempt == 1 && held.worker == "w1");
        assert(held.leaseExpiresAt == before.leaseExpiresAt);
        assert(stores.requestStates.get("ra").get.version_ == version_, "An unchanged request is not written");
    }
}

unittest
{
    // A request that cannot be reconciled is logged and counted, and the tick still reconciles the
    // other open requests
    auto stores = projectStores(new InMemoryDocumentStore());
    createChain(stores, "a");
    intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
    BuildRequest ghost;
    ghost.id = "ghost";
    ghost.projectId = "game";
    stores.requestStates.createFor(ghost);

    auto summary = sweepCoordination(stores, 3, fixedNow());
    assert(summary.errors == 1 && summary.requestsReconciled == 1);
    assert(!stores.ledgers.get(fingerprintNow(stores, "a", "compile")).get.active.isNull,
        "The reconciled request dispatched its execution");
}

unittest
{
    // The attempt limit is required: a tick without one is refused before it touches anything
    auto stores = projectStores(new InMemoryDocumentStore());
    const fingerprint = runningRequest(stores);
    bool refused = false;
    try sweepCoordination(stores, 0, later(2.minutes));
    catch (Exception e) refused = e.msg.canFind("at least 1");
    assert(refused);
    assert(activeAt(stores, fingerprint).status == ExecutionStatus.running);
}
