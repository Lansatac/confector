module confector.core.request_state;

/**
 * Request state (AGENTS.md, "What a build is" and "Coordinating builds"): the `state` of a
 * BuildRequest, which caches its last evaluation and, once every target has settled, its outcome.
 * This module owns the type's rules: the pure transitions that produce it, and its validation.
 * `withEvaluation` caches an evaluation, and `withFailure` settles the request failed. The stores
 * write the result with BuildRequestStore.replaceState, by compare-and-set at the version read, and
 * that is the only write that can change a request after it is recorded.
 *
 * The state is a cache. It is recomputed from the request's recorded fields, the ledgers and the
 * rerun generations, so nothing in it is authoritative, and a settled request is final.
 *
 * Protocols:
 *
 * - **Request intake** records the request open (BuildRequestStore.create) in one write. Its state
 *   is recorded with it, so there is nothing to repair after a crash.
 * - **Reconciling** (confector.core.request_reconciler) reads the request, evaluates, dispatches what
 *   is needed and commits the evaluation with `withEvaluation` at the version read. A reconcile that
 *   loses the compare-and-set (another reconcile committed) reads again and evaluates again. A needed
 *   execution that cannot be built settles the request with `withFailure`, the error kept. So does a
 *   request that cannot be evaluated at all (its definition is missing, or it fails on what it
 *   recorded): `withFailure` without an evaluation keeps the tasks the last evaluation cached.
 * - **Deleting a project** settles its open requests with `withFailure` the same way.
 * - **Finding work**: BuildRequestStore.listOpen reads the open index of a project. It is discovery
 *   and may lag; a request it misses is found by a later look.
 */

import confector.core.state_validation : InvalidStateTransitionException, validateRequestState;
import confector.core.request_evaluator : RequestEvaluation;
import confector.api.model;

import std.format : format;

/**
 * The state of `request` with `evaluation` committed: its tasks cached and the outcome the
 * evaluation reached. Pure.
 *
 * Throws: InvalidStateTransitionException if `request` is settled already, or `evaluation` is of
 * another request or still needs executions (dispatch them and evaluate again: committing would
 * cache a state nothing is working towards).
 */
RequestState withEvaluation(in BuildRequest request, in RequestEvaluation evaluation) @trusted
{
    requireOpen(request);
    requireValid(evaluation.needed.length == 0, format(
        "The evaluation of request '%s' still needs %s executions; dispatch them and evaluate again before committing",
        request.id, evaluation.needed.length));
    requireSameRequest(request, evaluation);
    RequestState next;
    next.tasks = (cast(RequestTaskState[]) evaluation.tasks).dup;
    next.outcome = evaluation.outcome;
    validateRequestState(request.id, next);
    return next;
}

/**
 * The state of `request` settled failed because a needed execution could not be built: `error` says
 * why. `evaluation`'s tasks are cached as they were when the failure was found. Pure.
 *
 * Throws: InvalidStateTransitionException if `request` is settled already, `evaluation` is of
 * another request, or `error` is empty.
 */
RequestState withFailure(in BuildRequest request, in RequestEvaluation evaluation, string error) @trusted
{
    requireOpen(request);
    requireSameRequest(request, evaluation);
    requireValid(error.length > 0, format("Request '%s' cannot fail without an error", request.id));
    RequestState next;
    next.tasks = (cast(RequestTaskState[]) evaluation.tasks).dup;
    next.outcome = RequestOutcome.failed;
    next.error = error;
    validateRequestState(request.id, next);
    return next;
}

/**
 * The state of `request` settled failed because it cannot be evaluated: its definition is missing, or
 * evaluating it fails on what it recorded. No evaluation was made, so the tasks its state caches stay
 * as they are. Pure.
 *
 * Throws: InvalidStateTransitionException if `request` is settled already or `error` is empty.
 */
RequestState withFailure(in BuildRequest request, string error) @trusted
{
    requireOpen(request);
    requireValid(error.length > 0, format("Request '%s' cannot fail without an error", request.id));
    RequestState next = cast(RequestState) request.state;
    next.outcome = RequestOutcome.failed;
    next.error = error;
    validateRequestState(request.id, next);
    return next;
}

private void requireOpen(in BuildRequest request) @safe
{
    requireValid(request.state.outcome == RequestOutcome.open, format("Request '%s' is settled (%s), and a settled request never changes",
        request.id, request.state.outcome));
}

private void requireSameRequest(in BuildRequest request, in RequestEvaluation evaluation) @safe
{
    requireValid(evaluation.requestId == request.id, format(
        "An evaluation of request '%s' cannot be committed to the state of request '%s'", evaluation.requestId, request.id));
}

private void requireValid(bool condition, lazy string message) @safe
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

version (unittest)
{
    import confector.core.request_fixtures;
    import confector.core.state_stores : StateStores;
    import confector.api.document_store : DocumentConflictException;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
}

unittest
{
    // A request is recorded open, with no tasks, and is in the open index of its project from the
    // one write that records it
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    auto request = intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    assert(request.state.outcome == RequestOutcome.open && request.state.tasks.length == 0 && request.state.error.length == 0);
    assert(stores.requests.get("r1").get.value == request);
    assert(stores.requests.listOpen("game").length == 1 && stores.requests.listOpen("game")[0].id == "r1");
    assert(stores.requests.listOpen("tools").length == 0);
    assert(throwsA!InvalidStateTransitionException({ stores.requests.listOpen(""); }));
}

unittest
{
    // Committing an evaluation caches its tasks by compare-and-set at the version read, and writes
    // nothing when it changes nothing. A commit from an older read conflicts. An evaluation that
    // still needs executions, or is of another request, is refused
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    auto unready = stores.requests.get("r1").get;
    auto needing = evaluateFrom(stores, "r1");
    assert(needing.needed.length == 1);
    assert(throwsA!InvalidStateTransitionException({ commitEvaluation(stores, unready, needing); }),
        "An evaluation that needs executions is not committed");
    assert(stores.requests.get("r1").get.version_ == unready.version_);

    dispatch(stores, needing.needed[0], "r1");
    auto read = stores.requests.get("r1").get;
    auto evaluation = evaluateFrom(stores, "r1");
    auto committed = commitEvaluation(stores, read, evaluation);
    assert(committed.version_ == read.version_ + 1 && committed.state.outcome == RequestOutcome.open && committed.state.tasks.length == 2);
    assert(taskOf(committed, "compile").status == RequestTaskStatus.queued && taskOf(committed, "test").status == RequestTaskStatus.waitingUpstream);
    assert(throwsA!DocumentConflictException({ commitEvaluation(stores, read, evaluation); }), "A stale read loses");
    assert(commitEvaluation(stores, committed, evaluation).version_ == committed.version_, "An unchanged evaluation writes nothing");

    auto elsewhere = evaluation;
    elsewhere.requestId = "r2";
    assert(throwsA!InvalidStateTransitionException({ commitEvaluation(stores, committed, elsewhere); }));

    // States persist across a restart
    auto restarted = new StateStores((cast(InMemoryDocumentStore) stores.documentStore).restart());
    assert(restarted.requests.get("r1").get.value == committed.value);
}

unittest
{
    // A settled request leaves the open index and never changes again; failing it keeps the error
    // and the tasks as they were found
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto chain = createChain(stores, "c1");
    intake(stores, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    intake(stores, "c1", "r2", ["lint"], "2026-10-20T10:00:01Z");
    assert(stores.requests.listOpen("game").length == 2);

    auto read = stores.requests.get("r1").get;
    auto evaluation = evaluateFrom(stores, "r1");
    assert(throwsA!InvalidStateTransitionException({ failEvaluation(stores, read, evaluation, ""); }), "A failure needs its error");
    auto failed = failEvaluation(stores, read, evaluation, "task 'compile' has no address");
    assert(failed.state.outcome == RequestOutcome.failed && failed.state.error == "task 'compile' has no address");
    assert(taskOf(failed, "compile").status == RequestTaskStatus.needed);
    assert(stores.requests.listOpen("game").length == 1 && stores.requests.listOpen("game")[0].id == "r2");

    assert(throwsA!InvalidStateTransitionException({ commitEvaluation(stores, failed, evaluation); }));
    assert(throwsA!InvalidStateTransitionException({ failEvaluation(stores, failed, evaluation, "again"); }));

    // Every outcome an evaluation reaches is committed as it is
    auto lint = stores.requests.get("r2").get;
    dispatch(stores, evaluateFrom(stores, "r2").needed[0], "r2");
    finish(stores, chain, "lint", ExecutionStatus.succeeded);
    auto succeeded = commitEvaluation(stores, lint, evaluateFrom(stores, "r2"));
    assert(succeeded.state.outcome == RequestOutcome.succeeded && taskOf(succeeded, "lint").status == RequestTaskStatus.succeeded);
    assert(stores.requests.listOpen("game").length == 0);
}

unittest
{
    // A request that cannot be evaluated settles failed with its error, keeping the tasks its last
    // evaluation cached; a settled request or an empty error is refused
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    intake(stores, "c1", "r2", ["test"], "2026-10-20T10:00:01Z");

    auto read = stores.requests.get("r1").get;
    assert(throwsA!InvalidStateTransitionException({ withFailure(read.value, ""); }), "A failure needs its error");
    assert(withFailure(read.value, "no definition").tasks.length == 0, "An uncached request has no tasks");

    auto needing = evaluateFrom(stores, "r1");
    dispatch(stores, needing.needed[0], "r1");
    auto committed = commitEvaluation(stores, stores.requests.get("r1").get, evaluateFrom(stores, "r1"));
    auto failed = stores.requests.replaceState(committed, withFailure(committed.value, "The definition is missing"));
    assert(failed.state.outcome == RequestOutcome.failed && failed.state.error == "The definition is missing");
    assert(failed.state.tasks == committed.state.tasks, "The tasks cached by the last evaluation are kept");
    assert(stores.requests.listOpen("game").length == 1 && stores.requests.listOpen("game")[0].id == "r2");
    assert(throwsA!InvalidStateTransitionException({ withFailure(failed.value, "again"); }), "A settled request never changes");
}
