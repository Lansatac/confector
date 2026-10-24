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

import confector.core.chain_pins : describeInput, describePin, isEmptyPinned, mergePins, pinMap, samePin, validatePins;
import confector.core.dag : TaskGraph;
import confector.core.input_resolution : InputResolutionException, requireRepositorySpec, unpinnedRepositoryInputs;
import confector.core.counters : CounterStore;
import confector.core.definition_store : DefinitionStore;
import confector.core.document_collection;
import confector.api.model;
import confector.api.document_store;

import vibe.data.json : Json;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;
import std.typecons : Nullable;

/// Build chains, by chain id; indexed by project and number, and by project and headline and
/// number.
enum CollectionSpec buildChainsCollection = CollectionSpec("build_chains",
    [IndexSpec("by_project", "project_id", "number_key"), IndexSpec("by_headline", "headline_key", "number_key")]);

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
 * Build chains. A chain's identity (id, project, number, headline, creation time) never changes;
 * its pins are only added (`addPins`), and once set never change; its labels change and its events
 * are only appended (`update`). A request finds the chain it joins by pin agreement, not by
 * headline (bead confector-z7z.53.2); the headline only groups chains into a history
 * (`listForHeadline`).
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
        m_chains = new DocumentCollection!BuildChain(store, buildChainsCollection, ["number_key", "headline_key"],
            (in BuildChain chain) => [
                "number_key": sortableNumber(chain.number),
                "headline_key": headlineKey(chain.projectId, chain.headline),
            ]);
        m_counters = new CounterStore(store);
    }

    /// The `by_headline` partition key of project `projectId`'s chains with headline `headline`:
    /// the headline's kind, name and (change requests only) repository.
    private static string headlineKey(string projectId, in HeadlineRef headline) @safe
    {
        return compositeKey(projectId, headline.kind, headline.name, headline.repositoryId);
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
            && next.headline == was.headline && next.createdAt == was.createdAt,
            format("Only the labels and history of chain '%s' can change", was.id));
        requireValid(next.pins == was.pins,
            format("The pins of chain '%s' change only by adding pins (ChainStore.addPins)", was.id));
        requireValid(next.events.length >= was.events.length && next.events[0 .. was.events.length] == was.events,
            format("The history of chain '%s' can only be appended to", was.id));
        validateChain(next);
        return m_chains.replace(was.id, next, current.version_);
    }

    /**
     * Adds `pins` to chain `chainId`'s pins in one compare-and-set, re-reading and merging again
     * when a concurrent write lands first. Pins only grow: an input the chain already pins alike
     * (same repository, ref and revision, whatever the display info) is left as it is, and when
     * every pin is already there nothing is written. Returns the chain as stored afterwards.
     *
     * Throws: PinConflictException if the chain pins one of the task inputs differently (pins
     * never change; nothing is written, not even the other new pins; decide again);
     * InvalidPinsException if a pin is incomplete, has an empty value, or `pins` pins one input
     * two ways (caller mistakes); InvalidStateTransitionException if the chain's headline is
     * `default`, which holds no pins; Exception if the chain does not exist or every one of
     * maxWriteAttempts attempts lost a compare-and-set.
     */
    Versioned!BuildChain addPins(string chainId, in PinnedInput[] pins)
    {
        requireNonEmpty(chainId, "Adding pins needs a chain id");
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = m_chains.get(chainId);
            if (current.isNull) throw new Exception(format("Cannot add pins to chain '%s': it does not exist", chainId));
            requireValid(current.get.headline.kind != HeadlineKind.default_ || pins.length == 0,
                format("Chain '%s' has the headline default (a project with no repositories), so it holds no pins", chainId));
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

    /// Adds the one pin `pin` to chain `chainId`, as `addPins` does.
    Versioned!BuildChain addPin(string chainId, in PinnedInput pin)
    {
        return addPins(chainId, [pin]);
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
     * Lists project `projectId`'s chains with headline `headline` (its history) by number, newest
     * first unless `newestFirst` is false, at most `limit` of them. Discovery: may lag behind
     * writes, so a chain just created may be missing; never use it to decide whether a chain
     * exists (bead confector-z7z.53.2 finds chains through a head document read by id).
     *
     * Throws: InvalidStateTransitionException if `headline` is malformed (see `validateHeadline`).
     */
    Versioned!BuildChain[] listForHeadline(string projectId, in HeadlineRef headline, size_t limit, bool newestFirst = true)
    {
        requireNonEmpty(projectId, "Listing a headline's chains needs a project id");
        validateHeadline(headline, "the listed headline");
        IndexQuery lookup;
        lookup.index = "by_headline";
        lookup.partitionKey = headlineKey(projectId, headline);
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
 * creation time, a well-formed headline (see `validateHeadline`), well-formed pins (none under
 * the headline `default`), labels that are not empty, and complete events.
 *
 * Throws: InvalidStateTransitionException; InvalidPinsException for malformed pins.
 */
void validateChain(in BuildChain chain)
{
    requireValid(chain.id.length > 0 && chain.projectId.length > 0 && chain.number > 0 && chain.createdAt.length > 0,
        format("Chain '%s' needs an id, a project id, a number and a creation time", chain.id));
    requireTimestamp(chain.createdAt, format("The creation time of chain '%s'", chain.id));
    validateHeadline(chain.headline, format("chain '%s'", chain.id));
    validatePins(chain.pins, format("chain '%s'", chain.id));
    requireValid(chain.headline.kind != HeadlineKind.default_ || chain.pins.length == 0,
        format("Chain '%s' has the headline default (a project with no repositories), so it holds no pins", chain.id));
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
 * Throws InvalidStateTransitionException unless `headline` is well formed: `default` has no name
 * and no repository; any other kind has a name, and a repository exactly when it is a change
 * request. `owner` names whose headline it is, for the message ("chain 'c1'").
 *
 * The input resolver (bead confector-z7z.53.2) chooses `default` exactly when the project has no
 * repository inputs; the store cannot see the definition, but it holds a `default` chain to having
 * no pins (`validateChain`, `ChainStore.addPins`).
 */
void validateHeadline(in HeadlineRef headline, lazy string owner)
{
    if (headline.kind == HeadlineKind.default_)
    {
        requireValid(headline.name.length == 0 && headline.repositoryId.length == 0,
            format("The headline of %s is default, which names no ref and no repository", owner));
        return;
    }
    requireValid(headline.name.length > 0, format("The %s headline of %s needs a ref name", cast(string) headline.kind, owner));
    if (headline.kind == HeadlineKind.changeRequest)
    {
        requireValid(headline.repositoryId.length > 0,
            format("The change request headline '%s' of %s needs its repository", headline.name, owner));
    }
    else
    {
        requireValid(headline.repositoryId.length == 0,
            format("The %s headline '%s' of %s names a repository, which only a change request headline has",
                cast(string) headline.kind, headline.name, owner));
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
     * its chain does not exist or belongs to another project, its chain lacks one of its pins or
     * pins that input differently (repository, ref or revision), its definition is not stored, a
     * target is not a task of its definition, its chain lacks a pin of a repository input its
     * targets or their upstream tasks declare, or pins one to another repository than the
     * definition declares, or its demands are not for exactly its targets and their upstream
     * tasks; InvalidPinsException if its pins are not a well-formed list.
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
            auto onChain = inputKey(entry) in chainPins;
            requireValid(onChain !is null && samePin(*onChain, entry),
                format("Request '%s' pins %s to %s, which chain '%s' %s; add the request's pins to the chain first",
                    request.id, describeInput(inputKey(entry)), describePin(entry), request.chainId,
                    onChain is null ? "lacks" : "pins differently"));
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

        // Every repository input the targets and their upstream tasks declare must be pinned on the
        // chain already, to the repository it declares, so the request can be evaluated against its
        // chain's pins alone.
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
        // A malformed repository input is the definition's problem, not the chain's: report it as such
        foreach (ref task; closure)
        {
            foreach (name, decl; task.inputs)
            {
                if (decl.kind != InputKind.repository) continue;
                try requireRepositorySpec(task.id, name, decl);
                catch (InputResolutionException e)
                {
                    requireValid(false, format("Request '%s' runs with definition '%s', which is invalid: %s", request.id,
                        request.definitionId, e.msg));
                }
            }
        }
        InputKey[] unpinned;
        try unpinned = unpinnedRepositoryInputs(new TaskGraph(closure), chainPins);
        catch (InputResolutionException e)
        {
            requireValid(false, format("Request '%s' cannot run on chain '%s': %s", request.id, request.chainId, e.msg));
        }
        if (unpinned.length > 0)
        {
            string[] missing;
            foreach (key; unpinned) missing ~= describeInput(key);
            requireValid(false, format("Request '%s' needs pins that chain '%s' lacks: %-(%s, %); add them to the chain first",
                request.id, request.chainId, missing));
        }

        // The request records a demand for exactly the tasks it covers, so chain state can be
        // derived from it (validateRequest checked they are sorted and distinct)
        string[] covered;
        foreach (ref task; closure) covered ~= task.id;
        covered.sort();
        string[] demanded;
        foreach (ref demand; request.demands) demanded ~= demand.taskId;
        requireValid(demanded == covered, format(
            "Request '%s' records demands for tasks [%-(%s, %)], but its targets and their upstream tasks are [%-(%s, %)]",
            request.id, demanded, covered));
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
 * least one target with none empty or repeated (exactly one for a rerun), well-formed pins,
 * demands sorted by task id with a task, fingerprint and base each, a definition id and a complete
 * definition source, who made it, and a valid request time.
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
    requireValid(request.demands.length > 0, format("Request '%s' records no demands", request.id));
    foreach (i, ref demand; request.demands)
    {
        requireValid(demand.taskId.length > 0 && demand.fingerprint.length > 0 && demand.base.length > 0,
            format("Demand %s of request '%s' needs a task id, a fingerprint and a base fingerprint", i, request.id));
        requireValid(i == 0 || request.demands[i - 1].taskId < demand.taskId,
            format("The demands of request '%s' must be sorted by task id, each task once ('%s' is out of order or repeated)",
                request.id, demand.taskId));
    }
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

    /// One page of the active executions with `status` (queued or running), oldest first, from
    /// `cursor` (null for the first page). `nextCursor` is empty after the last page. Discovery.
    Page!TaskExecution listActivePage(ExecutionStatus status, string cursor)
    {
        requireValid(isActive(status), format("%s is not an active execution status", status));
        IndexQuery lookup;
        lookup.index = "active";
        lookup.partitionKey = status;
        lookup.limit = pageSize;
        lookup.cursor = cursor;
        return m_executions.query(lookup);
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
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    /// Task `task`'s input `input` pinned to repository `repository` at branch `branch`, revision `sha`.
    private PinnedInput pinOf(string task, string input, string repository, string branch, string sha, string[string] info = null)
    {
        return PinnedInput(task, input, repository, RepositoryRef(RefKind.branch, branch), InputPin(Json(sha), info));
    }

    private BuildChain sampleChain(string projectId, ulong number, string refName = "main")
    {
        BuildChain chain;
        chain.id = format("%s-%s", projectId, number);
        chain.projectId = projectId;
        chain.number = number;
        chain.headline = HeadlineRef(HeadlineKind.branch, refName);
        chain.pins = [pinOf("compile", "src", projectId, "main", "aaa111")];
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

    /// A project definition with tasks `compile` (repository input `src` of `game`) and `lint`.
    private ProjectDefinition sampleDefinition()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game", RefSpec.fromString("same else main"));
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
        request.demands = [TaskDemand("compile", "fp-compile", "b-compile")];
        request.requestedBy = "jason";
        request.requestedAt = "2026-10-15T14:02:00.5Z";
        return request;
    }

    /// One demand, at a made-up fingerprint, for each of `taskIds` (sorted).
    private TaskDemand[] demandsFor(string[] taskIds...)
    {
        TaskDemand[] demands;
        foreach (taskId; taskIds) demands ~= TaskDemand(taskId, "fp-" ~ taskId, "b-" ~ taskId);
        return demands;
    }
}

unittest
{
    // Chains: created once, numbered per project, with a headline and the pins they start with
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    assert(chains.nextNumber("game") == 1);
    assert(chains.nextNumber("game") == 2);
    assert(chains.nextNumber("tools") == 1);

    auto created = chains.create(sampleChain("game", 1));
    assert(created.version_ == 1);
    assert(chains.get(created.id).get.value == created.value);
    assert(created.headline == HeadlineRef(HeadlineKind.branch, "main") && created.pins == [pinOf("compile", "src", "game", "main", "aaa111")]);
    assert(chains.get("game-9").isNull);
    assert(throwsA!DocumentConflictException({ chains.create(sampleChain("game", 1)); }), "A chain is created once");

    // A project with no repositories has chains without pins, under the headline default
    auto unpinned = sampleChain("game", 2);
    unpinned.headline = defaultHeadline();
    unpinned.pins = null;
    assert(chains.create(unpinned).pins.length == 0);

    // A default headline holds no pins: not when created, and not added later
    auto pinnedDefault = sampleChain("game", 6);
    pinnedDefault.headline = defaultHeadline();
    assert(throwsA!InvalidStateTransitionException({ chains.create(pinnedDefault); }), "A default chain has no pins");
    assert(throwsA!InvalidStateTransitionException({ chains.addPin("game-2", pinOf("compile", "src", "game", "main", "aaa111")); }));
    assert(chains.get("game-2").get.pins.length == 0 && chains.get("game-2").get.version_ == 1);
    assert(chains.addPins("game-2", null).version_ == 1, "Adding nothing to a default chain is fine");

    // A change request headline names its repository; other headlines do not
    auto pullRequest = sampleChain("game", 3);
    pullRequest.headline = headlineOf("game", RepositoryRef(RefKind.changeRequest, "pull/12"));
    assert(chains.create(pullRequest).headline.repositoryId == "game");
    auto byRevision = sampleChain("game", 4);
    byRevision.headline = headlineOf("game", RepositoryRef(RefKind.revision, "aaa111"));
    assert(chains.create(byRevision).headline == HeadlineRef(HeadlineKind.revision, "aaa111"));

    // One repository at two refs in two inputs of one closure
    auto twoRefs = sampleChain("game", 5);
    twoRefs.pins = [pinOf("compile", "src", "game", "main", "aaa111"), pinOf("compile", "stable", "game", "release", "ccc333")];
    assert(chains.create(twoRefs).pins.length == 2);

    // Incomplete or malformed chains are rejected
    BuildChain[string] malformed;
    auto noId = sampleChain("game", 9);
    noId.id = null;
    malformed["no id"] = noId;
    auto noProject = sampleChain("game", 9);
    noProject.projectId = null;
    malformed["no project"] = noProject;
    malformed["no number"] = sampleChain("game", 0);
    auto badTime = sampleChain("game", 9);
    badTime.createdAt = "today";
    malformed["a malformed time"] = badTime;
    auto unsetHeadline = sampleChain("game", 9);
    unsetHeadline.headline = HeadlineRef.init;
    malformed["an unset headline"] = unsetHeadline;
    auto unnamed = sampleChain("game", 9);
    unnamed.headline = HeadlineRef(HeadlineKind.tag);
    malformed["a headline without a name"] = unnamed;
    auto namedDefault = sampleChain("game", 9);
    namedDefault.headline = HeadlineRef(HeadlineKind.default_, "main");
    malformed["a default headline with a name"] = namedDefault;
    auto defaultWithRepository = sampleChain("game", 9);
    defaultWithRepository.headline = HeadlineRef(HeadlineKind.default_, null, "game");
    malformed["a default headline with a repository"] = defaultWithRepository;
    auto branchWithRepository = sampleChain("game", 9);
    branchWithRepository.headline = HeadlineRef(HeadlineKind.branch, "main", "game");
    malformed["a branch headline with a repository"] = branchWithRepository;
    auto pullWithoutRepository = sampleChain("game", 9);
    pullWithoutRepository.headline = HeadlineRef(HeadlineKind.changeRequest, "pull/12");
    malformed["a change request headline without its repository"] = pullWithoutRepository;
    auto emptyLabel = sampleChain("game", 9);
    emptyLabel.labels = [""];
    malformed["an empty label"] = emptyLabel;
    auto badEvent = sampleChain("game", 9);
    badEvent.events = [ChainEvent(ChainEventKind.rerun, "r1", "compile", "base", 0)];
    malformed["a rerun to generation 0"] = badEvent;
    foreach (what, chain; malformed)
    {
        assert(throwsA!InvalidStateTransitionException({ chains.create(chain); }), "A chain with " ~ what ~ " must be refused");
    }

    PinnedInput[][string] malformedPins = [
        "unsorted": [pinOf("lint", "src", "game", "main", "aaa111"), pinOf("compile", "src", "game", "main", "aaa111")],
        "an input twice": [pinOf("compile", "src", "game", "main", "aaa111"), pinOf("compile", "src", "game", "main", "bbb222")],
        "an empty revision": [PinnedInput("compile", "src", "game", RepositoryRef(RefKind.branch, "main"), InputPin(Json(null)))],
        "no ref": [pinOf("compile", "src", "game", "", "aaa111")],
        "no repository": [pinOf("compile", "src", "", "main", "aaa111")],
        "no input": [pinOf("compile", "", "game", "main", "aaa111")],
    ];
    foreach (what, pins; malformedPins)
    {
        auto chain = sampleChain("game", 9);
        chain.pins = pins;
        assert(throwsA!InvalidPinsException({ chains.create(chain); }), "Pins with " ~ what ~ " must be refused");
    }
    assert(chains.get("game-9").isNull, "Nothing malformed was written");

    // Chains persist across a restart
    assert(new ChainStore(documents.restart()).get(created.id).get.value == created.value);

    // A malformed chain written behind the store's back fails loudly when read
    documents.create(buildChainsCollection.name, "broken", Json(["id": Json("broken"), "project_id": Json("game")]));
    assert(throwsA!MalformedDocumentException({ chains.get("broken"); }));
}

unittest
{
    // Chains: only labels change and history is only appended, by compare-and-set; the identity,
    // headline and pins never change through update
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
    BuildChain retitled = v2.value;
    retitled.headline.name = "release";
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, retitled); }), "The headline is part of the identity");
    BuildChain repinned = v2.value;
    repinned.pins = [pinOf("compile", "src", "game", "main", "bbb222")];
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, repinned); }), "A pin never changes");
    BuildChain rerefed = v2.value;
    rerefed.pins = [pinOf("compile", "src", "game", "release", "aaa111")];
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, rerefed); }), "A pin's ref never changes");
    BuildChain grown = v2.value;
    grown.pins ~= pinOf("compile", "tools", "tools", "main", "ttt111");
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
    // Pins only grow: addPins adds what is missing in one write, writes nothing when everything is
    // there, and refuses to change a pin
    auto chains = new ChainStore(new InMemoryDocumentStore());
    auto v1 = chains.create(sampleChain("game", 1));

    // Already pinned alike, whatever the display info: nothing is written
    auto same = chains.addPin(v1.id, pinOf("compile", "src", "game", "main", "aaa111", ["subject": "Other"]));
    assert(same.version_ == 1 && same.pins == [pinOf("compile", "src", "game", "main", "aaa111")]);

    // Several missing pins are added in one write, in key order, and the chain stays well formed;
    // one repository may be pinned at two refs by two inputs
    auto v2 = chains.addPins(v1.id, [pinOf("compile", "stable", "game", "release", "ccc333"),
        pinOf("compile", "engine", "engine", "stable", "eee111"), pinOf("compile", "src", "game", "main", "aaa111")]);
    assert(v2.version_ == 2);
    assert(v2.pins == [pinOf("compile", "engine", "engine", "stable", "eee111"), pinOf("compile", "src", "game", "main", "aaa111"),
        pinOf("compile", "stable", "game", "release", "ccc333")]);
    assert(chains.get(v1.id).get.value == v2.value);

    // Another revision, ref or repository for a pinned input fails loudly, and nothing is written,
    // not even the pins that were new
    foreach (conflicting; [pinOf("compile", "src", "game", "main", "bbb222"), pinOf("compile", "src", "game", "develop", "aaa111"),
        PinnedInput("compile", "src", "game", RepositoryRef(RefKind.tag, "main"), InputPin(Json("aaa111"))),
        pinOf("compile", "src", "game-fork", "main", "aaa111")])
    {
        try
        {
            chains.addPins(v1.id, [pinOf("art", "src", "art", "main", "rrr111"), conflicting]);
            assert(false, "A conflicting pin must throw");
        }
        catch (PinConflictException e)
        {
            assert(e.key == InputKey("compile", "src") && e.existing == pinOf("compile", "src", "game", "main", "aaa111"));
            assert(e.proposed.repositoryId == conflicting.repositoryId && e.proposed.ref_ == conflicting.ref_);
        }
    }
    assert(chains.get(v1.id).get.version_ == 2 && chains.get(v1.id).get.pins.length == 3);

    // Malformed pins and missing chains fail loudly
    assert(throwsA!InvalidPinsException({ chains.addPin(v1.id, PinnedInput("art", "src", "art", RepositoryRef(RefKind.branch, "main"), InputPin(Json(null)))); }));
    assert(throwsA!InvalidPinsException({ chains.addPin(v1.id, pinOf("art", "src", "art", "", "rrr111")); }));
    assert(throwsA!InvalidPinsException({ chains.addPins(v1.id, [pinOf("art", "src", "art", "main", "r1"), pinOf("art", "src", "art", "main", "r2")]); }),
        "One input pinned two ways in one call is a caller's mistake");
    assert(throwsA!Exception({ chains.addPins("missing", [pinOf("art", "src", "art", "main", "rrr111")]); }));
    assert(throwsA!Exception({ chains.addPins("", [pinOf("art", "src", "art", "main", "rrr111")]); }));
    assert(chains.addPins(v1.id, null).version_ == 2, "Adding nothing writes nothing");
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
    auto afterLabel = chains.addPins(id, [pinOf("compile", "tools", "tools", "main", "ttt111")]);
    assert(afterLabel.version_ == 3 && afterLabel.labels == ["rc"]);
    assert(afterLabel.pins == [pinOf("compile", "src", "game", "main", "aaa111"), pinOf("compile", "tools", "tools", "main", "ttt111")]);

    // Two requests add pins of different inputs at once: both are kept
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("art", "src", "art", "main", "rrr111")]); };
    auto both = chains.addPins(id, [pinOf("compile", "engine", "engine", "stable", "eee111")]);
    assert(both.pins.length == 4 && both.pins[0] == pinOf("art", "src", "art", "main", "rrr111")
        && both.pins[1] == pinOf("compile", "engine", "engine", "stable", "eee111"));

    // Two requests add the same pin at once: the second finds it there and writes nothing more
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("docs", "src", "docs", "main", "ddd111")]); };
    auto same = chains.addPins(id, [pinOf("docs", "src", "docs", "main", "ddd111", ["subject": "Mine"])]);
    assert(same.version_ == direct.get(id).get.version_ && same.pins.length == 5);
    assert(same.pins[4].pin.info.length == 0, "The first writer's pin is kept");

    // Another revision for the same input lands first: the later writer is refused rather than
    // overwriting it, and none of its other pins are written
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("sound", "src", "sound", "main", "sss111")]); };
    assert(throwsA!PinConflictException({ chains.addPins(id, [pinOf("video", "src", "video", "main", "vvv111"), pinOf("sound", "src", "sound", "main", "sss222")]); }));
    assert(direct.get(id).get.pins.canFind(pinOf("sound", "src", "sound", "main", "sss111")));
    assert(!direct.get(id).get.pins.canFind!(p => p.taskId == "video"));

    // The same revision through another ref lands first: also a conflict, since the ref is part
    // of the pin
    interleaving.beforeNextWrite = () { direct.addPins(id, [pinOf("music", "src", "music", "main", "mmm111")]); };
    assert(throwsA!PinConflictException({ chains.addPins(id, [pinOf("music", "src", "music", "develop", "mmm111")]); }));

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
    try chains.addPins(id, [pinOf("video", "src", "video", "main", "vvv111")]);
    catch (Exception e) gaveUp = e.msg.canFind("attempts in a row");
    interleaving.beforeNextWrite = null;
    assert(gaveUp && landed == ChainStore.maxWriteAttempts, "addPins must give up after maxWriteAttempts lost writes");
    assert(direct.get(id).get.pins.length == pinsBefore);
}

unittest
{
    // Chains: listed by number per project and per headline, and found by number
    auto chains = new ChainStore(new InMemoryDocumentStore());
    foreach (n; 1 .. 13) chains.create(sampleChain("game", n, n % 3 == 0 ? "feature/x" : "main"));
    chains.create(sampleChain("tools", 1));
    auto tag = sampleChain("game", 13);
    tag.headline.kind = HeadlineKind.tag;
    chains.create(tag);
    auto pullInGame = sampleChain("game", 14);
    pullInGame.headline = HeadlineRef(HeadlineKind.changeRequest, "pull/1", "game");
    chains.create(pullInGame);
    auto pullInEngine = sampleChain("game", 15);
    pullInEngine.headline = HeadlineRef(HeadlineKind.changeRequest, "pull/1", "engine");
    chains.create(pullInEngine);
    auto unpinned = sampleChain("game", 16);
    unpinned.headline = defaultHeadline();
    unpinned.pins = null;
    chains.create(unpinned);

    auto newest = chains.listForProject("game", 3);
    assert(newest.length == 3 && newest[0].number == 16 && newest[2].number == 14, "Numbers sort numerically, not as text");
    auto oldest = chains.listForProject("game", 100, false);
    assert(oldest.length == 16 && oldest[0].number == 1);
    assert(chains.listForProject("nobody", 10).length == 0);

    auto onMain = chains.listForHeadline("game", HeadlineRef(HeadlineKind.branch, "main"), 100);
    assert(onMain.length == 8 && onMain[0].number == 11 && onMain[7].number == 1);
    auto onFeature = chains.listForHeadline("game", HeadlineRef(HeadlineKind.branch, "feature/x"), 2, false);
    assert(onFeature.length == 2 && onFeature[0].number == 3 && onFeature[1].number == 6);
    auto onTag = chains.listForHeadline("game", HeadlineRef(HeadlineKind.tag, "main"), 100);
    assert(onTag.length == 1 && onTag[0].number == 13, "A tag and a branch of one name are different headlines");
    auto onPull = chains.listForHeadline("game", HeadlineRef(HeadlineKind.changeRequest, "pull/1", "game"), 100);
    assert(onPull.length == 1 && onPull[0].number == 14, "Change requests of different repositories are different headlines");
    auto onDefault = chains.listForHeadline("game", defaultHeadline(), 100);
    assert(onDefault.length == 1 && onDefault[0].number == 16);
    assert(chains.listForHeadline("tools", HeadlineRef(HeadlineKind.branch, "main"), 100).length == 1, "Headlines are per project");
    foreach (malformed; [HeadlineRef.init, HeadlineRef(HeadlineKind.default_, "main"), HeadlineRef(HeadlineKind.changeRequest, "pull/1")])
    {
        assert(throwsA!InvalidStateTransitionException({ chains.listForHeadline("game", malformed, 100); }), "A malformed headline fails fast");
    }

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

    // A request's pins must already be on its chain, identical in repository, ref and revision
    auto pinned = sampleRequest("r4", "game-1", definitionId);
    pinned.pins = [pinOf("compile", "src", "game", "main", "aaa111", ["subject": "From the trigger"])];
    assert(requests.create(pinned).pins.length == 1);
    auto unpinnedOnChain = sampleRequest("r5", "game-1", definitionId);
    unpinnedOnChain.pins = [pinOf("lint", "tools", "tools", "main", "ttt111")];
    assert(throwsA!InvalidStateTransitionException({ requests.create(unpinnedOnChain); }), "Add the request's pins to the chain first");
    chains.addPins("game-1", unpinnedOnChain.pins);
    assert(requests.create(unpinnedOnChain).id == "r5");
    foreach (i, disagreeing; [pinOf("compile", "src", "game", "main", "bbb222"), pinOf("compile", "src", "game", "develop", "aaa111"),
        pinOf("compile", "src", "game-fork", "main", "aaa111")])
    {
        auto request6 = sampleRequest(format("r6-%s", i), "game-1", definitionId);
        request6.pins = [disagreeing];
        try
        {
            requests.create(request6);
            assert(false, "A request's pin must be identical to its chain's");
        }
        catch (InvalidStateTransitionException e)
        {
            assert(e.msg.canFind("pins differently") && e.msg.canFind("task 'compile' input 'src'"), e.msg);
        }
    }
}

unittest
{
    // Requests: the chain must already pin every repository input the targets and their upstream
    // tasks declare, per task input, and only those
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    auto definitions = new DefinitionStore(documents);
    auto requests = new BuildRequestStore(documents, chains, definitions);
    chains.create(sampleChain("game", 1)); // pins compile's src: game at main

    auto definition = sampleDefinition();
    TaskNode sdk;
    sdk.id = "sdk";
    sdk.inputs["sdk"] = repositoryInput("console-sdk");
    sdk.inputs["src"] = repositoryInput("game");
    TaskNode external;
    external.id = "external";
    external.inputs["bin"] = taskOutputInput("compile");
    external.inputs["sdk"] = taskOutputInput("sdk");
    TaskNode art;
    art.id = "art";
    art.inputs["src"] = repositoryInput("art");
    definition.tasks ~= [sdk, external, art];
    const definitionId = definitions.put(definition);

    // compile needs only its own src, which the chain pins; lint needs nothing
    auto internal = sampleRequest("r1", "game-1", definitionId);
    internal.targets = ["compile", "lint"];
    internal.demands = demandsFor("compile", "lint");
    requests.create(internal);

    // external needs sdk's inputs through its upstream task sdk, including sdk's own input of
    // game, which compile's pin does not cover; art is not upstream of it
    auto release = sampleRequest("r2", "game-1", definitionId);
    release.targets = ["external"];
    release.demands = demandsFor("compile", "external", "sdk");
    try
    {
        requests.create(release);
        assert(false, "A request whose chain lacks a pin its targets need must be refused");
    }
    catch (InvalidStateTransitionException e)
    {
        assert(e.msg.canFind("task 'sdk' input 'sdk'") && e.msg.canFind("task 'sdk' input 'src'") && !e.msg.canFind("'art'"), e.msg);
    }
    assert(requests.get("r2").isNull);
    auto added = chains.addPins("game-1", [pinOf("sdk", "sdk", "console-sdk", "v2", "sdk222"), pinOf("sdk", "src", "game", "main", "aaa111")]);

    // A crash after the pins were added and before the request was recorded: the retry adds the
    // same pins again, which writes nothing, and records the request
    auto retried = chains.addPins("game-1", [pinOf("sdk", "sdk", "console-sdk", "v2", "sdk222"), pinOf("sdk", "src", "game", "main", "aaa111")]);
    assert(retried.version_ == added.version_ && retried.value == added.value);
    assert(requests.create(release).id == "r2", "Once the chain holds the pins the request is accepted");

    // A later definition declaring another repository for a pinned input cannot run on the chain
    auto moved = sampleDefinition();
    moved.tasks[0].inputs["src"] = repositoryInput("game-fork");
    const movedId = definitions.put(moved);
    try
    {
        requests.create(sampleRequest("r3", "game-1", movedId));
        assert(false, "A pin of another repository must not serve the input");
    }
    catch (InvalidStateTransitionException e)
    {
        assert(e.msg.canFind("'game-fork'") && e.msg.canFind("cannot run on chain"), e.msg);
    }

    // A malformed repository input in the definition is reported as the definition's problem
    auto invalid = sampleDefinition();
    invalid.tasks[0].inputs["src"] = repositoryInput("game", RefSpec.fromString("event +:*"));
    const invalidId = definitions.put(invalid);
    try
    {
        requests.create(sampleRequest("r4", "game-1", invalidId));
        assert(false, "A request with an invalid definition must be refused");
    }
    catch (InvalidStateTransitionException e)
    {
        assert(e.msg.canFind("which is invalid") && !e.msg.canFind("cannot run on chain") && e.msg.canFind("'src'"), e.msg);
    }
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
    unsortedPins.pins = [pinOf("lint", "src", "tools", "main", "ttt111"), pinOf("compile", "src", "game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ requests.create(unsortedPins); }));
    auto incompletePin = sampleRequest("r", "game-1", definitionId);
    incompletePin.pins = [pinOf("compile", "src", "game", "", "aaa111")];
    assert(throwsA!InvalidPinsException({ requests.create(incompletePin); }));
    assert(requests.get("r").isNull, "Nothing was written");

    // Demands must be for exactly the targets and their upstream tasks, sorted, each complete
    TaskDemand[][string] badDemands = [
        "no demands": null,
        "a demand for a task not covered": demandsFor("compile", "lint"),
        "a demand missing": demandsFor("lint"),
        "unsorted demands": [TaskDemand("lint", "fp", "b"), TaskDemand("compile", "fp", "b")],
        "a task demanded twice": [TaskDemand("compile", "fp", "b"), TaskDemand("compile", "fp", "b")],
        "a demand without a fingerprint": [TaskDemand("compile", "", "b")],
        "a demand without a base": [TaskDemand("compile", "fp", "")],
        "a demand without a task": [TaskDemand("", "fp", "b")],
    ];
    foreach (what, demands; badDemands)
    {
        auto request = sampleRequest("r", "game-1", definitionId);
        request.demands = demands;
        assert(throwsA!InvalidStateTransitionException({ requests.create(request); }), "A request with " ~ what ~ " must be refused");
    }
    assert(requests.get("r").isNull);
    auto wider = sampleRequest("wide", "game-1", definitionId);
    wider.targets = ["compile", "lint"];
    wider.demands = demandsFor("compile", "lint");
    requests.create(wider);
    assert(requests.get("wide").get.demands == demandsFor("compile", "lint"), "Demands are stored as given");

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
