module confector.core.build_stores;

/**
 * State stores for the build model (design records: beads confector-z7z.4, confector-z7z.14 and
 * confector-z7z.2; AGENTS.md, "What a build is" and "Coordinating builds"): build chains, build
 * requests, task executions, fingerprint claims and artifact records, each a typed collection in
 * the DocumentStore.
 *
 * Correctness depends only on reads by id and compare-and-set on one document. Index queries
 * (`list...`, `find...ByNumber`) are for discovery and may lag behind writes; level-triggered
 * re-evaluation tolerates that. Writes never retry on a lost compare-and-set: they throw
 * DocumentConflictException and the caller re-reads and decides again.
 */

import confector.core.counters : CounterStore;
import confector.core.document_collection;
import confector.core.model;
import confector.plugin_api.document_store;

import std.algorithm.searching : canFind;
import std.format : format;
import std.typecons : Nullable;

/// Build chains, by chain id (`chainIdFor`); indexed by project and number.
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

/// Fingerprint claims, by fingerprint. Read by id only.
enum CollectionSpec fingerprintClaimsCollection = CollectionSpec("fingerprint_claims", null);

/// Artifact records, by `artifactRecordId`; indexed by fingerprint.
enum CollectionSpec artifactRecordsCollection = CollectionSpec("artifact_records",
    [IndexSpec("by_fingerprint", "task_fingerprint", "artifact_id")]);

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
 * The id of a project's chain with join key `snapshotHash` (which covers the chain's resolved
 * inputs and branch context). Deriving the id from the join key makes joining a read by id, and
 * makes two requests that race to create the same chain collide on create: the loser joins the
 * winner's chain.
 */
string chainIdFor(string projectId, string snapshotHash) @safe
{
    return hashedId(projectId, snapshotHash);
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

    /// Reads the chain a request resolving to `snapshotHash` in project `projectId` joins, if it
    /// exists. Strongly consistent.
    Nullable!(Versioned!BuildChain) findJoinable(string projectId, string snapshotHash)
    {
        return m_chains.get(chainIdFor(projectId, snapshotHash));
    }

    /**
     * Creates `chain`. Its id must be `chainIdFor(projectId, snapshotHash)` and its number one
     * from `nextNumber`.
     *
     * Throws: DocumentConflictException if the chain exists (join it instead);
     * InvalidStateTransitionException if the chain is incomplete or its id is not derived from
     * its join key.
     */
    Versioned!BuildChain create(BuildChain chain)
    {
        requireValid(chain.projectId.length > 0 && chain.snapshotHash.length > 0 && chain.number > 0 && chain.createdAt.length > 0,
            format("Chain '%s' needs a project id, a snapshot hash, a number and a creation time", chain.id));
        requireValid(chain.id == chainIdFor(chain.projectId, chain.snapshotHash),
            format("Chain id '%s' is not chainIdFor('%s', '%s')", chain.id, chain.projectId, chain.snapshotHash));
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
            && next.snapshotHash == was.snapshotHash && next.createdAt == was.createdAt && next.tasks == was.tasks,
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
     * or the definition (and its hash) it was dispatched with.
     */
    Versioned!TaskExecution update(in Versioned!TaskExecution current, TaskExecution next)
    {
        const was = current.value;
        requireValid(isActive(was.status),
            format("Execution '%s' is %s, and a terminal execution never changes", was.id, was.status));
        requireValid(next.id == was.id && next.projectId == was.projectId && next.taskId == was.taskId
            && next.fingerprint == was.fingerprint && next.createdAt == was.createdAt,
            format("The identity of execution '%s' cannot change", was.id));
        requireValid(next.definitionHash == was.definitionHash && next.definition == cast(TaskNode) was.definition,
            format("Execution '%s' ran with the definition it was dispatched with; it cannot change", was.id));
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

    /// The executions at each of `fingerprints`, in the form the chain evaluator takes, with an
    /// entry (possibly empty) for every fingerprint. Discovery: may lag behind writes.
    TaskExecution[][string] listForFingerprints(in string[] fingerprints)
    {
        TaskExecution[][string] result;
        foreach (fingerprint; fingerprints)
        {
            result[fingerprint] = listForFingerprint(fingerprint);
        }
        return result;
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

/// The outcome of FingerprintClaimStore.claim.
struct ClaimResult
{
    /// Whether the claim is now held for the execution that asked for it.
    bool won;
    /// The claim as it now stands: when `won` is false, `executionId` names the holder.
    Versioned!FingerprintClaim claim;
}

/**
 * Fingerprint claims: at most one active execution per fingerprint (bead confector-z7z.2). A
 * claim is one document per fingerprint, never removed, so its version only grows and a writer
 * holding an older version always loses.
 */
final class FingerprintClaimStore
{
    private DocumentCollection!FingerprintClaim m_claims;

    /// Declares `fingerprintClaimsCollection` on `store`.
    this(DocumentStore store)
    {
        m_claims = new DocumentCollection!FingerprintClaim(store, fingerprintClaimsCollection);
    }

    /// Reads the claim on `fingerprint`. Null if it was never claimed.
    Nullable!(Versioned!FingerprintClaim) get(string fingerprint)
    {
        return m_claims.get(fingerprint);
    }

    /**
     * Claims `fingerprint` for execution `executionId`, if no execution holds it. Claiming a
     * fingerprint the same execution already holds wins again without writing.
     *
     * Throws: DocumentConflictException if a concurrent write to the claim landed between this
     * method's read and its write: the caller re-reads and decides again. Exception if either
     * argument is empty.
     */
    ClaimResult claim(string fingerprint, string executionId)
    {
        requireNonEmpty(fingerprint, "A claim needs a fingerprint");
        requireNonEmpty(executionId, "A claim needs an execution id");
        auto current = m_claims.get(fingerprint);
        if (current.isNull)
        {
            return ClaimResult(true, m_claims.create(fingerprint, FingerprintClaim(fingerprint, executionId)));
        }
        const holder = current.get.executionId;
        if (holder == executionId) return ClaimResult(true, current.get);
        if (holder.length > 0) return ClaimResult(false, current.get);
        return ClaimResult(true, m_claims.replace(fingerprint, FingerprintClaim(fingerprint, executionId), current.get.version_));
    }

    /**
     * Releases `fingerprint` if execution `executionId` holds it. Returns false, writing
     * nothing, if another execution or none holds it.
     *
     * Throws: DocumentConflictException if a concurrent write to the claim landed between this
     * method's read and its write. Exception if either argument is empty.
     */
    bool release(string fingerprint, string executionId)
    {
        requireNonEmpty(fingerprint, "A claim needs a fingerprint");
        requireNonEmpty(executionId, "A claim needs an execution id");
        auto current = m_claims.get(fingerprint);
        if (current.isNull || current.get.executionId != executionId) return false;
        m_claims.replace(fingerprint, FingerprintClaim(fingerprint), current.get.version_);
        return true;
    }
}

/// The id of the artifact record for artifact `artifactId` produced at `fingerprint`.
string artifactRecordId(string fingerprint, string artifactId) @safe
{
    return hashedId(fingerprint, artifactId);
}

/**
 * Artifact records: which artifact store holds each artifact, addressed as the artifact stores
 * address bytes, by the producing task's fingerprint and the artifact's id (AGENTS.md, "Backends
 * and extensions"). An artifact's address never changes; its other details may (for example when
 * retention deletes its bytes).
 */
final class ArtifactRecordStore
{
    private DocumentCollection!ArtifactMetadata m_records;

    /// Declares `artifactRecordsCollection` on `store`.
    this(DocumentStore store)
    {
        m_records = new DocumentCollection!ArtifactMetadata(store, artifactRecordsCollection);
    }

    /// Reads the record of artifact `artifactId` at `fingerprint`. Null if there is none.
    Nullable!(Versioned!ArtifactMetadata) get(string fingerprint, string artifactId)
    {
        return m_records.get(artifactRecordId(fingerprint, artifactId));
    }

    /**
     * Records an artifact.
     *
     * Throws: DocumentConflictException if it is already recorded;
     * InvalidStateTransitionException if it has no fingerprint, artifact id or storage backend.
     */
    Versioned!ArtifactMetadata create(ArtifactMetadata record)
    {
        requireValid(record.taskFingerprint.length > 0 && record.artifactId.length > 0 && record.storageBackend.length > 0,
            format("Artifact record '%s' needs a fingerprint, an artifact id and a storage backend", record.artifactId));
        return m_records.create(artifactRecordId(record.taskFingerprint, record.artifactId), record);
    }

    /**
     * Replaces the record `current` with `next`, which must keep its address.
     *
     * Throws: DocumentConflictException if the record changed since `current` was read;
     * InvalidStateTransitionException if `next` changes the fingerprint or artifact id.
     */
    Versioned!ArtifactMetadata update(in Versioned!ArtifactMetadata current, ArtifactMetadata next)
    {
        const was = current.value;
        requireValid(next.taskFingerprint == was.taskFingerprint && next.artifactId == was.artifactId,
            format("The address of artifact record '%s' at '%s' cannot change", was.artifactId, was.taskFingerprint));
        return m_records.replace(artifactRecordId(was.taskFingerprint, was.artifactId), next, current.version_);
    }

    /// Lists the artifacts recorded at `fingerprint`, by artifact id. Discovery.
    ArtifactMetadata[] listForFingerprint(string fingerprint)
    {
        IndexQuery lookup;
        lookup.index = "by_fingerprint";
        lookup.partitionKey = fingerprint;
        lookup.limit = pageSize;
        return values(m_records.queryAll(lookup));
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
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import vibe.data.json : Json;

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    private BuildChain sampleChain(string projectId, string snapshotHash, ulong number)
    {
        BuildChain chain;
        chain.id = chainIdFor(projectId, snapshotHash);
        chain.projectId = projectId;
        chain.number = number;
        chain.snapshotHash = snapshotHash;
        ChainTask compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game", "main");
        compile.resolvedInputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"))];
        chain.tasks = [compile];
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
    // Chains: create once under the id derived from the join key, join by id, number per project
    auto documents = new InMemoryDocumentStore();
    auto chains = new ChainStore(documents);
    assert(chains.nextNumber("game") == 1);
    assert(chains.nextNumber("game") == 2);
    assert(chains.nextNumber("tools") == 1);

    assert(chains.findJoinable("game", "snap1").isNull);
    auto created = chains.create(sampleChain("game", "snap1", 1));
    assert(created.version_ == 1);
    auto joined = chains.findJoinable("game", "snap1");
    assert(!joined.isNull && joined.get.value == created.value);
    assert(chains.get(created.id).get.number == 1);
    assert(chains.findJoinable("tools", "snap1").isNull, "Projects never share chains");

    // A second creator of the same chain loses and joins the winner's chain
    assert(throwsA!DocumentConflictException({ chains.create(sampleChain("game", "snap1", 2)); }));
    assert(chains.findJoinable("game", "snap1").get.number == 1);

    // Incomplete chains and ids not derived from the join key are rejected
    auto badId = sampleChain("game", "snap2", 2);
    badId.id = "chain-2";
    assert(throwsA!InvalidStateTransitionException({ chains.create(badId); }));
    auto noNumber = sampleChain("game", "snap2", 0);
    assert(throwsA!InvalidStateTransitionException({ chains.create(noNumber); }));
    auto badTime = sampleChain("game", "snap2", 2);
    badTime.createdAt = "today";
    assert(throwsA!Exception({ chains.create(badTime); }));

    // Chains persist across a restart
    assert(new ChainStore(documents.restart()).get(created.id).get.value == created.value);
}

unittest
{
    // Chains: two requests racing to create the same chain both allocate a number; the loser's
    // create conflicts, it joins the winner's chain, and its number is a gap
    auto documents = new InMemoryDocumentStore();
    auto winner = new ChainStore(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto loser = new ChainStore(interleaving);

    const loserNumber = loser.nextNumber("game");
    assert(loser.findJoinable("game", "snap1").isNull, "Nothing to join yet");
    interleaving.beforeNextWrite = () {
        winner.create(sampleChain("game", "snap1", winner.nextNumber("game")));
    };
    assert(throwsA!DocumentConflictException({ loser.create(sampleChain("game", "snap1", loserNumber)); }));
    auto joined = loser.findJoinable("game", "snap1");
    assert(!joined.isNull && joined.get.number == 2 && loserNumber == 1, "The loser joins the winner's chain");
    assert(loser.nextNumber("game") == 3, "The loser's number 1 is not reused");
    assert(loser.listForProject("game", 10).length == 1);
}

unittest
{
    // Chains: only labels change and history is only appended, by compare-and-set
    auto chains = new ChainStore(new InMemoryDocumentStore());
    auto v1 = chains.create(sampleChain("game", "snap1", 1));

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

    BuildChain retasked = v2.value;
    retasked.tasks = null;
    assert(throwsA!InvalidStateTransitionException({ chains.update(v2, retasked); }), "The snapshot is immutable");
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
    foreach (n; 1 .. 13) chains.create(sampleChain("game", format("snap%s", n), n));
    chains.create(sampleChain("tools", "snap1", 1));

    auto newest = chains.listForProject("game", 3);
    assert(newest.length == 3 && newest[0].number == 12 && newest[2].number == 10, "Numbers sort numerically, not as text");
    auto oldest = chains.listForProject("game", 100, false);
    assert(oldest.length == 12 && oldest[0].number == 1);
    assert(chains.listForProject("nobody", 10).length == 0);

    assert(chains.findByNumber("game", 7).get.snapshotHash == "snap7");
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
    restepped.definition.steps = [BuildStep("Compile", "bash", null, "make release")];
    assert(throwsA!InvalidStateTransitionException({ executions.update(v3, restepped); }), "The definition is fixed at dispatch");

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
    auto byFingerprint = executions.listForFingerprints(["fp1", "fp2", "none"]);
    assert(byFingerprint["fp1"].length == 2 && byFingerprint["fp2"].length == 1 && byFingerprint["none"].length == 0);

    auto history = executions.listForTask("game", "compile", 2);
    assert(history.length == 2 && history[0].id == "e3" && history[1].id == "e2");
    assert(executions.listForTask("game", "lint", 10).length == 1);

    auto active = executions.listActive(ExecutionStatus.queued, 10);
    assert(active.length == 3 && active[0].id == "e2", "A terminal execution leaves the active index");
    assert(executions.listActive(ExecutionStatus.running, 10).length == 0);
    assert(throwsA!InvalidStateTransitionException({ executions.listActive(ExecutionStatus.failed, 10); }));
}

unittest
{
    // Claims: at most one holder per fingerprint; claims are released, never removed
    auto documents = new InMemoryDocumentStore();
    auto claims = new FingerprintClaimStore(documents);
    assert(claims.get("fp1").isNull);

    auto first = claims.claim("fp1", "e1");
    assert(first.won && first.claim.executionId == "e1" && first.claim.version_ == 1);
    auto again = claims.claim("fp1", "e1");
    assert(again.won && again.claim.version_ == 1, "Claiming again for the holder writes nothing");
    auto lost = claims.claim("fp1", "e2");
    assert(!lost.won && lost.claim.executionId == "e1");

    assert(!claims.release("fp1", "e2"), "Only the holder releases");
    assert(!claims.release("fp9", "e1"));
    assert(claims.release("fp1", "e1"));
    assert(claims.get("fp1").get.executionId.length == 0 && claims.get("fp1").get.version_ == 2);
    assert(!claims.release("fp1", "e1"));

    auto next = claims.claim("fp1", "e2");
    assert(next.won && next.claim.version_ == 3);

    assert(throwsA!Exception({ claims.claim("", "e1"); }));
    assert(throwsA!Exception({ claims.claim("fp1", ""); }));
}

unittest
{
    // Claims: two dispatchers racing for one fingerprint produce exactly one winner; the loser's
    // write conflicts, and re-reading shows it lost
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto documents = new InMemoryDocumentStore();
    auto rival = new FingerprintClaimStore(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto claims = new FingerprintClaimStore(interleaving);

    interleaving.beforeNextWrite = () { assert(rival.claim("fp1", "e1").won); };
    assert(throwsA!DocumentConflictException({ claims.claim("fp1", "e2"); }), "Losing the create conflicts");
    assert(!claims.claim("fp1", "e2").won && claims.get("fp1").get.executionId == "e1");

    assert(rival.release("fp1", "e1"));
    interleaving.beforeNextWrite = () { assert(rival.claim("fp1", "e3").won); };
    assert(throwsA!DocumentConflictException({ claims.claim("fp1", "e2"); }), "Losing the replace conflicts");
    assert(claims.get("fp1").get.executionId == "e3");
}

unittest
{
    // Artifact records: addressed by fingerprint and artifact id; the address never changes
    auto records = new ArtifactRecordStore(new InMemoryDocumentStore());
    ArtifactMetadata artifact;
    artifact.taskFingerprint = "fp1";
    artifact.artifactId = "game.zip";
    artifact.sha256 = "abc";
    artifact.sizeBytes = 1024;
    artifact.storageBackend = "local";
    auto created = records.create(artifact);
    auto other = artifact;
    other.artifactId = "tools.zip";
    records.create(other);

    assert(records.get("fp1", "game.zip").get.value == artifact);
    assert(records.get("fp2", "game.zip").isNull);
    auto listed = records.listForFingerprint("fp1");
    assert(listed.length == 2 && listed[0].artifactId == "game.zip");

    ArtifactMetadata moved = artifact;
    moved.storageBackend = "s3";
    assert(records.update(created, moved).storageBackend == "s3");
    assert(throwsA!DocumentConflictException({ records.update(created, moved); }));
    ArtifactMetadata readdressed = records.get("fp1", "game.zip").get.value;
    auto current = records.get("fp1", "game.zip").get;
    readdressed.artifactId = "other.zip";
    assert(throwsA!InvalidStateTransitionException({ records.update(current, readdressed); }));

    assert(throwsA!DocumentConflictException({ records.create(artifact); }));
    auto unstored = artifact;
    unstored.artifactId = "x";
    unstored.storageBackend = null;
    assert(throwsA!InvalidStateTransitionException({ records.create(unstored); }));
}
