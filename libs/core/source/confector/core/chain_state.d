module confector.core.chain_state;

/**
 * Chain state (design record: bead confector-z7z.48; AGENTS.md, "What a build is" and "Coordinating
 * builds"): one ChainState document per chain, with the chain id as its id, read by id and changed
 * only by compare-and-set, so it works on every DocumentStore backend and in stateless
 * invocations. It names the chain's requests in the order they were added, so a chain's demand
 * never depends on the lagging request index; it caches the last evaluation
 * (confector.core.chain_evaluator) for the dashboard; and it carries the dirty marker that signals
 * land on. The collection declares no index yet: finding dirty chains is the sweep's (bead
 * confector-z7z.49.5), which will add a sparse one.
 *
 * It is a projection, never the only record of anything: the chain, its requests (each records
 * its demands, BuildRequest.demands), the ledgers and the rerun generations are authoritative.
 * Evaluating from them recomputes everything it caches, and `repair` rebuilds a missing one from
 * the chain and its requests.
 *
 * Protocols:
 *
 * - **Creating a chain** (the input resolver, bead confector-z7z.53.2): create the chain, then
 *   `createFor` its state. There is no multi-document transaction, so a crash between the two
 *   leaves a chain without a state; every operation on a missing state throws
 *   ChainStateMissingException rather than assuming one, and the caller `repair`s it from the chain
 *   and the requests it can find (`BuildRequestStore.listForChain`, plus any it holds).
 * - **Adding a request** (request intake, bead confector-z7z.23.7): record the request (it records
 *   its demands, read from settled ledgers), then `addRequest`, which appends its id and marks the
 *   chain dirty, then reconcile. Repeating the intake after a crash between the two adds it then;
 *   `addRequest` is idempotent.
 * - **Signals** (an execution the chain waited on ended, a rerun reached it): `markDirty`. It always
 *   writes, even to a state that is already dirty, so a reconcile that read the state before the
 *   signal cannot commit over it.
 * - **Reconciling** (bead confector-z7z.49.3): read the state, then by id its requests, their
 *   definitions, the generations and the ledgers; evaluate. If anything is needed, dispatch it and
 *   evaluate again: an evaluation that still needs executions is never committed (`commit`
 *   refuses it). Otherwise subscribe the chain on each awaited execution's ledger at the version
 *   the evaluation read (AwaitedExecution.ledger), never on a fresh read: an execution that ended
 *   since then makes that subscribe fail with DocumentConflictException (or report notActive), and
 *   the reconcile re-reads and evaluates again without committing, because nothing would wake a
 *   chain committed as waiting on an execution whose end it never saw. Then `commit` the
 *   evaluation at the state version read, which clears the dirty marker. A request or signal that
 *   landed meanwhile makes the commit fail with DocumentConflictException: re-read and reconcile
 *   again. A chain whose subscribe throws LedgerWaiterLimitException must not commit.
 */

import confector.core.build_stores : InvalidStateTransitionException;
import confector.core.chain_evaluator : ChainEvaluation;
import confector.core.document_collection;
import confector.api.document_store;
import confector.api.model;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;
import std.typecons : Nullable;

/// The state store collection holding chain states, keyed by chain id.
enum CollectionSpec chainStatesCollection = CollectionSpec("chain_states", null);

/// A chain has no ChainState: it was never created (a crash after creating the chain) or was
/// lost. Repair it (`ChainStateStore.repair`) and try again.
class ChainStateMissingException : Exception
{
    string chainId;

    this(string msg, string chainId, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.chainId = chainId;
    }
}

/**
 * The ChainState of `chain` rebuilt from `requests`, the chain's requests in the order to name them
 * (see `requestOrder`): no evaluation yet, and dirty when there is anything to evaluate. Pure.
 *
 * Throws: InvalidStateTransitionException if a request belongs to another chain or project or is
 * given twice.
 */
ChainState chainStateFor(in BuildChain chain, in BuildRequest[] requests) @safe
{
    ChainState state;
    state.chainId = chain.id;
    state.projectId = chain.projectId;
    foreach (ref request; requests)
    {
        requireBelongs(state, request);
        requireValid(!state.requestIds.canFind(request.id), format("Request '%s' is given twice for chain '%s'", request.id, chain.id));
        state.requestIds ~= request.id;
    }
    state.dirty = state.requestIds.length > 0;
    validateChainState(state);
    return state;
}

/**
 * `requests` sorted by request time, then id: the order a rebuilt ChainState names them in. Once a
 * ChainState exists, its own order (the order requests were added) is authoritative; the order only
 * breaks ties between requests whose demands saw as many stops, choosing whose definition an
 * execution is dispatched with, never whether a demand is settled.
 *
 * Throws: Exception if a request time is not an ISO 8601 timestamp.
 */
BuildRequest[] requestOrder(in BuildRequest[] requests) @trusted
{
    auto sorted = (cast(BuildRequest[]) requests).dup;
    string[string] keys;
    foreach (ref request; sorted) keys[request.id] = sortableTimestamp(request.requestedAt);
    sorted.sort!((a, b) => keys[a.id] != keys[b.id] ? keys[a.id] < keys[b.id] : a.id < b.id);
    return sorted;
}

/**
 * `state` with `evaluation` committed: its tasks cached and the dirty marker cleared. Pure.
 *
 * Throws: InvalidStateTransitionException if `evaluation` is of another chain or of other requests
 * than `state` names (a reconcile evaluates exactly the requests of the state it read), or still
 * needs executions (dispatch them and evaluate again: committing would clear the dirty marker with
 * nothing dispatched and nothing to wake the chain).
 */
ChainState withEvaluation(in ChainState state, in ChainEvaluation evaluation) @trusted
{
    requireValid(evaluation.needed.length == 0, format(
        "The evaluation of chain '%s' still needs %s executions; dispatch them and evaluate again before committing",
        state.chainId, evaluation.needed.length));
    requireValid(evaluation.chainId == state.chainId, format("An evaluation of chain '%s' cannot be committed to the state of chain '%s'",
        evaluation.chainId, state.chainId));
    requireValid(evaluation.requestIds == state.requestIds, format(
        "The evaluation of chain '%s' covers requests [%-(%s, %)], but its state names [%-(%s, %)]", state.chainId,
        evaluation.requestIds, state.requestIds));
    ChainState next = cast(ChainState) state;
    next.requestIds = state.requestIds.dup;
    next.tasks = (cast(ChainTaskState[]) evaluation.tasks).dup;
    next.dirty = false;
    validateChainState(next);
    return next;
}

/**
 * Throws InvalidStateTransitionException unless `state` is well formed: a chain and a project;
 * request ids that are not empty and appear once; and cached tasks that appear once, with a
 * fingerprint, a demand naming one of the requests, and blocking tasks exactly when blocked.
 */
void validateChainState(in ChainState state) @safe
{
    requireValid(state.chainId.length > 0 && state.projectId.length > 0, "A chain state needs a chain id and a project id");
    foreach (i, id; state.requestIds)
    {
        requireValid(id.length > 0, format("The state of chain '%s' names an empty request id", state.chainId));
        requireValid(!state.requestIds[0 .. i].canFind(id), format("The state of chain '%s' names request '%s' twice", state.chainId, id));
    }
    bool[string] seen;
    foreach (ref task; state.tasks)
    {
        requireValid(task.taskId.length > 0 && task.fingerprint.length > 0,
            format("A task state of chain '%s' needs a task id and a fingerprint", state.chainId));
        requireValid(task.taskId !in seen, format("The state of chain '%s' has task '%s' twice", state.chainId, task.taskId));
        seen[task.taskId] = true;
        requireValid(task.demandSeq >= 1 && task.demandSeq <= state.requestIds.length, format(
            "Task '%s' of chain '%s' is demanded by request %s of %s", task.taskId, state.chainId, task.demandSeq, state.requestIds.length));
        requireValid((task.status == ChainTaskStatus.blocked) == (task.blockedBy.length > 0), format(
            "Task '%s' of chain '%s' is %s and names %s blocking tasks", task.taskId, state.chainId, task.status, task.blockedBy.length));
    }
}

/**
 * Chain states in a DocumentStore. See the module documentation for the protocols. Chain states are
 * never removed.
 */
final class ChainStateStore
{
    /// How many times an operation that decides by itself (`addRequest`, `markDirty`) re-reads and
    /// retries after losing a compare-and-set before failing. Every lost attempt means another
    /// write succeeded; like a ledger, a chain's state is written by every request and signal that
    /// reaches the chain, and by its reconciles.
    enum maxWriteAttempts = 100;

    private DocumentCollection!ChainState m_states;

    /// Declares `chainStatesCollection` on `store`.
    this(DocumentStore store)
    {
        m_states = new DocumentCollection!ChainState(store, chainStatesCollection);
    }

    /**
     * Reads the state of chain `chainId` by id. Null if it has none.
     *
     * Throws: Exception if `chainId` is empty; MalformedDocumentException if the stored state names
     * another chain.
     */
    Nullable!(Versioned!ChainState) get(string chainId)
    {
        requireChainId(chainId);
        auto found = m_states.get(chainId);
        if (!found.isNull && found.get.chainId != chainId)
        {
            throw new MalformedDocumentException(format("Chain state '%s' in collection '%s' names chain '%s'", chainId,
                chainStatesCollection.name, found.get.chainId), chainStatesCollection.name, chainId);
        }
        return found;
    }

    /**
     * Creates the state of the new chain `chain`: no requests, clean. Idempotent: if the chain has
     * a state already, returns it and writes nothing.
     *
     * Throws: InvalidStateTransitionException if the stored state is of another project.
     */
    Versioned!ChainState createFor(in BuildChain chain)
    {
        return repair(chain, null);
    }

    /**
     * Returns the state of `chain`, rebuilding it first if it is missing (`chainStateFor`) from
     * `requests`, the chain's requests the caller could find: listed with
     * `BuildRequestStore.listForChain` (which may lag) plus any it holds, in any order
     * (`requestOrder` orders them). A rebuilt state with requests is dirty, so the next reconcile
     * fills in its evaluation. A state that exists is returned as it is: its own request order is
     * authoritative. A request the listing missed is added by repeating its intake.
     *
     * Throws: InvalidStateTransitionException if a request belongs to another chain or project, or
     * the stored state is of another project; Exception if a request time is malformed.
     */
    Versioned!ChainState repair(in BuildChain chain, in BuildRequest[] requests)
    {
        requireChainId(chain.id);
        // The listing and the requests the caller holds overlap: name each request once
        BuildRequest[] distinct;
        foreach (ref request; requests)
        {
            if (!distinct.canFind!(r => r.id == request.id)) distinct ~= cast(BuildRequest) request;
        }
        auto rebuilt = chainStateFor(chain, requestOrder(distinct));
        foreach (attempt; 0 .. 2)
        {
            auto existing = get(chain.id);
            if (!existing.isNull)
            {
                requireValid(existing.get.projectId == chain.projectId, format(
                    "The state of chain '%s' belongs to project '%s', not '%s'", chain.id, existing.get.projectId, chain.projectId));
                return existing.get;
            }
            try
            {
                return m_states.create(chain.id, rebuilt);
            }
            catch (DocumentConflictException)
            {
                // Created concurrently: read it and return that one.
            }
        }
        throw new Exception(format("The state of chain '%s' was reported to exist and then not found", chain.id));
    }

    /**
     * Adds `request` to its chain's state and marks the chain dirty, in one compare-and-set,
     * retried when another write lands first. Idempotent: a request already named is not added
     * again and nothing is written. Returns the state as stored afterwards.
     *
     * Throws: ChainStateMissingException if the chain has no state (repair it, then add again);
     * InvalidStateTransitionException if the request belongs to another project; Exception if
     * every one of maxWriteAttempts attempts lost a compare-and-set.
     */
    Versioned!ChainState addRequest(in BuildRequest request)
    {
        requireValid(request.id.length > 0, format("A request added to chain '%s' needs an id", request.chainId));
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = existing(request.chainId, format("request '%s' cannot be added", request.id));
            requireBelongs(current.value, request);
            if (current.requestIds.canFind(request.id)) return current;
            ChainState next = current.value;
            next.requestIds = current.requestIds ~ request.id;
            next.dirty = true;
            try
            {
                return m_states.replace(request.chainId, next, current.version_);
            }
            catch (DocumentConflictException)
            {
                // A signal, another request or a commit landed: read it and add again.
            }
        }
        throw new Exception(format("Could not add request '%s' to chain '%s': %s attempts in a row lost a compare-and-set",
            request.id, request.chainId, maxWriteAttempts));
    }

    /**
     * Marks chain `chainId` dirty: something it depends on changed. Always writes, even when the
     * chain is dirty already, so a reconcile that read the state before the change cannot commit
     * over it. Returns the state as stored afterwards.
     *
     * Throws: ChainStateMissingException if the chain has no state (repair it, then mark it);
     * Exception if every one of maxWriteAttempts attempts lost a compare-and-set.
     */
    Versioned!ChainState markDirty(string chainId)
    {
        requireChainId(chainId);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = existing(chainId, "it cannot be marked dirty");
            ChainState next = current.value;
            next.dirty = true;
            try
            {
                return m_states.replace(chainId, next, current.version_);
            }
            catch (DocumentConflictException)
            {
                // Another write landed: read it and mark again.
            }
        }
        throw new Exception(format("Could not mark chain '%s' dirty: %s attempts in a row lost a compare-and-set",
            chainId, maxWriteAttempts));
    }

    /**
     * Commits `evaluation`, made from the state `read`, by compare-and-set at the version read:
     * caches its tasks and clears the dirty marker (`withEvaluation`).
     *
     * Throws: DocumentConflictException if the state changed since `read` (a request or signal
     * landed): re-read and reconcile again; InvalidStateTransitionException if `evaluation` is not
     * of the requests `read` names.
     */
    Versioned!ChainState commit(in Versioned!ChainState read, in ChainEvaluation evaluation)
    {
        requireChainId(read.chainId);
        return m_states.replace(read.chainId, withEvaluation(read.value, evaluation), read.version_);
    }

    /// The state of chain `chainId`; throws ChainStateMissingException, saying what `failed`, if
    /// there is none.
    private Versioned!ChainState existing(string chainId, string failed)
    {
        auto found = get(chainId);
        if (found.isNull)
        {
            throw new ChainStateMissingException(format("Chain '%s' has no chain state, so %s; repair it from the chain and its requests",
                chainId, failed), chainId);
        }
        return found.get;
    }
}

private void requireBelongs(in ChainState state, in BuildRequest request) @safe
{
    requireValid(request.chainId == state.chainId && request.projectId == state.projectId, format(
        "Request '%s' (project '%s', chain '%s') does not belong to chain '%s' of project '%s'", request.id, request.projectId,
        request.chainId, state.chainId, state.projectId));
}

private void requireValid(bool condition, lazy string message) @safe
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

private void requireChainId(string chainId) @safe
{
    if (chainId.length == 0) throw new Exception("A chain state needs a chain id");
}

version (unittest)
{
    import confector.core.chain_evaluator;
    import confector.core.chain_pins : pinMap;
    import confector.core.fingerprint_ledger : ClaimOutcome, SubscribeOutcome;
    import confector.core.input_resolution : GraphResolution;
    import confector.core.rerun_generations : RerunGenerationReader, readGraphResolution;
    import confector.core.state_stores : StateStores;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import vibe.data.json : Json;

    /// compile -> test -> report, and lint; compile and lint build repository game.
    private ProjectDefinition sampleDefinition()
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
        TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
        TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
        TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game");
        return ProjectDefinition([compile, test, report, lint]);
    }

    private BuildChain sampleChain(string id)
    {
        BuildChain chain;
        chain.id = id;
        chain.projectId = "game";
        chain.number = 1;
        chain.headline = HeadlineRef(HeadlineKind.branch, "main");
        foreach (task; ["compile", "lint"])
        {
            chain.pins ~= PinnedInput(task, "src", "game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111")));
        }
        chain.createdAt = "2026-10-20T10:00:00Z";
        return chain;
    }

    /// Creates chain `id` without its state, as a resolver that crashed before creating it would.
    private BuildChain createChainOnly(StateStores stores, string id)
    {
        return stores.chains.create(sampleChain(id)).value;
    }

    /// Creates chain `id` and its state, as the input resolver does.
    private BuildChain createChain(StateStores stores, string id)
    {
        auto chain = createChainOnly(stores, id);
        stores.chainStates.createFor(chain);
        return chain;
    }

    private RerunGenerationReader readerOf(StateStores stores)
    {
        return (in string[] bases) => stores.rerunGenerations.read(bases);
    }

    /// The fingerprints, now, of the tasks a request for `targets` covers.
    private GraphResolution closureNow(StateStores stores, in BuildChain chain, in string[] targets,
        ProjectDefinition definition = sampleDefinition())
    {
        return readGraphResolution(chain.projectId, closureGraph(definition, targets), pinMap(chain.pins), readerOf(stores));
    }

    /// Records request `id` as an intake does: its demands from the settled ledgers, then the
    /// request. It is not yet added to the chain's state (`intake` does both).
    private BuildRequest recordRequest(StateStores stores, string chainId, string id, string[] targets, string requestedAt,
        ProjectDefinition definition = sampleDefinition())
    {
        const chain = stores.chains.get(chainId).get.value;
        auto closure = closureNow(stores, chain, targets, definition);
        ulong[string] stopSeqs;
        foreach (fingerprint; closure.fingerprints.byValue)
        {
            auto settled = stores.ledgers.settle(fingerprint);
            stopSeqs[fingerprint] = settled.ledger.isNull ? 0 : settled.ledger.get.stopSeq;
        }
        BuildRequest request;
        request.id = id;
        request.projectId = chain.projectId;
        request.chainId = chain.id;
        request.targets = targets;
        request.intent = BuildIntent.build;
        request.trigger.type = TriggerType.manual;
        request.definitionId = stores.definitions.put(definition);
        request.definitionSource = DefinitionSource(DefinitionLocation.confector);
        request.demands = requestDemands(closure, stopSeqs);
        request.requestedBy = "jason";
        request.requestedAt = requestedAt;
        return stores.requests.create(request).value;
    }

    private BuildRequest intake(StateStores stores, string chainId, string id, string[] targets, string requestedAt)
    {
        auto request = recordRequest(stores, chainId, id, targets, requestedAt);
        stores.chainStates.addRequest(request);
        return request;
    }

    /// The chain's requests as its state names them, each with its definition, read by id.
    private ChainRequest[] requestsOf(StateStores stores, in ChainState state)
    {
        ChainRequest[] requests;
        foreach (id; state.requestIds)
        {
            auto request = stores.requests.get(id).get.value;
            requests ~= ChainRequest(request, stores.definitions.get(request.definitionId).get);
        }
        return requests;
    }

    /// Evaluates chain `chainId` from what the stores hold, all read by id, from the state `read`.
    private ChainEvaluation evaluateFrom(StateStores stores, in Versioned!ChainState read)
    {
        const chain = stores.chains.get(read.chainId).get.value;
        auto requests = requestsOf(stores, read.value);
        auto generations = readChainGenerations(chain, requests, readerOf(stores));
        LedgerSummary[string] summaries;
        foreach (fingerprint; chainFingerprints(chain, requests, generations))
        {
            summaries[fingerprint] = readLedgerSummary(stores.ledgers, stores.executions, fingerprint);
        }
        return evaluateChain(chain, requests, generations, summaries);
    }

    /// Claims and records the execution `needed` asks for, as the dispatcher does (bead
    /// confector-z7z.49.3), with the definition of the request it is needed for.
    private void dispatch(StateStores stores, in NeededExecution needed)
    {
        auto claimed = stores.ledgers.claim(needed.fingerprint, needed.seenExecutionSeq);
        assert(claimed.outcome == ClaimOutcome.won, "The test dispatcher's claim must win");
        auto request = stores.requests.get(needed.requestId).get;
        TaskExecution execution;
        execution.id = claimed.executionId;
        execution.projectId = request.projectId;
        execution.taskId = needed.taskId;
        execution.fingerprint = needed.fingerprint;
        execution.status = ExecutionStatus.queued;
        foreach (ref task; stores.definitions.get(request.definitionId).get.tasks)
        {
            if (task.id == needed.taskId) execution.definition = task;
        }
        execution.definitionHash = "def";
        execution.inputs = cast(ResolvedInput[]) needed.inputs;
        execution.createdAt = "2026-10-20T10:00:00Z";
        stores.executions.createIfAbsent(execution);
    }

    /**
     * Reconciles chain `chainId` until it commits, as the chain reconciler does (bead
     * confector-z7z.49.3): read the state, evaluate, dispatch what is needed (then evaluate again),
     * subscribe on what it waits on at the ledger versions the evaluation read (re-evaluating,
     * without committing, if one conflicts or is no longer active), commit at the state version
     * read; on a conflict, start again.
     */
    private Versioned!ChainState reconcile(StateStores stores, string chainId, void delegate() beforeSubscribing = null)
    {
        import confector.api.document_store : DocumentConflictException;

        foreach (attempt; 0 .. 20)
        {
            auto read = stores.chainStates.get(chainId).get;
            auto evaluation = evaluateFrom(stores, read);
            if (evaluation.needed.length > 0)
            {
                foreach (ref needed; evaluation.needed) dispatch(stores, needed);
                continue;
            }
            if (beforeSubscribing !is null && evaluation.awaited.length > 0)
            {
                auto hook = beforeSubscribing;
                beforeSubscribing = null;
                hook();
            }
            try
            {
                bool ended = false;
                foreach (ref awaited; evaluation.awaited)
                {
                    const subscribed = stores.ledgers.subscribe(awaited.ledger, chainId);
                    ended = ended || subscribed.outcome == SubscribeOutcome.notActive;
                }
                if (ended) continue;
                return stores.chainStates.commit(read, evaluation);
            }
            catch (DocumentConflictException)
            {
                // Something changed since the read: reconcile again.
            }
        }
        assert(false, "The test reconcile did not converge");
    }

    /// Ends the active execution of `taskId`'s current fingerprint in chain `chainId` with `status`:
    /// the terminal compare-and-set, the fold, and the drain marking its waiters dirty.
    private void finish(StateStores stores, in BuildChain chain, string taskId, ExecutionStatus status)
    {
        const fingerprint = closureNow(stores, chain, [taskId]).fingerprints[taskId];
        auto ledger = stores.ledgers.get(fingerprint).get;
        auto current = stores.executions.get(ledger.activeExecutionId).get;
        TaskExecution ended = current.value;
        ended.status = status;
        ended.finishedAt = "2026-10-20T11:00:00Z";
        stores.executions.update(current, ended);
        auto folded = stores.ledgers.fold(ended).ledger;
        foreach (ref notice; folded.pendingNotify) stores.chainStates.markDirty(notice.chainId);
        stores.ledgers.clearNotified(fingerprint, folded.pendingNotify);
    }

    private ChainTaskState taskOf(in ChainState state, string taskId)
    {
        foreach (ref task; state.tasks)
        {
            if (task.taskId == taskId) return cast(ChainTaskState) task;
        }
        assert(false, format("task '%s' has no state", taskId));
    }

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }
}

unittest
{
    // A chain's state is created with the chain, clean and empty; creating it again is a no-op.
    // Adding a request appends its id and marks the chain dirty, once
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto chain = createChain(stores, "c1");
    auto created = stores.chainStates.get("c1").get;
    assert(created.version_ == 1 && created.chainId == "c1" && created.projectId == "game");
    assert(created.requestIds.length == 0 && created.tasks.length == 0 && !created.dirty);
    assert(stores.chainStates.createFor(chain).version_ == 1, "Creating it again writes nothing");
    assert(stores.chainStates.get("c9").isNull);

    auto request = recordRequest(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto added = stores.chainStates.addRequest(request);
    assert(added.requestIds == ["r1"] && added.dirty && added.version_ == 2);
    assert(stores.chainStates.addRequest(request).version_ == 2, "Adding a request again writes nothing");

    // A request of another chain or project is refused, as is a state of another project
    auto stray = request;
    stray.projectId = "tools";
    assert(throwsA!InvalidStateTransitionException({ stores.chainStates.addRequest(stray); }));
    auto otherProject = chain;
    otherProject.projectId = "tools";
    assert(throwsA!InvalidStateTransitionException({ stores.chainStates.createFor(otherProject); }));
    assert(throwsA!Exception({ stores.chainStates.get(""); }));

    // Marking dirty always writes, dirty or not
    auto marked = stores.chainStates.markDirty("c1");
    assert(marked.dirty && marked.version_ == 3);
    assert(stores.chainStates.markDirty("c1").version_ == 4);

    // An evaluation that still needs executions is never committed: it would clear the dirty
    // marker with nothing dispatched
    auto unready = stores.chainStates.get("c1").get;
    auto needing = evaluateFrom(stores, unready);
    assert(needing.needed.length == 1);
    assert(throwsA!InvalidStateTransitionException({ stores.chainStates.commit(unready, needing); }));
    assert(stores.chainStates.get("c1").get.version_ == unready.version_ && stores.chainStates.get("c1").get.dirty);

    // A reconcile commits its evaluation at the version it read, caching the tasks and clearing
    // the dirty marker; a commit from an older read conflicts
    foreach (ref needed; needing.needed) dispatch(stores, needed);
    auto read = stores.chainStates.get("c1").get;
    auto evaluation = evaluateFrom(stores, read);
    auto committed = stores.chainStates.commit(read, evaluation);
    assert(!committed.dirty && committed.tasks.length == 2 && taskOf(committed, "compile").status == ChainTaskStatus.queued);
    assert(throwsA!DocumentConflictException({ stores.chainStates.commit(read, evaluation); }));

    // An evaluation of other requests or another chain is refused
    auto fresh = stores.chainStates.get("c1").get;
    auto stale = evaluation;
    stale.requestIds = null;
    assert(throwsA!InvalidStateTransitionException({ stores.chainStates.commit(fresh, stale); }));
    auto elsewhere = evaluation;
    elsewhere.chainId = "c2";
    assert(throwsA!InvalidStateTransitionException({ stores.chainStates.commit(fresh, elsewhere); }));

    // States persist across a restart
    auto restarted = new StateStores((cast(InMemoryDocumentStore) stores.documentStore).restart());
    assert(restarted.chainStates.get("c1").get.value == committed.value);
}

unittest
{
    // A chain without a state (the resolver crashed between creating the chain and its state)
    // is never assumed to have one: adding a request or marking it dirty fails loudly, naming it.
    // Repair rebuilds it from the chain and its requests, dirty, and the next reconcile fills it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto chain = createChainOnly(stores, "c1");
    auto request = recordRequest(stores, "c1", "r1", ["report"], "2026-10-20T10:00:00Z");
    try
    {
        stores.chainStates.addRequest(request);
        assert(false, "A missing chain state must not be assumed");
    }
    catch (ChainStateMissingException e)
    {
        assert(e.chainId == "c1" && e.msg.canFind("'c1'") && e.msg.canFind("repair"));
    }
    assert(throwsA!ChainStateMissingException({ stores.chainStates.markDirty("c1"); }));

    // The intake repairs it from what it can find (the lagging listing and the request it holds),
    // and adds its request again, which is now there
    auto repaired = stores.chainStates.repair(chain, stores.requests.listForChain("c1") ~ request);
    assert(repaired.requestIds == ["r1"] && repaired.dirty && repaired.tasks.length == 0);
    assert(stores.chainStates.addRequest(request).version_ == repaired.version_);
    assert(stores.chainStates.repair(chain, null).value == repaired.value, "A state that exists is never rebuilt over");

    auto reconciled = reconcile(stores, "c1");
    assert(!reconciled.dirty && taskOf(reconciled, "compile").status == ChainTaskStatus.queued);

    // Rebuilding names requests in request time order, refuses requests of another chain, and an
    // empty chain's rebuilt state is clean
    auto later = recordRequest(stores, "c1", "r0", ["lint"], "2026-10-20T09:00:00Z");
    assert(chainStateFor(chain, requestOrder([request, later])).requestIds == ["r0", "r1"]);
    assert(throwsA!InvalidStateTransitionException({ chainStateFor(chain, [request, request]); }));
    auto stray = request;
    stray.chainId = "c2";
    assert(throwsA!InvalidStateTransitionException({ chainStateFor(chain, [stray]); }));
    assert(!chainStateFor(chain, null).dirty);
}

unittest
{
    // Crash points of an intake and a reconcile: each is repaired by repeating the step
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "c1");

    // The intake recorded its request and crashed before adding it: repeating the intake finds
    // the request recorded and adds it
    auto request = recordRequest(stores, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    stores = new StateStores(documents.restart());
    assert(throwsA!DocumentConflictException({ stores.requests.create(request); }), "The request is already recorded");
    assert(stores.chainStates.addRequest(stores.requests.get("r1").get.value).requestIds == ["r1"]);

    // A reconcile dispatched and crashed before committing: the chain stays dirty, and the next
    // reconcile finds the execution active and commits
    auto read = stores.chainStates.get("c1").get;
    foreach (ref needed; evaluateFrom(stores, read).needed) dispatch(stores, needed);
    stores = new StateStores(documents.restart());
    assert(stores.chainStates.get("c1").get.dirty);
    auto committed = reconcile(stores, "c1");
    assert(!committed.dirty && taskOf(committed, "compile").status == ChainTaskStatus.queued);
    assert(taskOf(committed, "test").status == ChainTaskStatus.waitingUpstream);
}

unittest
{
    // A signal landing between a reconcile's read and its commit makes the commit fail, even when
    // the chain was already dirty when the reconcile read it; the reconcile reads again and sees
    // what the signal was about
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto chain = createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    reconcile(direct, "c1"); // compile dispatched; the chain waits on it
    direct.chainStates.markDirty("c1"); // say a rerun reached it

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    auto read = racing.chainStates.get("c1").get;
    assert(read.dirty);
    auto evaluation = evaluateFrom(racing, read);
    assert(taskOf(withEvaluation(read.value, evaluation), "compile").status == ChainTaskStatus.queued);

    // compile ends and its drain marks the chain dirty just before the reconcile commits
    interleaving.beforeNextWrite = () { finish(direct, chain, "compile", ExecutionStatus.succeeded); };
    assert(throwsA!DocumentConflictException({ racing.chainStates.commit(read, evaluation); }), "The signal must not be lost");
    auto again = reconcile(racing, "c1");
    assert(taskOf(again, "compile").status == ChainTaskStatus.succeeded && taskOf(again, "test").status == ChainTaskStatus.queued);
}

unittest
{
    // Requests added concurrently are both kept, in the order they land; a request added between
    // a reconcile's read and its commit makes the commit fail, so it is never evaluated late
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    createChain(direct, "c1");
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);

    auto first = recordRequest(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto second = recordRequest(direct, "c1", "r2", ["lint"], "2026-10-20T10:00:01Z");
    interleaving.beforeNextWrite = () { direct.chainStates.addRequest(second); };
    auto both = racing.chainStates.addRequest(first);
    assert(both.requestIds == ["r2", "r1"] && both.dirty);
    foreach (ref needed; evaluateFrom(direct, both).needed) dispatch(direct, needed);

    auto read = racing.chainStates.get("c1").get;
    auto evaluation = evaluateFrom(racing, read);
    auto third = recordRequest(direct, "c1", "r3", ["report"], "2026-10-20T10:00:02Z");
    interleaving.beforeNextWrite = () { direct.chainStates.addRequest(third); };
    assert(throwsA!DocumentConflictException({ racing.chainStates.commit(read, evaluation); }));
    auto committed = reconcile(racing, "c1");
    assert(committed.requestIds == ["r2", "r1", "r3"] && taskOf(committed, "report").status == ChainTaskStatus.waitingUpstream);

    // Two repairs at once: the second's create loses and it returns the first's state
    auto chain = createChainOnly(direct, "c2");
    interleaving.beforeNextWrite = () { direct.chainStates.createFor(chain); };
    auto repaired = racing.chainStates.repair(chain, null);
    assert(repaired.version_ == 1 && repaired.requestIds.length == 0);
}

unittest
{
    // A ChainState rebuilt from the chain, its requests and the ledgers equals the one maintained
    // step by step, after a history with a failure, a retry, a cancellation, a rerun and a later
    // request: nothing in it is the only record of anything
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    auto chain = createChain(stores, "c1");

    intake(stores, "c1", "r1", ["report"], "2026-10-20T10:00:00Z");
    reconcile(stores, "c1");
    finish(stores, chain, "compile", ExecutionStatus.failed);
    auto failed = reconcile(stores, "c1");
    assert(taskOf(failed, "compile").status == ChainTaskStatus.failed && taskOf(failed, "report").status == ChainTaskStatus.blocked);

    intake(stores, "c1", "r2", ["compile"], "2026-10-20T10:01:00Z"); // the retry
    reconcile(stores, "c1");
    finish(stores, chain, "compile", ExecutionStatus.succeeded);
    reconcile(stores, "c1");
    finish(stores, chain, "test", ExecutionStatus.succeeded);
    reconcile(stores, "c1");
    finish(stores, chain, "report", ExecutionStatus.cancelled);
    auto cancelled = reconcile(stores, "c1");
    assert(taskOf(cancelled, "report").status == ChainTaskStatus.cancelled);

    // compile is rerun: its generation is bumped and the rerun reaches this chain
    const base = closureNow(stores, chain, ["compile"]).bases["compile"];
    stores.rerunGenerations.bump(base);
    stores.chainStates.markDirty("c1");
    reconcile(stores, "c1");
    finish(stores, chain, "compile", ExecutionStatus.succeeded);
    reconcile(stores, "c1");
    finish(stores, chain, "test", ExecutionStatus.failed);
    intake(stores, "c1", "r3", ["lint"], "2026-10-20T10:02:00Z");
    reconcile(stores, "c1");
    finish(stores, chain, "lint", ExecutionStatus.succeeded);
    auto incremental = reconcile(stores, "c1");
    assert(!incremental.dirty && incremental.requestIds == ["r1", "r2", "r3"]);
    assert(taskOf(incremental, "compile").status == ChainTaskStatus.succeeded);
    assert(taskOf(incremental, "test").status == ChainTaskStatus.failed && taskOf(incremental, "report").status == ChainTaskStatus.blocked);
    assert(taskOf(incremental, "compile").demandSeq == 2 && taskOf(incremental, "compile").stopSeqAtDemand == 0,
        "The retry's demand was recorded at the old generation");
    assert(taskOf(incremental, "lint").status == ChainTaskStatus.succeeded && taskOf(incremental, "lint").demandSeq == 3);

    // The state is lost; it is rebuilt from the chain and its requests (as listed), and one
    // reconcile over the ledgers recomputes everything it cached
    documents.remove(chainStatesCollection.name, "c1", incremental.version_);
    auto rebuiltStores = new StateStores(documents.restart());
    auto repaired = rebuiltStores.chainStates.repair(rebuiltStores.chains.get("c1").get, rebuiltStores.requests.listForChain("c1"));
    assert(repaired.dirty && repaired.tasks.length == 0);
    auto rebuilt = reconcile(rebuiltStores, "c1");
    assert(rebuilt.value == incremental.value, "The rebuilt chain state must equal the maintained one");

    // And so does the pure rebuild, from the same inputs
    auto purelyRebuilt = withEvaluation(chainStateFor(chain, requestOrder(rebuiltStores.requests.listForChain("c1"))),
        evaluateFrom(rebuiltStores, rebuilt));
    assert(purelyRebuilt == incremental.value);
}

unittest
{
    // Malformed states are refused before anything is written
    ChainState state;
    state.chainId = "c1";
    state.projectId = "game";
    state.requestIds = ["r1"];
    validateChainState(state);
    ChainState[string] bad;
    auto noChain = state; noChain.chainId = null; bad["no chain"] = noChain;
    auto twice = state; twice.requestIds = ["r1", "r1"]; bad["a request twice"] = twice;
    auto empty = state; empty.requestIds = [""]; bad["an empty request id"] = empty;
    auto undemanded = state; undemanded.tasks = [ChainTaskState("compile", "fp", ChainTaskStatus.needed, true, 2)]; bad["a demand of no request"] = undemanded;
    auto unblocked = state; unblocked.tasks = [ChainTaskState("compile", "fp", ChainTaskStatus.blocked, true, 1)]; bad["a block without blockers"] = unblocked;
    auto doubled = state;
    doubled.tasks = [ChainTaskState("compile", "fp", ChainTaskStatus.needed, true, 1), ChainTaskState("compile", "fp", ChainTaskStatus.needed, true, 1)];
    bad["a task twice"] = doubled;
    foreach (what, malformed; bad)
    {
        assert(throwsA!InvalidStateTransitionException({ validateChainState(malformed); }), "A state with " ~ what ~ " must be refused");
    }
}

unittest
{
    // A wakeup cannot be lost between evaluating and subscribing: the execution the chain waits on
    // ends after the evaluation read its ledger and before the chain subscribes. Nobody was
    // subscribed, so its fold notices nobody and the chain is not marked dirty; the subscribe at
    // the version the evaluation read fails, the reconcile evaluates again instead of committing,
    // and the chain goes on to the next task rather than ending clean and waiting forever
    auto documents = new InMemoryDocumentStore();
    auto direct = new StateStores(documents);
    auto chain = createChain(direct, "c1");
    intake(direct, "c1", "r1", ["test"], "2026-10-20T10:00:00Z");
    auto read = direct.chainStates.get("c1").get;
    foreach (ref needed; evaluateFrom(direct, read).needed) dispatch(direct, needed); // compile; nobody subscribed yet

    // Step by step: the evaluation reads compile's ledger active; compile ends; the subscribe at the
    // version read conflicts, where a subscribe on a fresh read would find nothing to wait on
    auto evaluation = evaluateFrom(direct, direct.chainStates.get("c1").get);
    assert(evaluation.awaited.length == 1 && evaluation.needed.length == 0);
    finish(direct, chain, "compile", ExecutionStatus.succeeded);
    assert(throwsA!DocumentConflictException({ direct.ledgers.subscribe(evaluation.awaited[0].ledger, "c1"); }));

    // Through the reconcile: test is dispatched (nobody subscribed yet), and it ends between the
    // reconcile's evaluation and its subscribe. Its fold notices nobody, so only the subscribe at
    // the version read can tell the reconcile to evaluate again
    foreach (ref needed; evaluateFrom(direct, direct.chainStates.get("c1").get).needed) dispatch(direct, needed);
    const testAt = closureNow(direct, chain, ["test"]).fingerprints["test"];
    assert(direct.ledgers.get(testAt).get.subscribers.length == 0);
    auto committed = reconcile(direct, "c1", () { finish(direct, chain, "test", ExecutionStatus.succeeded); });
    assert(direct.ledgers.get(testAt).get.pendingNotify.length == 0, "Nobody was woken by the fold");
    assert(taskOf(committed, "test").status == ChainTaskStatus.succeeded, "The chain must not end clean and stuck");
    assert(!committed.dirty && taskOf(committed, "compile").status == ChainTaskStatus.succeeded);
}
