module confector.core.build_stores;

/**
 * State stores for the build model (design records: beads confector-z7z.4, confector-z7z.14,
 * confector-z7z.2 and confector-z7z.52; AGENTS.md, "What a build is" and "Coordinating builds"):
 * build chains, build requests and task executions, each a typed collection in the DocumentStore.
 * The definitions requests run with are in confector.core.definition_store.
 *
 * Correctness depends only on reads by id and compare-and-set on one document. Index queries
 * (`list...`, `find...ByNumber`) are for discovery and may lag behind writes; level-triggered
 * re-evaluation tolerates that. Writes that take the version they replace never retry on a lost
 * compare-and-set: they throw DocumentConflictException and the caller re-reads and decides
 * again. `ChainStore.addPins` takes only a chain id: its whole decision is the pin merge, so it
 * re-reads and decides again itself.
 *
 * Every write validates the whole document and rejects a malformed one loudly
 * (InvalidStateTransitionException, or InvalidPinsException for malformed pins).
 */

import confector.core.chain_pins : describePinKey, isEmptyPinned, mergePins, pinMap, samePinned, validatePins;
import confector.core.dag : TaskGraph;
import confector.core.input_resolution : unpinnedRepositoryInputs;
import confector.core.counters : CounterStore;
import confector.core.definition_store : DefinitionStore;
import confector.core.document_collection;
import confector.api.model;
import confector.api.document_store;

import vibe.data.json : Json;

import std.algorithm.searching : canFind;
import std.format : format;
import std.typecons : Nullable;

/// Build chains, by chain id; indexed by project and number, and by project and branch context
/// and number.
enum CollectionSpec buildChainsCollection = CollectionSpec("build_chains",
    [IndexSpec("by_project", "project_id", "number_key"), IndexSpec("by_branch", "branch_key", "number_key")]);

/// Build requests, by request id; indexed by chain and by project, in request order.
enum CollectionSpec buildRequestsCollection = CollectionSpec("build_requests",
    [IndexSpec("by_chain", "chain_id", "requested_key"), IndexSpec("by_project", "project_id", "requested_key")]);

/// Task executions, by execution id; indexed by fingerprint, by project and task, and (active
/// executions only) by status, each in creation order.
enum CollectionSpec taskExecutionsCollection = CollectionSpec("task_executions",
    [IndexSpec("by_fingerprint", "fingerprint", "created_key"),
     IndexSpec("by_task", "project_task", "created_key"),
     IndexSpec("active", "active_status", "created_key")]);

/// Page size of the queries that list everything they find.
private enum size_t pageSize = 100;

/// A write that would break the build model's rules: changing an immutable field, rewriting a
/// chain's history, or changing a terminal execution.
class InvalidStateTransitionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Build chains. A chain's identity (id, project, number, branch context, creation time) never
 * changes; its pins are only added (`addPins`), and once set never change; its labels change and
 * its events are only appended (`update`).
 */
final class ChainStore
{
    /// How many times `addPins` re-reads and retries after losing a compare-and-set to a
    /// concurrent write of the same chain before failing. Every lost attempt means another write
    /// succeeded; like a ledger, a chain is shared by every request that joins it, so many can
    /// add pins at once.
    enum maxWriteAttempts = 100;

    private DocumentCollection!BuildChain m_chains;
    private CounterStore m_counters;

    /// Declares `buildChainsCollection` and the counters collection on `store`.
    this(DocumentStore store)
    {
        m_chains = new DocumentCollection!BuildChain(store, buildChainsCollection, ["number_key", "branch_key"],
            (in BuildChain chain) => [
                "number_key": sortableNumber(chain.number),
                "branch_key": branchKey(chain.projectId, chain.branch),
            ]);
        m_counters = new CounterStore(store);
    }

    /// The `by_branch` partition key of project `projectId`'s chains of branch context `branch`.
    private static string branchKey(string projectId, in BranchContext branch) @safe
    {
        return compositeKey(projectId, branch.repositoryId, branch.kind, branch.refName);
    }

    /// Allocates the next chain number of project `projectId`, starting at 1. A number allocated
    /// for a chain that is then not created (because the create lost to a concurrent one) is not
    /// reused, so numbers can have gaps.
    ulong nextNumber(string projectId)
    {
        requireNonEmpty(projectId, "A chain number needs a project id");
        return m_counters.next(compositeKey("chain_number", projectId));
    }

    /// Reads a chain by id. Null if it does not exist.
    Nullable!(Versioned!BuildChain) get(string id)
    {
        return m_chains.get(id);
    }

    /**
     * Creates `chain`, with the pins it starts with (possibly none). Its number must be one from
     * `nextNumber`.
     *
     * Throws: DocumentConflictException if a chain with its id exists;
     * InvalidStateTransitionException if the chain is incomplete or malformed (see
     * `validateChain`); InvalidPinsException if its pins are not a well-formed list.
     */
    Versioned!BuildChain create(BuildChain chain)
    {
        validateChain(chain);
        return m_chains.create(chain.id, chain);
    }

    /**
     * Replaces the chain `current` with `next`, which may differ only in its labels and by events
     * appended to its history. Pins are added only by `addPins`.
     *
     * Throws: DocumentConflictException if the chain changed since `current` was read;
     * InvalidStateTransitionException if `next` changes anything else or is malformed.
     */
    Versioned!BuildChain update(in Versioned!BuildChain current, BuildChain next)
    {
        const was = current.value;
        requireValid(next.id == was.id && next.projectId == was.projectId && next.number == was.number
            && next.branch == was.branch && next.createdAt == was.createdAt,
            format("Only the labels and history of chain '%s' can change", was.id));
        requireValid(next.pins == was.pins,
            format("The pins of chain '%s' change only by adding pins (ChainStore.addPins)", was.id));
        requireValid(next.events.length >= was.events.length && next.events[0 .. was.events.length] == was.events,
            format("The history of chain '%s' can only be appended to", was.id));
        validateChain(next);
        return m_chains.replace(was.id, next, current.version_);
    }

    /**
     * Adds `pins` to chain `chainId`'s pins by compare-and-set, re-reading and merging again when
     * a concurrent write lands first. Pins only grow: an input the chain already pins to the same
     * value (whatever the display info) is left as it is, and when every pin is already there
     * nothing is written. Returns the chain as stored afterwards.
     *
     * Throws: PinConflictException if the chain pins one of the inputs to another value (pins
     * never change; nothing is written; decide again); InputResolutionException or
     * InvalidPinsException if a pin is not a pin of an external input, has an empty value, or
     * `pins` pins one input twice with different values (caller mistakes); Exception if the
     * chain does not exist or every one of maxWriteAttempts attempts lost a compare-and-set.
     */
    Versioned!BuildChain addPins(string chainId, in PinnedInput[] pins)
    {
        requireNonEmpty(chainId, "Adding pins needs a chain id");
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = m_chains.get(chainId);
            if (current.isNull) throw new Exception(format("Cannot add pins to chain '%s': it does not exist", chainId));
            const merged = mergePins(current.get.pins, pins);
            if (merged.length == current.get.pins.length) return current.get;

            BuildChain next = current.get.value;
            next.pins = cast(PinnedInput[]) merged;
            validateChain(next);
            try
            {
                return m_chains.replace(chainId, next, current.get.version_);
            }
            catch (DocumentConflictException)
            {
                // Another write landed since the read: read it and merge again.
            }
        }
        throw new Exception(format("Could not add pins to chain '%s': %s attempts in a row lost a compare-and-set",
            chainId, maxWriteAttempts));
    }

    /// Adds the one pin `pin` of input `input` to chain `chainId`, as `addPins` does.
    Versioned!BuildChain addPin(string chainId, in InputDecl input, in InputPin pin)
    {
        return addPins(chainId, [PinnedInput(cast(InputDecl) input, cast(InputPin) pin)]);
    }

    /// Lists project `projectId`'s chains by number, newest first unless `newestFirst` is false,
    /// at most `limit` of them. Discovery: may lag behind writes.
    Versioned!BuildChain[] listForProject(string projectId, size_t limit, bool newestFirst = true)
    {
        IndexQuery lookup;
        lookup.index = "by_project";
        lookup.partitionKey = projectId;
        lookup.descending = newestFirst;
        lookup.limit = pageSize;
        return m_chains.queryAll(lookup, limit);
    }

    /**
     * Lists project `projectId`'s chains of branch context `branch` by number, newest first unless
     * `newestFirst` is false, at most `limit` of them. Discovery: may lag behind writes, so a
     * chain just created may be missing. Deciding from it that no chain exists must not create a
     * duplicate (bead confector-z7z.53.2).
     */
    Versioned!BuildChain[] listForBranch(string projectId, in BranchContext branch, size_t limit, bool newestFirst = true)
    {
        requireNonEmpty(projectId, "Listing a branch's chains needs a project id");
        IndexQuery lookup;
        lookup.index = "by_branch";
        lookup.partitionKey = branchKey(projectId, branch);
        lookup.descending = newestFirst;
        lookup.limit = pageSize;
        return m_chains.queryAll(lookup, limit);
    }

    /// Finds project `projectId`'s chain number `number` ("build #123"). Discovery: may lag
    /// behind writes.
    Nullable!(Versioned!BuildChain) findByNumber(string projectId, ulong number)
    {
        IndexQuery lookup;
        lookup.index = "by_project";
        lookup.partitionKey = projectId;
        lookup.sortKeyFrom = sortableNumber(number);
        lookup.sortKeyTo = sortableNumber(number);
        lookup.limit = 1;
        auto found = m_chains.query(lookup).items;
        return found.length == 0 ? Nullable!(Versioned!BuildChain).init : Nullable!(Versioned!BuildChain)(found[0]);
    }
}

/**
 * Throws unless `chain` is a complete, well-formed chain: an id, a project, a number, a valid
 * creation time, a complete branch context, well-formed pins, labels that are not empty, and
 * complete events.
 *
 * Throws: InvalidStateTransitionException; InvalidPinsException for malformed pins.
 */
void validateChain(in BuildChain chain)
{
    requireValid(chain.id.length > 0 && chain.projectId.length > 0 && chain.number > 0 && chain.createdAt.length > 0,
        format("Chain '%s' needs an id, a project id, a number and a creation time", chain.id));
    requireTimestamp(chain.createdAt, format("The creation time of chain '%s'", chain.id));
    requireValid(chain.branch.repositoryId.length > 0 && chain.branch.refName.length > 0,
        format("Chain '%s' needs a branch context: a repository and a ref name", chain.id));
    validatePins(chain.pins, format("chain '%s'", chain.id));
    foreach (label; chain.labels)
    {
        requireValid(label.length > 0, format("Chain '%s' has an empty label", chain.id));
    }
    foreach (i, ref event; chain.events)
    {
        requireValid(event.requestId.length > 0 && event.taskId.length > 0,
            format("Event %s of chain '%s' needs the request that caused it and the task it concerns", i, chain.id));
        final switch (event.kind)
        {
            case ChainEventKind.rerun:
                requireValid(event.base.length > 0 && event.generation > 0,
                    format("Rerun event %s of chain '%s' needs the base fingerprint and the generation it was bumped to", i, chain.id));
                break;
        }
    }
}

/**
 * Build requests. Immutable: written once, never replaced or removed. A request is recorded only
 * once its chain and definition are stored and the chain holds every pin the request supplies,
 * so a crash between those writes and the request's never leaves a request whose pins or
 * definition are lost.
 */
final class BuildRequestStore
{
    private DocumentCollection!BuildRequest m_requests;
    private ChainStore m_chains;
    private DefinitionStore m_definitions;

    /// Declares `buildRequestsCollection` on `store`; `chains` and `definitions` are where the
    /// requests' chains and definitions are stored.
    this(DocumentStore store, ChainStore chains, DefinitionStore definitions)
    {
        if (chains is null || definitions is null)
        {
            throw new Exception("BuildRequestStore requires the chain store and the definition store");
        }
        m_requests = new DocumentCollection!BuildRequest(store, buildRequestsCollection, ["requested_key"],
            (in BuildRequest request) => ["requested_key": sortableTimestamp(request.requestedAt)]);
        m_chains = chains;
        m_definitions = definitions;
    }

    /// Reads a request by id. Null if it does not exist.
    Nullable!(Versioned!BuildRequest) get(string id)
    {
        return m_requests.get(id);
    }

    /**
     * Records `request`, after checking it against its chain and its definition, both read by id.
     *
     * Throws: DocumentConflictException if a request with its id exists;
     * InvalidStateTransitionException if it is incomplete or malformed (see `validateRequest`),
     * its chain does not exist or belongs to another project, its chain lacks or disagrees with
     * one of its pins, its definition is not stored, a target is not a task of its definition, or
     * its chain lacks a pin of an external input its targets or their upstream tasks declare;
     * InvalidPinsException if its pins are not a well-formed list.
     */
    Versioned!BuildRequest create(BuildRequest request)
    {
        validateRequest(request);

        auto chain = m_chains.get(request.chainId);
        requireValid(!chain.isNull, format("Request '%s' names chain '%s', which does not exist", request.id, request.chainId));
        requireValid(chain.get.projectId == request.projectId,
            format("Request '%s' is for project '%s', but chain '%s' belongs to project '%s'", request.id, request.projectId,
                request.chainId, chain.get.projectId));
        const chainPins = pinMap(chain.get.pins);
        foreach (ref entry; request.pins)
        {
            auto onChain = entry.input in chainPins;
            requireValid(onChain !is null && samePinned(onChain.pinned, entry.pin.pinned),
                format("Request '%s' pins %s, which chain '%s' %s; add the request's pins to the chain first",
                    request.id, describePinKey(entry.input), request.chainId, onChain is null ? "lacks" : "pins to another value"));
        }

        auto definition = m_definitions.get(request.definitionId);
        requireValid(!definition.isNull,
            format("Request '%s' runs with definition '%s', which is not stored", request.id, request.definitionId));
        foreach (target; request.targets)
        {
            requireValid(definition.get.tasks.canFind!(t => t.id == target),
                format("Request '%s' targets task '%s', which its definition '%s' does not have", request.id, target,
                    request.definitionId));
        }

        // Every external input the targets and their upstream tasks declare must be pinned on the
        // chain already, so the request can be evaluated against its chain's pins alone.
        auto graph = new TaskGraph(definition.get.tasks);
        bool[string] needed;
        foreach (target; request.targets)
        {
            foreach (taskId; graph.resolveSubgraph(target)) needed[taskId] = true;
        }
        TaskNode[] closure;
        foreach (taskId; graph.topologicalSort())
        {
            if (taskId in needed) closure ~= graph.getTask(taskId);
        }
        auto unpinned = unpinnedRepositoryInputs(new TaskGraph(closure), chainPins);
        if (unpinned.length > 0)
        {
            string[] missing;
            foreach (key; unpinned) missing ~= describePinKey(key);
            requireValid(false, format("Request '%s' needs pins that chain '%s' lacks: %-(%s, %); add them to the chain first",
                request.id, request.chainId, missing));
        }
        return m_requests.create(request.id, request);
    }

    /// Lists chain `chainId`'s requests, oldest first. Discovery: may lag behind writes, which a
    /// level-triggered evaluation tolerates (a request not yet listed is seen next time).
    BuildRequest[] listForChain(string chainId)
    {
        IndexQuery lookup;
        lookup.index = "by_chain";
        lookup.partitionKey = chainId;
        lookup.limit = pageSize;
        return values(m_requests.queryAll(lookup));
    }

    /// Lists project `projectId`'s requests, newest first, at most `limit` of them. Discovery.
    BuildRequest[] listForProject(string projectId, size_t limit)
    {
        IndexQuery lookup;
        lookup.index = "by_project";
        lookup.partitionKey = projectId;
        lookup.descending = true;
        lookup.limit = pageSize;
        return values(m_requests.queryAll(lookup, limit));
    }
}

/**
 * Throws unless `request` is complete and well formed on its own: an id, a project, a chain, at
 * least one target with none empty or repeated (exactly one for a rerun), well-formed pins, a
 * definition id and a complete definition source, who made it, and a valid request time.
 *
 * Throws: InvalidStateTransitionException; InvalidPinsException for malformed pins.
 */
void validateRequest(in BuildRequest request)
{
    requireValid(request.id.length > 0 && request.projectId.length > 0 && request.chainId.length > 0 && request.targets.length > 0,
        format("Request '%s' needs an id, a project id, a chain id and at least one target", request.id));
    foreach (i, target; request.targets)
    {
        requireValid(target.length > 0, format("Request '%s' has an empty target", request.id));
        requireValid(!request.targets[0 .. i].canFind(target), format("Request '%s' targets task '%s' twice", request.id, target));
    }
    requireValid(request.intent != BuildIntent.rerun || request.targets.length == 1,
        format("Rerun request '%s' must name exactly the one task to rerun", request.id));
    validatePins(request.pins, format("request '%s'", request.id));
    requireValid(request.definitionId.length > 0, format("Request '%s' needs the id of the definition it runs with", request.id));

    const source = request.definitionSource;
    final switch (source.location)
    {
        case DefinitionLocation.confector:
            requireValid(source.repositoryId.length == 0 && source.refName.length == 0 && source.path.length == 0
                && (source.revision.type == Json.Type.null_ || source.revision.type == Json.Type.undefined),
                format("Request '%s' read its definition from Confector, so its source names no repository, ref, path or revision (the definition id identifies it)",
                    request.id));
            break;
        case DefinitionLocation.repository:
            requireValid(source.repositoryId.length > 0 && source.refName.length > 0 && source.path.length > 0,
                format("Request '%s' read its definition from a repository, so its source needs the repository, ref and path", request.id));
            requireValid(!isEmptyPinned(source.revision),
                format("Request '%s' read its definition from a repository, so its source needs the revision read (the provider's pinned value)",
                    request.id));
            break;
    }
    requireValid(request.requestedBy.length > 0, format("Request '%s' needs the identity that made it", request.id));
    requireTimestamp(request.requestedAt, format("The request time of request '%s'", request.id));
}

/**
 * Task executions. Append-only and shared across chains: an execution is created queued, moves
 * between queued and running while workers claim and lose it, and once terminal never changes
 * again. Its identity (project, task, fingerprint, creation time) and the definition it was
 * dispatched with never change.
 */
final class ExecutionStore
{
    private DocumentCollection!TaskExecution m_executions;

    /// Declares `taskExecutionsCollection` on `store`.
    this(DocumentStore store)
    {
        m_executions = new DocumentCollection!TaskExecution(store, taskExecutionsCollection,
            ["created_key", "project_task", "active_status"], &derivedFields);
    }

    private static string[string] derivedFields(in TaskExecution execution)
    {
        string[string] fields = [
            "created_key": sortableTimestamp(execution.createdAt),
            "project_task": compositeKey(execution.projectId, execution.taskId),
        ];
        if (isActive(execution.status)) fields["active_status"] = execution.status;
        return fields;
    }

    /// Whether an execution with `status` is active (queued or running).
    static bool isActive(ExecutionStatus status) pure nothrow @safe
    {
        return status == ExecutionStatus.queued || status == ExecutionStatus.running;
    }

    /// Reads an execution by id. Null if it does not exist.
    Nullable!(Versioned!TaskExecution) get(string id)
    {
        return m_executions.get(id);
    }

    /**
     * Records a new execution, which must be queued: an execution is created when it is
     * dispatched.
     *
     * Throws: DocumentConflictException if an execution with its id exists;
     * InvalidStateTransitionException if it has no id, project, task or fingerprint, or is not
     * queued; Exception if `createdAt` is not an ISO 8601 timestamp.
     */
    Versioned!TaskExecution create(TaskExecution execution)
    {
        requireValid(execution.id.length > 0 && execution.projectId.length > 0 && execution.taskId.length > 0
            && execution.fingerprint.length > 0,
            format("Execution '%s' needs an id, a project id, a task id and a fingerprint", execution.id));
        requireValid(execution.status == ExecutionStatus.queued,
            format("Execution '%s' must be created queued, not %s", execution.id, execution.status));
        return m_executions.create(execution.id, execution);
    }

    /**
     * Records `execution` as `create` does, unless an execution with its id exists already; then
     * returns the stored one, whatever its status, and writes nothing. For executions with
     * deterministic ids (confector.core.fingerprint_ledger.executionIdFor): the dispatcher that
     * won a claim, and anyone repairing a claim whose dispatcher crashed before recording it,
     * create the same execution, and whichever writes first is kept. The stored execution may
     * carry another request's definition: an execution runs with the definition of whoever
     * recorded it (AGENTS.md, "Pipeline definitions").
     *
     * Callers must check the returned record's status: a slow dispatcher or repairer can get back
     * an execution that already ran and finished, which must not be sent again or treated as
     * newly queued.
     *
     * Throws: as `create`; InvalidStateTransitionException if the stored execution has another
     * project, task or fingerprint, which a deterministic id rules out unless the store is
     * corrupt.
     */
    Versioned!TaskExecution createIfAbsent(TaskExecution execution)
    {
        foreach (attempt; 0 .. 2)
        {
            auto existing = m_executions.get(execution.id);
            if (!existing.isNull)
            {
                const was = existing.get.value;
                requireValid(was.projectId == execution.projectId && was.taskId == execution.taskId
                    && was.fingerprint == execution.fingerprint,
                    format("Execution '%s' exists for project '%s', task '%s' at fingerprint %s, not for project '%s', task '%s' at fingerprint %s",
                        execution.id, was.projectId, was.taskId, was.fingerprint, execution.projectId, execution.taskId,
                        execution.fingerprint));
                return existing.get;
            }
            try
            {
                return create(execution);
            }
            catch (DocumentConflictException)
            {
                // Created concurrently: read it and check it is the same execution.
            }
        }
        throw new Exception(format("Execution '%s' was reported to exist and then not found", execution.id));
    }

    /**
     * Replaces the execution `current` with `next`.
     *
     * Throws: DocumentConflictException if the execution changed since `current` was read;
     * InvalidStateTransitionException if `current` is terminal or `next` changes its identity,
     * or the definition (and its hash), inputs or repository addresses it was dispatched with, or
     * `next` is terminal without recording when it finished.
     */
    Versioned!TaskExecution update(in Versioned!TaskExecution current, TaskExecution next)
    {
        const was = current.value;
        requireValid(isActive(was.status),
            format("Execution '%s' is %s, and a terminal execution never changes", was.id, was.status));
        requireValid(next.id == was.id && next.projectId == was.projectId && next.taskId == was.taskId
            && next.fingerprint == was.fingerprint && next.createdAt == was.createdAt,
            format("The identity of execution '%s' cannot change", was.id));
        requireValid(next.definitionHash == was.definitionHash && next.definition == cast(TaskNode) was.definition
            && next.inputs == was.inputs && next.repositoryAddresses == cast(string[string]) was.repositoryAddresses,
            format("Execution '%s' runs with the definition and inputs it was dispatched with; they cannot change", was.id));
        requireValid(isActive(next.status) || next.finishedAt.length > 0,
            format("Execution '%s' is %s, and must record when it finished", was.id, next.status));
        return m_executions.replace(was.id, next, current.version_);
    }

    /// Lists every execution recorded at `fingerprint`, oldest first. Discovery: may lag behind
    /// writes.
    TaskExecution[] listForFingerprint(string fingerprint)
    {
        IndexQuery lookup;
        lookup.index = "by_fingerprint";
        lookup.partitionKey = fingerprint;
        lookup.limit = pageSize;
        return values(m_executions.queryAll(lookup));
    }

    /// Lists task `taskId` of project `projectId`'s executions ("task runs"), newest first, at
    /// most `limit` of them. Discovery.
    TaskExecution[] listForTask(string projectId, string taskId, size_t limit)
    {
        IndexQuery lookup;
        lookup.index = "by_task";
        lookup.partitionKey = compositeKey(projectId, taskId);
        lookup.descending = true;
        lookup.limit = pageSize;
        return values(m_executions.queryAll(lookup, limit));
    }

    /// Lists active executions with `status` (queued or running), oldest first, at most `limit`
    /// of them. Discovery.
    TaskExecution[] listActive(ExecutionStatus status, size_t limit)
    {
        requireValid(isActive(status), format("%s is not an active execution status", status));
        IndexQuery lookup;
        lookup.index = "active";
        lookup.partitionKey = status;
        lookup.limit = pageSize;
        return values(m_executions.queryAll(lookup, limit));
    }
}

private T[] values(T)(Versioned!T[] items)
{
    T[] result;
    result.reserve(items.length);
    foreach (item; items) result ~= item.value;
    return result;
}

private void requireValid(bool condition, lazy string message)
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

/// Throws InvalidStateTransitionException unless `timestamp` is an ISO 8601 timestamp; `what`
/// names it for the message.
private void requireTimestamp(string timestamp, lazy string what)
{
    try sortableTimestamp(timestamp);
    catch (Exception e) throw new InvalidStateTransitionException(format("%s is not valid: %s", what, e.msg));
}

private void requireNonEmpty(string value, lazy string message)
{
    if (value.length == 0) throw new Exception(message);
}

version (unittest)
{
    import confector.core.chain_pins : InvalidPinsException, PinConflictException;
    import confector.core.input_resolution : InputResolutionException;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    private PinnedInput pinOf(string repository, string refSelector, string sha, string[string] info = null)
    {
        return PinnedInput(repositoryInput(repository, refSelector), InputPin(Json(sha), info));
    }

    private BuildChain sampleChain(string projectId, ulong number, string refName = "main")
    {
        BuildChain chain;
        chain.id = format("%s-%s", projectId, number);
        chain.projectId = projectId;
        chain.number = number;
        chain.branch = BranchContext(projectId, RefKind.branch, refName);
        chain.pins = [pinOf(projectId, "main", "aaa111")];
        chain.createdAt = "2026-10-15T14:02:00Z";
        return chain;
    }

    private TaskExecution sampleExecution(string id, string fingerprint, string createdAt, string taskId = "compile")
    {
        TaskExecution execution;
        execution.id = id;
        execution.projectId = "game";
        execution.taskId = taskId;
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.definition.id = taskId;
        execution.definitionHash = "def1";
        execution.createdAt = createdAt;
        return execution;
    }

    /// A project definition with tasks `compile` and `lint`.
    private ProjectDefinition sampleDefinition()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game", "main");
        TaskNode lint;
        lint.id = "lint";
        return ProjectDefinition([compile, lint]);
    }

    private BuildRequest sampleRequest(string id, string chainId, string definitionId)
    {
        BuildRequest request;
        request.id = id;
        request.projectId = "game";
        request.chainId = chainId;
        request.targets = ["compile"];
        request.intent = BuildIntent.build;
        request.trigger.type = TriggerType.manual;
        request.definitionId = definitionId;
        request.definitionSource = DefinitionSource(DefinitionLocation.confector);
        request.requestedBy = "jason";
        request.requestedAt = "2026-10-15T14:02:00.5Z";
        return request;
    }
}

unittest
{
    // Chains: created once, numbered per project, with a branch context and the pins they start with
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    assert(chains.nextNumber("game") == 1);
    assert(chains.nextNumber("game") == 2);
    assert(chains.nextNumber("tools") == 1);

    auto created = chains.create(sampleChain("game", 1));
    assert(created.version_ == 1);
    assert(chains.get(created.id).get.value == created.value);
    assert(created.branch == BranchContext("game", RefKind.branch, "main") && created.pins == [pinOf("game", "main", "aaa111")]);
    assert(chains.get("game-9").isNull);
    assert(throwsA!DocumentConflictException({ chains.create(sampleChain("game", 1)); }), "A chain is created once");

    // A chain may start without pins: a project with no external inputs has none
    auto unpinned = sampleChain("game", 2);
    unpinned.pins = null;
    assert(chains.create(unpinned).pins.length == 0);

    // Incomplete or malformed chains are rejected
    auto noId = sampleChain("game", 3);
    noId.id = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noId); }));
    auto noProject = sampleChain("game", 3);
    noProject.projectId = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noProject); }));
    auto noNumber = sampleChain("game", 0);
    assert(throwsA!InvalidStateTransitionException({ chains.create(noNumber); }));
    auto badTime = sampleChain("game", 3);
    badTime.createdAt = "today";
    assert(throwsA!InvalidStateTransitionException({ chains.create(badTime); }));
    auto noBranch = sampleChain("game", 3);
    noBranch.branch.refName = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noBranch); }), "A chain needs a branch context");
    auto noBranchRepository = sampleChain("game", 3);
    noBranchRepository.branch.repositoryId = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noBranchRepository); }));
    auto unsortedPins = sampleChain("game", 3);
    unsortedPins.pins = [pinOf("tools", "main", "ttt111"), pinOf("game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ chains.create(unsortedPins); }));
    auto doublePinned = sampleChain("game", 3);
    doublePinned.pins = [pinOf("game", "main", "aaa111"), pinOf("game", "main", "bbb222")];
    assert(throwsA!InvalidPinsException({ chains.create(doublePinned); }));
    auto emptyPin = sampleChain("game", 3);
    emptyPin.pins = [PinnedInput(repositoryInput("game", "main"), InputPin(Json(null)))];
    assert(throwsA!InvalidPinsException({ chains.create(emptyPin); }));
    auto valuePin = sampleChain("game", 3);
    valuePin.pins = [PinnedInput(valueInput("x"), InputPin(Json("x")))];
    assert(throwsA!InvalidPinsException({ chains.create(valuePin); }));
    auto emptyLabel = sampleChain("game", 3);
    emptyLabel.labels = [""];
    assert(throwsA!InvalidStateTransitionException({ chains.create(emptyLabel); }));
    auto badEvent = sampleChain("game", 3);
    badEvent.events = [ChainEvent(ChainEventKind.rerun, "r1", "compile", "base", 0)];
    assert(throwsA!InvalidStateTransitionException({ chains.create(badEvent); }), "A rerun bumps to generation 1 or later");
    assert(chains.get("game-3").isNull, "Nothing malformed was written");

    // Chains persist across a restart
    assert(new ChainStore(documents.restart()).get(created.id).get.value == created.value);

    // A malformed chain written behind the store's back fails loudly when read
    documents.create(buildChainsCollection.name, "broken", Json(["id": Json("broken"), "project_id": Json("game")]));
    assert(throwsA!MalformedDocumentException({ chains.get("broken"); }));
}

unittest
{
    // Chains: only labels change and history is only appended, by compare-and-set; the identity,
    // branch and pins never change through update
    auto chains = new ChainStore(new InMemoryDocumentStore());
    auto v1 = chains.create(sampleChain("game", 1));

    BuildChain labelled = v1.value;
    labelled.labels = ["release candidate"];
    labelled.events = [ChainEvent(ChainEventKind.rerun, "r2", "compile", "base", 1)];
    auto v2 = chains.update(v1, labelled);
    assert(v2.version_ == 2 && v2.labels == ["release candidate"] && v2.events.length == 1);

    // A stale writer loses
    BuildChain stale = v1.value;
    stale.labels = ["other"];
    assert(throwsA!DocumentConflictException({ chains.update(v1, stale); }));

    BuildChain rewritten = v2.value;
    rewritten.events = [ChainEvent(ChainEventKind.rerun, "r3", "compile", "base", 2)];
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, rewritten); }), "History is never rewritten");
    BuildChain truncated = v2.value;
    truncated.events = null;
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, truncated); }));

    BuildChain moved = v2.value;
    moved.projectId = "tools";
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, moved); }));
    BuildChain renumbered = v2.value;
    renumbered.number = 9;
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, renumbered); }));
    BuildChain rebranched = v2.value;
    rebranched.branch.refName = "release";
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, rebranched); }), "The branch is part of the identity");
    BuildChain repinned = v2.value;
    repinned.pins = [pinOf("game", "main", "bbb222")];
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, repinned); }), "A pin never changes");
    BuildChain grown = v2.value;
    grown.pins ~= pinOf("tools", "main", "ttt111");
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, grown); }), "Pins are added only by addPins");
    BuildChain malformedEvent = v2.value;
    malformedEvent.events ~= ChainEvent(ChainEventKind.rerun, "", "compile", "base", 2);
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, malformedEvent); }));

    BuildChain appended = v2.value;
    appended.events ~= ChainEvent(ChainEventKind.rerun, "r3", "compile", "base", 2);
    assert(chains.update(v2, appended).events.length == 2);
}

unittest
{
    // Pins only grow: addPins adds what is missing, writes nothing when everything is there, and
    // refuses to change a pin
    auto chains = new ChainStore(new InMemoryDocumentStore());
    auto v1 = chains.create(sampleChain("game", 1));

    // Already pinned to the same value, whatever the display info: nothing is written
    auto same = chains.addPin(v1.id, repositoryInput("game", "main"), InputPin(Json("aaa111"), ["subject": "Other"]));
    assert(same.version_ == 1 && same.pins == [pinOf("game", "main", "aaa111")]);

    // A missing pin is added, in pin key order, and the stored chain stays well formed
    auto v2 = chains.addPins(v1.id, [pinOf("engine", "stable", "eee111"), pinOf("game", "main", "aaa111")]);
    assert(v2.version_ == 2);
    assert(v2.pins == [pinOf("engine", "stable", "eee111"), pinOf("game", "main", "aaa111")]);
    assert(chains.get(v1.id).get.value == v2.value);

    // A key carrying stray fields is reduced to its pin key
    InputDecl noisy = repositoryInput("tools", "main");
    noisy.spec.value = "stray";
    auto v3 = chains.addPin(v1.id, noisy, InputPin(Json("ttt111")));
    assert(v3.version_ == 3 && v3.pins[2] == pinOf("tools", "main", "ttt111"));

    // Another value for a pinned input fails loudly, and nothing is written, not even the pins
    // that were new
    try
    {
        chains.addPins(v1.id, [pinOf("art", "main", "rrr111"), pinOf("game", "main", "bbb222")]);
        assert(false, "A conflicting pin must throw");
    }
    catch (PinConflictException e)
    {
        assert(e.input == repositoryInput("game", "main") && e.existing == Json("aaa111") && e.proposed == Json("bbb222"));
    }
    assert(chains.get(v1.id).get.version_ == 3 && chains.get(v1.id).get.pins.length == 3);

    // Malformed pins and missing chains fail loudly
    assert(throwsA!InvalidPinsException({ chains.addPin(v1.id, repositoryInput("art", "main"), InputPin(Json(null))); }));
    assert(throwsA!InputResolutionException({ chains.addPin(v1.id, valueInput("x"), InputPin(Json("x"))); }));
    assert(throwsA!Exception({ chains.addPins("missing", [pinOf("art", "main", "rrr111")]); }));
    assert(throwsA!Exception({ chains.addPins("", [pinOf("art", "main", "rrr111")]); }));
    assert(chains.addPins(v1.id, null).version_ == 3, "Adding nothing writes nothing");
}

unittest
{
    // addPins under forced interleavings: it merges with whatever lands first, never loses a
    // concurrent write, and still refuses a conflicting pin that lands between its read and write
    auto documents = new InMemoryDocumentStore();
    auto direct = new ChainStore(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto chains = new ChainStore(interleaving);
    const id = direct.create(sampleChain("game", 1)).id;

    // A label edit lands between the read and the write: the pin is added on a re-read, and the
    // label is kept
    interleaving.beforeNextWrite = () {
        auto current = direct.get(id).get;
        BuildChain labelled = current.value;
        labelled.labels = ["rc"];
        direct.update(current, labelled);
    };
    auto afterLabel = chains.addPins(id, [pinOf("tools", "main", "ttt111")]);
    assert(afterLabel.version_ == 3 && afterLabel.labels == ["rc"]);
    assert(afterLabel.pins == [pinOf("game", "main", "aaa111"), pinOf("tools", "main", "ttt111")]);

    // Two requests add different pins at once: both are kept
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("art", "main", "rrr111")]); };
    auto both = chains.addPins(id, [pinOf("engine", "stable", "eee111")]);
    assert(both.pins.length == 4 && both.pins[0] == pinOf("art", "main", "rrr111") && both.pins[1] == pinOf("engine", "stable", "eee111"));

    // Two requests add the same pin at once: the second finds it there and writes nothing more
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("docs", "main", "ddd111")]); };
    auto same = chains.addPins(id, [pinOf("docs", "main", "ddd111", ["subject": "Mine"])]);
    assert(same.version_ == direct.get(id).get.version_ && same.pins.length == 5);
    assert(same.pins[1].pin.info.length == 0, "The first writer's pin is kept");

    // Another value for the same input lands first: the later writer is refused rather than
    // overwriting it
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("sound", "main", "sss111")]); };
    assert(throwsA!PinConflictException({ chains.addPins(id, [pinOf("sound", "main", "sss222")]); }));
    assert(direct.get(id).get.pins.canFind(pinOf("sound", "main", "sss111")));

    // A write landing before every attempt: addPins gives up after maxWriteAttempts, loudly,
    // having written nothing of its own
    size_t landed = 0;
    void delegate() relabel;
    relabel = () {
        auto current = direct.get(id).get;
        BuildChain labelled = current.value;
        labelled.labels = [format("edit %s", current.version_)];
        direct.update(current, labelled);
        ++landed;
        interleaving.beforeNextWrite = relabel;
    };
    interleaving.beforeNextWrite = relabel;
    const pinsBefore = direct.get(id).get.pins.length;
    bool gaveUp = false;
    try chains.addPins(id, [pinOf("video", "main", "vvv111")]);
    catch (Exception e) gaveUp = e.msg.canFind("attempts in a row");
    interleaving.beforeNextWrite = null;
    assert(gaveUp && landed == ChainStore.maxWriteAttempts, "addPins must give up after maxWriteAttempts lost writes");
    assert(direct.get(id).get.pins.length == pinsBefore);
}

unittest
{
    // Chains: listed by number per project and per branch context, and found by number
    auto chains = new ChainStore(new InMemoryDocumentStore());
    foreach (n; 1 .. 13) chains.create(sampleChain("game", n, n % 3 == 0 ? "feature/x" : "main"));
    chains.create(sampleChain("tools", 1));
    auto tag = sampleChain("game", 13);
    tag.branch.kind = RefKind.tag;
    chains.create(tag);

    auto newest = chains.listForProject("game", 3);
    assert(newest.length == 3 && newest[0].number == 13 && newest[2].number == 11, "Numbers sort numerically, not as text");
    auto oldest = chains.listForProject("game", 100, false);
    assert(oldest.length == 13 && oldest[0].number == 1);
    assert(chains.listForProject("nobody", 10).length == 0);

    auto onMain = chains.listForBranch("game", BranchContext("game", RefKind.branch, "main"), 100);
    assert(onMain.length == 8 && onMain[0].number == 11 && onMain[7].number == 1);
    auto onFeature = chains.listForBranch("game", BranchContext("game", RefKind.branch, "feature/x"), 2, false);
    assert(onFeature.length == 2 && onFeature[0].number == 3 && onFeature[1].number == 6);
    auto onTag = chains.listForBranch("game", BranchContext("game", RefKind.tag, "main"), 100);
    assert(onTag.length == 1 && onTag[0].number == 13, "A tag and a branch of one name are different contexts");
    assert(chains.listForBranch("tools", BranchContext("tools", RefKind.branch, "main"), 100).length == 1);
    assert(chains.listForBranch("tools", BranchContext("game", RefKind.branch, "main"), 100).length == 0,
        "Branch contexts are per project");

    assert(chains.findByNumber("game", 7).get.id == "game-7");
    assert(chains.findByNumber("tools", 1).get.projectId == "tools");
    assert(chains.findByNumber("game", 99).isNull);
}

unittest
{
    // Requests: immutable, listed per chain in request time order (not text order) and per project
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    auto definitions = new DefinitionStore(documents);
    auto requests = new BuildRequestStore(documents, chains, definitions);
    chains.create(sampleChain("game", 1));
    chains.create(sampleChain("game", 2));
    const definitionId = definitions.put(sampleDefinition());

    auto request = sampleRequest("r1", "game-1", definitionId);
    requests.create(request);
    auto earlier = request;
    earlier.id = "r2";
    earlier.requestedAt = "2026-10-15T14:02:00Z"; // sorts after r1 as text, before it as a time
    requests.create(earlier);
    auto otherChain = request;
    otherChain.id = "r3";
    otherChain.chainId = "game-2";
    otherChain.requestedAt = "2026-10-15T15:00:00Z";
    requests.create(otherChain);

    assert(requests.get("r1").get.value == request);
    assert(requests.get("missing").isNull);
    auto onChain = requests.listForChain("game-1");
    assert(onChain.length == 2 && onChain[0].id == "r2" && onChain[1].id == "r1");
    auto onProject = requests.listForProject("game", 2);
    assert(onProject.length == 2 && onProject[0].id == "r3" && onProject[1].id == "r1");
    assert(throwsA!DocumentConflictException({ requests.create(request); }), "A request is written once");

    // A request references its definition, which reads back by id
    assert(definitions.get(requests.get("r1").get.definitionId).get.tasks[0].id == "compile");

    // A request's pins must already be on its chain, with the same values
    auto pinned = sampleRequest("r4", "game-1", definitionId);
    pinned.pins = [pinOf("game", "main", "aaa111", ["subject": "From the trigger"])];
    assert(requests.create(pinned).pins.length == 1);
    auto unpinnedOnChain = sampleRequest("r5", "game-1", definitionId);
    unpinnedOnChain.pins = [pinOf("tools", "main", "ttt111")];
    assert(throwsA!InvalidStateTransitionException({ requests.create(unpinnedOnChain); }), "Add the request's pins to the chain first");
    chains.addPins("game-1", unpinnedOnChain.pins);
    assert(requests.create(unpinnedOnChain).id == "r5");
    auto disagreeing = sampleRequest("r6", "game-1", definitionId);
    disagreeing.pins = [pinOf("game", "main", "bbb222")];
    assert(throwsA!InvalidStateTransitionException({ requests.create(disagreeing); }), "A request's pin must agree with its chain");
}

unittest
{
    // Requests: the chain must already pin every external input the targets and their upstream
    // tasks declare, and only those
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    auto definitions = new DefinitionStore(documents);
    auto requests = new BuildRequestStore(documents, chains, definitions);
    chains.create(sampleChain("game", 1)); // pins game at main

    auto definition = sampleDefinition();
    TaskNode sdk;
    sdk.id = "sdk";
    sdk.inputs["sdk"] = repositoryInput("console-sdk", "v2");
    TaskNode external;
    external.id = "external";
    external.inputs["bin"] = taskOutputInput("compile");
    external.inputs["sdk"] = taskOutputInput("sdk");
    TaskNode art;
    art.id = "art";
    art.inputs["src"] = repositoryInput("art", "main");
    definition.tasks ~= [sdk, external, art];
    const definitionId = definitions.put(definition);

    // compile needs only game at main, which the chain pins; lint needs nothing
    auto internal = sampleRequest("r1", "game-1", definitionId);
    internal.targets = ["compile", "lint"];
    requests.create(internal);

    // external needs console-sdk through its upstream task sdk; art is not upstream of it
    auto release = sampleRequest("r2", "game-1", definitionId);
    release.targets = ["external"];
    try
    {
        requests.create(release);
        assert(false, "A request whose chain lacks a pin its targets need must be refused");
    }
    catch (InvalidStateTransitionException e)
    {
        assert(e.msg.canFind("repository 'console-sdk' at ref 'v2'") && !e.msg.canFind("'art'"), e.msg);
    }
    assert(requests.get("r2").isNull);
    chains.addPin("game-1", repositoryInput("console-sdk", "v2"), InputPin(Json("sdk222")));
    assert(requests.create(release).id == "r2", "Once the chain holds the pin the request is accepted");
}

unittest
{
    // Requests: malformed requests, and requests that do not fit their chain or definition, are
    // refused before anything is written
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    auto definitions = new DefinitionStore(documents);
    auto requests = new BuildRequestStore(documents, chains, definitions);
    chains.create(sampleChain("game", 1));
    chains.create(sampleChain("tools", 1));
    const definitionId = definitions.put(sampleDefinition());

    BuildRequest[string] bad;
    auto untargeted = sampleRequest("r", "game-1", definitionId);
    untargeted.targets = null;
    bad["no targets"] = untargeted;
    auto emptyTarget = sampleRequest("r", "game-1", definitionId);
    emptyTarget.targets = ["compile", ""];
    bad["an empty target"] = emptyTarget;
    auto repeated = sampleRequest("r", "game-1", definitionId);
    repeated.targets = ["compile", "compile"];
    bad["a repeated target"] = repeated;
    auto wideRerun = sampleRequest("r", "game-1", definitionId);
    wideRerun.intent = BuildIntent.rerun;
    wideRerun.targets = ["compile", "lint"];
    bad["a rerun of two tasks"] = wideRerun;
    auto noProject = sampleRequest("r", "game-1", definitionId);
    noProject.projectId = null;
    bad["no project"] = noProject;
    auto noChain = sampleRequest("r", "", definitionId);
    bad["no chain"] = noChain;
    auto missingChain = sampleRequest("r", "game-9", definitionId);
    bad["a chain that does not exist"] = missingChain;
    auto otherProject = sampleRequest("r", "tools-1", definitionId);
    bad["another project's chain"] = otherProject;
    auto noDefinition = sampleRequest("r", "game-1", "");
    bad["no definition"] = noDefinition;
    auto unstored = sampleRequest("r", "game-1", "0000000000000000000000000000000000000000000000000000000000000000");
    bad["a definition that is not stored"] = unstored;
    auto unknownTarget = sampleRequest("r", "game-1", definitionId);
    unknownTarget.targets = ["package"];
    bad["a target its definition lacks"] = unknownTarget;
    foreach (i, revision; [Json.undefined, Json(null), Json(""), Json.emptyObject])
    {
        auto unrevised = sampleRequest("r", "game-1", definitionId);
        unrevised.definitionSource = DefinitionSource(DefinitionLocation.repository, "ci-config", "main", "game.yaml", revision);
        bad[format("a repository source with empty revision %s", i)] = unrevised;
    }
    auto confectorRevision = sampleRequest("r", "game-1", definitionId);
    confectorRevision.definitionSource.revision = Json(4);
    bad["a Confector source with a revision"] = confectorRevision;
    auto repositoryWithoutPath = sampleRequest("r", "game-1", definitionId);
    repositoryWithoutPath.definitionSource = DefinitionSource(DefinitionLocation.repository, "ci-config", "main", null, Json("ccc333"));
    bad["a repository source without a path"] = repositoryWithoutPath;
    auto confectorWithPath = sampleRequest("r", "game-1", definitionId);
    confectorWithPath.definitionSource.path = "game.yaml";
    bad["a Confector source with a path"] = confectorWithPath;
    auto anonymous = sampleRequest("r", "game-1", definitionId);
    anonymous.requestedBy = null;
    bad["no requester"] = anonymous;
    auto badTime = sampleRequest("r", "game-1", definitionId);
    badTime.requestedAt = "now";
    bad["a malformed time"] = badTime;
    foreach (what, request; bad)
    {
        assert(throwsA!InvalidStateTransitionException({ requests.create(request); }), "A request with " ~ what ~ " must be refused");
    }

    auto unsortedPins = sampleRequest("r", "game-1", definitionId);
    unsortedPins.pins = [pinOf("tools", "main", "ttt111"), pinOf("game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ requests.create(unsortedPins); }));
    assert(requests.get("r").isNull, "Nothing was written");

    // A rerun of one task and a request from a definition file are fine
    auto rerun = sampleRequest("rerun", "game-1", definitionId);
    rerun.intent = BuildIntent.rerun;
    rerun.definitionSource = DefinitionSource(DefinitionLocation.repository, "ci-config", "main", "game.yaml", Json("ccc333"));
    assert(requests.create(rerun).intent == BuildIntent.rerun);

    assert(throwsA!Exception({ new BuildRequestStore(documents, null, definitions); }));
    assert(throwsA!Exception({ new BuildRequestStore(documents, chains, null); }));
}

unittest
{
    // Executions: created queued, active until terminal, then never changed again
    auto executions = new ExecutionStore(new InMemoryDocumentStore());
    auto queued = executions.create(sampleExecution("e1", "fp1", "2026-10-15T14:02:00Z"));
    assert(queued.version_ == 1);

    TaskExecution running = queued.value;
    running.status = ExecutionStatus.running;
    running.attempts = 1;
    running.worker = "w1";
    running.startedAt = "2026-10-15T14:03:00Z";
    auto v2 = executions.update(queued, running);
    assert(v2.status == ExecutionStatus.running && v2.attempts == 1);

    // A stale writer (another worker's lost update) loses the compare-and-set
    TaskExecution stale = queued.value;
    stale.status = ExecutionStatus.cancelled;
    stale.finishedAt = "2026-10-15T14:03:00Z";
    assert(throwsA!DocumentConflictException({ executions.update(queued, stale); }));

    // A lost worker puts it back in the queue; the identity cannot change
    TaskExecution requeued = v2.value;
    requeued.status = ExecutionStatus.queued;
    auto v3 = executions.update(v2, requeued);
    TaskExecution moved = v3.value;
    moved.fingerprint = "fp2";
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, moved); }));
    TaskExecution redefined = v3.value;
    redefined.definitionHash = "def2";
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, redefined); }), "The definition hash is fixed at dispatch");
    TaskExecution restepped = v3.value;
    restepped.definition.steps = [BuildStep("Compile", "bash", Json(["script": Json("make release")]))];
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, restepped); }), "The definition is fixed at dispatch");
    TaskExecution repinned = v3.value;
    repinned.inputs = [ResolvedInput("src", InputKind.repository, Json("bbb222"))];
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, repinned); }), "The inputs are fixed at dispatch");
    TaskExecution readdressed = v3.value;
    readdressed.repositoryAddresses = ["src": "https://example.test/other.git"];
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, readdressed); }));
    TaskExecution sent = v3.value;
    sent.sentAt = "2026-10-15T14:03:30Z";
    v3 = executions.update(v3, sent);

    TaskExecution succeeded = v3.value;
    succeeded.status = ExecutionStatus.succeeded;
    succeeded.finishedAt = "2026-10-15T14:09:00Z";
    auto v4 = executions.update(v3, succeeded);
    TaskExecution reopened = v4.value;
    reopened.status = ExecutionStatus.running;
    assert(throwsA!InvalidStateTransitionException({ executions.update(v4, reopened); }), "A terminal execution never changes");
    assert(executions.get("e1").get.value == succeeded);

    // Only queued executions are created
    auto premature = sampleExecution("e2", "fp1", "2026-10-15T14:02:00Z");
    premature.status = ExecutionStatus.succeeded;
    assert(throwsA!InvalidStateTransitionException({ executions.create(premature); }));
    assert(throwsA!InvalidStateTransitionException({ executions.create(sampleExecution("e2", "", "2026-10-15T14:02:00Z")); }));
    assert(throwsA!DocumentConflictException({ executions.create(sampleExecution("e1", "fp1", "2026-10-15T14:02:00Z")); }));
}

unittest
{
    // A terminal execution records when it finished: one that finishes without a time is refused
    auto executions = new ExecutionStore(new InMemoryDocumentStore());
    auto queued = executions.create(sampleExecution("e1", "fp1", "2026-10-15T14:02:00Z"));
    foreach (status; [ExecutionStatus.failed, ExecutionStatus.cancelled, ExecutionStatus.succeeded])
    {
        TaskExecution unfinished = queued.value;
        unfinished.status = status;
        assert(throwsA!InvalidStateTransitionException({ executions.update(queued, unfinished); }),
            "A terminal execution without finished_at is refused");
    }

    TaskExecution cancelled = queued.value;
    cancelled.status = ExecutionStatus.cancelled;
    cancelled.finishedAt = "2026-10-15T14:04:00Z";
    assert(executions.update(queued, cancelled).value.finishedAt == "2026-10-15T14:04:00Z");
}

unittest
{
    // Executions: listed by fingerprint, by task and while active
    auto executions = new ExecutionStore(new InMemoryDocumentStore());
    auto first = executions.create(sampleExecution("e1", "fp1", "2026-10-15T14:02:00Z"));
    executions.create(sampleExecution("e2", "fp1", "2026-10-15T14:02:00.25Z"));
    executions.create(sampleExecution("e3", "fp2", "2026-10-15T15:00:00Z"));
    executions.create(sampleExecution("e4", "fp9", "2026-10-15T16:00:00Z", "lint"));

    TaskExecution failed = first.value;
    failed.status = ExecutionStatus.failed;
    failed.finishedAt = "2026-10-15T14:05:00Z";
    executions.update(first, failed);

    auto atFp1 = executions.listForFingerprint("fp1");
    assert(atFp1.length == 2 && atFp1[0].id == "e1" && atFp1[1].id == "e2");
    assert(executions.listForFingerprint("fp2").length == 1 && executions.listForFingerprint("none").length == 0);

    auto history = executions.listForTask("game", "compile", 2);
    assert(history.length == 2 && history[0].id == "e3" && history[1].id == "e2");
    assert(executions.listForTask("game", "lint", 10).length == 1);

    auto active = executions.listActive(ExecutionStatus.queued, 10);
    assert(active.length == 3 && active[0].id == "e2", "A terminal execution leaves the active index");
    assert(executions.listActive(ExecutionStatus.running, 10).length == 0);
    assert(throwsA!InvalidStateTransitionException({ executions.listActive(ExecutionStatus.failed, 10); }));
}
