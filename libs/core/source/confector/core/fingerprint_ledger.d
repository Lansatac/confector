module confector.core.fingerprint_ledger;

/**
 * The fingerprint ledger (AGENTS.md, "Coordinating builds"): one FingerprintLedger document per
 * fingerprint, read by id and changed only by compare-and-set, so it works on every DocumentStore
 * backend and in stateless invocations. The ledger holds everything about the fingerprint that
 * changes: its active execution (queued or running, at most one), its latest success and its
 * latest stop.
 *
 * Every operation reads only by id (the ledger and, for `fold`, `settle` and a losing `claim`,
 * the execution record it names) and writes only by single-document compare-and-set, retried on a
 * lost compare-and-set where the decision does not depend on what changed. Every operation is
 * idempotent, so a crash between any two steps is repaired by repeating them.
 *
 * The active execution's life, each step one compare-and-set on the ledger (the pure transitions
 * are the `with...` functions, and `LedgerStore.update` writes them):
 *
 * - `claim(F, seen, proposed)` creates it queued, with everything the execution needs (the task,
 *   its definition, resolved inputs and repository addresses), under the deterministic id
 *   `executionIdFor(F, seen + 1)`. `seen` is the ledger's `executionSeq` as the caller read it
 *   when it decided F needs an execution (0 if it found no ledger). A loser learns the active
 *   execution or that an execution was claimed and finished since it read; either way it
 *   re-evaluates and waits on the active execution, which reconciles its request again when it
 *   ends.
 * - `withStart`: a worker starts it (queued to running, one more attempt, a lease).
 *   `withLease`: a heartbeat extends the lease. `withRequeue`: a release, or `withLostLease`: an
 *   expired lease, puts it back to queued.
 * - It ends by writing the immutable TaskExecution (`ExecutionStore.create`, which only one ender
 *   can win) and then `fold`, which in one compare-and-set clears the active execution and records
 *   the outcome as `lastSuccessExecutionId` or `lastStoppedExecutionId` (with `stopSeq`
 *   incremented).
 *
 * Crash repair, by whoever next reads the ledger (`settle`, or a losing `claim`): if the active
 * execution already has its record (its ender crashed between the write and the fold), complete
 * the fold. A crash before the record leaves the execution active, to be ended again.
 *
 * The collection's `active` index lists ledgers whose active execution is queued (oldest first)
 * or running (by lease expiry): discovery for workers asking for work and for the sweep, which
 * may lag. Both read the ledger by id before acting.
 *
 * Reuse: `lastSuccessExecutionId` only names the latest success. Whether it is usable (its
 * artifacts may have expired) is on the execution record and decided by the caller, which
 * claims again if it is not. A claim never looks at the last success; there is no special case
 * for claiming over one.
 */

import confector.core.build_stores : defaultPageSize, ExecutionStore, InvalidStateTransitionException;
import confector.core.document_collection;
import confector.api.document_store;
import confector.api.model;

import std.conv : to;
import std.format : format;
import std.typecons : Nullable, nullable;

/// The state store collection holding fingerprint ledgers, keyed by fingerprint. Its `active`
/// index holds the ledgers with an active execution: partitioned by its status, ordered by when it
/// was claimed (queued) or when its lease expires (running).
enum CollectionSpec fingerprintLedgersCollection = CollectionSpec("fingerprint_ledgers",
    [IndexSpec("active", "active_status", "active_due")]);

/**
 * The id of the `seq`th execution claimed at `fingerprint` (seq starts at 1): a hash of both,
 * so the same claim always names the same execution and repeating its steps after a crash
 * creates nothing twice. Stable: changing it orphans every recorded execution's ledger link.
 *
 * Throws: Exception if `fingerprint` is empty or `seq` is 0.
 */
string executionIdFor(string fingerprint, ulong seq) @safe
{
    if (fingerprint.length == 0) throw new Exception("An execution id needs a fingerprint");
    if (seq == 0) throw new Exception(format("Execution sequence numbers start at 1; fingerprint %s was given 0", fingerprint));
    return hashedId("task_execution", fingerprint, to!string(seq));
}

/// Whether `executionId` is one of the executions ever claimed on `ledger` (sequence 1 to
/// `executionSeq`), active or not.
bool claimedOn(in FingerprintLedger ledger, string executionId) @safe
{
    foreach (seq; 1 .. ledger.executionSeq + 1)
    {
        if (executionIdFor(ledger.fingerprint, seq) == executionId) return true;
    }
    return false;
}

/**
 * `ledger` with its next execution claimed: `proposed` (its project, task, definition, inputs,
 * repository addresses and creation time) becomes the active execution, queued under the next
 * deterministic id, and counted in `executionSeq`.
 *
 * Throws: InvalidStateTransitionException if an execution is active.
 */
FingerprintLedger withClaim(in FingerprintLedger ledger, in ActiveExecution proposed) @trusted
{
    requireValid(ledger.active.isNull, format("Fingerprint %s already has active execution '%s'",
        ledger.fingerprint, ledger.active.isNull ? "" : ledger.active.get.id));
    auto next = copyOf(ledger);
    next.executionSeq += 1;
    ActiveExecution claimed;
    claimed.id = executionIdFor(ledger.fingerprint, next.executionSeq);
    claimed.projectId = proposed.projectId;
    claimed.taskId = proposed.taskId;
    claimed.status = ExecutionStatus.queued;
    claimed.definitionId = proposed.definitionId;
    claimed.inputs = (cast(ResolvedInput[]) proposed.inputs).dup;
    claimed.repositoryAddresses = (cast(string[string]) proposed.repositoryAddresses).dup;
    claimed.createdAt = proposed.createdAt;
    next.active = claimed;
    return next;
}

/**
 * `ledger` with its queued active execution started by `worker`: running, one more attempt, held
 * until `leaseExpiresAt`, started at `now`.
 *
 * Throws: InvalidStateTransitionException if the active execution is not queued.
 */
FingerprintLedger withStart(in FingerprintLedger ledger, string worker, string leaseExpiresAt, string now) @trusted
{
    auto active = activeOf(ledger, "start");
    requireValid(active.status == ExecutionStatus.queued, format("Execution '%s' is %s, so it cannot be started", active.id, active.status));
    active.status = ExecutionStatus.running;
    active.attempt += 1;
    active.worker = worker;
    active.leaseExpiresAt = leaseExpiresAt;
    active.startedAt = now;
    auto next = copyOf(ledger);
    next.active = active;
    return next;
}

/**
 * `ledger` with the lease of its running active execution extended to `leaseExpiresAt`.
 *
 * Throws: InvalidStateTransitionException if the active execution is not running.
 */
FingerprintLedger withLease(in FingerprintLedger ledger, string leaseExpiresAt) @trusted
{
    auto active = activeOf(ledger, "extend the lease of");
    requireValid(active.status == ExecutionStatus.running, format("Execution '%s' is %s, so it holds no lease", active.id, active.status));
    active.leaseExpiresAt = leaseExpiresAt;
    auto next = copyOf(ledger);
    next.active = active;
    return next;
}

/**
 * `ledger` with its running active execution given back: queued again, for any worker to start. A
 * release is not a lost lease (`withLostLease`): it does not count toward the attempt limit.
 *
 * Throws: InvalidStateTransitionException if the active execution is not running.
 */
FingerprintLedger withRequeue(in FingerprintLedger ledger) @trusted
{
    auto active = activeOf(ledger, "release");
    requireValid(active.status == ExecutionStatus.running, format("Execution '%s' is %s, so it cannot be released", active.id, active.status));
    active.status = ExecutionStatus.queued;
    active.worker = null;
    active.leaseExpiresAt = null;
    active.startedAt = null;
    auto next = copyOf(ledger);
    next.active = active;
    return next;
}

/**
 * `ledger` with a lost lease counted on its running active execution (`expiredLeases`); with
 * `requeue` the execution is also queued again for another attempt. Without it the execution stays
 * running, counted, for its ender to fail.
 *
 * Throws: InvalidStateTransitionException if the active execution is not running.
 */
FingerprintLedger withLostLease(in FingerprintLedger ledger, bool requeue) @trusted
{
    auto next = requeue ? withRequeue(ledger) : copyOf(ledger);
    auto active = activeOf(next, "expire the lease of");
    requireValid(requeue || active.status == ExecutionStatus.running,
        format("Execution '%s' is %s, so it holds no lease", active.id, active.status));
    active.expiredLeases += 1;
    next.active = active;
    return next;
}

/**
 * `ledger` with the terminal outcome of its active execution `execution` folded in: no active
 * execution, and the outcome recorded as the last success or, with `stopSeq` incremented, the last
 * stop.
 *
 * Throws: InvalidStateTransitionException if `execution` is not terminal or not the ledger's
 * active execution.
 */
FingerprintLedger withFold(in FingerprintLedger ledger, in TaskExecution execution) @safe
{
    requireValid(!ExecutionStore.isActive(execution.status),
        format("Execution '%s' is %s; only a finished execution is folded into its ledger", execution.id, execution.status));
    requireValid(!ledger.active.isNull && ledger.active.get.id == execution.id,
        format("Execution '%s' is not the active execution ('%s') of fingerprint %s", execution.id,
            ledger.active.isNull ? "" : ledger.active.get.id, ledger.fingerprint));
    auto next = copyOf(ledger);
    next.active.nullify();
    if (execution.status == ExecutionStatus.succeeded)
    {
        next.lastSuccessExecutionId = execution.id;
    }
    else
    {
        next.lastStoppedExecutionId = execution.id;
        next.stopSeq += 1;
    }
    return next;
}

/**
 * The record of `active`, the execution at `fingerprint`, ended as `status` at `finishedAt`: its
 * identity, inputs and times, and the attempt and lost leases it ended with. The caller adds the
 * outcome's exit code, error and artifacts. Pure.
 */
TaskExecution endedExecution(string fingerprint, in ActiveExecution active, ExecutionStatus status, string finishedAt) @trusted
{
    TaskExecution ended;
    ended.id = active.id;
    ended.projectId = active.projectId;
    ended.taskId = active.taskId;
    ended.fingerprint = fingerprint;
    ended.status = status;
    ended.attempts = active.attempt;
    ended.expiredLeases = active.expiredLeases;
    ended.definitionId = active.definitionId;
    ended.inputs = (cast(ResolvedInput[]) active.inputs).dup;
    ended.repositoryAddresses = (cast(string[string]) active.repositoryAddresses).dup;
    ended.worker = active.worker;
    ended.createdAt = active.createdAt;
    ended.startedAt = active.startedAt;
    ended.finishedAt = finishedAt;
    return ended;
}

/// What a claim found.
enum ClaimOutcome
{
    /// The claim won: `executionId` is the new active execution.
    won,
    /// Another execution is active: `executionId`. The caller waits for it to end.
    active,
    /// No execution is active, but executions were claimed since the caller read the ledger
    /// (`ledger.executionSeq` moved), so its decision is stale. Re-evaluate with this ledger.
    superseded
}

/// The result of `LedgerStore.claim`.
struct LedgerClaim
{
    ClaimOutcome outcome;
    /// won: the claimed execution; active: the execution that is active; superseded: empty.
    string executionId;
    /// The ledger after the claim (won) or as found (otherwise, after completing any fold).
    Versioned!FingerprintLedger ledger;
}

/// What a fold did.
enum FoldOutcome
{
    /// The outcome was folded in by this call.
    folded,
    /// The execution had been folded already (by a concurrent or earlier fold); nothing was
    /// written.
    alreadyFolded
}

/// The result of `LedgerStore.fold`.
struct LedgerFold
{
    FoldOutcome outcome;
    /// The ledger after the fold (folded) or as found (alreadyFolded).
    Versioned!FingerprintLedger ledger;
}

/**
 * Fingerprint ledgers in a DocumentStore, with the execution records they name. See the module
 * documentation for the protocols. Ledgers are never removed.
 */
final class LedgerStore
{
    /// How many times an operation re-reads and retries after losing a compare-and-set to a
    /// concurrent write of the same ledger before failing. Every lost attempt means another write
    /// succeeded, so this is reached only under sustained contention on one fingerprint. A ledger
    /// is shared by every chain that needs the fingerprint and by the workers and the sweep, so
    /// many writers can contend on it at once.
    enum maxWriteAttempts = 100;

    private DocumentCollection!FingerprintLedger m_ledgers;
    private ExecutionStore m_executions;
    /// Ledgers per page of the `active` index.
    private immutable size_t m_pageSize;

    /// Declares `fingerprintLedgersCollection` on `store`; `executions` is where the ledgers'
    /// finished executions are recorded. `pageSize` is how many ledgers one page of the `active` index holds.
    this(DocumentStore store, ExecutionStore executions, size_t pageSize = defaultPageSize)
    {
        if (executions is null) throw new Exception("LedgerStore requires the execution store");
        if (pageSize == 0) throw new Exception("LedgerStore needs a positive page size");
        m_ledgers = new DocumentCollection!FingerprintLedger(store, fingerprintLedgersCollection,
            ["active_status", "active_due"], &derivedFields);
        m_executions = executions;
        m_pageSize = pageSize;
    }

    private static string[string] derivedFields(in FingerprintLedger ledger)
    {
        if (ledger.active.isNull) return null;
        const active = ledger.active.get;
        return [
            "active_status": active.status,
            "active_due": sortableTimestamp(active.status == ExecutionStatus.queued ? active.createdAt : active.leaseExpiresAt),
        ];
    }

    /**
     * Reads the ledger of `fingerprint` by id. Null if no execution was ever claimed there.
     *
     * Throws: Exception if `fingerprint` is empty; MalformedDocumentException if the stored
     * ledger names another fingerprint.
     */
    Nullable!(Versioned!FingerprintLedger) get(string fingerprint)
    {
        requireFingerprint(fingerprint);
        auto found = m_ledgers.get(fingerprint);
        if (!found.isNull && found.get.fingerprint != fingerprint)
        {
            throw new MalformedDocumentException(format("Ledger '%s' in collection '%s' names fingerprint '%s'",
                fingerprint, fingerprintLedgersCollection.name, found.get.fingerprint), fingerprintLedgersCollection.name, fingerprint);
        }
        return found;
    }

    /**
     * Claims the next execution at `fingerprint`, creating its ledger on the first claim, with
     * `proposed` as the active execution (see `withClaim`). Wins only if no execution is active
     * and the ledger's `executionSeq` is still `seenExecutionSeq`, the value the caller read when
     * it decided an execution is needed (0 when it found no ledger), so a decision made before
     * another execution started and finished never builds the fingerprint twice. The claim is one
     * compare-and-set on the ledger. Of concurrent claimers exactly one wins; the others see its
     * execution. A claim that finds an active execution which already ended (its fold never
     * happened) completes the fold and decides again. See ClaimOutcome.
     *
     * Throws: Exception if `fingerprint` is empty or every one of maxWriteAttempts attempts lost
     * a compare-and-set; InvalidStateTransitionException if `seenExecutionSeq` is ahead of the
     * ledger (the caller did not read it from this ledger) or `proposed` is incomplete.
     */
    LedgerClaim claim(string fingerprint, ulong seenExecutionSeq, in ActiveExecution proposed)
    {
        requireFingerprint(fingerprint);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = get(fingerprint);
            const ulong executionSeq = current.isNull ? 0 : current.get.executionSeq;
            requireValid(seenExecutionSeq <= executionSeq, format(
                "A claim at fingerprint %s saw execution %s, but the ledger has only claimed %s", fingerprint,
                seenExecutionSeq, executionSeq));
            if (!current.isNull && !current.get.active.isNull)
            {
                // Only on this losing path: if the active execution ended but was never folded
                // (its ender crashed), complete the fold and decide again.
                const activeId = current.get.active.get.id;
                auto ended = m_executions.get(activeId);
                if (!ended.isNull)
                {
                    requireValid(ended.get.fingerprint == fingerprint, format(
                        "The active execution '%s' of fingerprint %s is recorded at fingerprint %s", activeId,
                        fingerprint, ended.get.fingerprint));
                    foldRecord(ended.get.value);
                    continue;
                }
                return LedgerClaim(ClaimOutcome.active, activeId, current.get);
            }
            if (executionSeq != seenExecutionSeq)
            {
                return LedgerClaim(ClaimOutcome.superseded, null, current.get);
            }
            try
            {
                if (current.isNull)
                {
                    FingerprintLedger fresh;
                    fresh.fingerprint = fingerprint;
                    auto claimed = withClaim(fresh, proposed);
                    requireWellFormed(claimed);
                    auto created = m_ledgers.create(fingerprint, claimed);
                    return LedgerClaim(ClaimOutcome.won, created.active.get.id, created);
                }
                auto claimed = withClaim(current.get.value, proposed);
                requireWellFormed(claimed);
                auto replaced = m_ledgers.replace(fingerprint, claimed, current.get.version_);
                return LedgerClaim(ClaimOutcome.won, replaced.active.get.id, replaced);
            }
            catch (DocumentConflictException)
            {
                // Another write landed since the read: read it and decide again.
            }
        }
        throw new Exception(format("Could not claim fingerprint %s: %s attempts in a row lost a compare-and-set",
            fingerprint, maxWriteAttempts));
    }

    /**
     * Replaces the ledger `current` with `next`, which may change only its active execution's
     * attempt, status, worker, lease and lost leases (the `withStart`, `withLease`, `withRequeue`
     * and `withLostLease` transitions): the claim and the fold have their own operations.
     *
     * Throws: DocumentConflictException if the ledger changed since `current` was read;
     * InvalidStateTransitionException if `next` changes anything else, or is malformed.
     */
    Versioned!FingerprintLedger update(in Versioned!FingerprintLedger current, FingerprintLedger next)
    {
        const was = current.value;
        requireValid(!was.active.isNull && !next.active.isNull, format(
            "Fingerprint %s: only an active execution is updated in place", was.fingerprint));
        const before = was.active.get;
        const after = next.active.get;
        requireValid(next.fingerprint == was.fingerprint && next.lastSuccessExecutionId == was.lastSuccessExecutionId
            && next.lastStoppedExecutionId == was.lastStoppedExecutionId && next.stopSeq == was.stopSeq
            && next.executionSeq == was.executionSeq,
            format("Fingerprint %s: an update cannot change its identity, outcomes or counts", was.fingerprint));
        requireValid(after.id == before.id && after.projectId == before.projectId && after.taskId == before.taskId
            && after.definitionId == before.definitionId && after.inputs == before.inputs
            && cast(string[string]) after.repositoryAddresses == cast(string[string]) before.repositoryAddresses && after.createdAt == before.createdAt,
            format("Execution '%s' runs with what it was claimed with; it cannot change", before.id));
        requireValid(after.attempt >= before.attempt && after.expiredLeases >= before.expiredLeases,
            format("The attempt and lost leases of execution '%s' never go down", before.id));
        requireWellFormed(next);
        return m_ledgers.replace(was.fingerprint, next, current.version_);
    }

    /**
     * Folds the outcome of `execution` into its fingerprint's ledger (see `withFold`). The
     * execution is identified by its id: its stored record is read by id and that record's
     * outcome is folded, never the status in `execution`, so a caller that lost the race to write
     * the record cannot fold the outcome it intended. Idempotent: folding an execution the
     * ledger already folded writes nothing.
     *
     * Throws: InvalidStateTransitionException if the stored execution is missing, is not
     * terminal, is at another fingerprint than `execution` says, has no ledger, or was never
     * claimed on its ledger (a fold for an execution the ledger does not know is a bug, so it
     * fails loudly rather than being ignored); Exception if every one of maxWriteAttempts
     * attempts lost a compare-and-set.
     */
    LedgerFold fold(in TaskExecution execution)
    {
        auto stored = m_executions.get(execution.id);
        requireValid(!stored.isNull, format("Execution '%s' is not recorded, so it cannot be folded", execution.id));
        requireValid(stored.get.fingerprint == execution.fingerprint, format(
            "Execution '%s' is recorded at fingerprint %s, not %s", execution.id, stored.get.fingerprint, execution.fingerprint));
        return foldRecord(stored.get.value);
    }

    /// Folds `execution`, a record just read by id from the execution store.
    private LedgerFold foldRecord(in TaskExecution execution)
    {
        requireFingerprint(execution.fingerprint);
        requireValid(!ExecutionStore.isActive(execution.status),
            format("Execution '%s' is %s; only a finished execution is folded into its ledger", execution.id, execution.status));
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = get(execution.fingerprint);
            requireValid(!current.isNull, format("Execution '%s' at fingerprint %s has no ledger: it was never claimed",
                execution.id, execution.fingerprint));
            const ledger = current.get;
            if (ledger.active.isNull || ledger.active.get.id != execution.id)
            {
                requireValid(claimedOn(ledger, execution.id), format(
                    "Execution '%s' was never claimed at fingerprint %s (its ledger has claimed %s executions; active: '%s')",
                    execution.id, execution.fingerprint, ledger.executionSeq, ledger.active.isNull ? "" : ledger.active.get.id));
                return LedgerFold(FoldOutcome.alreadyFolded, current.get);
            }
            try
            {
                return LedgerFold(FoldOutcome.folded,
                    m_ledgers.replace(execution.fingerprint, withFold(ledger.value, execution), ledger.version_));
            }
            catch (DocumentConflictException)
            {
                // Another write landed: read it and fold again (or find it folded).
            }
        }
        throw new Exception(format("Could not fold execution '%s' into fingerprint %s: %s attempts in a row lost a compare-and-set",
            execution.id, execution.fingerprint, maxWriteAttempts));
    }

    /**
     * Reads the ledger of `fingerprint`, completing a half-finished fold first: if the active
     * execution already has its record (its ender crashed between writing it and the fold),
     * folds it. Any reader may call it, any number of times. Null if no execution was ever
     * claimed at the fingerprint; otherwise the ledger's `active` is queued or running.
     *
     * Throws: Exception if `fingerprint` is empty or the ledger keeps changing for
     * maxWriteAttempts reads; InvalidStateTransitionException if the active execution's record
     * names another fingerprint.
     */
    Nullable!(Versioned!FingerprintLedger) settle(string fingerprint)
    {
        requireFingerprint(fingerprint);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto ledger = get(fingerprint);
            if (ledger.isNull || ledger.get.active.isNull) return ledger;
            const activeId = ledger.get.active.get.id;
            auto ended = m_executions.get(activeId);
            if (ended.isNull) return ledger;
            requireValid(ended.get.fingerprint == fingerprint, format(
                "The active execution '%s' of fingerprint %s is recorded at fingerprint %s", activeId,
                fingerprint, ended.get.fingerprint));
            foldRecord(ended.get.value);
        }
        throw new Exception(format("Could not settle fingerprint %s: it changed on each of %s reads", fingerprint, maxWriteAttempts));
    }

    /// One page of the ledgers whose active execution is queued, oldest claim first, from `cursor`
    /// (null for the first page). `nextCursor` is empty after the last page. Discovery: it may lag,
    /// so read each ledger by id before acting on it.
    Page!FingerprintLedger queuedPage(string cursor)
    {
        IndexQuery lookup;
        lookup.index = "active";
        lookup.partitionKey = ExecutionStatus.queued;
        lookup.limit = m_pageSize;
        lookup.cursor = cursor;
        return m_ledgers.query(lookup);
    }

    /// One page of the ledgers whose running execution's lease expires at or before `now`, the
    /// earliest first, from `cursor`. Discovery, like `queuedPage`.
    Page!FingerprintLedger leaseDuePage(string now, string cursor)
    {
        IndexQuery lookup;
        lookup.index = "active";
        lookup.partitionKey = ExecutionStatus.running;
        lookup.sortKeyTo = sortableTimestamp(now);
        lookup.limit = m_pageSize;
        lookup.cursor = cursor;
        return m_ledgers.query(lookup);
    }
}

/// A mutable copy of `ledger`. The active execution's arrays are shared, which is safe because
/// ledgers are only ever replaced, never edited in place.
private FingerprintLedger copyOf(in FingerprintLedger ledger) @trusted
{
    return cast(FingerprintLedger) ledger;
}

/// A mutable copy of the active execution of `ledger`, for a transition to change.
private ActiveExecution activeOf(in FingerprintLedger ledger, string action) @trusted
{
    requireValid(!ledger.active.isNull, format("Fingerprint %s has no active execution to %s", ledger.fingerprint, action));
    return cast(ActiveExecution) ledger.active.get;
}

/// Throws InvalidStateTransitionException unless `ledger` is well formed: its active execution
/// (if any) is the latest claim, has what it was claimed with, and is queued without a worker or
/// running with one and a lease.
private void requireWellFormed(in FingerprintLedger ledger)
{
    requireFingerprint(ledger.fingerprint);
    if (ledger.active.isNull) return;
    const active = ledger.active.get;
    requireValid(ledger.executionSeq > 0 && active.id == executionIdFor(ledger.fingerprint, ledger.executionSeq),
        format("The active execution '%s' of fingerprint %s is not its latest claim", active.id, ledger.fingerprint));
    requireValid(active.projectId.length > 0 && active.taskId.length > 0 && active.definitionId.length > 0,
        format("Execution '%s' needs a project id, a task id and a definition id", active.id));
    requireTimestamp(active.createdAt, format("The creation time of execution '%s'", active.id));
    final switch (active.status)
    {
        case ExecutionStatus.queued:
            requireValid(active.worker.length == 0 && active.leaseExpiresAt.length == 0 && active.startedAt.length == 0,
                format("Execution '%s' is queued, so it has no worker, lease or start time", active.id));
            break;
        case ExecutionStatus.running:
            requireValid(active.worker.length > 0 && active.attempt > 0 && active.startedAt.length > 0,
                format("Execution '%s' is running, so it needs a worker, an attempt and a start time", active.id));
            requireTimestamp(active.leaseExpiresAt, format("The lease expiry of running execution '%s'", active.id));
            break;
        case ExecutionStatus.succeeded:
        case ExecutionStatus.failed:
        case ExecutionStatus.cancelled:
            requireValid(false, format("Execution '%s' is %s, which is not an active status", active.id, active.status));
            break;
    }
}

private void requireTimestamp(string timestamp, lazy string what)
{
    try sortableTimestamp(timestamp);
    catch (Exception e) throw new InvalidStateTransitionException(format("%s is not valid: %s", what, e.msg));
}

private void requireValid(bool condition, lazy string message) @safe
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

private void requireFingerprint(string fingerprint) @safe
{
    if (fingerprint.length == 0) throw new Exception("A fingerprint ledger needs a fingerprint");
}

version (unittest)
{
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import vibe.data.json : Json;

    /// The two stores the ledger works with, over one document store.
    private struct Stores
    {
        ExecutionStore executions;
        LedgerStore ledgers;
    }

    private Stores storesOver(DocumentStore documents)
    {
        auto executions = new ExecutionStore(documents);
        return Stores(executions, new LedgerStore(documents, executions));
    }

    /// What a claim of task "compile" carries.
    private ActiveExecution proposal(string definitionId = "def1", string createdAt = "2026-10-18T10:00:00Z")
    {
        ActiveExecution proposed;
        proposed.projectId = "game";
        proposed.taskId = "compile";
        proposed.definitionId = definitionId;
        proposed.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
        proposed.repositoryAddresses = ["src": "https://example.test/game.git"];
        proposed.createdAt = createdAt;
        return proposed;
    }

    /// Claims `fingerprint` (which must win) as a dispatch does. Returns the claimed id.
    private string dispatch(Stores stores, string fingerprint, ulong seen, string createdAt = "2026-10-18T10:00:00Z")
    {
        auto claimed = stores.ledgers.claim(fingerprint, seen, proposal("def1", createdAt));
        assert(claimed.outcome == ClaimOutcome.won, "The dispatch's claim must win");
        return claimed.executionId;
    }

    /// Writes the record of the active execution at `fingerprint` ended as `status`, without the fold.
    private TaskExecution finish(Stores stores, string fingerprint, ExecutionStatus status)
    {
        auto ledger = stores.ledgers.get(fingerprint).get;
        auto ended = endedExecution(fingerprint, ledger.active.get, status, "2026-10-18T10:05:00Z");
        return stores.executions.create(ended).value;
    }

    /// A finished record under an arbitrary id, which no ledger claimed.
    private TaskExecution strangerAt(Stores stores, string id, string fingerprint)
    {
        ActiveExecution active = proposal();
        active.id = id;
        return stores.executions.create(endedExecution(fingerprint, active, ExecutionStatus.succeeded, "2026-10-18T10:05:00Z")).value;
    }

    private Versioned!FingerprintLedger ledgerOf(Stores stores, string fingerprint)
    {
        return stores.ledgers.get(fingerprint).get;
    }

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    /// Counts the writes through `store` into `writes`, from now on.
    private void countWrites(InterleavingDocumentStore store, ref size_t writes)
    {
        size_t* counter = &writes;
        void arm()
        {
            store.beforeNextWrite = () { *counter += 1; arm(); };
        }
        arm();
    }
}

unittest
{
    // Execution ids are deterministic and stable: a hash of the fingerprint and the claim's
    // sequence number, the same in every process and release
    assert(executionIdFor("fp1", 1) == "279a77664abf4b2ab751fca323dd8ef48d9761cf82e36f2f1412f40dd2cbf985");
    assert(executionIdFor("fp1", 1) == executionIdFor("fp1", 1));
    assert(executionIdFor("fp1", 2) != executionIdFor("fp1", 1));
    assert(executionIdFor("fp2", 1) != executionIdFor("fp1", 1));
    assert(throwsA!Exception({ executionIdFor("", 1); }));
    assert(throwsA!Exception({ executionIdFor("fp1", 0); }));
    {
        auto documents = new InMemoryDocumentStore();
        assert(throwsA!Exception({ new LedgerStore(documents, new ExecutionStore(documents), 0); }));
    }

    // Claims name them: the nth claim at a fingerprint names its nth id, on any store
    auto stores = storesOver(new InMemoryDocumentStore());
    assert(stores.ledgers.claim("fp1", 0, proposal()).executionId == executionIdFor("fp1", 1));
    assert(storesOver(new InMemoryDocumentStore()).ledgers.claim("fp1", 0, proposal()).executionId == executionIdFor("fp1", 1));
}

unittest
{
    // A claim creates the ledger with the active execution, queued and complete, in one write; a
    // second claimer sees it. A claim decided on an older ledger is superseded; a claim never
    // looks at the last success
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = storesOver(interleaving);
    assert(stores.ledgers.get("fp1").isNull);

    size_t writes;
    countWrites(interleaving, writes);
    auto won = stores.ledgers.claim("fp1", 0, proposal());
    assert(writes == 1, "A claim is one compare-and-set");
    assert(won.outcome == ClaimOutcome.won && won.executionId == executionIdFor("fp1", 1));
    assert(won.ledger.version_ == 1 && won.ledger.executionSeq == 1 && won.ledger.fingerprint == "fp1");
    auto active = won.ledger.active.get;
    assert(active.id == won.executionId && active.status == ExecutionStatus.queued && active.attempt == 0);
    assert(active.projectId == "game" && active.taskId == "compile" && active.definitionId == "def1");
    assert(active.inputs == proposal().inputs && active.repositoryAddresses == proposal().repositoryAddresses);
    assert(active.createdAt == "2026-10-18T10:00:00Z" && active.worker.length == 0 && active.leaseExpiresAt.length == 0);

    foreach (seen; [0UL, 1UL])
    {
        auto lost = stores.ledgers.claim("fp1", seen, proposal());
        assert(lost.outcome == ClaimOutcome.active && lost.executionId == won.executionId);
    }
    assert(ledgerOf(stores, "fp1").version_ == 1 && writes == 1, "A losing claim writes nothing");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp1", 5, proposal()); }), "A claim cannot have seen the future");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp9", 1, proposal()); }));
    assert(throwsA!Exception({ stores.ledgers.claim("", 0, proposal()); }));
    auto incomplete = proposal();
    incomplete.definitionId = null;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp8", 0, incomplete); }), "An incomplete claim is refused");
    assert(stores.ledgers.get("fp8").isNull);

    finish(stores, "fp1", ExecutionStatus.succeeded);
    stores.ledgers.fold(stores.executions.get(won.executionId).get.value);

    auto stale = stores.ledgers.claim("fp1", 0, proposal());
    assert(stale.outcome == ClaimOutcome.superseded && stale.executionId.length == 0);
    assert(stale.ledger.lastSuccessExecutionId == won.executionId);

    // The caller decided the success is unusable (say its artifacts expired) and claims again
    auto again = stores.ledgers.claim("fp1", 1, proposal());
    assert(again.outcome == ClaimOutcome.won && again.executionId == executionIdFor("fp1", 2));
    assert(again.ledger.lastSuccessExecutionId == won.executionId && again.ledger.executionSeq == 2);

    // Ledgers persist across a restart
    auto restarted = storesOver(documents.restart());
    assert(ledgerOf(restarted, "fp1").value == again.ledger.value);
}

unittest
{
    // Two claimers racing to create the ledger: exactly one execution becomes active, and the
    // loser, whose create loses, re-reads and sees the winner's execution
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    LedgerClaim first;
    interleaving.beforeNextWrite = () { first = direct.ledgers.claim("fp1", 0, proposal()); };
    auto second = racing.ledgers.claim("fp1", 0, proposal());
    assert(first.outcome == ClaimOutcome.won);
    assert(second.outcome == ClaimOutcome.active && second.executionId == first.executionId,
        "The loser sees the winner's execution");
    auto ledger = ledgerOf(direct, "fp1");
    assert(ledger.version_ == 1 && ledger.executionSeq == 1 && ledger.active.get.id == first.executionId);

    // And racing to claim an existing, idle ledger: the loser's compare-and-set loses
    finish(direct, "fp1", ExecutionStatus.failed);
    direct.ledgers.settle("fp1");
    interleaving.beforeNextWrite = () { first = direct.ledgers.claim("fp1", 1, proposal()); };
    second = racing.ledgers.claim("fp1", 1, proposal());
    assert(first.outcome == ClaimOutcome.won && first.executionId == executionIdFor("fp1", 2));
    assert(second.outcome == ClaimOutcome.active && second.executionId == first.executionId);
    assert(ledgerOf(direct, "fp1").executionSeq == 2);
}

unittest
{
    // A claim that finds an active execution which ended without being folded (its ender
    // crashed after writing the record) completes the fold and decides again, instead of
    // reporting an execution that will never end as active
    auto documents = new InMemoryDocumentStore();
    auto before = storesOver(documents);
    const id = dispatch(before, "fp1", 0);
    finish(before, "fp1", ExecutionStatus.failed); // ... and the process dies

    auto after = storesOver(documents.restart());
    auto retry = after.ledgers.claim("fp1", 1, proposal());
    assert(retry.outcome == ClaimOutcome.won && retry.executionId == executionIdFor("fp1", 2));
    assert(retry.ledger.lastStoppedExecutionId == id && retry.ledger.stopSeq == 1);

    // A claimer that decided before that execution existed is superseded, not active
    auto other = storesOver(new InMemoryDocumentStore());
    const ended = dispatch(other, "fp1", 0);
    finish(other, "fp1", ExecutionStatus.succeeded);
    auto stale = other.ledgers.claim("fp1", 0, proposal());
    assert(stale.outcome == ClaimOutcome.superseded && stale.ledger.lastSuccessExecutionId == ended);
}

unittest
{
    // A claimer whose compare-and-set loses re-reads and finds the winner's execution already
    // ended and folded: its decision is stale, so it is superseded
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    string winner;
    interleaving.beforeNextWrite = () {
        winner = dispatch(direct, "fp1", 0);
        direct.ledgers.fold(finish(direct, "fp1", ExecutionStatus.succeeded));
    };
    auto lost = racing.ledgers.claim("fp1", 0, proposal());
    assert(lost.outcome == ClaimOutcome.superseded && lost.executionId.length == 0);
    assert(lost.ledger.lastSuccessExecutionId == winner && lost.ledger.executionSeq == 1);
}

unittest
{
    import core.thread : Thread;

    // Many claimers on many threads at once: exactly one wins, every other sees its execution
    auto documents = new InMemoryDocumentStore();
    enum threadCount = 8;
    LedgerClaim[threadCount] claims;
    Thread[] threads;
    foreach (t; 0 .. threadCount)
    {
        auto stores = storesOver(documents);
        threads ~= new Thread(((size_t index, Stores s) => () { claims[index] = s.ledgers.claim("shared", 0, proposal()); })(t, stores));
    }
    foreach (thread; threads) thread.start();
    foreach (thread; threads) thread.join();

    size_t winners = 0;
    foreach (claim; claims)
    {
        if (claim.outcome == ClaimOutcome.won) ++winners;
        else assert(claim.outcome == ClaimOutcome.active);
        assert(claim.executionId == executionIdFor("shared", 1));
    }
    assert(winners == 1);
    assert(ledgerOf(storesOver(documents), "shared").executionSeq == 1);
}

unittest
{
    // The transitions of the active execution, each one compare-and-set on the ledger: start,
    // heartbeat, release, a lost lease with a requeue or counted alone; the claim's own fields
    // never change, and what a transition cannot do is refused
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = storesOver(interleaving);
    const id = dispatch(stores, "fp1", 0);

    size_t writes;
    countWrites(interleaving, writes);
    auto queued = ledgerOf(stores, "fp1");
    auto started = stores.ledgers.update(queued, withStart(queued.value, "w1", "2026-10-18T10:01:00Z", "2026-10-18T10:00:00Z"));
    assert(writes == 1 && started.version_ == 2, "A start is one compare-and-set");
    auto running = started.active.get;
    assert(running.status == ExecutionStatus.running && running.attempt == 1 && running.worker == "w1");
    assert(running.leaseExpiresAt == "2026-10-18T10:01:00Z" && running.startedAt == "2026-10-18T10:00:00Z");
    assert(running.id == id && running.inputs == proposal().inputs);

    auto extended = stores.ledgers.update(started, withLease(started.value, "2026-10-18T10:05:00Z"));
    assert(writes == 2 && extended.active.get.leaseExpiresAt == "2026-10-18T10:05:00Z" && extended.active.get.attempt == 1);

    auto released = stores.ledgers.update(extended, withRequeue(extended.value));
    const back = released.active.get;
    assert(back.status == ExecutionStatus.queued && back.attempt == 1 && back.expiredLeases == 0, "A release keeps the attempt and counts nothing");
    assert(back.worker.length == 0 && back.leaseExpiresAt.length == 0 && back.startedAt.length == 0);

    auto second = stores.ledgers.update(released, withStart(released.value, "w2", "2026-10-18T10:06:00Z", "2026-10-18T10:05:00Z"));
    assert(second.active.get.attempt == 2);
    auto lostAndQueued = stores.ledgers.update(second, withLostLease(second.value, true));
    assert(lostAndQueued.active.get.status == ExecutionStatus.queued && lostAndQueued.active.get.expiredLeases == 1);
    auto third = stores.ledgers.update(lostAndQueued, withStart(lostAndQueued.value, "w3", "2026-10-18T10:08:00Z", "2026-10-18T10:07:00Z"));
    assert(third.active.get.attempt == 3 && third.active.get.expiredLeases == 1);
    auto counted = stores.ledgers.update(third, withLostLease(third.value, false));
    assert(counted.active.get.status == ExecutionStatus.running && counted.active.get.expiredLeases == 2 && counted.active.get.attempt == 3);

    // Transitions that cannot apply
    assert(throwsA!InvalidStateTransitionException({ withStart(counted.value, "w4", "2026-10-18T10:08:00Z", "2026-10-18T10:07:00Z"); }));
    assert(throwsA!InvalidStateTransitionException({ withLease(lostAndQueued.value, "2026-10-18T10:09:00Z"); }));
    assert(throwsA!InvalidStateTransitionException({ withRequeue(released.value); }));
    assert(throwsA!InvalidStateTransitionException({ withLostLease(released.value, true); }));
    assert(throwsA!InvalidStateTransitionException({ withClaim(counted.value, proposal()); }), "An active execution cannot be claimed over");

    // update refuses what is not a transition of the active execution
    FingerprintLedger edited = counted.value;
    auto changed = edited.active.get;
    changed.definitionId = "def2";
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "The claim's definition is fixed");
    edited = counted.value;
    changed = edited.active.get;
    changed.inputs = [ResolvedInput("src", InputKind.repository, Json("bbb222"))];
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "The claim's inputs are fixed");
    edited = counted.value;
    changed = edited.active.get;
    changed.repositoryAddresses = ["src": "https://example.test/other.git"];
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "The claim's addresses are fixed");
    edited = counted.value;
    changed = edited.active.get;
    changed.attempt = 1;
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "The attempt never goes down");
    edited = counted.value;
    edited.stopSeq = 5;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "Counts change only by claim and fold");
    edited = counted.value;
    edited.active.nullify();
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "Only the fold clears the execution");
    edited = counted.value;
    changed = edited.active.get;
    changed.leaseExpiresAt = null;
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "A running execution needs a lease");
    edited = counted.value;
    changed = edited.active.get;
    changed.status = ExecutionStatus.queued;
    edited.active = changed;
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.update(counted, edited); }), "A queued execution has no worker");
    assert(ledgerOf(stores, "fp1").version_ == counted.version_, "Nothing refused was written");

    // A stale writer loses the compare-and-set
    assert(throwsA!DocumentConflictException({ stores.ledgers.update(started, withLease(started.value, "2026-10-18T10:30:00Z")); }));
}

unittest
{
    // The active index lists queued executions oldest claim first and running ones by lease
    // expiry; a ledger with nothing active, or whose execution moved between states, is in the
    // partition of its current status only
    auto stores = storesOver(new InMemoryDocumentStore());
    dispatch(stores, "fp_b", 0, "2026-10-18T10:00:00.5Z");
    dispatch(stores, "fp_a", 0, "2026-10-18T10:00:01Z");
    dispatch(stores, "fp_c", 0, "2026-10-18T10:00:00Z");
    dispatch(stores, "fp_d", 0, "2026-10-18T09:00:00Z");

    string[] fingerprintsOf(Page!FingerprintLedger page)
    {
        string[] result;
        foreach (item; page.items) result ~= item.fingerprint;
        return result;
    }

    assert(fingerprintsOf(stores.ledgers.queuedPage(null)) == ["fp_d", "fp_c", "fp_b", "fp_a"], "Oldest claim first, by time not by text");
    assert(stores.ledgers.queuedPage(null).nextCursor.length == 0);

    void start(string fingerprint, string leaseExpiresAt)
    {
        auto current = ledgerOf(stores, fingerprint);
        stores.ledgers.update(current, withStart(current.value, "w", leaseExpiresAt, "2026-10-18T10:00:00Z"));
    }
    start("fp_a", "2026-10-18T10:10:00Z");
    start("fp_b", "2026-10-18T10:02:00.5Z");
    start("fp_c", "2026-10-18T10:02:00Z");
    assert(fingerprintsOf(stores.ledgers.queuedPage(null)) == ["fp_d"]);
    assert(fingerprintsOf(stores.ledgers.leaseDuePage("2026-10-18T11:00:00Z", null)) == ["fp_c", "fp_b", "fp_a"]);
    assert(fingerprintsOf(stores.ledgers.leaseDuePage("2026-10-18T10:02:00.25Z", null)) == ["fp_c"], "Only the leases that ran out");
    assert(fingerprintsOf(stores.ledgers.leaseDuePage("2026-10-18T10:02:00Z", null)) == ["fp_c"], "A lease expiring now has run out");
    assert(stores.ledgers.leaseDuePage("2026-10-18T10:01:59Z", null).items.length == 0);

    // An ended execution leaves the index
    finish(stores, "fp_c", ExecutionStatus.succeeded);
    stores.ledgers.settle("fp_c");
    assert(fingerprintsOf(stores.ledgers.leaseDuePage("2026-10-18T11:00:00Z", null)) == ["fp_b", "fp_a"]);

    // Paging follows the cursor
    foreach (i; 0 .. defaultPageSize + 3) dispatch(stores, format("fp_q%04d", i), 0);
    auto page = stores.ledgers.queuedPage(null);
    assert(page.items.length == defaultPageSize && page.nextCursor.length > 0);
    assert(stores.ledgers.queuedPage(page.nextCursor).items.length == 4);
}

unittest
{
    // Folding: a success becomes the last success without counting as a stop; a failure (also
    // how a lost execution ends) or a cancellation becomes the last stop and increments stopSeq.
    // Earlier outcomes stay until replaced
    auto stores = storesOver(new InMemoryDocumentStore());
    ulong seen = 0;
    string run(ExecutionStatus status)
    {
        const id = dispatch(stores, "fp1", seen++);
        const result = stores.ledgers.fold(finish(stores, "fp1", status));
        assert(result.outcome == FoldOutcome.folded && result.ledger.active.isNull);
        return id;
    }

    const success1 = run(ExecutionStatus.succeeded);
    auto ledger = ledgerOf(stores, "fp1");
    assert(ledger.lastSuccessExecutionId == success1 && ledger.stopSeq == 0 && ledger.lastStoppedExecutionId.length == 0);

    const failed = run(ExecutionStatus.failed);
    ledger = ledgerOf(stores, "fp1");
    assert(ledger.lastStoppedExecutionId == failed && ledger.stopSeq == 1 && ledger.lastSuccessExecutionId == success1);

    const cancelled = run(ExecutionStatus.cancelled);
    ledger = ledgerOf(stores, "fp1");
    assert(ledger.lastStoppedExecutionId == cancelled && ledger.stopSeq == 2);

    const success2 = run(ExecutionStatus.succeeded);
    ledger = ledgerOf(stores, "fp1");
    assert(ledger.lastSuccessExecutionId == success2 && ledger.stopSeq == 2 && ledger.lastStoppedExecutionId == cancelled);
    assert(ledger.executionSeq == 4);

    // A repeated fold, or a late fold of an earlier execution, is a no-op
    foreach (id; [success2, failed, success1])
    {
        auto repeated = stores.ledgers.fold(stores.executions.get(id).get.value);
        assert(repeated.outcome == FoldOutcome.alreadyFolded && repeated.ledger.version_ == ledger.version_);
    }
    assert(ledgerOf(stores, "fp1").value == ledger.value);
}

unittest
{
    // A fold that cannot be right fails loudly and writes nothing: an execution still active (no
    // record yet), one the ledger never claimed, or one at a fingerprint with no ledger
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    const version_ = ledgerOf(stores, "fp1").version_;

    TaskExecution unrecorded = endedExecution("fp1", ledgerOf(stores, "fp1").active.get, ExecutionStatus.succeeded, "2026-10-18T10:05:00Z");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(unrecorded); }), "An execution with no record is not folded");

    auto stranger = strangerAt(stores, "exe_stranger", "fp1");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(stranger); }), "An execution never claimed is rejected");
    auto unclaimed = strangerAt(stores, "exe_unclaimed", "fp_none");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(unclaimed); }), "An execution with no ledger is rejected");

    auto moved = stranger;
    moved.fingerprint = "fp_none";
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(moved); }), "The fingerprint must match the record");
    assert(ledgerOf(stores, "fp1").version_ == version_ && stores.ledgers.get("fp_none").isNull);
    assert(ledgerOf(stores, "fp1").active.get.id == id);
}

unittest
{
    // A fold folds the stored record, not the value it is given: a caller that lost the race to
    // write the record (it meant to record a success, a cancel won) cannot fold its intended outcome
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    auto cancelled = finish(stores, "fp1", ExecutionStatus.cancelled);
    TaskExecution intended = cancelled;
    intended.status = ExecutionStatus.succeeded;

    auto folded = stores.ledgers.fold(intended).ledger;
    assert(folded.lastStoppedExecutionId == id && folded.stopSeq == 1 && folded.lastSuccessExecutionId.length == 0);

    // And a value claiming the execution is still running does not stop the stored outcome
    TaskExecution running = cancelled;
    running.status = ExecutionStatus.running;
    assert(stores.ledgers.fold(running).outcome == FoldOutcome.alreadyFolded);
}

unittest
{
    // Crash after an execution's record is written, before its fold: the next reader, after a
    // restart, completes the fold. Settling again writes nothing
    auto documents = new InMemoryDocumentStore();
    auto before = storesOver(documents);
    const id = dispatch(before, "fp1", 0);
    finish(before, "fp1", ExecutionStatus.succeeded); // ... and the process dies

    auto after = storesOver(documents.restart());
    auto settled = after.ledgers.settle("fp1");
    auto ledger = settled.get;
    assert(ledger.active.isNull && ledger.lastSuccessExecutionId == id);

    auto again = after.ledgers.settle("fp1");
    assert(again.get.version_ == ledger.version_);

    // The ender, resuming, folds again: a no-op
    assert(before.ledgers.fold(before.executions.get(id).get.value).outcome == FoldOutcome.alreadyFolded);
    assert(ledgerOf(after, "fp1").version_ == ledger.version_);
}

unittest
{
    // A reader settling races the ender's own fold: whichever lands second finds it folded, and
    // the outcome is folded once
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    const id = dispatch(direct, "fp1", 0);
    const done = finish(direct, "fp1", ExecutionStatus.cancelled);

    interleaving.beforeNextWrite = () { assert(direct.ledgers.fold(done).outcome == FoldOutcome.folded); };
    auto settled = racing.ledgers.settle("fp1");
    assert(settled.get.active.isNull);
    assert(settled.get.stopSeq == 1 && settled.get.lastStoppedExecutionId == id);
}

unittest
{
    // settle reports what it finds: no ledger, or an active execution with no record yet, which
    // stays active. A record of the active execution at another fingerprint means a corrupt
    // store and fails loudly
    auto stores = storesOver(new InMemoryDocumentStore());
    assert(stores.ledgers.settle("fp1").isNull);

    const id = dispatch(stores, "fp1", 0);
    auto settled = stores.ledgers.settle("fp1").get;
    assert(settled.active.get.id == id && settled.active.get.status == ExecutionStatus.queued);
    assert(settled.version_ == 1, "Settling an execution that has not ended writes nothing");

    const misplaced = stores.ledgers.claim("fp2", 0, proposal()).executionId;
    strangerAt(stores, misplaced, "fp_other");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.settle("fp2"); }));
}

unittest
{
    // A claim that finds a record for the active execution at another fingerprint fails loudly
    // instead of folding it
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    strangerAt(stores, id, "fp_other");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp1", 1, proposal()); }));
    assert(!ledgerOf(stores, "fp1").active.isNull, "Nothing was folded");
}
