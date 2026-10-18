module confector.core.fingerprint_ledger;

/**
 * The fingerprint ledger (design record: bead confector-z7z.48; AGENTS.md, "Coordinating
 * builds"): one FingerprintLedger document per fingerprint, read by id and changed only by
 * compare-and-set, so it works on every DocumentStore backend and in stateless invocations. The
 * collection declares no index: nothing here depends on a query.
 *
 * Every operation reads only by id (the ledger and, for `fold`, `settle` and a losing `claim`,
 * the execution it names) and writes only by single-document compare-and-set, retried on a lost
 * compare-and-set where the decision does not depend on what changed. `settle` and a losing
 * `claim` may also complete a fold, a second compare-and-set. Every operation is idempotent, so
 * a crash between any two steps is repaired by repeating them.
 *
 * Dispatching an execution at fingerprint F (the execution dispatcher, bead confector-z7z.49.3):
 *
 * 1. `claim(F, seen)`, where `seen` is the ledger's `executionSeq` as the caller read it when it
 *    decided F needs an execution (0 if it found no ledger). The claim moves the ledger from "no
 *    active execution" to active = `executionIdFor(F, seen + 1)`. A loser learns the active
 *    execution (and subscribes to it, below) or that an execution was created and finished since
 *    it read (and re-evaluates).
 * 2. `ExecutionStore.createIfAbsent` the queued TaskExecution with that id, carrying the
 *    definition, inputs and repository addresses of the request it is dispatched for.
 * 3. Send its DispatchMessage to the pool's dispatch queue.
 * 4. Stamp `sentAt` on the execution by compare-and-set (receiving it stamps it too).
 *
 * Crash repair, by whoever next reads the ledger (`settle`):
 * - After 1, before 2: the ledger's active execution has no record; `settle` reports it
 *   `unrecorded` with its id. The ledger cannot move on (only a fold of a terminal record
 *   clears the active execution), so every later reader that needs F sees the same id. The
 *   ledger cannot invent the execution: its definition, inputs and repository addresses come
 *   from a request. So whoever needs F (a reconcile of a chain that wants it, bead
 *   confector-z7z.49.3) repeats steps 2 to 4 with that id, from its own request; concurrent
 *   repairers and the original dispatcher converge on whichever record is written first.
 * - After 2, before 4: the execution is queued with an empty `sentAt`; `settle` reports it
 *   `recorded`, and the dispatcher or the sweep sends it again (beads confector-z7z.49.3 and
 *   confector-z7z.49.5). A duplicate message is harmless: receiving starts an execution by
 *   compare-and-set.
 *
 * Ending an execution (bead confector-z7z.49.4): the terminal compare-and-set on the
 * TaskExecution stays the fence against duplicate or racing completions; only its winner goes
 * on. Then `fold` moves the ledger, in one compare-and-set, from active to idle: the outcome
 * becomes `lastSuccessExecutionId` or `lastStoppedExecutionId` (with `stopSeq` incremented),
 * and every subscriber becomes a LedgerNotice in `pendingNotify`. Then each noticed chain is
 * marked dirty, and `clearNotified` removes exactly the notices handled. A crash after the
 * terminal compare-and-set and before the fold leaves a ledger whose active execution is
 * terminal: `settle` completes the fold. A crash before the notices are cleared leaves them in
 * `pendingNotify` for the next drain (marking a chain dirty twice is harmless).
 *
 * Waiting: a chain that finds F active subscribes with `subscribe`, a compare-and-set at the
 * version it read, written even when the chain is already a subscriber. Subscribe and fold are
 * compare-and-sets on the same document, so either the fold takes the subscriber into
 * `pendingNotify` or the subscribe loses and the chain re-reads the ended execution: no wakeup
 * can be lost and no index is involved. A reconcile reads its ChainState first and the ledgers
 * after it, so a fold whose notice marks the chain dirty after the ChainState read makes the
 * reconcile's ChainState compare-and-set fail, and a fold before it is seen in the ledger read
 * or makes the subscribe's compare-and-set fail.
 *
 * The waiter limit (maxLedgerWaiters, counting `subscribers` and undrained `pendingNotify`
 * together): a chain whose subscribe throws LedgerWaiterLimitException must not commit its
 * reconcile; it leaves its ChainState dirty, so the sweep retries it and the error stays
 * visible until the waiters drain.
 *
 * Reuse: `lastSuccessExecutionId` only names the latest success. Whether it is usable (its
 * artifacts may have expired) is on the execution record and decided by the caller, which
 * claims again if it is not. A claim never looks at the last success; there is no special case
 * for claiming over one.
 */

import confector.core.build_stores : ExecutionStore, InvalidStateTransitionException;
import confector.core.document_collection;
import confector.api.document_store;
import confector.api.model;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.format : format;
import std.typecons : Nullable, nullable;

/// The state store collection holding fingerprint ledgers, keyed by fingerprint.
enum CollectionSpec fingerprintLedgersCollection = CollectionSpec("fingerprint_ledgers", null);

/**
 * The most chains one ledger holds in `subscribers` and `pendingNotify` together. Subscribing
 * beyond it throws LedgerWaiterLimitException; a fold never fails on it, because it only moves
 * entries from one list to the other.
 *
 * Chosen so that a ledger stays under maxDocumentBytes in the worst case, every chain id
 * maxKeyBytes long (checked below; chain ids are printable ASCII without quotes or backslashes,
 * see requireChainId, so each byte serializes as one byte), while being far above the number of chains a small team's
 * branches keep waiting on one execution at once. Reaching it means either that many chains
 * really wait on one fingerprint, or that notices are not being drained; both need looking at,
 * so it fails loudly rather than degrading.
 */
enum size_t maxLedgerWaiters = 200;

// Worst case: every entry a notice (the larger kind) with a chain id of maxKeyBytes and a
// 64-character execution id, plus the fingerprint (at most maxKeyBytes) and the fixed fields.
private enum size_t worstNoticeBytes = `{"chain_id":"","execution_id":""},`.length + maxKeyBytes + 64;
static assert(maxLedgerWaiters * worstNoticeBytes + maxKeyBytes + 1024 <= maxDocumentBytes,
    "maxLedgerWaiters must keep a full ledger within maxDocumentBytes");

/// Subscribing would take a ledger past maxLedgerWaiters. Nothing was written.
class LedgerWaiterLimitException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

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
 * `ledger` with its next execution claimed: active, and counted in `executionSeq`.
 *
 * Throws: InvalidStateTransitionException if an execution is active.
 */
FingerprintLedger withClaim(in FingerprintLedger ledger) @safe
{
    requireValid(ledger.activeExecutionId.length == 0, format("Fingerprint %s already has active execution '%s'",
        ledger.fingerprint, ledger.activeExecutionId));
    auto next = copyOf(ledger);
    next.executionSeq += 1;
    next.activeExecutionId = executionIdFor(ledger.fingerprint, next.executionSeq);
    return next;
}

/**
 * `ledger` with `chainId` waiting on its active execution.
 *
 * Throws: InvalidStateTransitionException if no execution is active or `chainId` is not a valid
 * chain id (see requireChainId); LedgerWaiterLimitException if it would take the ledger past
 * maxLedgerWaiters.
 */
FingerprintLedger withSubscriber(in FingerprintLedger ledger, string chainId) @safe
{
    requireChainId(chainId);
    requireValid(ledger.activeExecutionId.length > 0,
        format("Chain '%s' cannot wait on fingerprint %s: no execution is active", chainId, ledger.fingerprint));
    auto next = copyOf(ledger);
    if (next.subscribers.canFind(chainId)) return next;
    if (next.subscribers.length + next.pendingNotify.length >= maxLedgerWaiters)
    {
        throw new LedgerWaiterLimitException(format(
            "Chain '%s' cannot wait on execution '%s' at fingerprint %s: %s chains wait on it and %s notices are undrained, and the limit is %s",
            chainId, ledger.activeExecutionId, ledger.fingerprint, next.subscribers.length, next.pendingNotify.length,
            maxLedgerWaiters));
    }
    next.subscribers ~= chainId;
    return next;
}

/**
 * Checks that `chainId` can be held in a ledger: 1 to maxKeyBytes bytes of printable ASCII
 * (0x20 to 0x7E) other than `"` and backslash, so it serializes as itself and the ledger's
 * worst-case size (see maxLedgerWaiters) holds.
 *
 * Throws: InvalidStateTransitionException otherwise.
 */
void requireChainId(string chainId) @safe
{
    requireValid(chainId.length > 0 && chainId.length <= maxKeyBytes,
        format("A chain id of %s bytes cannot wait on a fingerprint; it must be 1 to %s", chainId.length, maxKeyBytes));
    foreach (c; chainId)
    {
        requireValid(c >= 0x20 && c <= 0x7E && c != '"' && c != '\\',
            format("Chain id '%s' cannot wait on a fingerprint: it must be printable ASCII without quotes or backslashes", chainId));
    }
}

/**
 * `ledger` with the terminal outcome of its active execution `execution` folded in: no active
 * execution; the outcome recorded as the last success or, with `stopSeq` incremented, the last
 * stop; and every subscriber moved to `pendingNotify` as a notice of this execution.
 *
 * Throws: InvalidStateTransitionException if `execution` is not terminal or not the ledger's
 * active execution.
 */
FingerprintLedger withFold(in FingerprintLedger ledger, in TaskExecution execution) @safe
{
    requireValid(!ExecutionStore.isActive(execution.status),
        format("Execution '%s' is %s; only a finished execution is folded into its ledger", execution.id, execution.status));
    requireValid(ledger.activeExecutionId.length > 0 && ledger.activeExecutionId == execution.id,
        format("Execution '%s' is not the active execution ('%s') of fingerprint %s", execution.id,
            ledger.activeExecutionId, ledger.fingerprint));
    auto next = copyOf(ledger);
    next.activeExecutionId = null;
    if (execution.status == ExecutionStatus.succeeded)
    {
        next.lastSuccessExecutionId = execution.id;
    }
    else
    {
        next.lastStoppedExecutionId = execution.id;
        next.stopSeq += 1;
    }
    foreach (chainId; next.subscribers) next.pendingNotify ~= LedgerNotice(chainId, execution.id);
    next.subscribers = null;
    return next;
}

/// `ledger` without the notices in `handled`. Notices not in `handled` (written by a later
/// fold) stay.
FingerprintLedger withoutNotices(in FingerprintLedger ledger, in LedgerNotice[] handled) @safe
{
    auto next = copyOf(ledger);
    next.pendingNotify = null;
    foreach (notice; ledger.pendingNotify)
    {
        if (!handled.canFind(notice)) next.pendingNotify ~= notice;
    }
    return next;
}

/// What a claim found.
enum ClaimOutcome
{
    /// The claim won: `executionId` is the new active execution, which the claimer records and
    /// sends.
    won,
    /// Another execution is active: `executionId`. Wait on it (`subscribe`).
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

/// What a subscribe did.
enum SubscribeOutcome
{
    /// The chain was added to the subscribers.
    subscribed,
    /// The chain was already a subscriber. The ledger was still written at the version read (with
    /// unchanged content), so a stale read is detected as for `subscribed`.
    alreadySubscribed,
    /// The ledger read has no active execution: nothing to wait on. Re-evaluate with it.
    notActive
}

/// The result of `LedgerStore.subscribe`.
struct LedgerSubscription
{
    SubscribeOutcome outcome;
    /// The ledger after the subscribe (subscribed, alreadySubscribed) or as read (notActive).
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

/// The state of a fingerprint's active execution, after `settle` completed any unfinished fold.
enum LedgerActivity
{
    /// No execution is active (or none was ever claimed).
    idle,
    /// The active execution is recorded, queued or running. If it is queued with an empty
    /// `sentAt`, its message may never have been sent.
    recorded,
    /// The active execution was claimed but never recorded (its dispatcher crashed): record it
    /// with `ExecutionStore.createIfAbsent` under `executionId`, from the request that needs it,
    /// and send it.
    unrecorded
}

/// The result of `LedgerStore.settle`.
struct LedgerSettlement
{
    LedgerActivity activity;
    /// The ledger, settled; null if no execution was ever claimed at the fingerprint.
    Nullable!(Versioned!FingerprintLedger) ledger;
    /// recorded and unrecorded: the active execution's id.
    string executionId;
    /// recorded: the active execution.
    Nullable!(Versioned!TaskExecution) execution;
}

/**
 * Fingerprint ledgers in a DocumentStore, with the executions they name. See the module
 * documentation for the protocols. Ledgers are never removed.
 */
final class LedgerStore
{
    /// How many times an operation re-reads and retries after losing a compare-and-set to a
    /// concurrent write of the same ledger before failing. Every lost attempt means another write
    /// succeeded, so this is reached only under sustained contention on one fingerprint. Higher
    /// than work_orders.maxWriteAttempts (10, for one execution, written by its worker and the
    /// control plane): like a counter or a rerun generation record (100), a ledger is shared by
    /// every chain that needs the fingerprint, so many subscribers can contend on it at once.
    enum maxWriteAttempts = 100;

    private DocumentCollection!FingerprintLedger m_ledgers;
    private ExecutionStore m_executions;

    /// Declares `fingerprintLedgersCollection` on `store`; `executions` is where the ledgers'
    /// executions are recorded.
    this(DocumentStore store, ExecutionStore executions)
    {
        if (executions is null) throw new Exception("LedgerStore requires the execution store");
        m_ledgers = new DocumentCollection!FingerprintLedger(store, fingerprintLedgersCollection);
        m_executions = executions;
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
     * Claims the next execution at `fingerprint`, creating its ledger on the first claim. Wins
     * only if no execution is active and the ledger's `executionSeq` is still `seenExecutionSeq`,
     * the value the caller read when it decided an execution is needed (0 when it found no
     * ledger), so a decision made before another execution started and finished never builds the
     * fingerprint twice. Of concurrent claimers exactly one wins; the others see its execution.
     * A claim that finds an active execution which already ended (its fold never happened)
     * completes the fold and decides again. See ClaimOutcome.
     *
     * Throws: Exception if `fingerprint` is empty or every one of maxWriteAttempts attempts lost
     * a compare-and-set; InvalidStateTransitionException if `seenExecutionSeq` is ahead of the
     * ledger (the caller did not read it from this ledger).
     */
    LedgerClaim claim(string fingerprint, ulong seenExecutionSeq)
    {
        requireFingerprint(fingerprint);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = get(fingerprint);
            const ulong executionSeq = current.isNull ? 0 : current.get.executionSeq;
            requireValid(seenExecutionSeq <= executionSeq, format(
                "A claim at fingerprint %s saw execution %s, but the ledger has only claimed %s", fingerprint,
                seenExecutionSeq, executionSeq));
            if (!current.isNull && current.get.activeExecutionId.length > 0)
            {
                // Only on this losing path: if the active execution ended but was never folded
                // (its ender crashed), complete the fold and decide again.
                auto active = m_executions.get(current.get.activeExecutionId);
                if (!active.isNull && !ExecutionStore.isActive(active.get.status))
                {
                    foldRecord(active.get.value);
                    continue;
                }
                return LedgerClaim(ClaimOutcome.active, current.get.activeExecutionId, current.get);
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
                    auto created = m_ledgers.create(fingerprint, withClaim(fresh));
                    return LedgerClaim(ClaimOutcome.won, created.activeExecutionId, created);
                }
                auto replaced = m_ledgers.replace(fingerprint, withClaim(current.get.value), current.get.version_);
                return LedgerClaim(ClaimOutcome.won, replaced.activeExecutionId, replaced);
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
     * Adds chain `chainId` to the subscribers of the ledger `read`, by compare-and-set at the
     * version read, so it is woken when the active execution it saw ends. The compare-and-set is
     * made even when the chain is already a subscriber, so a stale read is always detected. See
     * SubscribeOutcome.
     *
     * Callers read the chain's ChainState first and the ledger after it (see the module
     * documentation). A chain whose subscribe throws LedgerWaiterLimitException must leave its
     * ChainState dirty (not commit its reconcile), so the sweep retries it and the error stays
     * visible; undrained notices count toward the limit.
     *
     * Throws: DocumentConflictException if the ledger changed since `read`: re-read it (the
     * execution may have ended) and decide again. LedgerWaiterLimitException at
     * maxLedgerWaiters; InvalidStateTransitionException if `chainId` is not a valid chain id
     * (checked first, whatever the ledger holds).
     */
    LedgerSubscription subscribe(in Versioned!FingerprintLedger read, string chainId)
    {
        requireFingerprint(read.fingerprint);
        requireChainId(chainId);
        if (read.activeExecutionId.length == 0) return LedgerSubscription(SubscribeOutcome.notActive, copyOf(read));
        const outcome = read.subscribers.canFind(chainId) ? SubscribeOutcome.alreadySubscribed : SubscribeOutcome.subscribed;
        return LedgerSubscription(outcome, m_ledgers.replace(read.fingerprint, withSubscriber(read.value, chainId), read.version_));
    }

    /**
     * Folds the outcome of `execution` into its fingerprint's ledger (see `withFold`). The
     * execution is identified by its id: its stored record is read by id and that record's
     * outcome is folded, never the status in `execution`, so a caller that lost the terminal
     * compare-and-set cannot fold the outcome it intended. Idempotent: folding an execution the
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
            if (ledger.activeExecutionId != execution.id)
            {
                requireValid(claimedOn(ledger, execution.id), format(
                    "Execution '%s' was never claimed at fingerprint %s (its ledger has claimed %s executions; active: '%s')",
                    execution.id, execution.fingerprint, ledger.executionSeq, ledger.activeExecutionId));
                return LedgerFold(FoldOutcome.alreadyFolded, current.get);
            }
            try
            {
                return LedgerFold(FoldOutcome.folded,
                    m_ledgers.replace(execution.fingerprint, withFold(ledger.value, execution), ledger.version_));
            }
            catch (DocumentConflictException)
            {
                // A subscriber or another fold landed: read it and fold again (or find it folded).
            }
        }
        throw new Exception(format("Could not fold execution '%s' into fingerprint %s: %s attempts in a row lost a compare-and-set",
            execution.id, execution.fingerprint, maxWriteAttempts));
    }

    /**
     * Removes the notices in `handled` from the `pendingNotify` of `fingerprint`'s ledger, once
     * the caller has marked their chains dirty, and returns the ledger. Idempotent; notices a
     * fold added meanwhile stay, even for the same chain, because they name another execution.
     *
     * Throws: InvalidStateTransitionException if the ledger does not exist; Exception if every
     * one of maxWriteAttempts attempts lost a compare-and-set.
     */
    Versioned!FingerprintLedger clearNotified(string fingerprint, in LedgerNotice[] handled)
    {
        requireFingerprint(fingerprint);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = get(fingerprint);
            requireValid(!current.isNull, format("Fingerprint %s has no ledger, so it has no notices to clear", fingerprint));
            auto next = withoutNotices(current.get.value, handled);
            if (next.pendingNotify.length == current.get.pendingNotify.length) return current.get;
            try
            {
                return m_ledgers.replace(fingerprint, next, current.get.version_);
            }
            catch (DocumentConflictException)
            {
                // A fold or another drain landed: read it and clear what is still there.
            }
        }
        throw new Exception(format("Could not clear the notices of fingerprint %s: %s attempts in a row lost a compare-and-set",
            fingerprint, maxWriteAttempts));
    }

    /**
     * Reads the ledger of `fingerprint` and its active execution by id, completing a
     * half-finished fold first: if the active execution is terminal (its ender crashed between
     * the terminal compare-and-set and the fold), folds it. Any reader may call it, any number of
     * times. See LedgerActivity for what the caller must do.
     *
     * Throws: Exception if `fingerprint` is empty or the ledger keeps changing for
     * maxWriteAttempts reads; InvalidStateTransitionException if the active execution's record
     * names another fingerprint.
     */
    LedgerSettlement settle(string fingerprint)
    {
        requireFingerprint(fingerprint);
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            LedgerSettlement result;
            result.ledger = get(fingerprint);
            if (result.ledger.isNull || result.ledger.get.activeExecutionId.length == 0) return result;
            result.executionId = result.ledger.get.activeExecutionId;
            auto execution = m_executions.get(result.executionId);
            if (execution.isNull)
            {
                result.activity = LedgerActivity.unrecorded;
                return result;
            }
            requireValid(execution.get.fingerprint == fingerprint, format(
                "The active execution '%s' of fingerprint %s is recorded at fingerprint %s", result.executionId,
                fingerprint, execution.get.fingerprint));
            if (ExecutionStore.isActive(execution.get.status))
            {
                result.activity = LedgerActivity.recorded;
                result.execution = execution;
                return result;
            }
            foldRecord(execution.get.value);
        }
        throw new Exception(format("Could not settle fingerprint %s: it changed on each of %s reads", fingerprint, maxWriteAttempts));
    }
}

private FingerprintLedger copyOf(in FingerprintLedger ledger) @safe
{
    FingerprintLedger copy;
    copy.fingerprint = ledger.fingerprint;
    copy.activeExecutionId = ledger.activeExecutionId;
    copy.lastSuccessExecutionId = ledger.lastSuccessExecutionId;
    copy.lastStoppedExecutionId = ledger.lastStoppedExecutionId;
    copy.stopSeq = ledger.stopSeq;
    copy.executionSeq = ledger.executionSeq;
    copy.subscribers = ledger.subscribers.dup;
    copy.pendingNotify = ledger.pendingNotify.dup;
    return copy;
}

private Versioned!FingerprintLedger copyOf(in Versioned!FingerprintLedger ledger) @safe
{
    return Versioned!FingerprintLedger(copyOf(ledger.value), ledger.version_);
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

    private TaskExecution queuedExecution(string id, string fingerprint, string definitionHash = "def1")
    {
        TaskExecution execution;
        execution.id = id;
        execution.projectId = "game";
        execution.taskId = "compile";
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.definition.id = "compile";
        execution.definitionHash = definitionHash;
        execution.createdAt = "2026-10-18T10:00:00Z";
        return execution;
    }

    /// Claims `fingerprint` (which must win) and records its execution, as the dispatcher does.
    private string dispatch(Stores stores, string fingerprint, ulong seen)
    {
        auto claimed = stores.ledgers.claim(fingerprint, seen);
        assert(claimed.outcome == ClaimOutcome.won, "The dispatch's claim must win");
        stores.executions.createIfAbsent(queuedExecution(claimed.executionId, fingerprint));
        return claimed.executionId;
    }

    /// The terminal compare-and-set on execution `id`, without the fold.
    private TaskExecution finish(Stores stores, string id, ExecutionStatus status)
    {
        auto current = stores.executions.get(id).get;
        TaskExecution next = current.value;
        next.status = status;
        next.finishedAt = "2026-10-18T10:05:00Z";
        return stores.executions.update(current, next).value;
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

    // Claims name them: the nth claim at a fingerprint names its nth id, on any store
    auto stores = storesOver(new InMemoryDocumentStore());
    assert(stores.ledgers.claim("fp1", 0).executionId == executionIdFor("fp1", 1));
    assert(storesOver(new InMemoryDocumentStore()).ledgers.claim("fp1", 0).executionId == executionIdFor("fp1", 1));
}

unittest
{
    // A claim creates the ledger, then holds the fingerprint until the execution is folded; a
    // second claimer sees the active execution. A claim decided on an older ledger is
    // superseded; a claim never looks at the last success
    auto documents = new InMemoryDocumentStore();
    auto stores = storesOver(documents);
    assert(stores.ledgers.get("fp1").isNull);

    auto won = stores.ledgers.claim("fp1", 0);
    assert(won.outcome == ClaimOutcome.won && won.executionId == executionIdFor("fp1", 1));
    assert(won.ledger.version_ == 1 && won.ledger.executionSeq == 1 && won.ledger.activeExecutionId == won.executionId);
    assert(won.ledger.fingerprint == "fp1");

    foreach (seen; [0UL, 1UL])
    {
        auto lost = stores.ledgers.claim("fp1", seen);
        assert(lost.outcome == ClaimOutcome.active && lost.executionId == won.executionId);
    }
    assert(ledgerOf(stores, "fp1").version_ == 1, "A losing claim writes nothing");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp1", 5); }), "A claim cannot have seen the future");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.claim("fp9", 1); }));
    assert(throwsA!Exception({ stores.ledgers.claim("", 0); }));

    stores.executions.createIfAbsent(queuedExecution(won.executionId, "fp1"));
    stores.ledgers.fold(finish(stores, won.executionId, ExecutionStatus.succeeded));

    auto stale = stores.ledgers.claim("fp1", 0);
    assert(stale.outcome == ClaimOutcome.superseded && stale.executionId.length == 0);
    assert(stale.ledger.lastSuccessExecutionId == won.executionId);

    // The caller decided the success is unusable (say its artifacts expired) and claims again
    auto again = stores.ledgers.claim("fp1", 1);
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
    interleaving.beforeNextWrite = () { first = direct.ledgers.claim("fp1", 0); };
    auto second = racing.ledgers.claim("fp1", 0);
    assert(first.outcome == ClaimOutcome.won);
    assert(second.outcome == ClaimOutcome.active && second.executionId == first.executionId,
        "The loser sees the winner's execution");
    auto ledger = ledgerOf(direct, "fp1");
    assert(ledger.version_ == 1 && ledger.executionSeq == 1 && ledger.activeExecutionId == first.executionId);

    // And racing to claim an existing, idle ledger: the loser's compare-and-set loses
    direct.executions.createIfAbsent(queuedExecution(first.executionId, "fp1"));
    direct.ledgers.fold(finish(direct, first.executionId, ExecutionStatus.failed));
    interleaving.beforeNextWrite = () { first = direct.ledgers.claim("fp1", 1); };
    second = racing.ledgers.claim("fp1", 1);
    assert(first.outcome == ClaimOutcome.won && first.executionId == executionIdFor("fp1", 2));
    assert(second.outcome == ClaimOutcome.active && second.executionId == first.executionId);
    assert(ledgerOf(direct, "fp1").executionSeq == 2);
}

unittest
{
    // A claim that finds an active execution which ended without being folded (its ender
    // crashed after the terminal compare-and-set) completes the fold and decides again, instead
    // of reporting an execution that will never end as active
    auto documents = new InMemoryDocumentStore();
    auto before = storesOver(documents);
    const id = dispatch(before, "fp1", 0);
    before.ledgers.subscribe(ledgerOf(before, "fp1"), "c1");
    finish(before, id, ExecutionStatus.failed); // ... and the process dies

    auto after = storesOver(documents.restart());
    auto retry = after.ledgers.claim("fp1", 1);
    assert(retry.outcome == ClaimOutcome.won && retry.executionId == executionIdFor("fp1", 2));
    assert(retry.ledger.lastStoppedExecutionId == id && retry.ledger.stopSeq == 1);
    assert(retry.ledger.pendingNotify == [LedgerNotice("c1", id)], "The fold's notices are kept");

    // A claimer that decided before that execution existed is superseded, not active
    auto other = storesOver(new InMemoryDocumentStore());
    const ended = dispatch(other, "fp1", 0);
    finish(other, ended, ExecutionStatus.succeeded);
    auto stale = other.ledgers.claim("fp1", 0);
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
        direct.ledgers.fold(finish(direct, winner, ExecutionStatus.succeeded));
    };
    auto lost = racing.ledgers.claim("fp1", 0);
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
        threads ~= new Thread(((size_t index, Stores s) => () { claims[index] = s.ledgers.claim("shared", 0); })(t, stores));
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
    // Subscribing: a compare-and-set at the version read. A stale read conflicts, even for a
    // chain that is already a subscriber; an idle ledger has nothing to wait on
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    auto read = ledgerOf(stores, "fp1");

    auto first = stores.ledgers.subscribe(read, "c1");
    assert(first.outcome == SubscribeOutcome.subscribed && first.ledger.subscribers == ["c1"] && first.ledger.version_ == 2);
    assert(throwsA!DocumentConflictException({ stores.ledgers.subscribe(read, "c2"); }), "A stale read loses");

    auto again = stores.ledgers.subscribe(first.ledger, "c1");
    assert(again.outcome == SubscribeOutcome.alreadySubscribed && again.ledger.subscribers == ["c1"]);
    assert(again.ledger.version_ == 3, "Already subscribed still writes at the version read");
    assert(throwsA!DocumentConflictException({ stores.ledgers.subscribe(first.ledger, "c1"); }),
        "Already subscribed on a stale read conflicts");
    auto second = stores.ledgers.subscribe(again.ledger, "c2");
    assert(second.outcome == SubscribeOutcome.subscribed && second.ledger.subscribers == ["c1", "c2"]);

    // Chain ids are plain printable ASCII without quotes or backslashes, at most maxKeyBytes
    char[] tooLong = new char[maxKeyBytes + 1];
    tooLong[] = 'c';
    foreach (bad; ["", tooLong.idup, `c"1`, `c\1`, "c\n1", "c\x7F", "c\u00e91"])
    {
        assert(throwsA!InvalidStateTransitionException({ stores.ledgers.subscribe(second.ledger, bad); }));
    }
    assert(ledgerOf(stores, "fp1").version_ == second.ledger.version_);

    auto folded = stores.ledgers.fold(finish(stores, id, ExecutionStatus.succeeded)).ledger;
    auto idle = stores.ledgers.subscribe(folded, "c3");
    assert(idle.outcome == SubscribeOutcome.notActive && idle.ledger.value == folded.value);
    assert(ledgerOf(stores, "fp1").version_ == folded.version_, "Nothing is written to an idle ledger");
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.subscribe(folded, ""); }),
        "The chain id is checked before the ledger, idle or not");
}

unittest
{
    // A chain that is already a subscriber, deciding on a stale ledger: the reconcile read the
    // ledger, then the execution ended, its fold noticed the chain and the drain marked it dirty
    // and cleared the notice, and only then did the reconcile read its (now dirty) ChainState.
    // Its subscribe must not trust the stale read: the compare-and-set fails, the chain re-reads
    // and finds the execution ended, instead of committing as if it still waited
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "c1");
    auto stale = ledgerOf(stores, "fp1");

    auto folded = stores.ledgers.fold(finish(stores, id, ExecutionStatus.succeeded)).ledger;
    stores.ledgers.clearNotified("fp1", folded.pendingNotify);

    assert(throwsA!DocumentConflictException({ stores.ledgers.subscribe(stale, "c1"); }),
        "A subscriber's stale read is detected");
    auto reread = ledgerOf(stores, "fp1");
    assert(stores.ledgers.subscribe(reread, "c1").outcome == SubscribeOutcome.notActive);
    assert(reread.lastSuccessExecutionId == id && reread.pendingNotify.length == 0 && reread.subscribers.length == 0);
}

unittest
{
    // Subscribe racing fold, the fold first: it lands between the subscriber's read and its
    // compare-and-set, so the subscribe loses; the chain re-reads, finds the execution ended and
    // re-evaluates. It is never left waiting on an idle ledger
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    const id = dispatch(direct, "fp1", 0);
    auto read = ledgerOf(racing, "fp1");
    const done = finish(direct, id, ExecutionStatus.succeeded);

    interleaving.beforeNextWrite = () { direct.ledgers.fold(done); };
    assert(throwsA!DocumentConflictException({ racing.ledgers.subscribe(read, "c1"); }), "The subscribe loses to the fold");
    auto reread = ledgerOf(racing, "fp1");
    assert(reread.activeExecutionId.length == 0 && reread.lastSuccessExecutionId == id);
    assert(racing.ledgers.subscribe(reread, "c1").outcome == SubscribeOutcome.notActive);
    assert(ledgerOf(direct, "fp1").subscribers.length == 0 && ledgerOf(direct, "fp1").pendingNotify.length == 0);
}

unittest
{
    // Subscribe racing fold, the subscribe first: it lands between the fold's read and its
    // compare-and-set, so the fold loses, re-reads and takes the new subscriber into its notices
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    const id = dispatch(direct, "fp1", 0);
    direct.ledgers.subscribe(ledgerOf(direct, "fp1"), "c0");
    const done = finish(direct, id, ExecutionStatus.failed);

    interleaving.beforeNextWrite = () {
        assert(direct.ledgers.subscribe(ledgerOf(direct, "fp1"), "c1").outcome == SubscribeOutcome.subscribed);
    };
    auto folded = racing.ledgers.fold(done);
    assert(folded.outcome == FoldOutcome.folded);
    assert(folded.ledger.pendingNotify == [LedgerNotice("c0", id), LedgerNotice("c1", id)], "The late subscriber is in the fold");
    assert(folded.ledger.subscribers.length == 0 && folded.ledger.activeExecutionId.length == 0);
    assert(folded.ledger.stopSeq == 1 && folded.ledger.lastStoppedExecutionId == id);
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
        const result = stores.ledgers.fold(finish(stores, id, status));
        assert(result.outcome == FoldOutcome.folded && result.ledger.activeExecutionId.length == 0);
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
    // A fold that cannot be right fails loudly and writes nothing: an execution still active,
    // one the ledger never claimed, or one at a fingerprint with no ledger
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    const version_ = ledgerOf(stores, "fp1").version_;

    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(stores.executions.get(id).get.value); }),
        "A queued execution is not folded");

    stores.executions.create(queuedExecution("exe_stranger", "fp1"));
    auto stranger = finish(stores, "exe_stranger", ExecutionStatus.succeeded);
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(stranger); }), "An execution never claimed is rejected");

    stores.executions.create(queuedExecution("exe_unclaimed", "fp_none"));
    const unclaimed = finish(stores, "exe_unclaimed", ExecutionStatus.succeeded);
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(unclaimed); }), "An execution with no ledger is rejected");

    auto unrecorded = stranger;
    unrecorded.id = "exe_unrecorded";
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(unrecorded); }), "An unrecorded execution is rejected");
    auto moved = stranger;
    moved.fingerprint = "fp_none";
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.fold(moved); }), "The fingerprint must match the record");
    assert(ledgerOf(stores, "fp1").version_ == version_ && stores.ledgers.get("fp_none").isNull);
}

unittest
{
    // A fold folds the stored record, not the value it is given: a caller that lost the terminal
    // compare-and-set (it meant to record a success, a cancel won) cannot fold its intended outcome
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    auto cancelled = finish(stores, id, ExecutionStatus.cancelled);
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
    // Crash after an execution's terminal compare-and-set, before its fold: the next reader,
    // after a restart, completes the fold, and its subscribers become notices. Settling again
    // writes nothing
    auto documents = new InMemoryDocumentStore();
    auto before = storesOver(documents);
    const id = dispatch(before, "fp1", 0);
    before.ledgers.subscribe(ledgerOf(before, "fp1"), "c1");
    before.ledgers.subscribe(ledgerOf(before, "fp1"), "c2");
    finish(before, id, ExecutionStatus.succeeded); // ... and the process dies

    auto after = storesOver(documents.restart());
    auto settled = after.ledgers.settle("fp1");
    assert(settled.activity == LedgerActivity.idle && settled.executionId.length == 0);
    auto ledger = settled.ledger.get;
    assert(ledger.activeExecutionId.length == 0 && ledger.lastSuccessExecutionId == id && ledger.subscribers.length == 0);
    assert(ledger.pendingNotify == [LedgerNotice("c1", id), LedgerNotice("c2", id)]);

    auto again = after.ledgers.settle("fp1");
    assert(again.activity == LedgerActivity.idle && again.ledger.get.version_ == ledger.version_);

    // The ender, resuming, folds again: a no-op
    assert(before.ledgers.fold(before.executions.get(id).get.value).outcome == FoldOutcome.alreadyFolded);
    assert(ledgerOf(after, "fp1").version_ == ledger.version_);
}

unittest
{
    // A reader settling races the ender's own fold: whichever lands second finds it folded, and
    // the notices are written once
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    const id = dispatch(direct, "fp1", 0);
    direct.ledgers.subscribe(ledgerOf(direct, "fp1"), "c1");
    const done = finish(direct, id, ExecutionStatus.cancelled);

    interleaving.beforeNextWrite = () { assert(direct.ledgers.fold(done).outcome == FoldOutcome.folded); };
    auto settled = racing.ledgers.settle("fp1");
    assert(settled.activity == LedgerActivity.idle);
    assert(settled.ledger.get.pendingNotify == [LedgerNotice("c1", id)] && settled.ledger.get.stopSeq == 1);
}

unittest
{
    // settle reports what it finds: no ledger, or an active execution that is recorded (and not
    // yet sent, which the dispatcher repairs). An active execution recorded at another
    // fingerprint means a corrupt store and fails loudly
    auto documents = new InMemoryDocumentStore();
    auto stores = storesOver(documents);
    auto none = stores.ledgers.settle("fp1");
    assert(none.activity == LedgerActivity.idle && none.ledger.isNull);

    const id = dispatch(stores, "fp1", 0);
    auto recorded = stores.ledgers.settle("fp1");
    assert(recorded.activity == LedgerActivity.recorded && recorded.executionId == id);
    assert(recorded.execution.get.id == id && recorded.execution.get.sentAt.length == 0);

    const misplaced = stores.ledgers.claim("fp2", 0).executionId;
    stores.executions.create(queuedExecution(misplaced, "fp_other"));
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.settle("fp2"); }));
}

unittest
{
    // Crash between the claim and recording its execution: the ledger keeps the claimed id, so
    // no second execution can be claimed; the next reader learns the id is unrecorded and
    // records it from its own request. Recording it again (the original dispatcher resuming)
    // keeps the first record and writes nothing
    auto documents = new InMemoryDocumentStore();
    auto before = storesOver(documents);
    const claimed = before.ledgers.claim("fp1", 0).executionId; // ... and the process dies

    auto after = storesOver(documents.restart());
    auto settled = after.ledgers.settle("fp1");
    assert(settled.activity == LedgerActivity.unrecorded && settled.executionId == claimed && settled.execution.isNull);
    auto other = after.ledgers.claim("fp1", 1);
    assert(other.outcome == ClaimOutcome.active && other.executionId == claimed, "Another chain cannot claim a second execution");

    auto repaired = after.executions.createIfAbsent(queuedExecution(settled.executionId, "fp1", "def_repairer"));
    assert(repaired.version_ == 1 && repaired.definitionHash == "def_repairer");
    auto now = after.ledgers.settle("fp1");
    assert(now.activity == LedgerActivity.recorded && now.execution.get.id == claimed);

    auto resumed = before.executions.createIfAbsent(queuedExecution(claimed, "fp1", "def_original"));
    assert(resumed.version_ == 1 && resumed.definitionHash == "def_repairer", "The first record is kept");

    // An execution under that id for another fingerprint or task is refused loudly
    assert(throwsA!InvalidStateTransitionException({ after.executions.createIfAbsent(queuedExecution(claimed, "fp_other")); }));
    auto otherTask = queuedExecution(claimed, "fp1");
    otherTask.taskId = "link";
    assert(throwsA!InvalidStateTransitionException({ after.executions.createIfAbsent(otherTask); }));
}

unittest
{
    // Two repairers recording one claimed execution at once: the second's create loses, and it
    // returns the first's record
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);
    const claimed = direct.ledgers.claim("fp1", 0).executionId;

    interleaving.beforeNextWrite = () { direct.executions.createIfAbsent(queuedExecution(claimed, "fp1", "def_first")); };
    auto second = racing.executions.createIfAbsent(queuedExecution(claimed, "fp1", "def_second"));
    assert(second.version_ == 1 && second.definitionHash == "def_first");
    assert(direct.executions.get(claimed).get.definitionHash == "def_first");
}

unittest
{
    import std.algorithm.searching : canFind;

    // The waiter limit: subscribing beyond maxLedgerWaiters fails loudly and writes nothing.
    // Undrained notices count, so a drain that stops working is noticed; a fold never fails on it
    auto stores = storesOver(new InMemoryDocumentStore());
    const id = dispatch(stores, "fp1", 0);
    foreach (i; 0 .. maxLedgerWaiters)
    {
        assert(stores.ledgers.subscribe(ledgerOf(stores, "fp1"), format("c%s", i)).outcome == SubscribeOutcome.subscribed);
    }
    auto full = ledgerOf(stores, "fp1");
    bool limited = false;
    try stores.ledgers.subscribe(full, "one_too_many");
    catch (LedgerWaiterLimitException e) limited = e.msg.canFind("one_too_many") && e.msg.canFind(format("%s", maxLedgerWaiters));
    assert(limited);
    assert(ledgerOf(stores, "fp1").version_ == full.version_);
    assert(stores.ledgers.subscribe(full, "c0").outcome == SubscribeOutcome.alreadySubscribed);

    auto folded = stores.ledgers.fold(finish(stores, id, ExecutionStatus.succeeded)).ledger;
    assert(folded.pendingNotify.length == maxLedgerWaiters);
    const next = dispatch(stores, "fp1", 1);
    assert(throwsA!LedgerWaiterLimitException({ stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "late"); }),
        "Undrained notices count towards the limit");
    stores.ledgers.clearNotified("fp1", [LedgerNotice("c0", id)]);
    assert(stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "late").outcome == SubscribeOutcome.subscribed);
    assert(ledgerOf(stores, "fp1").activeExecutionId == next);
}

unittest
{
    // A full ledger stays within maxDocumentBytes even when every chain id and the fingerprint
    // are maxKeyBytes long
    auto stores = storesOver(new InMemoryDocumentStore());
    char[] longName(char fill, size_t number)
    {
        auto name = new char[maxKeyBytes];
        name[] = fill;
        const suffix = format("%s", number);
        name[$ - suffix.length .. $] = suffix;
        return name;
    }

    const fingerprint = longName('f', 0).idup;
    const id = dispatch(stores, fingerprint, 0);
    foreach (i; 0 .. maxLedgerWaiters)
    {
        stores.ledgers.subscribe(ledgerOf(stores, fingerprint), longName('c', i).idup);
    }
    auto folded = stores.ledgers.fold(finish(stores, id, ExecutionStatus.failed)).ledger;
    assert(folded.pendingNotify.length == maxLedgerWaiters);
}

unittest
{
    // Draining notices: clearing removes exactly the notices handled, and is idempotent. A chain
    // noticed for one execution and then subscribed to the next gets a second notice, which
    // clearing the first leaves in place, so its second wakeup is not lost
    auto stores = storesOver(new InMemoryDocumentStore());
    const first = dispatch(stores, "fp1", 0);
    stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "c1");
    stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "c2");
    stores.ledgers.fold(finish(stores, first, ExecutionStatus.failed));

    const handled = ledgerOf(stores, "fp1").pendingNotify.dup; // the drainer marks c1 and c2 dirty
    const second = dispatch(stores, "fp1", 1);
    stores.ledgers.subscribe(ledgerOf(stores, "fp1"), "c1");
    stores.ledgers.fold(finish(stores, second, ExecutionStatus.succeeded));
    assert(ledgerOf(stores, "fp1").pendingNotify == [LedgerNotice("c1", first), LedgerNotice("c2", first), LedgerNotice("c1", second)]);

    auto cleared = stores.ledgers.clearNotified("fp1", handled);
    assert(cleared.pendingNotify == [LedgerNotice("c1", second)], "The second notice for c1 stays");
    auto again = stores.ledgers.clearNotified("fp1", handled);
    assert(again.version_ == cleared.version_, "Clearing again writes nothing");
    assert(stores.ledgers.clearNotified("fp1", [LedgerNotice("c1", second)]).pendingNotify.length == 0);
    assert(throwsA!InvalidStateTransitionException({ stores.ledgers.clearNotified("fp_none", handled); }));
}

unittest
{
    // A fold landing between a drain's read and its compare-and-set: the drain loses, re-reads
    // and clears only what it handled; the fold's new notice stays
    auto documents = new InMemoryDocumentStore();
    auto direct = storesOver(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = storesOver(interleaving);

    const first = dispatch(direct, "fp1", 0);
    direct.ledgers.subscribe(ledgerOf(direct, "fp1"), "c1");
    direct.ledgers.fold(finish(direct, first, ExecutionStatus.succeeded));
    const second = dispatch(direct, "fp1", 1);
    direct.ledgers.subscribe(ledgerOf(direct, "fp1"), "c3");
    const done = finish(direct, second, ExecutionStatus.failed);

    interleaving.beforeNextWrite = () { direct.ledgers.fold(done); };
    auto cleared = racing.ledgers.clearNotified("fp1", [LedgerNotice("c1", first)]);
    assert(cleared.pendingNotify == [LedgerNotice("c3", second)]);
}
