module confector.core.work_orders;

/**
 * The control plane's side of running work (AGENTS.md, "Workers and capacity"): a worker asks for
 * work and is handed a queued execution it holds under a lease, extends the lease while it runs,
 * and reports the outcome. There is no queue service: the execution is the active execution of its
 * fingerprint's ledger (confector.core.fingerprint_ledger), and every step of its life is one
 * compare-and-set on that ledger.
 *
 * `claimWork` finds ledgers with a queued execution through the ledger's `active` index
 * (discovery, which may lag: work found late is only delayed) and starts one by compare-and-set
 * (queued to running, one more attempt, a lease expiry, the worker). Of two workers starting the
 * same execution exactly one wins; the other moves on. The work order is built from the
 * execution's claim and the task of its stored definition.
 *
 * `ActiveExecution.attempt` counts starts, and the current start's number is its attempt. A
 * worker's heartbeat and completion are for the attempt its token names; one from an earlier
 * attempt (the lease expired and the execution was started again) is answered
 * `LeaseAnswer.superseded` or rejected, so a worker that lost its lease cannot extend it or report.
 *
 * A lease that runs out (`expireLease`, which a sweep calls) is an infrastructure failure, counted
 * in `ActiveExecution.expiredLeases`: within the limit the execution
 * goes back to queued; with the limit reached it fails with the reason "lease lost N times" (a
 * failed execution is never a cache hit, and only a user retries it) through the same end as a
 * completion.
 *
 * Every way an execution ends goes through `endExecution`: it writes the immutable TaskExecution
 * (only one ender can: the others are rejected as stale), then folds the outcome into the
 * fingerprint's ledger. The write and the fold are separate steps: a crash between them leaves a
 * finished execution that nothing has folded yet, which `LedgerStore.settle` completes on the next
 * read of the ledger. Then the open requests of the execution's project are reconciled; a
 * reconcile that fails is logged and left to a later one.
 *
 * An outcome is decided from the ledger as read, and the record write is not conditional on the
 * ledger, so a completion whose attempt was superseded between its check and its write stands: the
 * worker did finish the execution, and the newer attempt is told it is superseded at its next
 * heartbeat. A completion that arrives after the supersession is visible is rejected.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.document_collection : Versioned, maxWriteAttempts;
import confector.api.model;
import confector.core.fingerprint_ledger : claimedOn, endedExecution, withLease, withLostLease, withStart;
import confector.core.request_reconciler : reconcileOpenRequests;
import confector.core.state_stores : StateStores;
import confector.api.document_store : DocumentConflictException;

import core.time : Duration, hours, seconds;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.format : format;
import std.typecons : Nullable, nullable;
import vibe.core.log : logWarn;

/**
 * How many attempts an execution gets when the admin sets no limit (`server.execution.maxAttempts`):
 * a worker holding it may be lost this many times before the execution fails. This is the
 * documented default of that optional setting.
 */
enum uint defaultMaxAttempts = 3;

/// The longest lease a worker may ask for.
enum Duration maxLeaseDuration = 12.hours;

/**
 * The lease of `seconds` seconds a worker asked for, checked against 1 second to
 * `maxLeaseDuration` before it is converted, so an enormous count cannot overflow.
 *
 * Throws: InvalidLeaseRequestException if `seconds` is outside that range.
 */
Duration leaseOfSeconds(long seconds)
{
    if (seconds < 1 || seconds > maxLeaseDuration.total!"seconds")
    {
        throw new InvalidLeaseRequestException(format("Lease of %s seconds is outside 1 second to %s", seconds, maxLeaseDuration));
    }
    return seconds.seconds;
}

/**
 * The current time as the build model records it: ISO 8601 in UTC.
 */
string utcNow()
{
    return Clock.currTime(UTC()).toISOExtString();
}

/**
 * A work order a worker claimed, with the attempt that claim started. The worker presents the
 * attempt in every later call about the execution.
 */
struct ClaimedWork
{
    WorkOrder workOrder;
    /// The execution's attempt number this claim started (`ActiveExecution.attempt`).
    ulong attempt;
}

/**
 * A request about a lease that can never be honoured as made: no worker id, or a lease duration
 * outside 1 second to `maxLeaseDuration` or not whole seconds. Nothing was written.
 */
class InvalidLeaseRequestException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * The work order for `active`, the execution at `fingerprint`, running `task` (the task of its
 * stored definition): the task (whose steps, environment and declared outputs the runner uses),
 * fingerprint, resolved inputs and repository addresses. Pure.
 */
WorkOrder workOrderFor(string fingerprint, in ActiveExecution active, in TaskNode task) @trusted
{
    WorkOrder order;
    order.executionId = active.id;
    order.taskNode = cast(TaskNode) task;
    order.fingerprint = fingerprint;
    order.payload.inputs = (cast(ResolvedInput[]) active.inputs).dup;
    foreach (name, address; active.repositoryAddresses) order.payload.repositoryAddresses[name] = address;
    order.timeoutSeconds = task.timeoutSeconds;
    order.createdAt = active.createdAt;
    return order;
}

/**
 * Claims the oldest queued execution for worker `workerId`, holding it under a lease of `lease`
 * from `now` (default `utcNow`), and returns its work order and attempt; null if no queued
 * execution could be claimed. Ledgers with a queued execution are found through the ledger index
 * and each execution is started by compare-and-set (`startExecution`), so concurrent workers never
 * claim one execution twice: a worker that loses moves on to the next.
 *
 * Throws: InvalidLeaseRequestException if `workerId` is empty or `lease` is not valid; Exception
 * if the stored definition of the execution it starts, or its task, is missing (see `definedTask`);
 * whatever the stores throw.
 */
Nullable!ClaimedWork claimWork(StateStores stores, string workerId, Duration lease, string now = null)
{
    if (workerId.length == 0)
    {
        throw new InvalidLeaseRequestException("Claiming work needs the id of the worker claiming it");
    }
    requireLeaseDuration(lease);
    if (now.length == 0) now = utcNow();
    string cursor;
    while (true)
    {
        auto page = stores.ledgers.queuedPage(cursor);
        foreach (ref candidate; page.items)
        {
            if (candidate.active.isNull || candidate.active.get.status != ExecutionStatus.queued) continue;
            auto started = startExecution(stores, candidate.fingerprint, workerId, lease, now);
            if (started.isNull) continue;
            const task = definedTask(stores, started.get);
            return ClaimedWork(workOrderFor(candidate.fingerprint, started.get, task), started.get.attempt).nullable;
        }
        if (page.nextCursor.length == 0) return Nullable!ClaimedWork.init;
        cursor = page.nextCursor;
    }
}

/// The task `active` runs, read from its stored definition. Definitions are never removed and the
/// request reconciler only dispatches tasks its definition has, so a missing one is an internal error.
///
/// Throws: Exception if the definition or the task is missing.
private TaskNode definedTask(StateStores stores, in ActiveExecution active)
{
    auto definition = stores.definitions.get(active.definitionId);
    if (definition.isNull)
    {
        throw new Exception(format("Execution '%s' runs with definition '%s', which does not exist", active.id, active.definitionId));
    }
    foreach (ref task; definition.get.tasks)
    {
        if (task.id == active.taskId) return task;
    }
    throw new Exception(format("Execution '%s' runs task '%s', which definition '%s' does not have", active.id, active.taskId, active.definitionId));
}

/**
 * Starts the active execution of `fingerprint` for worker `workerId` by compare-and-set: a queued
 * execution becomes running with one more attempt, held by the worker until `now` plus `lease`.
 * Returns the running execution, or null (writing nothing) if the fingerprint's active execution is
 * not queued: it was started by another worker, or it has ended (or has its record, and is folded
 * instead).
 *
 * Throws: UnknownExecutionException if the fingerprint has no ledger.
 */
Nullable!ActiveExecution startExecution(StateStores stores, string fingerprint, string workerId, Duration lease, string now)
{
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = stores.ledgers.get(fingerprint);
        if (current.isNull)
        {
            throw new UnknownExecutionException(format("Cannot start an execution at fingerprint %s, which has no ledger", fingerprint));
        }
        if (current.get.active.isNull || current.get.active.get.status != ExecutionStatus.queued) return Nullable!ActiveExecution.init;
        // An execution that already ended but was not folded is not started: fold it instead
        if (!stores.executions.get(current.get.active.get.id).isNull)
        {
            stores.ledgers.settle(fingerprint);
            return Nullable!ActiveExecution.init;
        }
        try
        {
            return stores.ledgers.update(current.get, withStart(current.get.value, workerId, leaseExpiry(now, lease), now)).active;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not start the execution at fingerprint %s: it lost %s compare-and-sets in a row",
        fingerprint, maxWriteAttempts));
}

/// What a worker is told about the execution it holds, by a heartbeat.
enum LeaseAnswer : string
{
    /// The attempt still holds the execution: keep running. A heartbeat extended its lease.
    continue_ = "continue",
    /// The execution was cancelled: stop the work.
    cancel = "cancel",
    /// The attempt no longer holds the execution (its lease expired and the execution was queued
    /// or started again, or it finished): stop the work and report nothing.
    superseded = "superseded"
}

/**
 * Extends the lease of attempt `attempt` of execution `executionId` at `fingerprint` to `now`
 * (default `utcNow`) plus `lease`, by compare-and-set on the ledger, and answers what the worker is
 * to do. Writes nothing unless the answer is `continue_`.
 *
 * Throws: UnknownExecutionException if the fingerprint has no ledger or never claimed the
 * execution; InvalidLeaseRequestException if `lease` is not valid.
 */
LeaseAnswer heartbeatExecution(StateStores stores, string fingerprint, string executionId, ulong attempt, Duration lease, string now = null)
{
    requireLeaseDuration(lease);
    if (now.length == 0) now = utcNow();
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = readLedger(stores, fingerprint, executionId, "A heartbeat");
        const answer = holderAnswer(stores, current.value, executionId, attempt, "A heartbeat");
        if (answer != LeaseAnswer.continue_) return answer;
        try
        {
            stores.ledgers.update(current, withLease(current.value, leaseExpiry(now, lease)));
            return LeaseAnswer.continue_;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not extend the lease of execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

/// The ledger of `fingerprint`, which a worker's request (`what`) about `executionId` names.
private Versioned!FingerprintLedger readLedger(StateStores stores, string fingerprint, string executionId, string what)
{
    auto found = stores.ledgers.get(fingerprint);
    if (found.isNull)
    {
        throw new UnknownExecutionException(format("%s names execution '%s' at fingerprint %s, which has no ledger", what, executionId, fingerprint));
    }
    return found.get;
}

/// What the ledger says to the worker holding attempt `attempt` of execution `executionId`:
/// continue only if that attempt still holds the active execution. An execution the ledger no
/// longer holds has ended: cancelled tells the worker to stop, any other end supersedes it.
///
/// Throws: UnknownExecutionException if the ledger never claimed the execution.
private LeaseAnswer holderAnswer(StateStores stores, in FingerprintLedger ledger, string executionId, ulong attempt, string what)
{
    if (!ledger.active.isNull && ledger.active.get.id == executionId)
    {
        const active = ledger.active.get;
        return active.status == ExecutionStatus.running && active.attempt == attempt ? LeaseAnswer.continue_ : LeaseAnswer.superseded;
    }
    if (!claimedOn(ledger, executionId))
    {
        throw new UnknownExecutionException(format("%s names execution '%s', which fingerprint %s never claimed", what, executionId, ledger.fingerprint));
    }
    auto ended = stores.executions.get(executionId);
    return !ended.isNull && ended.get.status == ExecutionStatus.cancelled ? LeaseAnswer.cancel : LeaseAnswer.superseded;
}

/**
 * The attempt execution `executionId` at `fingerprint` is on: the active execution's current
 * attempt, or the attempt a finished execution ended with. Null if the fingerprint never claimed
 * the execution (or its record is missing).
 */
Nullable!ulong currentAttempt(StateStores stores, string fingerprint, string executionId)
{
    auto ledger = stores.ledgers.get(fingerprint);
    if (ledger.isNull) return Nullable!ulong.init;
    if (!ledger.get.active.isNull && ledger.get.active.get.id == executionId) return nullable(ledger.get.active.get.attempt);
    if (!claimedOn(ledger.get.value, executionId)) return Nullable!ulong.init;
    auto ended = stores.executions.get(executionId);
    return ended.isNull ? Nullable!ulong.init : nullable(ended.get.attempts);
}

/// What `expireLease` did.
enum LostLeaseDisposition
{
    /// The execution is queued again, for a worker to start.
    requeued,
    /// The attempts were used up: the execution failed and was folded into its ledger.
    failed,
    /// Nothing was written: the fingerprint has no running execution, or its lease has not
    /// expired.
    nothingToDo
}

/// The result of `expireLease`.
struct LostLease
{
    LostLeaseDisposition disposition;
    /// requeued and failed: how many leases the execution has lost, this one included.
    ulong expiredLeases;
    /// failed: the finished execution.
    Nullable!TaskExecution ended;
}

/**
 * Expires the lease of the execution running at `fingerprint` if its lease ran out by `now`
 * (default `utcNow`): the worker holding it is presumed lost, and the loss is counted in
 * `expiredLeases` by one compare-and-set on the ledger. Within the limit the same write puts the
 * execution back to queued, to be started as the next attempt; when the count reaches
 * `maxAttempts` the execution is ended failed with the reason "lease lost N times", by the same
 * write and fold as a completion (`endExecution`). A task that failed is never retried this way:
 * this handles only attempts that never reported. This is the entry point for a sweep that finds
 * expired leases.
 *
 * Throws: UnknownExecutionException if the fingerprint has no ledger; OutcomeNotFoldedException
 * if it failed but the fold did not complete; Exception if `maxAttempts` is 0 or a running
 * execution has no lease expiry.
 */
LostLease expireLease(StateStores stores, string fingerprint, uint maxAttempts, string now = null)
{
    requireAttemptLimit(maxAttempts);
    if (now.length == 0) now = utcNow();
    foreach (_; 0 .. maxWriteAttempts)
    {
        // Settled first: an execution that already ended is folded, not counted as lost
        auto current = stores.ledgers.settle(fingerprint);
        if (current.isNull)
        {
            throw new UnknownExecutionException(format("A lease expiry names fingerprint %s, which has no ledger", fingerprint));
        }
        if (current.get.active.isNull || current.get.active.get.status != ExecutionStatus.running)
        {
            return LostLease(LostLeaseDisposition.nothingToDo);
        }
        const seen = current.get.active.get;
        if (seen.leaseExpiresAt.length == 0)
        {
            throw new Exception(format("Execution '%s' is running but has no lease expiry", seen.id));
        }
        if (SysTime.fromISOExtString(seen.leaseExpiresAt) > SysTime.fromISOExtString(now))
        {
            return LostLease(LostLeaseDisposition.nothingToDo);
        }
        const lost = seen.expiredLeases + 1;
        const fail = lost >= maxAttempts;
        Versioned!FingerprintLedger counted;
        try
        {
            counted = stores.ledgers.update(current.get, withLostLease(current.get.value, !fail));
        }
        catch (DocumentConflictException)
        {
            continue; // The execution moved on meanwhile: decide again from what is there now
        }
        if (!fail) return LostLease(LostLeaseDisposition.requeued, lost);
        try
        {
            auto finished = endExecution(stores, fingerprint, counted.active.get, ExecutionStatus.failed, 0,
                format("lease lost %s %s (attempt limit %s)", lost, lost == 1 ? "time" : "times", maxAttempts), null, now);
            return LostLease(LostLeaseDisposition.failed, lost, nullable(finished));
        }
        catch (StaleCompletionException)
        {
            return LostLease(LostLeaseDisposition.nothingToDo); // A completion ended it first
        }
    }
    throw new Exception(format("Could not expire the lease of the execution at fingerprint %s: it lost %s compare-and-sets in a row",
        fingerprint, maxWriteAttempts));
}

/// `now` plus `lease`, as the build model records times.
private string leaseExpiry(string now, Duration lease)
{
    return (SysTime.fromISOExtString(now) + lease).toISOExtString();
}

private void requireLeaseDuration(Duration lease)
{
    if (lease < 1.seconds || lease > maxLeaseDuration)
    {
        throw new InvalidLeaseRequestException(format("Lease %s is outside 1 second to %s", lease, maxLeaseDuration));
    }
    if (lease != lease.total!"seconds".seconds)
    {
        throw new InvalidLeaseRequestException(format("Lease %s is not a whole number of seconds", lease));
    }
}

/**
 * Checks that an attempt limit is usable: an execution needs at least one attempt.
 *
 * Throws: Exception if `maxAttempts` is 0.
 */
void requireAttemptLimit(uint maxAttempts)
{
    if (maxAttempts == 0)
    {
        throw new Exception("The attempt limit of an execution must be at least 1: it is the number of times a lease may expire before it fails");
    }
}

/**
 * A worker reported the outcome of an execution that has nothing left to report: it finished
 * already (a duplicate or late completion, or it was failed while the worker ran it). Its report
 * is rejected and nothing is recorded.
 */
class StaleCompletionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * A completion came from an attempt that no longer holds its execution: the lease expired and the
 * execution was queued or started again. Its report is rejected and nothing
 * is recorded.
 */
class SupersededAttemptException : StaleCompletionException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * A completion finished its execution, but folding the outcome into the fingerprint's ledger
 * failed (`next` is the failure). The outcome is recorded and final, so resending the completion
 * is rejected as stale. The next read of the ledger settles the fold (`LedgerStore.settle`), which
 * the coordination sweep does for every open request.
 */
class OutcomeNotFoldedException : Exception
{
    /// The execution that finished.
    string executionId;

    this(string executionId, string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) nothrow @safe
    {
        super(msg, file, line, cause);
        this.executionId = executionId;
    }
}

/**
 * A completion names an execution that does not exist (or none at all). Nothing is recorded.
 */
class UnknownExecutionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * A completion that can never be recorded as reported: a status a worker cannot report, another
 * task than the execution's, or artifacts under another fingerprint (ForeignArtifactException).
 * Reporting it again would be rejected the same way. Nothing is recorded.
 */
class InvalidCompletionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Reads the execution `executionId` at `fingerprint`, which a worker reports the outcome of, and
 * checks it is still active. The ledger's active execution is the only source of the completion's
 * task and definition: a worker never names them.
 *
 * Throws: StaleCompletionException if it is not active; UnknownExecutionException if
 * `executionId` is empty or the fingerprint never claimed it.
 */
ActiveExecution requireActiveExecution(StateStores stores, string fingerprint, string executionId)
{
    if (executionId.length == 0)
    {
        throw new UnknownExecutionException("A completion must name the execution it completes");
    }
    auto found = stores.ledgers.get(fingerprint);
    if (found.isNull)
    {
        throw new UnknownExecutionException(format("A completion names execution '%s', which does not exist", executionId));
    }
    if (!found.get.active.isNull && found.get.active.get.id == executionId) return found.get.active.get;
    if (!claimedOn(found.get.value, executionId))
    {
        throw new UnknownExecutionException(format("A completion names execution '%s', which does not exist", executionId));
    }
    auto ended = stores.executions.get(executionId);
    throw new StaleCompletionException(format(
        "Execution '%s' at fingerprint %s already finished%s; its completion is rejected",
        executionId, fingerprint, ended.isNull ? "" : " " ~ cast(string) ended.get.status));
}

/**
 * A completion reported artifacts that do not belong to its execution.
 */
class ForeignArtifactException : InvalidCompletionException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * The artifacts a worker reported for execution `executionId` at `fingerprint`, each stamped with
 * the fingerprint and execution id. An artifact may leave its fingerprint and execution id empty;
 * one naming another fingerprint or another execution is rejected, so a completion cannot place
 * artifacts under a cache key the control plane did not compute or attribute them to another
 * execution. Pure.
 *
 * Throws: ForeignArtifactException if an artifact names a fingerprint or execution other than the
 * execution's.
 */
ArtifactMetadata[] executionArtifacts(string fingerprint, string executionId, ArtifactMetadata[] reported)
{
    ArtifactMetadata[] own;
    foreach (artifact; reported)
    {
        if (artifact.taskFingerprint.length > 0 && artifact.taskFingerprint != fingerprint)
        {
            throw new ForeignArtifactException(format(
                "Execution '%s' (fingerprint %s) reported artifact '%s' under fingerprint %s; its completion is rejected",
                executionId, fingerprint, artifact.artifactId, artifact.taskFingerprint));
        }
        if (artifact.executionId.length > 0 && artifact.executionId != executionId)
        {
            throw new ForeignArtifactException(format(
                "Execution '%s' reported artifact '%s' as produced by execution '%s'; its completion is rejected",
                executionId, artifact.artifactId, artifact.executionId));
        }
        ArtifactMetadata stamped = artifact;
        stamped.taskFingerprint = fingerprint;
        stamped.executionId = executionId;
        own ~= stamped;
    }
    return own;
}

/**
 * Records the outcome a worker reported for execution `executionId` at `fingerprint` (`status`,
 * which must be terminal, with its exit code, error and artifacts, see `executionArtifacts`) as the
 * immutable execution record, folds it into the fingerprint's ledger, and returns the finished
 * execution. A terminal execution never changes: a completion that loses to another one is
 * rejected, not merged.
 *
 * Throws: StaleCompletionException if the execution is not active (see
 * `requireActiveExecution`), including when a concurrent completion finishes it first; ForeignArtifactException if an artifact names another fingerprint;
 * UnknownExecutionException if `executionId` names no execution; Exception if `status` is not
 * terminal; OutcomeNotFoldedException if the execution finished but the fold failed.
 */
TaskExecution finishExecution(StateStores stores, string fingerprint, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    const active = requireActiveExecution(stores, fingerprint, executionId);
    auto own = executionArtifacts(fingerprint, executionId, artifacts);
    return endExecution(stores, fingerprint, active, status, exitCode, errorMessage, own, now.length > 0 ? now : utcNow());
}

/**
 * Checks that `status`, as a worker reported it, is one a worker can report: a terminal status
 * (succeeded, failed or cancelled), since the worker finished running the execution. Returns it.
 *
 * Throws: InvalidCompletionException if `status` is active (queued or running).
 */
ExecutionStatus reportedExecutionStatus(ExecutionStatus status) pure @safe
{
    if (ExecutionStore.isActive(status))
    {
        throw new InvalidCompletionException(format("A completion reported status '%s'; a worker can report only succeeded, failed or cancelled",
            cast(string) status));
    }
    return status;
}

/**
 * Records the completion a worker reported for execution `executionId` at `fingerprint` (see
 * `finishExecution`) and returns the finished execution. The ledger's active execution is the
 * only source of the task: a `result` naming a different task is rejected. Only the attempt that
 * holds the execution (`attempt`, the attempt the worker's token names) may complete it.
 *
 * A completion writes the execution record, folds it into the fingerprint's ledger and reconciles
 * the open requests of its project; nothing is cached anywhere else.
 * Log lines are not part of a completion: the worker streams them to the execution's log as it
 * runs.
 *
 * Throws: as `finishExecution`, SupersededAttemptException if the execution is not running
 * attempt `attempt`, and InvalidCompletionException if `result.status` is not a status a
 * worker can report or `result.taskId` names another task; except for OutcomeNotFoldedException
 * (the outcome is recorded), nothing is recorded.
 */
TaskExecution completeExecution(StateStores stores, string fingerprint, string executionId, ulong attempt, in TaskExecutionResult result, string now = null)
{
    const status = reportedExecutionStatus(result.status);
    const active = requireActiveExecution(stores, fingerprint, executionId);
    if (result.taskId.length > 0 && result.taskId != active.taskId)
    {
        throw new InvalidCompletionException(format("A completion of execution '%s' (task '%s') names task '%s'; it is rejected",
            executionId, active.taskId, result.taskId));
    }
    if (active.status != ExecutionStatus.running || active.attempt != attempt)
    {
        throw new SupersededAttemptException(format(
            "Execution '%s' is %s at attempt %s; a completion from attempt %s is rejected",
            executionId, active.status, active.attempt, attempt));
    }
    auto own = executionArtifacts(fingerprint, executionId, (cast(ArtifactMetadata[]) result.producedArtifacts).dup);
    return endExecution(stores, fingerprint, active, status, result.exitCode, result.errorMessage, own,
        now.length > 0 ? now : utcNow());
}

private void requireTerminal(ExecutionStatus status)
{
    if (ExecutionStore.isActive(status))
    {
        throw new Exception(format("A finished execution cannot be %s", status));
    }
}

/**
 * What to log when an outcome decided for `seen` (the active execution as the ender read it) is
 * recorded after the ledger's execution moved on: a lost lease requeued it or a newer attempt
 * started it. Empty when it did not. The outcome stands: the attempt that ended the execution decided
 * it on its own attempt.
 */
string supersessionNote(in ActiveExecution seen, in Nullable!(Versioned!FingerprintLedger) ledger)
{
    if (ledger.isNull || ledger.get.active.isNull || ledger.get.active.get.id != seen.id) return null;
    const now = ledger.get.active.get;
    if (now.attempt == seen.attempt && now.status == seen.status) return null;
    return format("The outcome of execution '%s' from attempt %s stands over the ledger's attempt %s (%s)",
        seen.id, seen.attempt, now.attempt, now.status);
}

/// Ends `active`, the execution at `fingerprint`: writes its immutable record, folds the record
/// into the ledger and reconciles the project's open requests. Throws StaleCompletionException if
/// another ender wrote the record first, after completing that ender's fold.
private TaskExecution endExecution(StateStores stores, string fingerprint, in ActiveExecution active, ExecutionStatus status,
    int exitCode, string errorMessage, ArtifactMetadata[] artifacts, string now)
{
    auto ended = endedExecution(fingerprint, active, status, now);
    ended.exitCode = exitCode;
    ended.errorMessage = errorMessage;
    ended.artifacts = artifacts;
    try
    {
        stores.executions.create(ended);
    }
    catch (DocumentConflictException)
    {
        stores.ledgers.settle(fingerprint);
        auto winner = stores.executions.get(active.id);
        if (winner.isNull) throw new Exception(format("Execution '%s' was reported to exist and then not found", active.id));
        throw new StaleCompletionException(format(
            "Execution '%s' finished %s while this completion (%s) was recorded; its completion is rejected",
            active.id, winner.get.status, status));
    }
    // Only the winner of the record write gets here. The execution is final: a failure from here
    // on cannot undo it, so it is reported as such, not as a failed completion.
    const note = supersessionNote(active, stores.ledgers.get(fingerprint));
    if (note.length > 0) logWarn("[work] %s", note);
    try
    {
        stores.ledgers.fold(ended);
    }
    catch (Exception e)
    {
        throw new OutcomeNotFoldedException(ended.id, format(
            "Execution '%s' (fingerprint %s) finished %s, but folding it into its ledger failed: %s; "
            ~ "the outcome is recorded, so a resent completion is rejected as stale; the next read of the ledger settles it",
            ended.id, fingerprint, ended.status, e.msg), e);
    }
    reconcileOpenRequests(stores, ended.projectId, now);
    return ended;
}

version (unittest)
{
    import confector.core.request_fixtures : beforeWrite, createChain, fingerprintNow, intake, reconcilerOf, taskOf;
    import confector.core.fingerprint_ledger : ClaimOutcome, FoldOutcome, executionIdFor;
    import confector.api.document_store : IndexQuery, QueryPage;
    import confector.core.state_validation : InvalidStateTransitionException;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import core.time : minutes;
    import std.algorithm.searching : canFind;
    import vibe.data.json : Json;

    private string fixedNow() { return "2026-10-16T10:00:02Z"; }

    /// The lease the tests' workers ask for.
    private enum Duration testLease = 1.minutes;

    /// `fixedNow` plus `by`.
    private string later(Duration by)
    {
        return (SysTime.fromISOExtString(fixedNow()) + by).toISOExtString();
    }

    /// A project definition whose task "compile" has a full build configuration.
    private ProjectDefinition sampleProject()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game");
        compile.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
        compile.environment = ["MODE": "release"];
        compile.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];
        compile.timeoutSeconds = 1200;
        return ProjectDefinition([compile]);
    }

    /// What a claim of "compile" carries, with the stored definition's id.
    private ActiveExecution sampleClaim(StateStores stores, string createdAt = "2026-10-16T10:00:00Z")
    {
        ActiveExecution proposed;
        proposed.projectId = "p";
        proposed.taskId = "compile";
        proposed.definitionId = stores.definitions.put(sampleProject());
        proposed.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
        proposed.repositoryAddresses = ["src": "https://example.test/game.git"];
        proposed.createdAt = createdAt;
        return proposed;
    }

    /// Claims an execution of "compile" at `fingerprint` as a dispatch does (the claim must win, so
    /// any earlier execution there must have been folded). Returns the claimed id.
    private string queueExecution(StateStores stores, string fingerprint = "fp1", string createdAt = "2026-10-16T10:00:00Z")
    {
        auto ledger = stores.ledgers.get(fingerprint);
        auto claimed = stores.ledgers.claim(fingerprint, ledger.isNull ? 0 : ledger.get.executionSeq, sampleClaim(stores, createdAt));
        assert(claimed.outcome == ClaimOutcome.won, "The test dispatch's claim must win");
        return claimed.executionId;
    }

    /// As `queueExecution`, then started by worker `workerId` (attempt 1) at `fixedNow`.
    private string runningExecution(StateStores stores, string workerId = "w1", string fingerprint = "fp1")
    {
        const id = queueExecution(stores, fingerprint);
        assert(!startExecution(stores, fingerprint, workerId, testLease, fixedNow()).isNull);
        return id;
    }

    /// The active execution of `fingerprint`, which must have one.
    private ActiveExecution activeAt(StateStores stores, string fingerprint = "fp1")
    {
        auto ledger = stores.ledgers.get(fingerprint).get;
        assert(!ledger.active.isNull, "The fingerprint has no active execution");
        return ledger.active.get;
    }

    /// A successful completion.
    private TaskExecutionResult succeededResult()
    {
        TaskExecutionResult result;
        result.status = ExecutionStatus.succeeded;
        return result;
    }

    private bool throwsInvalidLease(scope void delegate() action)
    {
        try action();
        catch (InvalidLeaseRequestException) return true;
        return false;
    }
}

unittest
{
    // A worker claims a queued execution: it gets the full work order, built from the execution's
    // claim and its stored definition, and the attempt; the execution is running under the
    // worker's lease, and nothing is left to claim
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);

    auto claimed = claimWork(stores, "w1", testLease, fixedNow());
    assert(!claimed.isNull && claimed.get.attempt == 1);
    auto order = claimed.get.workOrder;
    assert(order.executionId == id && order.taskNode.id == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].config["script"].get!string == "make" && order.timeoutSeconds == 1200);
    assert(order.taskNode.environment == ["MODE": "release"]);
    assert(order.taskNode.outputs.artifacts == [OutputArtifactDecl("game.zip", "out/game.zip")]);
    assert(order.payload.inputs == sampleClaim(stores).inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    auto running = activeAt(stores);
    assert(running.status == ExecutionStatus.running && running.attempt == 1 && running.worker == "w1");
    assert(running.startedAt == fixedNow() && running.leaseExpiresAt == later(testLease));

    assert(claimWork(stores, "w2", testLease, fixedNow()).isNull, "A held execution is not claimed again");
    auto held = activeAt(stores);
    assert(held.attempt == 1 && held.worker == "w1");

    // Oldest first
    const newer = queueExecution(stores, "fp2", "2026-10-16T10:00:05Z");
    const older = queueExecution(stores, "fp3", "2026-10-16T10:00:03Z");
    assert(claimWork(stores, "w2", testLease, fixedNow()).get.workOrder.executionId == older);
    assert(claimWork(stores, "w2", testLease, fixedNow()).get.workOrder.executionId == newer);

    // A claim names its worker and asks for a lease that fits
    assert(throwsInvalidLease({ claimWork(stores, "", testLease); }));
    foreach (lease; [Duration.zero, 500.msecs, 1500.msecs, maxLeaseDuration + 1.seconds])
    {
        assert(throwsInvalidLease({ claimWork(stores, "w1", lease); }), lease.toString());
    }
}

version (unittest)
{
    import core.time : msecs;
}

unittest
{
    // Two workers claiming one queued execution at once: exactly one claims it, by
    // compare-and-set. The loser re-reads, finds it held, and moves on to the next queued
    // execution, or gets nothing
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const only = queueExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    Nullable!ClaimedWork first;
    interleaving.beforeNextWrite = () { first = claimWork(stores, "w1", testLease, fixedNow()); };
    auto second = claimWork(racing, "w2", testLease, fixedNow());
    assert(interleaving.beforeNextWrite is null);
    assert(!first.isNull && first.get.workOrder.executionId == only && first.get.attempt == 1);
    assert(second.isNull, "Two workers cannot claim one execution");
    auto held = activeAt(stores);
    assert(held.status == ExecutionStatus.running && held.attempt == 1 && held.worker == "w1");

    const other = queueExecution(stores, "fp2", "2026-10-16T10:00:05Z");
    const next = queueExecution(stores, "fp3", "2026-10-16T10:00:06Z");
    interleaving.beforeNextWrite = () { first = claimWork(stores, "w1", testLease, fixedNow()); };
    second = claimWork(racing, "w2", testLease, fixedNow());
    assert(first.get.workOrder.executionId == other && second.get.workOrder.executionId == next);
    assert(activeAt(stores, "fp2").worker == "w1" && activeAt(stores, "fp3").worker == "w2");
}

unittest
{
    // A queued execution whose record was already written (its ender crashed before the fold) is
    // not handed to a worker: claiming folds it and moves on
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores);
    stores.executions.create(endedExecution("fp1", activeAt(stores), ExecutionStatus.cancelled, fixedNow()));

    assert(claimWork(new StateStores(documents.restart()), "w1", testLease, fixedNow()).isNull);
    auto ledger = stores.ledgers.get("fp1").get;
    assert(ledger.active.isNull && ledger.lastStoppedExecutionId == id);
}

unittest
{
    // A heartbeat from the attempt that holds the execution extends its lease. A different attempt
    // is superseded, and so is an execution that is queued or finished; a cancelled execution
    // tells the worker to stop. Only a continue writes
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);

    assert(heartbeatExecution(stores, "fp1", id, 1, testLease, later(30.seconds)) == LeaseAnswer.continue_);
    assert(activeAt(stores).leaseExpiresAt == later(30.seconds + testLease));

    const lease = activeAt(stores).leaseExpiresAt;
    assert(heartbeatExecution(stores, "fp1", id, 2, testLease, later(40.seconds)) == LeaseAnswer.superseded);
    assert(heartbeatExecution(stores, "fp1", id, 0, testLease, later(40.seconds)) == LeaseAnswer.superseded);
    assert(activeAt(stores).leaseExpiresAt == lease, "A superseded heartbeat extends nothing");

    assert(expireLease(stores, "fp1", 3, later(2.hours)).disposition == LostLeaseDisposition.requeued);
    assert(heartbeatExecution(stores, "fp1", id, 1, testLease) == LeaseAnswer.superseded, "A queued execution is held by no attempt");

    const cancelledId = runningExecution(stores, "w1", "fp2");
    finishExecution(stores, "fp2", cancelledId, ExecutionStatus.cancelled, 0, "stopped", null, fixedNow());
    assert(heartbeatExecution(stores, "fp2", cancelledId, 1, testLease) == LeaseAnswer.cancel);

    const finishedId = runningExecution(stores, "w1", "fp3");
    finishExecution(stores, "fp3", finishedId, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(heartbeatExecution(stores, "fp3", finishedId, 1, testLease) == LeaseAnswer.superseded);

    bool unknown = false;
    try heartbeatExecution(stores, "fp1", "exe_missing", 1, testLease);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_missing'");
    assert(unknown);
    unknown = false;
    try heartbeatExecution(stores, "fp_nowhere", id, 1, testLease);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("no ledger");
    assert(unknown);
    assert(throwsInvalidLease({ heartbeatExecution(stores, "fp1", id, 1, Duration.zero); }));
}

unittest
{
    // An expired lease requeues the execution at once, for any worker to claim. The expired attempt
    // is superseded the moment it is claimed again: its heartbeat and completion are rejected and
    // change nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);

    assert(heartbeatExecution(stores, "fp1", id, 2, testLease) == LeaseAnswer.superseded, "Only the holding attempt holds the lease");
    assert(activeAt(stores).status == ExecutionStatus.running);
    assert(expireLease(stores, "fp1", 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);
    auto requeued = activeAt(stores);
    assert(requeued.status == ExecutionStatus.queued && requeued.attempt == 1);
    assert(requeued.worker.length == 0 && requeued.startedAt.length == 0 && requeued.leaseExpiresAt.length == 0);
    assert(heartbeatExecution(stores, "fp1", id, 1, testLease) == LeaseAnswer.superseded, "A queued execution is held by no attempt");

    auto again = claimWork(stores, "w2", testLease, fixedNow());
    assert(!again.isNull && again.get.workOrder.executionId == id && again.get.attempt == 2);

    assert(heartbeatExecution(stores, "fp1", id, 1, testLease) == LeaseAnswer.superseded);
    bool rejected = false;
    try completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow());
    catch (SupersededAttemptException e) rejected = e.msg.canFind(id) && e.msg.canFind("attempt 1");
    assert(rejected);
    auto held = activeAt(stores);
    assert(held.status == ExecutionStatus.running && held.attempt == 2 && held.worker == "w2");

    assert(completeExecution(stores, "fp1", id, 2, succeededResult(), fixedNow()).status == ExecutionStatus.succeeded);
    assert(heartbeatExecution(stores, "fp1", id, 2, testLease) == LeaseAnswer.superseded, "A finished execution holds no lease");

    bool unknown = false;
    try heartbeatExecution(stores, "fp1", "exe_missing", 1, testLease);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_missing'");
    assert(unknown);
}

unittest
{
    // Start, heartbeat and a lost lease are each one compare-and-set on the ledger
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = new StateStores(interleaving);
    const id = queueExecution(stores);

    size_t writes;
    void countWrites()
    {
        interleaving.beforeNextWrite = () { writes += 1; countWrites(); };
    }
    countWrites();
    assert(!startExecution(stores, "fp1", "w1", testLease, fixedNow()).isNull && writes == 1);
    assert(heartbeatExecution(stores, "fp1", id, 1, testLease, later(10.seconds)) == LeaseAnswer.continue_ && writes == 2);
    assert(expireLease(stores, "fp1", 3, later(5.minutes)).disposition == LostLeaseDisposition.requeued && writes == 3);
    assert(!startExecution(stores, "fp1", "w1", testLease, fixedNow()).isNull && writes == 4);
    assert(expireLease(stores, "fp1", 3, later(5.minutes)).disposition == LostLeaseDisposition.requeued && writes == 5);
}

unittest
{
    // A completion from a superseded attempt is rejected, loudly, and records nothing: the lease
    // of attempt 1 expired and the execution was claimed again. A completion for an execution no
    // worker holds (queued) is rejected too. The attempt that holds it completes it
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    assert(expireLease(stores, "fp1", 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);

    bool queuedRejected = false;
    try completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow());
    catch (SupersededAttemptException e) queuedRejected = e.msg.canFind("queued");
    assert(queuedRejected && activeAt(stores).status == ExecutionStatus.queued);

    assert(claimWork(stores, "w2", testLease, later(2.minutes)).get.attempt == 2);
    bool oldRejected = false;
    try completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow());
    catch (StaleCompletionException e) oldRejected = cast(SupersededAttemptException) e !is null;
    assert(oldRejected);
    assert(heartbeatExecution(stores, "fp1", id, 1, testLease) == LeaseAnswer.superseded);
    assert(activeAt(stores).status == ExecutionStatus.running);
    assert(stores.executions.get(id).isNull, "A rejected completion records nothing");

    assert(completeExecution(stores, "fp1", id, 2, succeededResult(), fixedNow()).worker == "w2");
}

unittest
{
    // A completion whose attempt is superseded between its check and its write: it read the
    // execution running attempt 1, then the lease expired and attempt 2 started before the
    // completion was written. The worker did finish the execution, so the outcome is recorded once
    // and folded; attempt 2 is told it is superseded and cannot report
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () {
        assert(expireLease(stores, "fp1", 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);
        assert(claimWork(stores, "w2", testLease, later(2.minutes)).get.attempt == 2);
    };
    auto done = completeExecution(racing, "fp1", id, 1, succeededResult(), fixedNow());
    assert(done.status == ExecutionStatus.succeeded && done.attempts == 1 && done.worker == "w1");
    auto ledger = stores.ledgers.get("fp1").get;
    assert(ledger.active.isNull && ledger.lastSuccessExecutionId == id && ledger.stopSeq == 0);
    assert(heartbeatExecution(stores, "fp1", id, 2, testLease) == LeaseAnswer.superseded);
    bool rejected = false;
    try completeExecution(stores, "fp1", id, 2, succeededResult(), fixedNow());
    catch (StaleCompletionException e) rejected = true;
    assert(rejected, "Attempt 2 cannot report once the outcome is recorded");
    assert(stores.executions.get(id).get.value == done && stores.executions.get(id).get.version_ == 1);
}

unittest
{
    // A worker lost on every attempt: each expired lease requeues the execution until the
    // attempts are used up. Then the execution fails with "lease lost N times" through the
    // end of a completion: it is folded into the ledger, and the request sees the task failed,
    // not retried
    auto stores = new StateStores(new InMemoryDocumentStore());
    const fingerprint = requestsSharingFingerprint(stores);
    const id = activeAt(stores, fingerprint).id;

    assert(claimWork(stores, "w1", testLease, fixedNow()).get.attempt == 1);
    assert(expireLease(stores, fingerprint, 3, later(testLease - 1.seconds)).disposition == LostLeaseDisposition.nothingToDo,
        "The lease has not run out");
    assert(activeAt(stores, fingerprint).status == ExecutionStatus.running);

    foreach (lostSoFar; 1 .. 3)
    {
        const at = later(lostSoFar * 10.minutes);
        auto lost = expireLease(stores, fingerprint, 3, at);
        assert(lost.disposition == LostLeaseDisposition.requeued && lost.expiredLeases == lostSoFar);
        auto requeued = activeAt(stores, fingerprint);
        assert(requeued.status == ExecutionStatus.queued && requeued.id == id);
        assert(requeued.attempt == lostSoFar && requeued.worker.length == 0 && requeued.leaseExpiresAt.length == 0);
        assert(stores.executions.get(id).isNull, "A lost lease within the limit ends nothing");

        auto retried = claimWork(stores, "w2", testLease, at);
        assert(!retried.isNull && retried.get.attempt == lostSoFar + 1);
        assert(activeAt(stores, fingerprint).status == ExecutionStatus.running);
    }

    // The third attempt is lost too
    auto last = expireLease(stores, fingerprint, 3, later(1.hours));
    assert(last.disposition == LostLeaseDisposition.failed && last.expiredLeases == 3);
    auto failed = stores.executions.get(id).get;
    assert(failed.status == ExecutionStatus.failed && failed.attempts == 3 && failed.finishedAt == later(1.hours));
    assert(failed.errorMessage.canFind("lease lost 3 times"), failed.errorMessage);
    assert(last.ended.get == failed.value);
    assert(claimWork(stores, "w3", testLease, later(1.hours)).isNull, "A failed execution is not claimed again");
    assert(expireLease(stores, fingerprint, 3, later(2.hours)).disposition == LostLeaseDisposition.nothingToDo);

    auto ledger = stores.ledgers.get(fingerprint).get;
    assert(ledger.active.isNull && ledger.lastStoppedExecutionId == id);
    auto settled = reconcilerOf(stores).reconcile("rb");
    assert(taskOf(settled.request, "compile").status == RequestTaskStatus.failed && settled.request.state.outcome == RequestOutcome.failed);
}

unittest
{
    // The attempt limit counts expired leases and nothing else: each start is one more attempt, and
    // with `maxAttempts` 2 the second lost lease fails the execution
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    assert(claimWork(stores, "w1", testLease, fixedNow()).get.attempt == 1);
    auto first = expireLease(stores, "fp1", 2, later(10.minutes));
    assert(first.disposition == LostLeaseDisposition.requeued && first.expiredLeases == 1);
    assert(claimWork(stores, "w2", testLease, later(10.minutes)).get.attempt == 2);
    auto last = expireLease(stores, "fp1", 2, later(20.minutes));
    assert(last.disposition == LostLeaseDisposition.failed && last.expiredLeases == 2);
    assert(last.ended.get.errorMessage.canFind("lease lost 2 times"), last.ended.get.errorMessage);
    assert(stores.executions.get(id).get.attempts == 2);
}

unittest
{
    // The expiry that fails an execution records the leases it counted, as a requeue does: the
    // stored execution and the answer agree on the count
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    assert(claimWork(stores, "w1", testLease, later(0.minutes)).get.attempt == 1);
    assert(expireLease(stores, "fp1", 2, later(5.minutes)).disposition == LostLeaseDisposition.requeued);
    assert(claimWork(stores, "w1", testLease, later(10.minutes)).get.attempt == 2);
    auto failed = expireLease(stores, "fp1", 2, later(15.minutes));
    assert(failed.disposition == LostLeaseDisposition.failed);
    assert(failed.expiredLeases == 2, "The failing expiry counts its lost lease");
    assert(failed.ended.get.expiredLeases == 2 && stores.executions.get(id).get.value.expiredLeases == 2);
}

unittest
{
    // What an expiry leaves alone: a task that reported failure is never retried by it, an
    // execution that is queued or whose lease runs on is not touched, and a running execution
    // without a lease expiry is a corrupt record that fails loudly
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);
    finishExecution(stores, "fp1", id, ExecutionStatus.failed, 2, "make failed", null, fixedNow());

    auto late = expireLease(stores, "fp1", 3, later(1.hours));
    assert(late.disposition == LostLeaseDisposition.nothingToDo);
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.failed && kept.attempts == 1 && kept.errorMessage == "make failed" && kept.exitCode == 2);

    queueExecution(stores, "fp2");
    assert(expireLease(stores, "fp2", 3, later(1.hours)).disposition == LostLeaseDisposition.nothingToDo);
    assert(activeAt(stores, "fp2").expiredLeases == 0, "A queued execution is not counted as lost");

    runningExecution(stores, "w1", "fp3");
    assert(expireLease(stores, "fp3", 3, later(testLease - 1.seconds)).disposition == LostLeaseDisposition.nothingToDo);
    assert(activeAt(stores, "fp3").expiredLeases == 0, "A lease that runs on is not counted");

    runningExecution(stores, "w1", "fp4");
    auto stored = documents.get("fingerprint_ledgers", "fp4").get;
    Json content = stored.content;
    content["active"]["lease_expires_at"] = Json("");
    documents.replace("fingerprint_ledgers", "fp4", content, stored.version_);
    bool corrupt = false;
    try expireLease(stores, "fp4", 3, later(1.hours));
    catch (Exception e) corrupt = e.msg.canFind("no lease expiry");
    assert(corrupt);

    bool unknown = false;
    try expireLease(stores, "fp_nowhere", 3);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("fp_nowhere");
    assert(unknown);

    bool noLimit = false;
    try expireLease(stores, "fp1", 0);
    catch (Exception e) noLimit = e.msg.canFind("at least 1");
    assert(noLimit);
}

unittest
{
    // An expiry that decides to fail the execution loses to a completion that finishes it
    // first: the completion stands, nothing is overwritten, and the expiry is nothingToDo
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow()); };
    auto result = expireLease(racing, "fp1", 1, later(1.hours));
    assert(result.disposition == LostLeaseDisposition.nothingToDo);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
    assert(stores.ledgers.get("fp1").get.lastSuccessExecutionId == id);

    // The same when the completion lands after the expiry counted its lost lease, before it ends
    // the execution: the completion's record is written first, and the expiry yields to it
    auto otherDocuments = new InMemoryDocumentStore();
    auto other = new StateStores(otherDocuments);
    const otherId = runningExecution(other);
    auto otherInterleaving = new InterleavingDocumentStore(otherDocuments);
    auto otherRacing = new StateStores(otherInterleaving);
    // The expiry's writes: 1 counts the lost lease, 2 writes the record
    beforeWrite(otherInterleaving, 2, () { completeExecution(other, "fp1", otherId, 1, succeededResult(), fixedNow()); });
    auto yielded = expireLease(otherRacing, "fp1", 1, later(1.hours));
    assert(otherInterleaving.beforeNextWrite is null);
    assert(yielded.disposition == LostLeaseDisposition.nothingToDo);
    assert(other.executions.get(otherId).get.status == ExecutionStatus.succeeded);
    assert(other.ledgers.get("fp1").get.active.isNull && other.ledgers.get("fp1").get.lastSuccessExecutionId == otherId);
}

unittest
{
    // An expiry that decides to fail the execution does not land on an execution that has moved
    // on since it read it: here the execution was requeued and a worker claimed a third attempt in
    // between, so the decision is made again from what is there, and the failure counts the
    // attempts that really were lost
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);
    assert(expireLease(stores, "fp1", 5, later(10.minutes)).disposition == LostLeaseDisposition.requeued);
    assert(claimWork(stores, "w2", testLease, later(10.minutes)).get.attempt == 2);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () {
        assert(expireLease(stores, "fp1", 5, later(20.minutes)).disposition == LostLeaseDisposition.requeued);
        assert(claimWork(stores, "w3", testLease, later(20.minutes)).get.attempt == 3);
    };
    auto result = expireLease(racing, "fp1", 2, later(1.hours));
    assert(result.disposition == LostLeaseDisposition.failed);
    assert(result.ended.get.errorMessage.canFind("lease lost 3 times"), result.ended.get.errorMessage);
    assert(result.ended.get.attempts == 3 && result.ended.get.worker == "w3" && result.ended.get.id == id);
}

unittest
{
    // A failed or cancelled outcome records when it finished even when the caller gives no time
    auto stores = new StateStores(new InMemoryDocumentStore());
    const cancelledId = queueExecution(stores);
    finishExecution(stores, "fp1", cancelledId, ExecutionStatus.cancelled, 0, "stopped", null);
    auto cancelled = stores.executions.get(cancelledId).get;
    assert(cancelled.status == ExecutionStatus.cancelled && cancelled.finishedAt.length > 0);

    const failedId = queueExecution(stores);
    finishExecution(stores, "fp1", failedId, ExecutionStatus.failed, 1, "boom", null);
    auto failed = stores.executions.get(failedId).get;
    assert(failed.status == ExecutionStatus.failed && failed.finishedAt.length > 0);
}

unittest
{
    // A completion is recorded only while its execution is active: once it finished (it was
    // failed meanwhile), a late completion is rejected loudly and records nothing, and a newer
    // execution at the same fingerprint is untouched
    auto stores = new StateStores(new InMemoryDocumentStore());
    const first = queueExecution(stores);
    finishExecution(stores, "fp1", first, ExecutionStatus.failed, 1, "worker lost", null, fixedNow());
    const second = queueExecution(stores);

    bool stale = false;
    try finishExecution(stores, "fp1", first, ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) stale = e.msg.canFind(first) && e.msg.canFind("failed");
    assert(stale);
    auto kept = stores.executions.get(first).get;
    assert(kept.status == ExecutionStatus.failed && kept.errorMessage == "worker lost");
    assert(activeAt(stores).id == second && activeAt(stores).status == ExecutionStatus.queued, "The newer execution is untouched");

    finishExecution(stores, "fp1", second, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(stores.executions.get(second).get.status == ExecutionStatus.succeeded);
}

unittest
{
    // A completion is identified only by its execution id. One naming no execution, or an
    // execution that does not exist, is rejected loudly and records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);

    bool unnamed = false;
    try finishExecution(stores, "fp1", "", ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) assert(false, "Not stale: unnamed");
    catch (UnknownExecutionException e) unnamed = e.msg.canFind("must name the execution");
    assert(unnamed);

    bool unknown = false;
    try finishExecution(stores, "fp1", "exe_unknown", ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) assert(false, "Not stale: unknown");
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_unknown'") && e.msg.canFind("does not exist");
    assert(unknown);

    bool noLedger = false;
    try finishExecution(stores, "fp_nowhere", id, ExecutionStatus.succeeded, 0, null, null);
    catch (UnknownExecutionException e) noLedger = e.msg.canFind(id);
    assert(noLedger);

    assert(activeAt(stores).id == id && activeAt(stores).status == ExecutionStatus.queued, "Nothing was recorded");
    assert(stores.executions.get("exe_unknown").isNull && stores.executions.get(id).isNull);
}

unittest
{
    // A duplicate or late completion of an execution that already finished is rejected loudly:
    // a terminal execution is never overwritten
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    auto produced = [ArtifactMetadata("game.zip")];
    finishExecution(stores, "fp1", id, ExecutionStatus.succeeded, 0, null, produced, fixedNow());

    foreach (status; [ExecutionStatus.succeeded, ExecutionStatus.failed])
    {
        bool rejected = false;
        try finishExecution(stores, "fp1", id, status, 7, "late", null, "2026-10-16T11:00:00Z");
        catch (StaleCompletionException e) rejected = e.msg.canFind(id);
        assert(rejected);
    }
    auto kept = stores.executions.get(id).get;
    assert(kept.version_ == 1, "A finished execution is written once");
    assert(kept.status == ExecutionStatus.succeeded && kept.exitCode == 0 && kept.errorMessage.length == 0);
    assert(kept.artifacts.length == 1 && kept.artifacts[0].artifactId == "game.zip" && kept.finishedAt == fixedNow());
}

unittest
{
    // Two completions of one execution racing (a worker reporting twice, or two control-plane
    // instances): both pass the check, exactly one writes its outcome, and the other is
    // rejected loudly instead of overwriting it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { finishExecution(stores, "fp1", id, ExecutionStatus.succeeded, 0, null, null, fixedNow()); };
    bool rejected = false;
    try finishExecution(racing, "fp1", id, ExecutionStatus.failed, 1, "duplicate", null, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected, "The loser finds the execution recorded, and is rejected");
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.succeeded && kept.errorMessage.length == 0 && kept.version_ == 1);
    assert(stores.ledgers.get("fp1").get.lastSuccessExecutionId == id && stores.ledgers.get("fp1").get.stopSeq == 0);
}

unittest
{
    // A completion cannot place artifacts under another fingerprint: one naming a fingerprint
    // other than its execution's is rejected and records nothing; unnamed ones are stamped with
    // the execution's
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);

    ArtifactMetadata foreign;
    foreign.artifactId = "game.zip";
    foreign.taskFingerprint = "fp_somebody_else";
    bool rejected = false;
    try finishExecution(stores, "fp1", id, ExecutionStatus.succeeded, 0, null, [foreign]);
    catch (ForeignArtifactException e) rejected = e.msg.canFind("fp_somebody_else") && e.msg.canFind(id);
    assert(rejected);
    assert(stores.executions.get(id).isNull && activeAt(stores).status == ExecutionStatus.queued, "Nothing was recorded");

    // Nor attribute them to another execution
    ArtifactMetadata misattributed;
    misattributed.artifactId = "game.zip";
    misattributed.executionId = "exe_somebody_else";
    bool rejectedExecution = false;
    try finishExecution(stores, "fp1", id, ExecutionStatus.succeeded, 0, null, [misattributed]);
    catch (ForeignArtifactException e) rejectedExecution = e.msg.canFind("exe_somebody_else") && e.msg.canFind(id);
    assert(rejectedExecution);
    assert(stores.executions.get(id).isNull && activeAt(stores).status == ExecutionStatus.queued, "Nothing was recorded");

    ArtifactMetadata unnamed;
    unnamed.artifactId = "game.zip";
    ArtifactMetadata own = unnamed;
    own.artifactId = "tools.zip";
    own.taskFingerprint = "fp1";
    own.executionId = id;
    const done = finishExecution(stores, "fp1", id, ExecutionStatus.succeeded, 0, null, [unnamed, own]);
    assert(done.artifacts.length == 2 && done.artifacts[0].taskFingerprint == "fp1" && done.artifacts[1].taskFingerprint == "fp1");
    assert(done.artifacts[0].executionId == id && done.artifacts[1].executionId == id);
}

unittest
{
    // A worker's completion: the reported status is the execution's outcome, a worker cannot
    // report an unfinished status, and a completion naming another task is rejected. Each
    // rejection records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);

    foreach (status; [ExecutionStatus.succeeded, ExecutionStatus.failed, ExecutionStatus.cancelled])
    {
        assert(reportedExecutionStatus(status) == status);
    }

    bool rejectedWith(TaskExecutionResult result, string text)
    {
        try completeExecution(stores, "fp1", id, 1, result);
        catch (InvalidCompletionException e) return e.msg.canFind(text);
        return false;
    }

    foreach (status; [ExecutionStatus.running, ExecutionStatus.queued])
    {
        TaskExecutionResult result;
        result.status = status;
        assert(rejectedWith(result, "can report only succeeded, failed or cancelled"));
    }
    TaskExecutionResult otherTask;
    otherTask.taskId = "link";
    otherTask.status = ExecutionStatus.succeeded;
    assert(rejectedWith(otherTask, "names task 'link'"));
    assert(activeAt(stores).status == ExecutionStatus.running && stores.executions.get(id).isNull, "Nothing was recorded");

    // A completion is recorded for the execution named in the route; its outcome, exit code,
    // error and artifacts (stamped with the execution's fingerprint) are kept. Nothing else is
    // written: no cache entry; the open requests of its project are reconciled after the fold
    TaskExecutionResult failed;
    failed.taskId = "compile";
    failed.status = ExecutionStatus.failed;
    failed.exitCode = 2;
    failed.errorMessage = "make: *** [all] Error 2";
    failed.producedArtifacts = [ArtifactMetadata("partial.log")];
    const done = completeExecution(stores, "fp1", id, 1, failed, fixedNow());
    assert(done.id == id && done.status == ExecutionStatus.failed && done.exitCode == 2);
    assert(done.errorMessage == "make: *** [all] Error 2" && done.finishedAt == fixedNow());
    assert(done.artifacts.length == 1 && done.artifacts[0].taskFingerprint == "fp1");
    assert(done.worker == "w1" && done.startedAt == fixedNow() && done.createdAt == "2026-10-16T10:00:00Z");
    assert(done.definitionId.length > 0 && done.inputs == sampleClaim(stores).inputs);
    assert(stores.executions.get(id).get.status == ExecutionStatus.failed);

    // A task id is optional; a duplicate is rejected as stale, an unknown execution as unknown
    bool unknownExecution = false;
    try completeExecution(stores, "fp1", "exe_nope", 1, failed);
    catch (UnknownExecutionException e) unknownExecution = e.msg.canFind("exe_nope");
    assert(unknownExecution);
    TaskExecutionResult again;
    again.status = ExecutionStatus.succeeded;
    bool stale = false;
    try completeExecution(stores, "fp1", id, 1, again);
    catch (StaleCompletionException e) stale = e.msg.canFind(id);
    assert(stale && stores.executions.get(id).get.status == ExecutionStatus.failed);
}

unittest
{
    // Two completions of one execution race through completeExecution: the second passes its
    // checks, then loses to the first and is rejected without overwriting it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    TaskExecutionResult succeeded;
    succeeded.taskId = "compile";
    succeeded.status = ExecutionStatus.succeeded;
    TaskExecutionResult cancelled = succeeded;
    cancelled.status = ExecutionStatus.cancelled;

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { completeExecution(stores, "fp1", id, 1, succeeded, fixedNow()); };
    bool rejected = false;
    try completeExecution(racing, "fp1", id, 1, cancelled, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
}

unittest
{
    // The attempt an execution is on, for the routes that check a worker's token: the active
    // execution's, then the finished one's, and none for an execution the fingerprint never had
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    assert(currentAttempt(stores, "fp1", id).get == 0);
    startExecution(stores, "fp1", "w1", testLease, fixedNow());
    assert(currentAttempt(stores, "fp1", id).get == 1);
    completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow());
    assert(currentAttempt(stores, "fp1", id).get == 1);
    assert(currentAttempt(stores, "fp1", "exe_missing").isNull && currentAttempt(stores, "fp_nowhere", id).isNull);
}

unittest
{
    // A finished execution is never written again: the record stays at version 1, unchanged, through
    // everything that can still reach its fingerprint (heartbeats, expiries, completions, and a
    // newer execution's whole life)
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    auto done = completeExecution(stores, "fp1", id, 1, succeededResult(), fixedNow());
    auto stored = stores.executions.get(id).get;
    assert(stored.version_ == 1 && stored.value == done);

    heartbeatExecution(stores, "fp1", id, 1, testLease);
    expireLease(stores, "fp1", 3, later(1.hours));
    bool lateRejected = false;
    try completeExecution(stores, "fp1", id, 1, succeededResult());
    catch (StaleCompletionException e) lateRejected = true;
    assert(lateRejected);
    const next = queueExecution(stores);
    startExecution(stores, "fp1", "w2", testLease, fixedNow());
    completeExecution(stores, "fp1", next, 1, succeededResult(), later(2.minutes));
    assert(stores.executions.get(id).get.version_ == 1 && stores.executions.get(id).get.value == done);
    assert(stores.executions.get(next).get.version_ == 1);
}

version (unittest)
{
    /// Requests "ra" (chain "a") and "rb" (chain "b"), both building compile at one fingerprint,
    /// each reconciled: "ra" won the claim and dispatched, "rb" lost it and waits. Both are open.
    private string requestsSharingFingerprint(StateStores stores)
    {
        createChain(stores, "a");
        createChain(stores, "b");
        intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
        intake(stores, "b", "rb", ["compile"], "2026-10-20T10:00:01Z");
        auto reconciler = reconcilerOf(stores);
        reconciler.reconcile("ra");
        reconciler.reconcile("rb");
        const fingerprint = fingerprintNow(stores, "a", "compile");
        assert(fingerprintNow(stores, "b", "compile") == fingerprint);
        assert(stores.requests.get("ra").get.state.outcome == RequestOutcome.open && stores.requests.get("rb").get.state.outcome == RequestOutcome.open);
        return fingerprint;
    }
}

unittest
{
    // Requests A and B share a fingerprint and B lost the claim: A's execution ending in any way
    // (success, failure, cancel) folds into the ledger, and the completion advances both requests
    foreach (status; [ExecutionStatus.succeeded, ExecutionStatus.failed, ExecutionStatus.cancelled])
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        const fingerprint = requestsSharingFingerprint(stores);
        const id = activeAt(stores, fingerprint).id;

        assert(!startExecution(stores, fingerprint, "w1", testLease, fixedNow()).isNull);
        TaskExecutionResult result;
        result.status = status;
        result.errorMessage = status == ExecutionStatus.succeeded ? null : "stopped";
        completeExecution(stores, fingerprint, id, 1, result, fixedNow());

        auto ledger = stores.ledgers.get(fingerprint).get;
        assert(ledger.active.isNull, "The outcome was folded");
        assert(ledger.lastSuccessExecutionId == (status == ExecutionStatus.succeeded ? id : ""));
        assert(ledger.lastStoppedExecutionId == (status == ExecutionStatus.succeeded ? "" : id));

        const expected = status == ExecutionStatus.succeeded ? RequestTaskStatus.succeeded
            : status == ExecutionStatus.failed ? RequestTaskStatus.failed : RequestTaskStatus.cancelled;
        foreach (requestId; ["ra", "rb"])
        {
            const state = stores.requests.get(requestId).get.value;
            assert(state.state.outcome != RequestOutcome.open && taskOf(state, "compile").status == expected, requestId);
        }
    }
}

unittest
{
    // A coordinator restart between the write of the execution's record and the fold: the
    // execution is finished but unfolded. After the restart, reconciling settles the ledger
    // (completing the fold) and sees the outcome
    auto documents = new InMemoryDocumentStore();
    auto before = new StateStores(documents);
    const fingerprint = requestsSharingFingerprint(before);
    const id = activeAt(before, fingerprint).id;
    before.executions.create(endedExecution(fingerprint, activeAt(before, fingerprint), ExecutionStatus.succeeded, fixedNow()));
    // ... and the process dies before the fold

    auto after = new StateStores(documents.restart());
    assert(after.ledgers.get(fingerprint).get.active.get.id == id, "Nothing was folded");

    auto reconciled = reconcilerOf(after).reconcile("rb");
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.succeeded && reconciled.request.state.outcome == RequestOutcome.succeeded);
    assert(after.ledgers.get(fingerprint).get.active.isNull && after.ledgers.get(fingerprint).get.lastSuccessExecutionId == id);

    // Folding again is idempotent
    assert(after.ledgers.fold(after.executions.get(id).get.value).outcome == FoldOutcome.alreadyFolded);
}

unittest
{
    // The fold failing after the execution's record is written: the completion answers
    // OutcomeNotFoldedException (the cause chained), the execution stays finished and a resent
    // completion is stale; the next read of the ledger completes the fold
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    // The completion's writes: 1 the record, 2 the fold
    beforeWrite(interleaving, 2, () { throw new Exception("The fold's write is lost"); });
    TaskExecutionResult result = succeededResult();
    bool unfolded = false;
    try completeExecution(racing, "fp1", id, 1, result, fixedNow());
    catch (OutcomeNotFoldedException e)
    {
        unfolded = e.executionId == id && e.next !is null && e.next.msg == "The fold's write is lost"
            && e.msg.canFind(id) && e.msg.canFind("is rejected as stale");
    }
    assert(unfolded);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
    assert(activeAt(stores).id == id, "The ledger was not folded");

    bool stale = false;
    try completeExecution(stores, "fp1", id, 1, result, fixedNow());
    catch (StaleCompletionException) stale = true;
    assert(stale);
    assert(stores.ledgers.get("fp1").get.active.isNull && stores.ledgers.get("fp1").get.lastSuccessExecutionId == id,
        "The resent completion completed the fold of the one that won");
}

unittest
{
    // A completion whose wake is lost (the reconcile's write of the request state fails) still
    // succeeds: the outcome is recorded and folded, and the request stays open until a later
    // reconcile advances it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    createChain(stores, "a");
    intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
    reconcilerOf(stores).reconcile("ra");
    const fingerprint = fingerprintNow(stores, "a", "compile");
    const id = activeAt(stores, fingerprint).id;
    assert(!startExecution(stores, fingerprint, "w1", testLease, fixedNow()).isNull);

    // The completion's writes: the record, the fold, then the reconcile's commit
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    bool wakeLost = false;
    beforeWrite(interleaving, 3, () { wakeLost = true; throw new Exception("The wake's write is lost"); });
    const done = completeExecution(racing, fingerprint, id, 1, succeededResult(), fixedNow());
    assert(wakeLost, "The wake's write was attempted and failed");
    assert(done.status == ExecutionStatus.succeeded, "The completion succeeds");
    assert(stores.ledgers.get(fingerprint).get.lastSuccessExecutionId == id, "The outcome is folded");
    assert(stores.requests.get("ra").get.state.outcome == RequestOutcome.open, "The lost wake leaves the request open");

    // A later reconcile, as the sweep runs it, advances the request
    auto reconciled = reconcilerOf(stores).reconcile("ra");
    assert(reconciled.committed && reconciled.request.state.outcome == RequestOutcome.succeeded);
    assert(taskOf(reconciled.request, "compile").status == RequestTaskStatus.succeeded);
}

version (unittest)
{
    /// A document store whose index queries fail while `failQueries` is set.
    private final class QueryFailingStore : InMemoryDocumentStore
    {
        bool failQueries;

        override QueryPage query(string collection, const IndexQuery lookup)
        {
            if (failQueries) throw new Exception("The index is unavailable");
            return super.query(collection, lookup);
        }
    }

    /// Request "ra" over chain "a", reconciled, with its compile execution running as attempt 1.
    /// Returns the execution's fingerprint and id.
    private string[2] runningRequest(StateStores stores)
    {
        createChain(stores, "a");
        intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
        reconcilerOf(stores).reconcile("ra");
        const fingerprint = fingerprintNow(stores, "a", "compile");
        const id = activeAt(stores, fingerprint).id;
        assert(!startExecution(stores, fingerprint, "w1", testLease, fixedNow()).isNull);
        return [fingerprint, id];
    }
}

unittest
{
    // A wake whose listing of open requests fails is logged, and the completion still succeeds:
    // the outcome is recorded and folded, and the request stays open until a later reconcile
    auto documents = new QueryFailingStore();
    auto stores = new StateStores(documents);
    const running = runningRequest(stores);

    documents.failQueries = true;
    const done = completeExecution(stores, running[0], running[1], 1, succeededResult(), fixedNow());
    assert(done.status == ExecutionStatus.succeeded, "The completion succeeds");
    assert(stores.ledgers.get(running[0]).get.lastSuccessExecutionId == running[1], "The outcome is folded");
    assert(stores.requests.get("ra").get.state.outcome == RequestOutcome.open, "The wake did not run");

    documents.failQueries = false;
    auto reconciled = reconcilerOf(stores).reconcile("ra");
    assert(reconciled.committed && reconciled.request.state.outcome == RequestOutcome.succeeded);
}

unittest
{
    // A lease expiry that fails the execution (the attempt limit is reached) takes the same end as
    // a completion, so its wake advances the open request with no reconcile
    auto stores = new StateStores(new InMemoryDocumentStore());
    const running = runningRequest(stores);

    auto lost = expireLease(stores, running[0], 1, later(2.minutes));
    assert(lost.disposition == LostLeaseDisposition.failed);
    const state = stores.requests.get("ra").get.value;
    assert(state.state.outcome == RequestOutcome.failed && taskOf(state, "compile").status == RequestTaskStatus.failed);
}

unittest
{
    // An expiry settles the ledger first: a running execution whose record already exists (its
    // ender crashed before the fold) is folded, not requeued or counted as lost
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    stores.executions.create(endedExecution("fp1", activeAt(stores), ExecutionStatus.succeeded, fixedNow()));

    assert(expireLease(stores, "fp1", 3, later(1.hours)).disposition == LostLeaseDisposition.nothingToDo);
    auto ledger = stores.ledgers.get("fp1").get;
    assert(ledger.active.isNull && ledger.lastSuccessExecutionId == id && ledger.stopSeq == 0);
    assert(stores.executions.get(id).get.expiredLeases == 0);
}

unittest
{
    // A process that dies after counting a lost lease and before writing the failed record leaves
    // the execution running with the count. The next expiry decides the same (it fails) and counts
    // the lease again, which the message and the record carry
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto crashing = new StateStores(interleaving);
    // The expiry's writes: 1 counts the lost lease, 2 writes the record, which fails
    beforeWrite(interleaving, 2, () { throw new Exception("The process died"); });
    bool died = false;
    try expireLease(crashing, "fp1", 1, later(1.hours));
    catch (Exception e) died = e.msg == "The process died";
    assert(died);
    assert(activeAt(stores).status == ExecutionStatus.running && activeAt(stores).expiredLeases == 1);
    assert(stores.executions.get(id).isNull);

    auto again = expireLease(stores, "fp1", 1, later(2.hours));
    assert(again.disposition == LostLeaseDisposition.failed);
    assert(again.expiredLeases == 2 && again.ended.get.expiredLeases == 2);
    assert(again.ended.get.errorMessage.canFind("lease lost 2 times (attempt limit 1)"), again.ended.get.errorMessage);
    assert(stores.ledgers.get("fp1").get.active.isNull && stores.ledgers.get("fp1").get.lastStoppedExecutionId == id);
}

unittest
{
    // An outcome recorded after its execution moved on is noted for the log: the attempt it was
    // decided for and the ledger's. Nothing to note while the execution is as it was read
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    const seen = activeAt(stores);
    assert(supersessionNote(seen, stores.ledgers.get("fp1")).length == 0);

    assert(expireLease(stores, "fp1", 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);
    const requeued = supersessionNote(seen, stores.ledgers.get("fp1"));
    assert(requeued.canFind(id) && requeued.canFind("attempt 1") && requeued.canFind("queued"), requeued);
    assert(claimWork(stores, "w2", testLease, later(2.minutes)).get.attempt == 2);
    const started = supersessionNote(seen, stores.ledgers.get("fp1"));
    assert(started.canFind("attempt 1") && started.canFind("attempt 2") && started.canFind("running"), started);

    completeExecution(stores, "fp1", id, 2, succeededResult(), later(3.minutes));
    assert(supersessionNote(seen, stores.ledgers.get("fp1")).length == 0, "An ended execution is not active");
}

unittest
{
    // Five open requests over pages of two, all waiting on one execution: its completion reconciles every one of
    // them, so none is left open
    auto stores = new StateStores(new InMemoryDocumentStore(), 2);
    createChain(stores, "a");
    foreach (ulong i; 0 .. 5) intake(stores, "a", format("r%s", i), ["compile"], format("2026-10-20T10:00:0%sZ", i));
    reconcilerOf(stores).reconcile("r0");
    const fingerprint = fingerprintNow(stores, "a", "compile");
    assert(!startExecution(stores, fingerprint, "w1", testLease, fixedNow()).isNull);
    const id = stores.ledgers.get(fingerprint).get.active.get.id;

    TaskExecutionResult result;
    result.status = ExecutionStatus.succeeded;
    assert(completeExecution(stores, fingerprint, id, 1, result, fixedNow()).status == ExecutionStatus.succeeded);
    assert(stores.requests.listOpen("game").length == 0);
}
