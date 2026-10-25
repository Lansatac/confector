module confector.core.request_state;

/**
 * Request state (AGENTS.md, "What a build is" and "Coordinating builds"): one RequestState
 * document per request, with the request id as its id, read by id and changed only by
 * compare-and-set, so it works on every DocumentStore backend and in stateless invocations. It
 * holds whether the request is still open, the last evaluation's task states
 * (confector.core.request_evaluator) for the dashboard, and the outcome once every target has
 * settled. A request is open until all its targets are settled; a settled state never changes.
 *
 * It is a projection, never the only record of anything: the request (which records its demands),
 * its chain's pins, the ledgers and the rerun generations are authoritative, and evaluating from
 * them recomputes everything it caches.
 *
 * Protocols:
 *
 * - **Request intake** records the request, then `createFor` its state, open. There is no
 *   multi-document transaction, so a crash between the two leaves a request without a state;
 *   repeating `createFor` repairs that, and every operation on a missing state throws
 *   RequestStateMissingException rather than assuming one.
 * - **Reconciling** (confector.core.request_reconciler) reads the state, evaluates, dispatches
 *   what is needed and `commit`s the evaluation at the version read. A reconcile that loses the
 *   compare-and-set (another reconcile committed) reads again and evaluates again. A needed
 *   execution that cannot be recorded settles the request failed (`fail`), with the error kept.
 * - **Finding work**: `listOpen` reads the index of open requests by project. It is discovery and
 *   may lag; a request it misses is found by a later look.
 */

import confector.core.build_stores : InvalidStateTransitionException;
import confector.core.document_collection;
import confector.core.request_evaluator : RequestEvaluation;
import confector.api.document_store;
import confector.api.model;

import std.format : format;
import std.typecons : Nullable;

/// The state store collection holding request states, keyed by request id. Indexed by project
/// while the request is open (sparse: a settled request is in no index).
enum CollectionSpec requestStatesCollection = CollectionSpec("request_states", [IndexSpec("open", "open_project", "request_id")]);

/// A request has no RequestState: it was never created (a crash after recording the request) or
/// was lost. Create it (`RequestStateStore.createFor`) and try again.
class RequestStateMissingException : Exception
{
    string requestId;

    this(string msg, string requestId, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.requestId = requestId;
    }
}

/**
 * `state` with `evaluation` committed: its tasks cached and the outcome the evaluation reached.
 * Pure.
 *
 * Throws: InvalidStateTransitionException if `state` is settled already, or `evaluation` is of
 * another request or still needs executions (dispatch them and evaluate again: committing would
 * cache a state nothing is working towards).
 */
RequestState withEvaluation(in RequestState state, in RequestEvaluation evaluation) @trusted
{
    requireOpen(state);
    requireValid(evaluation.needed.length == 0, format(
        "The evaluation of request '%s' still needs %s executions; dispatch them and evaluate again before committing",
        state.requestId, evaluation.needed.length));
    RequestState next = cast(RequestState) state;
    next.tasks = (cast(RequestTaskState[]) evaluation.tasks).dup;
    next.outcome = evaluation.outcome;
    requireSameRequest(state, evaluation);
    validateRequestState(next);
    return next;
}

/**
 * `state` settled failed because a needed execution could not be recorded: `error` says why.
 * `evaluation`'s tasks are cached as they were when the failure was found. Pure.
 *
 * Throws: InvalidStateTransitionException if `state` is settled already, `evaluation` is of
 * another request, or `error` is empty.
 */
RequestState withFailure(in RequestState state, in RequestEvaluation evaluation, string error) @trusted
{
    requireOpen(state);
    requireSameRequest(state, evaluation);
    requireValid(error.length > 0, format("Request '%s' cannot fail without an error", state.requestId));
    RequestState next = cast(RequestState) state;
    next.tasks = (cast(RequestTaskState[]) evaluation.tasks).dup;
    next.outcome = RequestOutcome.failed;
    next.error = error;
    validateRequestState(next);
    return next;
}

/**
 * Throws InvalidStateTransitionException unless `state` is well formed: a request and a project;
 * cached tasks that appear once, with a fingerprint and blocking tasks exactly when blocked; and
 * an error only on a failed request.
 */
void validateRequestState(in RequestState state) @safe
{
    requireValid(state.requestId.length > 0 && state.projectId.length > 0, "A request state needs a request id and a project id");
    bool[string] seen;
    foreach (ref task; state.tasks)
    {
        requireValid(task.taskId.length > 0 && task.fingerprint.length > 0,
            format("A task state of request '%s' needs a task id and a fingerprint", state.requestId));
        requireValid(task.taskId !in seen, format("The state of request '%s' has task '%s' twice", state.requestId, task.taskId));
        seen[task.taskId] = true;
        requireValid((task.status == RequestTaskStatus.blocked) == (task.blockedBy.length > 0), format(
            "Task '%s' of request '%s' is %s and names %s blocking tasks", task.taskId, state.requestId, task.status, task.blockedBy.length));
    }
    requireValid(state.error.length == 0 || state.outcome == RequestOutcome.failed,
        format("Request '%s' is %s but records an error", state.requestId, state.outcome));
}

/**
 * Request states in a DocumentStore. See the module documentation for the protocols. Request
 * states are never removed.
 */
final class RequestStateStore
{
    /// How many open requests `listOpen` returns at most.
    enum size_t pageSize = 100;

    private DocumentCollection!RequestState m_states;

    /// Declares `requestStatesCollection` on `store`.
    this(DocumentStore store)
    {
        m_states = new DocumentCollection!RequestState(store, requestStatesCollection, ["open_project"], &derivedFields);
    }

    private static string[string] derivedFields(in RequestState state)
    {
        string[string] fields;
        if (state.outcome == RequestOutcome.open) fields["open_project"] = state.projectId;
        return fields;
    }

    /**
     * Reads the state of request `requestId` by id. Null if it has none.
     *
     * Throws: Exception if `requestId` is empty; MalformedDocumentException if the stored state
     * names another request.
     */
    Nullable!(Versioned!RequestState) get(string requestId)
    {
        requireRequestId(requestId);
        auto found = m_states.get(requestId);
        if (!found.isNull && found.get.requestId != requestId)
        {
            throw new MalformedDocumentException(format("Request state '%s' in collection '%s' names request '%s'", requestId,
                requestStatesCollection.name, found.get.requestId), requestStatesCollection.name, requestId);
        }
        return found;
    }

    /**
     * Creates the state of the new request `request`: open, with no evaluation. Idempotent: if the
     * request has a state already, returns it and writes nothing.
     *
     * Throws: InvalidStateTransitionException if the request has no id or project, or the stored
     * state is of another project.
     */
    Versioned!RequestState createFor(in BuildRequest request)
    {
        requireValid(request.id.length > 0 && request.projectId.length > 0, "A request needs an id and a project id to have a state");
        RequestState fresh;
        fresh.requestId = request.id;
        fresh.projectId = request.projectId;
        foreach (attempt; 0 .. 2)
        {
            auto existing = get(request.id);
            if (!existing.isNull)
            {
                requireValid(existing.get.projectId == request.projectId, format(
                    "The state of request '%s' belongs to project '%s', not '%s'", request.id, existing.get.projectId, request.projectId));
                return existing.get;
            }
            try
            {
                return m_states.create(request.id, fresh);
            }
            catch (DocumentConflictException)
            {
                // Created concurrently: read it and return that one.
            }
        }
        throw new Exception(format("The state of request '%s' was reported to exist and then not found", request.id));
    }

    /**
     * Commits `evaluation`, made from the state `read`, by compare-and-set at the version read
     * (`withEvaluation`). Writes nothing when it changes nothing, and returns `read`.
     *
     * Throws: DocumentConflictException if the state changed since `read`: re-read and reconcile
     * again; InvalidStateTransitionException as `withEvaluation`.
     */
    Versioned!RequestState commit(in Versioned!RequestState read, in RequestEvaluation evaluation)
    {
        return write(read, withEvaluation(read.value, evaluation));
    }

    /**
     * Settles the request `read` failed with `error`, caching `evaluation`'s tasks, by
     * compare-and-set at the version read (`withFailure`).
     *
     * Throws: DocumentConflictException if the state changed since `read`;
     * InvalidStateTransitionException as `withFailure`.
     */
    Versioned!RequestState fail(in Versioned!RequestState read, in RequestEvaluation evaluation, string error)
    {
        return write(read, withFailure(read.value, evaluation, error));
    }

    /// Lists the open requests of project `projectId`, by request id, at most `pageSize` of
    /// them. Discovery: may lag behind writes.
    RequestState[] listOpen(string projectId)
    {
        requireValid(projectId.length > 0, "Open requests are listed for a project");
        IndexQuery lookup;
        lookup.index = "open";
        lookup.partitionKey = projectId;
        lookup.limit = pageSize;
        RequestState[] states;
        foreach (item; m_states.queryAll(lookup, pageSize)) states ~= item.value;
        return states;
    }

    private Versioned!RequestState write(in Versioned!RequestState read, RequestState next)
    {
        requireRequestId(read.requestId);
        if (next == read.value) return cast(Versioned!RequestState) read;
        return m_states.replace(read.requestId, next, read.version_);
    }
}

private void requireOpen(in RequestState state) @safe
{
    requireValid(state.outcome == RequestOutcome.open, format("Request '%s' is settled (%s), and a settled request never changes",
        state.requestId, state.outcome));
}

private void requireSameRequest(in RequestState state, in RequestEvaluation evaluation) @safe
{
    requireValid(evaluation.requestId == state.requestId, format(
        "An evaluation of request '%s' cannot be committed to the state of request '%s'", evaluation.requestId, state.requestId));
}

private void requireValid(bool condition, lazy string message) @safe
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

private void requireRequestId(string requestId) @safe
{
    if (requestId.length == 0) throw new Exception("A request state needs a request id");
}

version (unittest)
{
    import confector.core.request_evaluator : DefinedRequest;
    import confector.core.request_fixtures;
    import confector.core.state_stores : StateStores;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    import std.algorithm.searching : canFind;
}

unittest
{
    // A request's state is created with the request, open and empty; creating it again is a
    // no-op. It is in the index of open requests of its project
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    auto request = recordRequest(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    assert(stores.requestStates.get("r1").isNull && stores.requestStates.listOpen("game").length == 0);

    auto created = stores.requestStates.createFor(request);
    assert(created.version_ == 1 && created.requestId == "r1" && created.projectId == "game");
    assert(created.outcome == RequestOutcome.open && created.tasks.length == 0 && created.error.length == 0);
    assert(stores.requestStates.createFor(request).version_ == 1, "Creating it again writes nothing");
    assert(stores.requestStates.listOpen("game").length == 1 && stores.requestStates.listOpen("game")[0].requestId == "r1");
    assert(stores.requestStates.listOpen("tools").length == 0);

    // A state of another project, a request without an id and an empty id are refused
    auto stray = request;
    stray.projectId = "tools";
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.createFor(stray); }));
    stray.id = null;
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.createFor(stray); }));
    assert(throwsA!Exception({ stores.requestStates.get(""); }));
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.listOpen(""); }));
}

unittest
{
    // Committing an evaluation caches its tasks by compare-and-set at the version read, and
    // writes nothing when it changes nothing. A commit from an older read conflicts. An
    // evaluation that still needs executions, or is of another request, is refused
    auto stores = new StateStores(new InMemoryDocumentStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    auto unready = stores.requestStates.get("r1").get;
    auto needing = evaluateFrom(stores, "r1");
    assert(needing.needed.length == 1);
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.commit(unready, needing); }),
        "An evaluation that needs executions is not committed");
    assert(stores.requestStates.get("r1").get.version_ == unready.version_);

    dispatch(stores, needing.needed[0], "r1");
    auto read = stores.requestStates.get("r1").get;
    auto evaluation = evaluateFrom(stores, "r1");
    auto committed = stores.requestStates.commit(read, evaluation);
    assert(committed.version_ == read.version_ + 1 && committed.outcome == RequestOutcome.open && committed.tasks.length == 2);
    assert(taskOf(committed, "compile").status == RequestTaskStatus.queued && taskOf(committed, "test").status == RequestTaskStatus.waitingUpstream);
    assert(throwsA!DocumentConflictException({ stores.requestStates.commit(read, evaluation); }), "A stale read loses");
    assert(stores.requestStates.commit(committed, evaluation).version_ == committed.version_, "An unchanged evaluation writes nothing");

    auto elsewhere = evaluation;
    elsewhere.requestId = "r2";
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.commit(committed, elsewhere); }));

    // States persist across a restart
    auto restarted = new StateStores((cast(InMemoryDocumentStore) stores.documentStore).restart());
    assert(restarted.requestStates.get("r1").get.value == committed.value);
}

unittest
{
    // A settled request leaves the open index and never changes again; failing it keeps the
    // error and the tasks as they were found
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto chain = createChain(stores, "c1");
    intake(stores, "c1", "r1", ["compile"], "2026-10-20T10:00:00Z");
    intake(stores, "c1", "r2", ["lint"], "2026-10-20T10:00:01Z");
    assert(stores.requestStates.listOpen("game").length == 2);

    auto read = stores.requestStates.get("r1").get;
    auto evaluation = evaluateFrom(stores, "r1");
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.fail(read, evaluation, ""); }), "A failure needs its error");
    auto failed = stores.requestStates.fail(read, evaluation, "task 'compile' has no address");
    assert(failed.outcome == RequestOutcome.failed && failed.error == "task 'compile' has no address");
    assert(taskOf(failed, "compile").status == RequestTaskStatus.needed);
    assert(stores.requestStates.listOpen("game").length == 1 && stores.requestStates.listOpen("game")[0].requestId == "r2");

    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.commit(failed, evaluation); }));
    assert(throwsA!InvalidStateTransitionException({ stores.requestStates.fail(failed, evaluation, "again"); }));

    // Every outcome an evaluation reaches is committed as it is
    auto lint = stores.requestStates.get("r2").get;
    dispatch(stores, evaluateFrom(stores, "r2").needed[0], "r2");
    finish(stores, chain, "lint", ExecutionStatus.succeeded);
    auto succeeded = stores.requestStates.commit(lint, evaluateFrom(stores, "r2"));
    assert(succeeded.outcome == RequestOutcome.succeeded && taskOf(succeeded, "lint").status == RequestTaskStatus.succeeded);
    assert(stores.requestStates.listOpen("game").length == 0);
}

unittest
{
    // Malformed states are refused: tasks twice, blocking tasks that disagree with the status,
    // an error on a request that did not fail
    RequestState state;
    state.requestId = "r1";
    state.projectId = "game";
    validateRequestState(state);

    auto twice = state;
    twice.tasks = [RequestTaskState("compile", "fp1", RequestTaskStatus.queued), RequestTaskState("compile", "fp1", RequestTaskStatus.queued)];
    assert(throwsA!InvalidStateTransitionException({ validateRequestState(twice); }));
    auto blocked = state;
    blocked.tasks = [RequestTaskState("test", "fp2", RequestTaskStatus.blocked)];
    assert(throwsA!InvalidStateTransitionException({ validateRequestState(blocked); }));
    auto unfingerprinted = state;
    unfingerprinted.tasks = [RequestTaskState("test", "", RequestTaskStatus.queued)];
    assert(throwsA!InvalidStateTransitionException({ validateRequestState(unfingerprinted); }));
    auto errored = state;
    errored.error = "why";
    assert(throwsA!InvalidStateTransitionException({ validateRequestState(errored); }));
    errored.outcome = RequestOutcome.failed;
    validateRequestState(errored);
    assert(throwsA!InvalidStateTransitionException({ validateRequestState(RequestState.init); }));
}

unittest
{
    // Creating a state races another creation between the read and the write: the loser returns
    // the state that won
    import confector.testing.memory_document_store : InterleavingDocumentStore;

    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    createChain(direct, "c1");
    auto request = recordRequest(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");

    auto interleaving = new InterleavingDocumentStore(documents);
    interleaving.beforeNextWrite = () { direct.requestStates.createFor(request); };
    auto raced = new StateStores(interleaving).requestStates.createFor(request);
    assert(interleaving.beforeNextWrite is null, "The state was created between the read and the write");
    assert(raced.version_ == 1 && raced.requestId == "r1" && raced.outcome == RequestOutcome.open);
    assert(direct.requestStates.get("r1").get.version_ == 1);
}
