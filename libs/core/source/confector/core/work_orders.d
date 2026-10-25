module confector.core.work_orders;

/**
 * The control plane's side of running work (AGENTS.md, "Workers and capacity"): a worker asks for
 * work and is handed a queued execution it holds under a lease, extends the lease while it runs,
 * and reports the outcome. There is no queue service: the execution record is the queue entry.
 *
 * `claimWork` finds queued executions through the active-execution index (discovery, which may
 * lag: work found late is only delayed) and claims one by compare-and-set on the execution
 * (queued to running, one more attempt, a lease expiry, the worker). Of two workers claiming the
 * same execution exactly one wins; the other moves on. The work order is built from the
 * execution's record.
 *
 * `TaskExecution.attempts` counts claims, and the current claim's number is its attempt. A worker's
 * heartbeat, release and completion carry the attempt it was given; one from an earlier attempt
 * (the lease expired and the execution was claimed again, or released) is answered
 * `LeaseAnswer.superseded` or rejected, so a worker that lost its lease cannot extend it or report.
 *
 * A lease that runs out (`expireLease`, which a sweep calls) is an infrastructure failure, counted
 * in `TaskExecution.expiredLeases` (a release is not counted): within the limit the execution
 * goes back to queued; with the limit reached it fails with the reason "lease lost N times" (a failed execution is never a cache hit, and only a user retries
 * it) through the same terminal path as a completion.
 *
 * A completion finishes its execution by compare-and-set, then folds the outcome into the
 * fingerprint's ledger. Every way an execution ends goes through `recordOutcome`, so failed and
 * cancelled executions are folded the same way. The terminal compare-and-set and the fold are
 * separate writes: a crash between them leaves a finished execution that nothing has folded yet,
 * which `LedgerStore.settle` completes. A sweep that does this for every such execution does not
 * exist yet. Then the open requests of the execution's project are reconciled; a reconcile that
 * fails is logged and left to a later one.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.document_collection : Versioned;
import confector.core.execution_dispatcher : ExecutionDispatcher;
import confector.api.model;
import confector.core.request_reconciler : RequestReconciler;
import confector.core.state_stores : StateStores;
import confector.api.document_store : DocumentConflictException;

import core.time : Duration, hours, seconds;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.format : format;
import std.typecons : Nullable, nullable;
import vibe.core.log : logError;

/// How many times a write that loses a compare-and-set to a concurrent writer of the same
/// execution re-reads and retries. Every lost attempt means another write succeeded, so this is
/// reached only under sustained contention on one document.
enum maxWriteAttempts = 10;

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
    /// The execution's attempt number this claim started (`TaskExecution.attempts`).
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
 * The work order for `execution`: its definition (whose steps, environment and declared outputs
 * the runner uses), fingerprint, resolved inputs and repository addresses. Pure.
 */
WorkOrder workOrderFor(in TaskExecution execution) @trusted
{
    WorkOrder order;
    order.executionId = execution.id;
    order.taskNode = cast(TaskNode) execution.definition;
    order.fingerprint = execution.fingerprint;
    order.payload.inputs = (cast(ResolvedInput[]) execution.inputs).dup;
    foreach (name, address; execution.repositoryAddresses) order.payload.repositoryAddresses[name] = address;
    order.timeoutSeconds = execution.definition.timeoutSeconds;
    order.createdAt = execution.createdAt;
    return order;
}

/**
 * Claims the oldest queued execution for worker `workerId`, holding it under a lease of `lease`
 * from `now` (default `utcNow`), and returns its work order and attempt; null if no queued
 * execution could be claimed. Executions are found through the active-execution index and each
 * is claimed by compare-and-set (`startExecution`), so concurrent workers never claim one
 * execution twice: a worker that loses moves on to the next.
 *
 * Throws: InvalidLeaseRequestException if `workerId` is empty or `lease` is not valid; whatever
 * the stores throw.
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
        auto page = stores.executions.listActivePage(ExecutionStatus.queued, cursor);
        foreach (ref candidate; page.items)
        {
            auto started = startExecution(stores.executions, candidate.id, workerId, lease, now);
            if (!started.isNull) return ClaimedWork(workOrderFor(started.get), started.get.attempts).nullable;
        }
        if (page.nextCursor.length == 0) return Nullable!ClaimedWork.init;
        cursor = page.nextCursor;
    }
}

/**
 * Claims execution `executionId` for worker `workerId` by compare-and-set: a queued execution
 * becomes running with one more attempt, held by the worker until `now` plus `lease`. Returns the
 * running execution, or null (writing nothing) if it is not queued: it was claimed by another
 * worker, or it has ended.
 *
 * Throws: UnknownExecutionException if the execution does not exist.
 */
Nullable!TaskExecution startExecution(ExecutionStore executions, string executionId, string workerId, Duration lease, string now)
{
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = executions.get(executionId);
        if (current.isNull)
        {
            throw new UnknownExecutionException(format("Cannot claim execution '%s', which does not exist", executionId));
        }
        if (current.get.status != ExecutionStatus.queued) return Nullable!TaskExecution.init;

        TaskExecution next = current.get.value;
        next.status = ExecutionStatus.running;
        next.attempts += 1;
        next.worker = workerId;
        next.startedAt = now;
        next.leaseExpiresAt = leaseExpiry(now, lease);
        try
        {
            return executions.update(current.get, next).value.nullable;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not claim execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

/// What a worker is told about the execution it holds, by a heartbeat or a release.
enum LeaseAnswer : string
{
    /// The attempt still holds the execution: keep running. A heartbeat extended its lease.
    continue_ = "continue",
    /// A release was accepted: the execution is queued again, for any worker to claim.
    released = "released",
    /// The execution was cancelled: stop the work.
    cancel = "cancel",
    /// The attempt no longer holds the execution (its lease expired and the execution was queued
    /// or claimed again, or it finished): stop the work and report nothing.
    superseded = "superseded"
}

/**
 * Extends the lease of attempt `attempt` of execution `executionId` to `now` (default `utcNow`)
 * plus `lease`, by compare-and-set, and answers what the worker is to do. Writes nothing unless
 * the answer is `continue_`.
 *
 * Throws: UnknownExecutionException if the execution does not exist; InvalidLeaseRequestException
 * if `lease` is not valid.
 */
LeaseAnswer heartbeatExecution(StateStores stores, string executionId, ulong attempt, Duration lease, string now = null)
{
    requireLeaseDuration(lease);
    if (now.length == 0) now = utcNow();
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = readExecution(stores, executionId, "A heartbeat");
        const answer = holderAnswer(current.value, attempt);
        if (answer != LeaseAnswer.continue_) return answer;
        TaskExecution next = current.value;
        next.leaseExpiresAt = leaseExpiry(now, lease);
        try
        {
            stores.executions.update(current, next);
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

/**
 * Gives up attempt `attempt` of execution `executionId`: if that attempt still holds it, the
 * execution goes back to queued at once, for any worker to claim, and the answer is `released`.
 * A release is not a lost lease: it does not count toward the attempt limit. Writes nothing for
 * any other answer.
 *
 * Throws: UnknownExecutionException if the execution does not exist.
 */
LeaseAnswer releaseExecution(StateStores stores, string executionId, ulong attempt)
{
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = readExecution(stores, executionId, "A release");
        const answer = holderAnswer(current.value, attempt);
        if (answer != LeaseAnswer.continue_) return answer;
        try
        {
            stores.executions.update(current, requeued(current.value));
            return LeaseAnswer.released;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not release execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

private Versioned!TaskExecution readExecution(StateStores stores, string executionId, string what)
{
    auto found = stores.executions.get(executionId);
    if (found.isNull)
    {
        throw new UnknownExecutionException(format("%s names execution '%s', which does not exist", what, executionId));
    }
    return found.get;
}

/// What `execution` says to the worker holding attempt `attempt`: continue only if that attempt
/// still holds it.
private LeaseAnswer holderAnswer(in TaskExecution execution, ulong attempt) pure nothrow @safe
{
    if (execution.status == ExecutionStatus.cancelled) return LeaseAnswer.cancel;
    if (execution.status != ExecutionStatus.running || execution.attempts != attempt) return LeaseAnswer.superseded;
    return LeaseAnswer.continue_;
}

private TaskExecution requeued(in TaskExecution execution) @trusted
{
    TaskExecution next = cast(TaskExecution) execution;
    next.status = ExecutionStatus.queued;
    next.worker = null;
    next.startedAt = null;
    next.leaseExpiresAt = null;
    return next;
}

/// What `expireLease` did.
enum LostLeaseDisposition
{
    /// The execution is queued again, for a worker to claim.
    requeued,
    /// The attempts were used up: the execution failed and was folded into its ledger.
    failed,
    /// Nothing was written: the execution is not running, or its lease has not expired.
    nothingToDo
}

/// The result of `expireLease`.
struct LostLease
{
    LostLeaseDisposition disposition;
    /// The execution as it is now.
    TaskExecution execution;
}

/**
 * Expires the lease of execution `executionId` if it is running and its lease ran out by `now`
 * (default `utcNow`): the worker holding it is presumed lost, and the loss is counted in
 * `expiredLeases`. Within the limit the execution goes back to queued, to be claimed as the next
 * attempt; when the count reaches `maxAttempts` it fails with the reason "lease lost N times", by the same terminal compare-and-set and
 * fold as a completion (`recordOutcome`). A task that failed is never retried this way: this
 * handles only attempts that never reported. This is the entry point for a sweep that finds
 * expired leases.
 *
 * Throws: UnknownExecutionException if the execution does not exist; OutcomeNotFoldedException
 * if it failed but the fold did not complete; Exception if `maxAttempts` is 0 or a running
 * execution has no lease expiry.
 */
LostLease expireLease(StateStores stores, string executionId, uint maxAttempts, string now = null)
{
    requireAttemptLimit(maxAttempts);
    if (now.length == 0) now = utcNow();
    foreach (_; 0 .. maxWriteAttempts)
    {
        auto current = readExecution(stores, executionId, "A lease expiry");
        TaskExecution seen = current.value;
        if (seen.status != ExecutionStatus.running) return LostLease(LostLeaseDisposition.nothingToDo, seen);
        if (seen.leaseExpiresAt.length == 0)
        {
            throw new Exception(format("Execution '%s' is running but has no lease expiry", executionId));
        }
        if (SysTime.fromISOExtString(seen.leaseExpiresAt) > SysTime.fromISOExtString(now))
        {
            return LostLease(LostLeaseDisposition.nothingToDo, seen);
        }
        const lost = seen.expiredLeases + 1;
        if (lost >= maxAttempts)
        {
            try
            {
                auto finished = recordOutcome(stores, executionId, ExecutionStatus.failed, 0,
                    format("lease lost %s %s (attempt limit %s)", lost, lost == 1 ? "time" : "times", maxAttempts),
                    null, now, (in Versioned!TaskExecution latest) => latest.version_ == current.version_);
                return LostLease(LostLeaseDisposition.failed, finished);
            }
            catch (StaleCompletionException)
            {
                continue; // It finished or moved on meanwhile: decide again from what is there now
            }
        }
        try
        {
            auto next = requeued(seen);
            next.expiredLeases = lost;
            return LostLease(LostLeaseDisposition.requeued, stores.executions.update(current, next).value);
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not expire the lease of execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
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

private void requireAttemptLimit(uint maxAttempts)
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
 * execution was queued or claimed again, or it was released. Its report is rejected and nothing
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
 * is rejected as stale. Nothing repairs the fold automatically yet: it needs a sweep that settles
 * ledgers (`LedgerStore.settle`).
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
 * Reads execution `executionId`, which a worker reports the outcome of, and checks it is still
 * active. The execution record is the only source of the completion's fingerprint and task: a
 * worker never names them.
 *
 * Throws: StaleCompletionException if it is not active; UnknownExecutionException if
 * `executionId` is empty or names no execution.
 */
TaskExecution requireActiveExecution(StateStores stores, string executionId)
{
    if (executionId.length == 0)
    {
        throw new UnknownExecutionException("A completion must name the execution it completes");
    }
    auto found = stores.executions.get(executionId);
    if (found.isNull)
    {
        throw new UnknownExecutionException(format("A completion names execution '%s', which does not exist", executionId));
    }
    if (!ExecutionStore.isActive(found.get.status))
    {
        throw new StaleCompletionException(format(
            "Execution '%s' at fingerprint %s already finished %s; its completion is rejected",
            executionId, found.get.fingerprint, found.get.status));
    }
    return found.get.value;
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
 * The artifacts a worker reported for `execution`, each stamped with the execution's fingerprint
 * and id. An artifact may leave its fingerprint and execution id empty; one naming another
 * fingerprint or another execution is rejected, so a completion cannot place artifacts under a
 * cache key the control plane did not compute or attribute them to another execution. Pure.
 *
 * Throws: ForeignArtifactException if an artifact names a fingerprint or execution other than the
 * execution's.
 */
ArtifactMetadata[] executionArtifacts(in TaskExecution execution, ArtifactMetadata[] reported)
{
    ArtifactMetadata[] own;
    foreach (artifact; reported)
    {
        if (artifact.taskFingerprint.length > 0 && artifact.taskFingerprint != execution.fingerprint)
        {
            throw new ForeignArtifactException(format(
                "Execution '%s' (fingerprint %s) reported artifact '%s' under fingerprint %s; its completion is rejected",
                execution.id, execution.fingerprint, artifact.artifactId, artifact.taskFingerprint));
        }
        if (artifact.executionId.length > 0 && artifact.executionId != execution.id)
        {
            throw new ForeignArtifactException(format(
                "Execution '%s' reported artifact '%s' as produced by execution '%s'; its completion is rejected",
                execution.id, artifact.artifactId, artifact.executionId));
        }
        ArtifactMetadata stamped = artifact;
        stamped.taskFingerprint = execution.fingerprint;
        stamped.executionId = execution.id;
        own ~= stamped;
    }
    return own;
}

/**
 * Records the outcome a worker reported for execution `executionId` (`status`, which must be
 * terminal, with its exit code, error and artifacts, see `executionArtifacts`) by
 * compare-and-set, folds it into the fingerprint's ledger, and returns the finished execution. A terminal execution never changes:
 * a completion that loses the compare-and-set to another one is rejected, not merged.
 *
 * Throws: StaleCompletionException if the execution is not active (see
 * `requireActiveExecution`), including when a concurrent completion finishes it first; ForeignArtifactException if an artifact names another fingerprint;
 * UnknownExecutionException if `executionId` names no execution; Exception if `status` is not
 * terminal; OutcomeNotFoldedException if the execution finished but the fold failed.
 */
TaskExecution finishExecution(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    auto own = executionArtifacts(requireActiveExecution(stores, executionId), artifacts);
    return recordOutcome(stores, executionId, status, exitCode, errorMessage, own, now.length > 0 ? now : utcNow());
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
 * Records the completion a worker reported for execution `executionId` (see `finishExecution`)
 * and returns the finished execution. The execution record is the only source of the
 * fingerprint and task: a `result` naming a different task is rejected. Only the attempt that
 * holds the execution (`result.attempt`) may complete it.
 *
 * A completion finishes the execution, folds it into the fingerprint's ledger and reconciles the
 * open requests of its project; nothing is cached anywhere else.
 * Log lines are not part of a completion: the worker streams them to the execution's log as it
 * runs.
 *
 * Throws: as `finishExecution`, SupersededAttemptException if the execution is not running
 * attempt `result.attempt` (including when that changes while the outcome is recorded), and
 * InvalidCompletionException if `result.status` is not a status a worker can report or
 * `result.taskId` names another task; except for OutcomeNotFoldedException (the outcome is
 * recorded), nothing is recorded.
 */
TaskExecution completeExecution(StateStores stores, string executionId, in TaskExecutionResult result, string now = null)
{
    const status = reportedExecutionStatus(result.status);
    const execution = requireActiveExecution(stores, executionId);
    if (result.taskId.length > 0 && result.taskId != execution.taskId)
    {
        throw new InvalidCompletionException(format("A completion of execution '%s' (task '%s') names task '%s'; it is rejected",
            executionId, execution.taskId, result.taskId));
    }
    if (holderAnswer(execution, result.attempt) != LeaseAnswer.continue_)
    {
        throw new SupersededAttemptException(format(
            "Execution '%s' is %s at attempt %s; a completion from attempt %s is rejected",
            executionId, execution.status, execution.attempts, result.attempt));
    }
    auto own = executionArtifacts(execution, (cast(ArtifactMetadata[]) result.producedArtifacts).dup);
    return recordOutcome(stores, executionId, status, result.exitCode, result.errorMessage, own,
        now.length > 0 ? now : utcNow(),
        (in Versioned!TaskExecution latest) => holderAnswer(latest.value, result.attempt) == LeaseAnswer.continue_);
}

private void requireTerminal(ExecutionStatus status)
{
    if (ExecutionStore.isActive(status))
    {
        throw new Exception(format("A finished execution cannot be %s", status));
    }
}

private TaskExecution recordOutcome(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now, bool delegate(in Versioned!TaskExecution) stillApplies = null)
{
    foreach (attempt; 0 .. maxWriteAttempts)
    {
        auto current = stores.executions.get(executionId);
        if (current.isNull)
        {
            throw new Exception(format("Execution '%s' disappeared while its completion was recorded", executionId));
        }
        if (!ExecutionStore.isActive(current.get.status))
        {
            throw new StaleCompletionException(format(
                "Execution '%s' finished %s while this completion (%s) was recorded; its completion is rejected",
                executionId, current.get.status, status));
        }
        // An outcome decided from an earlier read (an expired lease, an attempt's completion) must
        // not land on an execution that has moved on since
        if (stillApplies !is null && !stillApplies(current.get))
        {
            throw new StaleCompletionException(format(
                "Execution '%s' changed while this outcome (%s) was recorded; the outcome is rejected", executionId, status));
        }
        TaskExecution next = current.get.value;
        next.status = status;
        next.exitCode = exitCode;
        next.errorMessage = errorMessage;
        next.artifacts = artifacts;
        next.finishedAt = now;
        TaskExecution finished;
        try
        {
            finished = stores.executions.update(current.get, next).value;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
        // Only the winner of the terminal compare-and-set gets here. The execution is final: a
        // failure from here on cannot undo it, so it is reported as such, not as a failed
        // completion.
        try
        {
            stores.ledgers.fold(finished);
        }
        catch (Exception e)
        {
            throw new OutcomeNotFoldedException(executionId, format(
                "Execution '%s' (fingerprint %s) finished %s, but folding it into its ledger failed: %s; "
                ~ "the outcome is recorded, so a resent completion is rejected as stale; a sweep must settle the ledger",
                executionId, finished.fingerprint, finished.status, e.msg), e);
        }
        reconcileOpenRequests(stores, finished.projectId, now);
        return finished;
    }
    throw new Exception(format("Could not record the outcome of execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

/**
 * Reconciles the open requests of `projectId` after one of its executions ended, so the requests
 * waiting on it advance now rather than at the next sweep. Each request is reconciled on its own:
 * a failure is logged and left to a later reconcile, and does not undo the outcome, which is
 * already recorded and folded.
 */
private void reconcileOpenRequests(StateStores stores, string projectId, string now)
{
    RequestState[] open;
    try open = stores.requestStates.listOpen(projectId);
    catch (Exception e)
    {
        logError("[work_orders] Could not list the open requests of project '%s': %s", projectId, e.toString());
        return;
    }
    auto reconciler = new RequestReconciler(stores, new ExecutionDispatcher(stores, () => now));
    foreach (state; open)
    {
        try reconciler.reconcile(state.requestId);
        catch (Exception e)
        {
            logError("[work_orders] Could not reconcile request '%s' after an execution of project '%s' ended; a later reconcile will retry it: %s",
                state.requestId, projectId, e.toString());
        }
    }
}


version (unittest)
{
    import confector.core.request_fixtures : beforeWrite, createChain, fingerprintNow, intake, reconcilerOf, taskOf;
    import confector.core.fingerprint_ledger : ClaimOutcome, FoldOutcome;
    import confector.api.document_store : IndexQuery, QueryPage;
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

    /// A queued execution `id` of task "compile" at `fingerprint`, with a full definition.
    private TaskExecution sampleExecution(string id, string fingerprint = "fp1", string createdAt = "2026-10-16T10:00:00Z")
    {
        TaskExecution execution;
        execution.id = id;
        execution.projectId = "p";
        execution.taskId = "compile";
        execution.fingerprint = fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.definition.id = "compile";
        execution.definition.inputs["src"] = repositoryInput("game");
        execution.definition.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
        execution.definition.environment = ["MODE": "release"];
        execution.definition.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];
        execution.definition.timeoutSeconds = 1200;
        execution.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
        execution.repositoryAddresses = ["src": "https://example.test/game.git"];
        execution.createdAt = createdAt;
        return execution;
    }

    /// Dispatches an execution at `fingerprint` as the dispatcher does: claims the fingerprint's
    /// ledger (the claim must win, so any earlier execution there must have been folded) and
    /// records `sampleExecution` under the claimed deterministic id, queued. Returns the id.
    private string queueExecution(StateStores stores, string fingerprint = "fp1", string createdAt = "2026-10-16T10:00:00Z")
    {
        auto ledger = stores.ledgers.get(fingerprint);
        auto claimed = stores.ledgers.claim(fingerprint, ledger.isNull ? 0 : ledger.get.executionSeq);
        assert(claimed.outcome == ClaimOutcome.won, "The test dispatch's claim must win");
        const id = claimed.executionId;
        stores.executions.createIfAbsent(sampleExecution(id, fingerprint, createdAt));
        return id;
    }

    /// As `queueExecution`, then claimed by worker `workerId` (attempt 1) at `fixedNow`.
    private string runningExecution(StateStores stores, string workerId = "w1", string fingerprint = "fp1")
    {
        const id = queueExecution(stores, fingerprint);
        assert(!startExecution(stores.executions, id, workerId, testLease, fixedNow()).isNull);
        return id;
    }

    /// A successful completion of attempt `attempt`.
    private TaskExecutionResult succeededAt(ulong attempt)
    {
        TaskExecutionResult result;
        result.status = ExecutionStatus.succeeded;
        result.attempt = attempt;
        return result;
    }
}

unittest
{
    // A worker claims a queued execution: it gets the full work order, built from the execution's
    // record, and the attempt; the execution is running under the worker's lease, and nothing is
    // left to claim
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);

    auto claimed = claimWork(stores, "w1", testLease, fixedNow());
    assert(!claimed.isNull && claimed.get.attempt == 1);
    auto order = claimed.get.workOrder;
    assert(order.executionId == id && order.taskNode.id == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].config["script"].get!string == "make" && order.timeoutSeconds == 1200);
    assert(order.taskNode.environment == ["MODE": "release"]);
    assert(order.taskNode.outputs.artifacts == [OutputArtifactDecl("game.zip", "out/game.zip")]);
    assert(order.payload.inputs == sampleExecution(id).inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    auto running = stores.executions.get(id).get;
    assert(running.status == ExecutionStatus.running && running.attempts == 1 && running.worker == "w1");
    assert(running.startedAt == fixedNow() && running.leaseExpiresAt == later(testLease));

    assert(claimWork(stores, "w2", testLease, fixedNow()).isNull, "A held execution is not claimed again");
    auto held = stores.executions.get(id).get;
    assert(held.attempts == 1 && held.worker == "w1");

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

    private bool throwsInvalidLease(scope void delegate() action)
    {
        try action();
        catch (InvalidLeaseRequestException) return true;
        return false;
    }
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
    auto held = stores.executions.get(only).get;
    assert(held.status == ExecutionStatus.running && held.attempts == 1 && held.worker == "w1");

    const other = queueExecution(stores, "fp2", "2026-10-16T10:00:05Z");
    const next = queueExecution(stores, "fp3", "2026-10-16T10:00:06Z");
    interleaving.beforeNextWrite = () { first = claimWork(stores, "w1", testLease, fixedNow()); };
    second = claimWork(racing, "w2", testLease, fixedNow());
    assert(first.get.workOrder.executionId == other && second.get.workOrder.executionId == next);
    assert(stores.executions.get(other).get.worker == "w1" && stores.executions.get(next).get.worker == "w2");
}

unittest
{
    // A heartbeat from the attempt that holds the execution extends its lease. A different attempt
    // is superseded, and so is an execution that is queued or finished; a cancelled execution
    // tells the worker to stop. Only a continue writes
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);

    assert(heartbeatExecution(stores, id, 1, testLease, later(30.seconds)) == LeaseAnswer.continue_);
    assert(stores.executions.get(id).get.leaseExpiresAt == later(30.seconds + testLease));

    const lease = stores.executions.get(id).get.leaseExpiresAt;
    assert(heartbeatExecution(stores, id, 2, testLease, later(40.seconds)) == LeaseAnswer.superseded);
    assert(heartbeatExecution(stores, id, 0, testLease, later(40.seconds)) == LeaseAnswer.superseded);
    assert(stores.executions.get(id).get.leaseExpiresAt == lease, "A superseded heartbeat extends nothing");

    assert(releaseExecution(stores, id, 1) == LeaseAnswer.released);
    assert(heartbeatExecution(stores, id, 1, testLease) == LeaseAnswer.superseded, "A queued execution is held by no attempt");

    const cancelledId = runningExecution(stores, "w1", "fp2");
    finishExecution(stores, cancelledId, ExecutionStatus.cancelled, 0, "stopped", null, fixedNow());
    assert(heartbeatExecution(stores, cancelledId, 1, testLease) == LeaseAnswer.cancel);

    const finishedId = runningExecution(stores, "w1", "fp3");
    finishExecution(stores, finishedId, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(heartbeatExecution(stores, finishedId, 1, testLease) == LeaseAnswer.superseded);

    bool unknown = false;
    try heartbeatExecution(stores, "exe_missing", 1, testLease);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_missing'");
    assert(unknown);
    assert(throwsInvalidLease({ heartbeatExecution(stores, id, 1, Duration.zero); }));
}

unittest
{
    // A release requeues the execution at once, for any worker to claim. The releasing attempt is
    // superseded the moment it is claimed again: its heartbeat, release and completion are
    // rejected and change nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);

    assert(releaseExecution(stores, id, 2) == LeaseAnswer.superseded, "Only the holding attempt releases");
    assert(stores.executions.get(id).get.status == ExecutionStatus.running);
    assert(releaseExecution(stores, id, 1) == LeaseAnswer.released);
    auto released = stores.executions.get(id).get;
    assert(released.status == ExecutionStatus.queued && released.attempts == 1);
    assert(released.worker.length == 0 && released.startedAt.length == 0 && released.leaseExpiresAt.length == 0);
    assert(releaseExecution(stores, id, 1) == LeaseAnswer.superseded, "A released attempt does not release again");

    auto again = claimWork(stores, "w2", testLease, fixedNow());
    assert(!again.isNull && again.get.workOrder.executionId == id && again.get.attempt == 2);

    assert(heartbeatExecution(stores, id, 1, testLease) == LeaseAnswer.superseded);
    assert(releaseExecution(stores, id, 1) == LeaseAnswer.superseded);
    bool rejected = false;
    try completeExecution(stores, id, succeededAt(1), fixedNow());
    catch (SupersededAttemptException e) rejected = e.msg.canFind(id) && e.msg.canFind("attempt 1");
    assert(rejected);
    auto held = stores.executions.get(id).get;
    assert(held.status == ExecutionStatus.running && held.attempts == 2 && held.worker == "w2");

    assert(completeExecution(stores, id, succeededAt(2), fixedNow()).status == ExecutionStatus.succeeded);
    assert(releaseExecution(stores, id, 2) == LeaseAnswer.superseded, "A finished execution is not released");

    bool unknown = false;
    try releaseExecution(stores, "exe_missing", 1);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_missing'");
    assert(unknown);
}

unittest
{
    // A completion from a superseded attempt is rejected, loudly, and records nothing: the lease
    // of attempt 1 expired and the execution was claimed again. A completion for an execution no
    // worker holds (queued) is rejected too. The attempt that holds it completes it
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    assert(expireLease(stores, id, 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);

    bool queuedRejected = false;
    try completeExecution(stores, id, succeededAt(1), fixedNow());
    catch (SupersededAttemptException e) queuedRejected = e.msg.canFind("queued");
    assert(queuedRejected && stores.executions.get(id).get.status == ExecutionStatus.queued);

    assert(claimWork(stores, "w2", testLease, later(2.minutes)).get.attempt == 2);
    bool oldRejected = false;
    try completeExecution(stores, id, succeededAt(1), fixedNow());
    catch (StaleCompletionException e) oldRejected = cast(SupersededAttemptException) e !is null;
    assert(oldRejected);
    assert(heartbeatExecution(stores, id, 1, testLease) == LeaseAnswer.superseded);
    assert(stores.executions.get(id).get.status == ExecutionStatus.running);

    assert(completeExecution(stores, id, succeededAt(2), fixedNow()).worker == "w2");
}

unittest
{
    // A completion that loses a race with an expiry and a new claim: it read the execution running
    // attempt 1, then the lease expired and attempt 2 claimed it before the completion was written.
    // It is rejected and attempt 2's execution is untouched
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () {
        assert(expireLease(stores, id, 3, later(2.minutes)).disposition == LostLeaseDisposition.requeued);
        assert(claimWork(stores, "w2", testLease, later(2.minutes)).get.attempt == 2);
    };
    bool rejected = false;
    try completeExecution(racing, id, succeededAt(1), fixedNow());
    catch (StaleCompletionException e) rejected = true;
    assert(rejected);
    auto held = stores.executions.get(id).get;
    assert(held.status == ExecutionStatus.running && held.attempts == 2 && held.worker == "w2");
}

unittest
{
    // A worker lost on every attempt: each expired lease requeues the execution until the
    // attempts are used up. Then the execution fails with "lease lost N times" through the
    // terminal path of a completion: it is folded into the ledger, and the request sees the task
    // failed, not retried
    auto stores = new StateStores(new InMemoryDocumentStore());
    const fingerprint = requestsSharingFingerprint(stores);
    const id = stores.ledgers.get(fingerprint).get.activeExecutionId;

    assert(claimWork(stores, "w1", testLease, fixedNow()).get.attempt == 1);
    assert(expireLease(stores, id, 3, later(testLease - 1.seconds)).disposition == LostLeaseDisposition.nothingToDo,
        "The lease has not run out");
    assert(stores.executions.get(id).get.status == ExecutionStatus.running);

    foreach (lostSoFar; 1 .. 3)
    {
        const at = later(lostSoFar * 10.minutes);
        auto lost = expireLease(stores, id, 3, at);
        assert(lost.disposition == LostLeaseDisposition.requeued && lost.execution.status == ExecutionStatus.queued);
        auto requeued = stores.executions.get(id).get;
        assert(requeued.attempts == lostSoFar && requeued.worker.length == 0 && requeued.leaseExpiresAt.length == 0);
        assert(stores.ledgers.get(fingerprint).get.activeExecutionId == id, "Still the active execution");

        auto retried = claimWork(stores, "w2", testLease, at);
        assert(!retried.isNull && retried.get.attempt == lostSoFar + 1);
        assert(stores.executions.get(id).get.status == ExecutionStatus.running);
    }

    // The third attempt is lost too
    auto last = expireLease(stores, id, 3, later(1.hours));
    assert(last.disposition == LostLeaseDisposition.failed);
    auto failed = stores.executions.get(id).get;
    assert(failed.status == ExecutionStatus.failed && failed.attempts == 3 && failed.finishedAt == later(1.hours));
    assert(failed.errorMessage.canFind("lease lost 3 times"), failed.errorMessage);
    assert(claimWork(stores, "w3", testLease, later(1.hours)).isNull, "A failed execution is not claimed again");
    assert(expireLease(stores, id, 3, later(2.hours)).disposition == LostLeaseDisposition.nothingToDo);

    auto ledger = stores.ledgers.get(fingerprint).get;
    assert(ledger.activeExecutionId.length == 0 && ledger.lastStoppedExecutionId == id);
    auto settled = reconcilerOf(stores).reconcile("rb");
    assert(taskOf(settled.state, "compile").status == RequestTaskStatus.failed && settled.state.outcome == RequestOutcome.failed);
}

unittest
{
    // A release is not a lost lease: any number of releases leave the limit untouched, and the
    // execution fails only when `maxAttempts` leases have expired
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    foreach (round; 1 .. 6)
    {
        assert(claimWork(stores, "w1", testLease, fixedNow()).get.attempt == round);
        assert(releaseExecution(stores, id, round) == LeaseAnswer.released);
    }
    assert(stores.executions.get(id).get.expiredLeases == 0 && stores.executions.get(id).get.attempts == 5);

    foreach (lost; 1 .. 3)
    {
        assert(claimWork(stores, "w1", testLease, later(lost * 10.minutes)).get.attempt == 5 + lost);
        auto expired = expireLease(stores, id, 3, later(lost * 10.minutes + 5.minutes));
        assert(expired.disposition == LostLeaseDisposition.requeued && expired.execution.expiredLeases == lost);
        assert(releaseExecution(stores, id, 5 + lost) == LeaseAnswer.superseded);
    }
    assert(claimWork(stores, "w1", testLease, later(1.hours)).get.attempt == 8);
    auto last = expireLease(stores, id, 3, later(2.hours));
    assert(last.disposition == LostLeaseDisposition.failed);
    assert(last.execution.errorMessage.canFind("lease lost 3 times"), last.execution.errorMessage);
}

unittest
{
    // What an expiry leaves alone: a task that reported failure is never retried by it, an
    // execution that is queued or whose lease runs on is not touched, and a running execution
    // without a lease expiry is a corrupt record that fails loudly
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningExecution(stores);
    finishExecution(stores, id, ExecutionStatus.failed, 2, "make failed", null, fixedNow());

    auto late = expireLease(stores, id, 3, later(1.hours));
    assert(late.disposition == LostLeaseDisposition.nothingToDo);
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.failed && kept.attempts == 1 && kept.errorMessage == "make failed" && kept.exitCode == 2);

    const queuedId = queueExecution(stores, "fp2");
    assert(expireLease(stores, queuedId, 3, later(1.hours)).disposition == LostLeaseDisposition.nothingToDo);
    assert(stores.executions.get(queuedId).get.attempts == 0, "A queued execution is not counted as lost");

    const leaseless = queueExecution(stores, "fp3");
    auto current = stores.executions.get(leaseless).get;
    TaskExecution broken = current.value;
    broken.status = ExecutionStatus.running;
    stores.executions.update(current, broken);
    bool corrupt = false;
    try expireLease(stores, leaseless, 3, later(1.hours));
    catch (Exception e) corrupt = e.msg.canFind("no lease expiry");
    assert(corrupt);

    bool unknown = false;
    try expireLease(stores, "exe_missing", 3);
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_missing'");
    assert(unknown);

    bool noLimit = false;
    try expireLease(stores, id, 0);
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
    interleaving.beforeNextWrite = () { completeExecution(stores, id, succeededAt(1), fixedNow()); };
    auto result = expireLease(racing, id, 1, later(1.hours));
    assert(result.disposition == LostLeaseDisposition.nothingToDo);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
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
    assert(expireLease(stores, id, 5, later(10.minutes)).disposition == LostLeaseDisposition.requeued);
    assert(claimWork(stores, "w2", testLease, later(10.minutes)).get.attempt == 2);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () {
        assert(expireLease(stores, id, 5, later(20.minutes)).disposition == LostLeaseDisposition.requeued);
        assert(claimWork(stores, "w3", testLease, later(20.minutes)).get.attempt == 3);
    };
    auto result = expireLease(racing, id, 2, later(1.hours));
    assert(result.disposition == LostLeaseDisposition.failed);
    assert(result.execution.errorMessage.canFind("lease lost 3 times"), result.execution.errorMessage);
}

unittest
{
    // A failed or cancelled outcome records when it finished even when the caller gives no time
    auto stores = new StateStores(new InMemoryDocumentStore());
    const cancelledId = queueExecution(stores);
    finishExecution(stores, cancelledId, ExecutionStatus.cancelled, 0, "stopped", null);
    auto cancelled = stores.executions.get(cancelledId).get;
    assert(cancelled.status == ExecutionStatus.cancelled && cancelled.finishedAt.length > 0);

    const failedId = queueExecution(stores);
    finishExecution(stores, failedId, ExecutionStatus.failed, 1, "boom", null);
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
    finishExecution(stores, first, ExecutionStatus.failed, 1, "worker lost", null, fixedNow());
    const second = queueExecution(stores);

    bool stale = false;
    try finishExecution(stores, first, ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) stale = e.msg.canFind(first) && e.msg.canFind("failed");
    assert(stale);
    auto kept = stores.executions.get(first).get;
    assert(kept.status == ExecutionStatus.failed && kept.errorMessage == "worker lost");
    assert(stores.executions.get(second).get.status == ExecutionStatus.queued, "The newer execution is untouched");

    finishExecution(stores, second, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(stores.executions.get(second).get.status == ExecutionStatus.succeeded);
}

unittest
{
    // Bug confector-1oj: a completion is identified only by its execution id. One naming no
    // execution, or an execution that does not exist, is rejected loudly and records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);

    bool unnamed = false;
    try finishExecution(stores, "", ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) assert(false, "Not stale: unnamed");
    catch (UnknownExecutionException e) unnamed = e.msg.canFind("must name the execution");
    assert(unnamed);

    bool unknown = false;
    try finishExecution(stores, "exe_unknown", ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) assert(false, "Not stale: unknown");
    catch (UnknownExecutionException e) unknown = e.msg.canFind("'exe_unknown'") && e.msg.canFind("does not exist");
    assert(unknown);

    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");
    assert(stores.executions.get("exe_unknown").isNull);
}

unittest
{
    // A duplicate or late completion of an execution that already finished is rejected loudly:
    // a terminal execution is never overwritten
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    auto produced = [ArtifactMetadata("game.zip")];
    finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, produced, fixedNow());

    foreach (status; [ExecutionStatus.succeeded, ExecutionStatus.failed])
    {
        bool rejected = false;
        try finishExecution(stores, id, status, 7, "late", null, "2026-10-16T11:00:00Z");
        catch (StaleCompletionException e) rejected = e.msg.canFind(id);
        assert(rejected);
    }
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.succeeded && kept.exitCode == 0 && kept.errorMessage.length == 0);
    assert(kept.artifacts.length == 1 && kept.artifacts[0].artifactId == "game.zip" && kept.finishedAt == fixedNow());
}

unittest
{
    // Two completions of one execution racing (a worker reporting twice, or two control-plane
    // instances): both pass the check, exactly one records its outcome by compare-and-set, and
    // the other is rejected loudly instead of overwriting it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, null, fixedNow()); };
    bool rejected = false;
    try finishExecution(racing, id, ExecutionStatus.failed, 1, "duplicate", null, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected, "The loser re-reads, finds it finished, and is rejected");
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.succeeded && kept.errorMessage.length == 0);
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
    try finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, [foreign]);
    catch (ForeignArtifactException e) rejected = e.msg.canFind("fp_somebody_else") && e.msg.canFind(id);
    assert(rejected);
    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");

    // Nor attribute them to another execution
    ArtifactMetadata misattributed;
    misattributed.artifactId = "game.zip";
    misattributed.executionId = "exe_somebody_else";
    bool rejectedExecution = false;
    try finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, [misattributed]);
    catch (ForeignArtifactException e) rejectedExecution = e.msg.canFind("exe_somebody_else") && e.msg.canFind(id);
    assert(rejectedExecution);
    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");

    ArtifactMetadata unnamed;
    unnamed.artifactId = "game.zip";
    ArtifactMetadata own = unnamed;
    own.artifactId = "tools.zip";
    own.taskFingerprint = "fp1";
    own.executionId = id;
    const done = finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, [unnamed, own]);
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
        try completeExecution(stores, id, result);
        catch (InvalidCompletionException e) return e.msg.canFind(text);
        return false;
    }

    foreach (status; [ExecutionStatus.running, ExecutionStatus.queued])
    {
        TaskExecutionResult result;
        result.status = status;
        result.attempt = 1;
        assert(rejectedWith(result, "can report only succeeded, failed or cancelled"));
    }
    TaskExecutionResult otherTask;
    otherTask.taskId = "link";
    otherTask.attempt = 1;
    otherTask.status = ExecutionStatus.succeeded;
    assert(rejectedWith(otherTask, "names task 'link'"));
    assert(stores.executions.get(id).get.status == ExecutionStatus.running, "Nothing was recorded");

    // A completion is recorded on the execution named in the route; its outcome, exit code,
    // error and artifacts (stamped with the execution's fingerprint) are kept. Nothing else is
    // written: no cache entry; the open requests of its project are reconciled after the fold
    TaskExecutionResult failed;
    failed.taskId = "compile";
    failed.attempt = 1;
    failed.status = ExecutionStatus.failed;
    failed.exitCode = 2;
    failed.errorMessage = "make: *** [all] Error 2";
    failed.producedArtifacts = [ArtifactMetadata("partial.log")];
    const done = completeExecution(stores, id, failed, fixedNow());
    assert(done.id == id && done.status == ExecutionStatus.failed && done.exitCode == 2);
    assert(done.errorMessage == "make: *** [all] Error 2" && done.finishedAt == fixedNow());
    assert(done.artifacts.length == 1 && done.artifacts[0].taskFingerprint == "fp1");
    assert(stores.executions.get(id).get.status == ExecutionStatus.failed);

    // A task id is optional; a duplicate is rejected as stale, an unknown execution as unknown
    bool unknownExecution = false;
    try completeExecution(stores, "exe_nope", failed);
    catch (UnknownExecutionException e) unknownExecution = e.msg.canFind("exe_nope");
    assert(unknownExecution);
    TaskExecutionResult again;
    again.status = ExecutionStatus.succeeded;
    again.attempt = 1;
    bool stale = false;
    try completeExecution(stores, id, again);
    catch (StaleCompletionException e) stale = e.msg.canFind(id);
    assert(stale && stores.executions.get(id).get.status == ExecutionStatus.failed);
}

unittest
{
    // Two completions of one execution race through completeExecution: the second passes its
    // checks, then loses the compare-and-set to the first and is rejected without overwriting it
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = runningExecution(stores);

    TaskExecutionResult succeeded;
    succeeded.taskId = "compile";
    succeeded.attempt = 1;
    succeeded.status = ExecutionStatus.succeeded;
    TaskExecutionResult cancelled = succeeded;
    cancelled.status = ExecutionStatus.cancelled;

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { completeExecution(stores, id, succeeded, fixedNow()); };
    bool rejected = false;
    try completeExecution(racing, id, cancelled, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
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
        assert(stores.requestStates.get("ra").get.outcome == RequestOutcome.open && stores.requestStates.get("rb").get.outcome == RequestOutcome.open);
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
        const id = stores.ledgers.get(fingerprint).get.activeExecutionId;

        assert(!startExecution(stores.executions, id, "w1", testLease, fixedNow()).isNull);
        TaskExecutionResult result;
        result.status = status;
        result.attempt = 1;
        result.errorMessage = status == ExecutionStatus.succeeded ? null : "stopped";
        completeExecution(stores, id, result, fixedNow());

        auto ledger = stores.ledgers.get(fingerprint).get;
        assert(ledger.activeExecutionId.length == 0, "The outcome was folded");
        assert(ledger.lastSuccessExecutionId == (status == ExecutionStatus.succeeded ? id : ""));
        assert(ledger.lastStoppedExecutionId == (status == ExecutionStatus.succeeded ? "" : id));

        const expected = status == ExecutionStatus.succeeded ? RequestTaskStatus.succeeded
            : status == ExecutionStatus.failed ? RequestTaskStatus.failed : RequestTaskStatus.cancelled;
        foreach (requestId; ["ra", "rb"])
        {
            const state = stores.requestStates.get(requestId).get.value;
            assert(state.outcome != RequestOutcome.open && taskOf(state, "compile").status == expected, requestId);
        }
    }
}

unittest
{
    // A coordinator restart between the terminal compare-and-set and the fold: the execution is
    // finished but unfolded. After the restart, reconciling settles the ledger (completing the
    // fold) and sees the outcome
    auto documents = new InMemoryDocumentStore();
    auto before = new StateStores(documents);
    const fingerprint = requestsSharingFingerprint(before);
    const id = before.ledgers.get(fingerprint).get.activeExecutionId;
    auto current = before.executions.get(id).get;
    TaskExecution ended = current.value;
    ended.status = ExecutionStatus.succeeded;
    ended.finishedAt = fixedNow();
    before.executions.update(current, ended); // ... and the process dies before the fold

    auto after = new StateStores(documents.restart());
    assert(after.ledgers.get(fingerprint).get.activeExecutionId == id, "Nothing was folded");

    auto reconciled = reconcilerOf(after).reconcile("rb");
    assert(taskOf(reconciled.state, "compile").status == RequestTaskStatus.succeeded && reconciled.state.outcome == RequestOutcome.succeeded);
    assert(after.ledgers.get(fingerprint).get.activeExecutionId.length == 0 && after.ledgers.get(fingerprint).get.lastSuccessExecutionId == id);

    // Folding again is idempotent
    assert(after.ledgers.fold(after.executions.get(id).get.value).outcome == FoldOutcome.alreadyFolded);
}

unittest
{
    // The fold failing after the terminal compare-and-set: here the execution was never claimed on
    // a ledger. The completion answers OutcomeNotFoldedException (the cause chained), the
    // execution stays finished and a resent completion is stale
    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.executions.createIfAbsent(sampleExecution("exe_unclaimed"));
    assert(!startExecution(stores.executions, "exe_unclaimed", "w1", testLease, fixedNow()).isNull);

    TaskExecutionResult result = succeededAt(1);
    bool unfolded = false;
    try completeExecution(stores, "exe_unclaimed", result, fixedNow());
    catch (OutcomeNotFoldedException e)
    {
        unfolded = e.executionId == "exe_unclaimed" && e.next !is null && e.msg.canFind("exe_unclaimed") && e.msg.canFind("is rejected as stale");
    }
    assert(unfolded);
    assert(stores.executions.get("exe_unclaimed").get.status == ExecutionStatus.succeeded);

    bool stale = false;
    try completeExecution(stores, "exe_unclaimed", result, fixedNow());
    catch (StaleCompletionException) stale = true;
    assert(stale);
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
    const id = stores.ledgers.get(fingerprint).get.activeExecutionId;
    assert(!startExecution(stores.executions, id, "w1", testLease, fixedNow()).isNull);

    // The completion's writes: the terminal compare-and-set, the fold, then the reconcile's commit
    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    bool wakeLost = false;
    beforeWrite(interleaving, 3, () { wakeLost = true; throw new Exception("The wake's write is lost"); });
    const done = completeExecution(racing, id, succeededAt(1), fixedNow());
    assert(wakeLost, "The wake's write was attempted and failed");
    assert(done.status == ExecutionStatus.succeeded, "The completion succeeds");
    assert(stores.ledgers.get(fingerprint).get.lastSuccessExecutionId == id, "The outcome is folded");
    assert(stores.requestStates.get("ra").get.outcome == RequestOutcome.open, "The lost wake leaves the request open");

    // A later reconcile, as the sweep runs it, advances the request
    auto reconciled = reconcilerOf(stores).reconcile("ra");
    assert(reconciled.committed && reconciled.state.outcome == RequestOutcome.succeeded);
    assert(taskOf(reconciled.state, "compile").status == RequestTaskStatus.succeeded);
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
    /// Returns the execution's id.
    private string runningRequest(StateStores stores)
    {
        createChain(stores, "a");
        intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
        reconcilerOf(stores).reconcile("ra");
        const fingerprint = fingerprintNow(stores, "a", "compile");
        const id = stores.ledgers.get(fingerprint).get.activeExecutionId;
        assert(!startExecution(stores.executions, id, "w1", testLease, fixedNow()).isNull);
        return id;
    }
}

unittest
{
    // A wake whose listing of open requests fails is logged, and the completion still succeeds:
    // the outcome is recorded and folded, and the request stays open until a later reconcile
    auto documents = new QueryFailingStore();
    auto stores = new StateStores(documents);
    const id = runningRequest(stores);

    documents.failQueries = true;
    const done = completeExecution(stores, id, succeededAt(1), fixedNow());
    assert(done.status == ExecutionStatus.succeeded, "The completion succeeds");
    assert(stores.ledgers.get(fingerprintNow(stores, "a", "compile")).get.lastSuccessExecutionId == id, "The outcome is folded");
    assert(stores.requestStates.get("ra").get.outcome == RequestOutcome.open, "The wake did not run");

    documents.failQueries = false;
    auto reconciled = reconcilerOf(stores).reconcile("ra");
    assert(reconciled.committed && reconciled.state.outcome == RequestOutcome.succeeded);
}

unittest
{
    // A lease expiry that fails the execution (the attempt limit is reached) takes the same
    // terminal path as a completion, so its wake advances the open request with no reconcile
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = runningRequest(stores);

    auto lost = expireLease(stores, id, 1, later(2.minutes));
    assert(lost.disposition == LostLeaseDisposition.failed);
    const state = stores.requestStates.get("ra").get.value;
    assert(state.outcome == RequestOutcome.failed && taskOf(state, "compile").status == RequestTaskStatus.failed);
}
