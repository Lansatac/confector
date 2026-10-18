module confector.core.build_stores;

/**
 * State stores for the build model (design records: beads confector-z7z.4, confector-z7z.14 and
 * confector-z7z.2; AGENTS.md, "What a build is" and "Coordinating builds"): build chains, build
 * requests and task executions, each a typed collection in the DocumentStore.
 *
 * Correctness depends only on reads by id and compare-and-set on one document. Index queries
 * (`list...`, `find...ByNumber`) are for discovery and may lag behind writes; level-triggered
 * re-evaluation tolerates that. Writes never retry on a lost compare-and-set: they throw
 * DocumentConflictException and the caller re-reads and decides again.
 */

import confector.core.counters : CounterStore;
import confector.core.document_collection;
import confector.api.model;
import confector.api.document_store;

import std.algorithm.searching : canFind;
import std.format : format;
import std.typecons : Nullable;

/// Build chains, by chain id; indexed by project and number.
enum CollectionSpec buildChainsCollection = CollectionSpec("build_chains",
    [IndexSpec("by_project", "project_id", "number_key")]);

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
 * Build chains. Everything but a chain's labels and events is immutable once created; events are
 * only appended.
 */
final class ChainStore
{
    private DocumentCollection!BuildChain m_chains;
    private CounterStore m_counters;

    /// Declares `buildChainsCollection` and the counters collection on `store`.
    this(DocumentStore store)
    {
        m_chains = new DocumentCollection!BuildChain(store, buildChainsCollection, ["number_key"],
            (in BuildChain chain) => ["number_key": sortableNumber(chain.number)]);
        m_counters = new CounterStore(store);
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
     * Creates `chain`. Its number must be one from `nextNumber`.
     *
     * Throws: DocumentConflictException if a chain with its id exists;
     * InvalidStateTransitionException if the chain is incomplete.
     */
    Versioned!BuildChain create(BuildChain chain)
    {
        requireValid(chain.id.length > 0 && chain.projectId.length > 0 && chain.number > 0 && chain.createdAt.length > 0,
            format("Chain '%s' needs an id, a project id, a number and a creation time", chain.id));
        sortableTimestamp(chain.createdAt);
        return m_chains.create(chain.id, chain);
    }

    /**
     * Replaces the chain `current` with `next`, which may differ only in its labels and by events
     * appended to its history.
     *
     * Throws: DocumentConflictException if the chain changed since `current` was read;
     * InvalidStateTransitionException if `next` changes anything else.
     */
    Versioned!BuildChain update(in Versioned!BuildChain current, BuildChain next)
    {
        const was = current.value;
        requireValid(next.id == was.id && next.projectId == was.projectId && next.number == was.number
            && next.createdAt == was.createdAt,
            format("Only the labels and history of chain '%s' can change", was.id));
        requireValid(next.events.length >= was.events.length && next.events[0 .. was.events.length] == was.events,
            format("The history of chain '%s' can only be appended to", was.id));
        return m_chains.replace(was.id, next, current.version_);
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
 * Build requests. Immutable: written once, never replaced or removed.
 */
final class BuildRequestStore
{
    private DocumentCollection!BuildRequest m_requests;

    /// Declares `buildRequestsCollection` on `store`.
    this(DocumentStore store)
    {
        m_requests = new DocumentCollection!BuildRequest(store, buildRequestsCollection, ["requested_key"],
            (in BuildRequest request) => ["requested_key": sortableTimestamp(request.requestedAt)]);
    }

    /// Reads a request by id. Null if it does not exist.
    Nullable!(Versioned!BuildRequest) get(string id)
    {
        return m_requests.get(id);
    }

    /**
     * Records `request`.
     *
     * Throws: DocumentConflictException if a request with its id exists;
     * InvalidStateTransitionException if it has no id, project, chain or targets; Exception if
     * `requestedAt` is not an ISO 8601 timestamp.
     */
    Versioned!BuildRequest create(BuildRequest request)
    {
        requireValid(request.id.length > 0 && request.projectId.length > 0 && request.chainId.length > 0 && request.targets.length > 0,
            format("Request '%s' needs an id, a project id, a chain id and at least one target", request.id));
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

private void requireNonEmpty(string value, lazy string message)
{
    if (value.length == 0) throw new Exception(message);
}

version (unittest)
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import vibe.data.json : Json;

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    private BuildChain sampleChain(string projectId, ulong number)
    {
        BuildChain chain;
        chain.id = format("%s-%s", projectId, number);
        chain.projectId = projectId;
        chain.number = number;
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
}

unittest
{
    // Chains: created once, numbered per project
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    assert(chains.nextNumber("game") == 1);
    assert(chains.nextNumber("game") == 2);
    assert(chains.nextNumber("tools") == 1);

    auto created = chains.create(sampleChain("game", 1));
    assert(created.version_ == 1);
    assert(chains.get(created.id).get.value == created.value);
    assert(chains.get("game-9").isNull);
    assert(throwsA!DocumentConflictException({ chains.create(sampleChain("game", 1)); }), "A chain is created once");

    // Incomplete chains are rejected
    auto noId = sampleChain("game", 2);
    noId.id = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noId); }));
    auto noProject = sampleChain("game", 2);
    noProject.projectId = null;
    assert(throwsA!InvalidStateTransitionException({ chains.create(noProject); }));
    auto noNumber = sampleChain("game", 0);
    assert(throwsA!InvalidStateTransitionException({ chains.create(noNumber); }));
    auto badTime = sampleChain("game", 2);
    badTime.createdAt = "today";
    assert(throwsA!Exception({ chains.create(badTime); }));

    // Chains persist across a restart
    assert(new ChainStore(documents.restart()).get(created.id).get.value == created.value);
}

unittest
{
    // Chains: only labels change and history is only appended, by compare-and-set
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

    BuildChain appended = v2.value;
    appended.events ~= ChainEvent(ChainEventKind.rerun, "r3", "compile", "base", 2);
    assert(chains.update(v2, appended).events.length == 2);
}

unittest
{
    // Chains: listed by number per project, and found by number
    auto chains = new ChainStore(new InMemoryDocumentStore());
    foreach (n; 1 .. 13) chains.create(sampleChain("game", n));
    chains.create(sampleChain("tools", 1));

    auto newest = chains.listForProject("game", 3);
    assert(newest.length == 3 && newest[0].number == 12 && newest[2].number == 10, "Numbers sort numerically, not as text");
    auto oldest = chains.listForProject("game", 100, false);
    assert(oldest.length == 12 && oldest[0].number == 1);
    assert(chains.listForProject("nobody", 10).length == 0);

    assert(chains.findByNumber("game", 7).get.id == "game-7");
    assert(chains.findByNumber("tools", 1).get.projectId == "tools");
    assert(chains.findByNumber("game", 99).isNull);
}

unittest
{
    // Requests: immutable, listed per chain in request time order (not text order) and per project
    auto requests = new BuildRequestStore(new InMemoryDocumentStore());
    BuildRequest request;
    request.id = "r1";
    request.projectId = "game";
    request.chainId = "c1";
    request.targets = ["compile"];
    request.intent = BuildIntent.build;
    request.trigger.type = TriggerType.manual;
    request.requestedBy = "jason";
    request.requestedAt = "2026-10-15T14:02:00.5Z";
    requests.create(request);

    auto earlier = request;
    earlier.id = "r2";
    earlier.requestedAt = "2026-10-15T14:02:00Z"; // sorts after r1 as text, before it as a time
    requests.create(earlier);
    auto otherChain = request;
    otherChain.id = "r3";
    otherChain.chainId = "c2";
    otherChain.requestedAt = "2026-10-15T15:00:00Z";
    requests.create(otherChain);

    assert(requests.get("r1").get.value == request);
    assert(requests.get("missing").isNull);
    auto onChain = requests.listForChain("c1");
    assert(onChain.length == 2 && onChain[0].id == "r2" && onChain[1].id == "r1");
    auto onProject = requests.listForProject("game", 2);
    assert(onProject.length == 2 && onProject[0].id == "r3" && onProject[1].id == "r1");

    assert(throwsA!DocumentConflictException({ requests.create(request); }), "A request is written once");
    auto untargeted = request;
    untargeted.id = "r4";
    untargeted.targets = null;
    assert(throwsA!InvalidStateTransitionException({ requests.create(untargeted); }));
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
