module confector.core.work_orders;

/**
 * The receiving side of dispatch (design records: beads confector-z7z.2 and confector-z7z.4):
 * turning a DispatchMessage, which names only an execution, into the work order a worker runs,
 * and recording the worker's outcome on the execution.
 *
 * Workers that receive through the control plane (`/queue/receive`) get work orders built here
 * from the execution's record, so the dispatch queue only ever carries ids. Receiving starts the
 * execution by compare-and-set (queued to running), which makes duplicate messages harmless: a
 * message for an execution that already finished, or that a worker already holds, is
 * acknowledged and dropped. A message delivered again after its lease expired (its worker was
 * lost) starts another attempt of the same execution; the attempt limit and lease sweep are bead
 * confector-z7z.23.5.
 *
 * A completion finishes its execution by compare-and-set, then folds the outcome into the
 * fingerprint's ledger and marks the chains waiting on it dirty. Every way an execution ends
 * goes through `recordOutcome`, so failed and cancelled executions wake their waiters the same
 * way (lost-lease and cancellation paths must use it too). The terminal compare-and-set, the fold
 * and the wake are separate writes: a crash between them leaves a finished execution that nothing
 * has folded yet, which `LedgerStore.settle` completes and `notifyWaiters` then wakes. A sweep
 * that does this for every such execution does not exist yet.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.document_collection : Versioned;
import confector.core.fingerprint_ledger : LedgerFold;
import confector.api.model;
import confector.core.state_stores : StateStores;
import confector.api.dispatch_queue : DispatchQueue, DispatchQueueUsageException, Lease;
import confector.api.document_store : DocumentConflictException;

import core.time : Duration;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.format : format;
import std.typecons : Nullable;
import vibe.core.log : logError;
import vibe.data.json : Json, deserializeJson;
import vibe.data.serialization : asName = name;

/**
 * The dispatch queue every execution is sent to. Until compute pools exist (bead
 * confector-z7z.31.5) there is one pool, and so one queue.
 */
enum string defaultPoolQueue = "default";

/**
 * The message sent to a pool's dispatch queue: the execution to run. Everything else a worker
 * needs is read from the execution's record when the message is received.
 */
struct DispatchMessage
{
    /// The execution to run (`TaskExecution.id`).
    @asName("execution_id") string executionId;
}

/// How many times a write that loses a compare-and-set to a concurrent writer of the same
/// execution re-reads and retries. Every lost attempt means another write succeeded, so this is
/// reached only under sustained contention on one document.
enum maxWriteAttempts = 10;

/**
 * The current time as the build model records it: ISO 8601 in UTC.
 */
string utcNow()
{
    return Clock.currTime(UTC()).toISOExtString();
}

/**
 * A work order a worker received, with its lease.
 */
struct ReceivedWorkOrder
{
    /// Identifies this delivery; pass it to ack, extend and release.
    string receipt;
    /// How many times the message has been delivered, including this delivery.
    uint receiveCount;
    WorkOrder workOrder;
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
 * Receives up to `maxMessages` messages from `queueName`, leased for `visibility`, and returns the
 * work orders for the executions they name, each started for worker `workerId`. A message whose
 * execution has nothing left to run (finished, or already held by a worker) is acknowledged and
 * left out, so fewer work orders than messages may be returned. `now` gives the current time
 * (default `utcNow`).
 *
 * Throws: DispatchQueueUsageException if `workerId` is empty. Exception if a message is
 * malformed or names an execution that does not exist; the leases not yet returned are released
 * first, so the work is not hidden until they expire.
 */
ReceivedWorkOrder[] receiveWork(StateStores stores, DispatchQueue queue, string queueName, size_t maxMessages,
    Duration visibility, string workerId, string delegate() now = null)
{
    if (workerId.length == 0)
    {
        throw new DispatchQueueUsageException("Receiving work needs the id of the worker receiving it");
    }
    if (now is null) now = () => utcNow();
    auto leases = queue.receive(queueName, maxMessages, visibility);
    ReceivedWorkOrder[] received;
    size_t handled = 0;
    try
    {
        foreach (lease; leases)
        {
            const message = deserializeJson!DispatchMessage(lease.message);
            if (message.executionId.length == 0)
            {
                throw new Exception(format("Dispatch message %s on queue '%s' names no execution", lease.message.toString(), queueName));
            }
            auto started = startExecution(stores.executions, message.executionId, lease.receiveCount, workerId, now());
            ++handled;
            if (started.isNull)
            {
                queue.ack(queueName, lease.receipt);
                continue;
            }
            received ~= ReceivedWorkOrder(lease.receipt, lease.receiveCount, workOrderFor(started.get));
        }
    }
    catch (Exception e)
    {
        // The caller never sees these leases: give them back rather than hide the work until
        // they expire. Best effort; the original error is what the caller needs.
        foreach (lease; leases[handled .. $])
        {
            try queue.release(queueName, lease.receipt);
            catch (Exception releaseError) logError("[work_orders] Failed to release receipt '%s' after a failed receive: %s", lease.receipt, releaseError.msg);
        }
        foreach (ref order; received)
        {
            try queue.release(queueName, order.receipt);
            catch (Exception releaseError) logError("[work_orders] Failed to release receipt '%s' after a failed receive: %s", order.receipt, releaseError.msg);
        }
        throw e;
    }
    return received;
}

/**
 * Starts execution `executionId` for worker `workerId`, delivered for the `receiveCount`th time,
 * by compare-and-set: a queued execution becomes running with one more attempt; a running one
 * delivered again (its lease expired, so its worker is presumed lost) starts another attempt.
 * Returns null, writing nothing, if there is nothing to run: the execution finished, or a worker
 * holds it and this is a duplicate message's first delivery.
 *
 * Throws: Exception if the execution does not exist.
 */
Nullable!TaskExecution startExecution(ExecutionStore executions, string executionId, uint receiveCount, string workerId, string now)
{
    foreach (attempt; 0 .. maxWriteAttempts)
    {
        auto current = executions.get(executionId);
        if (current.isNull)
        {
            throw new Exception(format("A dispatch message names execution '%s', which does not exist", executionId));
        }
        const status = current.get.status;
        if (!ExecutionStore.isActive(status)) return Nullable!TaskExecution.init;
        if (status == ExecutionStatus.running && receiveCount <= 1) return Nullable!TaskExecution.init;

        TaskExecution next = current.get.value;
        next.status = ExecutionStatus.running;
        next.attempts += 1;
        next.worker = workerId;
        next.startedAt = now;
        if (next.sentAt.length == 0) next.sentAt = now;
        try
        {
            return Nullable!TaskExecution(executions.update(current.get, next).value);
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not start execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
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
 * A completion finished its execution, but a step after that failed: folding the outcome into
 * the fingerprint's ledger, or waking the chains waiting on it (the message says which; `next`
 * is the failure). The outcome is recorded and final, so resending the completion is rejected as
 * stale. Nothing repairs the fold or the wake automatically yet: it needs a sweep that settles
 * ledgers (`LedgerStore.settle`) and wakes their waiters (`notifyWaiters`).
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
 * Some of the chains waiting on a fingerprint could not be woken (`notifyWaiters`). The others
 * were, and their notices are cleared; the failed chains' notices stay on the ledger.
 */
class WakeFailedException : Exception
{
    string fingerprint;
    /// One line per chain that could not be marked dirty, with the cause.
    string[] failures;

    /// `cause`, when exactly one chain failed, is that failure.
    this(string fingerprint, string[] failures, Throwable cause = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(format("Could not wake every chain waiting on fingerprint %s; their notices stay on its ledger:\n- %-(%s\n- %)",
            fingerprint, failures), file, line, cause);
        this.fingerprint = fingerprint;
        this.failures = failures;
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
 * compare-and-set, folds it into the fingerprint's ledger and wakes the chains waiting on it
 * (see `foldAndNotify`), and returns the finished execution. A terminal execution never changes:
 * a completion that loses the compare-and-set to another one is rejected, not merged.
 *
 * Throws: StaleCompletionException if the execution is not active (see
 * `requireActiveExecution`), including when a concurrent completion finishes it first; ForeignArtifactException if an artifact names another fingerprint;
 * UnknownExecutionException if `executionId` names no execution; Exception if `status` is not
 * terminal; OutcomeNotFoldedException if the execution finished but the fold or the wake failed.
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
 * fingerprint and task: a `result` naming a different task is rejected.
 *
 * A completion finishes the execution, folds it into the fingerprint's ledger and marks the
 * chains waiting on it dirty; nothing is cached anywhere else and no chain is re-evaluated here.
 * Log lines are not part of a completion: the worker streams them to the execution's log as it
 * runs.
 *
 * Throws: as `finishExecution`, and InvalidCompletionException if `result.status` is not a
 * status a worker can report or `result.taskId` names another task; except for
 * OutcomeNotFoldedException (the outcome is recorded), nothing is recorded.
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
    auto own = executionArtifacts(execution, (cast(ArtifactMetadata[]) result.producedArtifacts).dup);
    return recordOutcome(stores, executionId, status, result.exitCode, result.errorMessage, own,
        now.length > 0 ? now : utcNow());
}

/**
 * Folds `finished`, a terminal execution, into its fingerprint's ledger and wakes every chain the
 * ledger holds a notice for (`notifyWaiters`), including notices of earlier folds that were never
 * drained. Idempotent, so whoever finds a finished execution unfolded may call it.
 *
 * Throws: InvalidStateTransitionException if `finished` is not terminal or was never claimed on a
 * ledger (see `LedgerStore.fold`); WakeFailedException if some waiting chains could not be
 * marked dirty (see `notifyWaiters`); whatever the stores throw.
 */
LedgerFold foldAndNotify(StateStores stores, in TaskExecution finished)
{
    auto folded = stores.ledgers.fold(finished);
    notifyWaiters(stores, finished.fingerprint, folded.ledger.pendingNotify);
    return folded;
}

/**
 * Marks the chain of each of `notices`, taken from the ledger of `fingerprint`, dirty, then
 * removes the notices from the ledger. A chain is marked before its notice is removed, so a crash
 * in between wakes it twice rather than never.
 *
 * Every notice is attempted: a chain that cannot be marked (it has no chain state, say) does not
 * stop the others. The notices of the chains that were marked are removed; the failed ones stay
 * on the ledger.
 *
 * Throws: WakeFailedException if some chains could not be marked (repair them, then notify
 * again); whatever clearing the notices throws.
 */
void notifyWaiters(StateStores stores, string fingerprint, in LedgerNotice[] notices)
{
    LedgerNotice[] marked;
    string[] failures;
    Exception only;
    foreach (ref notice; notices)
    {
        try
        {
            stores.chainStates.markDirty(notice.chainId);
            marked ~= notice;
        }
        catch (Exception e)
        {
            only = e;
            failures ~= format("chain '%s': %s", notice.chainId, e.msg);
        }
    }
    stores.ledgers.clearNotified(fingerprint, marked);
    if (failures.length > 0) throw new WakeFailedException(fingerprint, failures, failures.length == 1 ? only : null);
}

private void requireTerminal(ExecutionStatus status)
{
    if (ExecutionStore.isActive(status))
    {
        throw new Exception(format("A finished execution cannot be %s", status));
    }
}

private TaskExecution recordOutcome(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now)
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
        LedgerFold folded;
        try
        {
            folded = stores.ledgers.fold(finished);
        }
        catch (Exception e)
        {
            throw new OutcomeNotFoldedException(executionId, format(
                "Execution '%s' (fingerprint %s) finished %s, but folding it into its ledger failed: %s; "
                ~ "the outcome is recorded, so a resent completion is rejected as stale; a sweep must settle the ledger and wake its waiters",
                executionId, finished.fingerprint, finished.status, e.msg), e);
        }
        try
        {
            notifyWaiters(stores, finished.fingerprint, folded.ledger.pendingNotify);
        }
        catch (Exception e)
        {
            throw new OutcomeNotFoldedException(executionId, format(
                "Execution '%s' (fingerprint %s) finished %s and was folded into its ledger, but waking its waiters failed: %s; "
                ~ "the outcome is recorded, so a resent completion is rejected as stale; a sweep must wake the waiters",
                executionId, finished.fingerprint, finished.status, e.msg), e);
        }
        return finished;
    }
    throw new Exception(format("Could not record the outcome of execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

version (unittest)
{
    import confector.core.chain_fixtures : createChain, createChainOnly, fingerprintNow, intake, reconcilerOf, taskOf;
    import confector.core.fingerprint_ledger : ClaimOutcome, FoldOutcome;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import core.time : hours;
    import std.algorithm.searching : canFind;
    import vibe.data.json : serializeToJson;

    private string fixedNow() { return "2026-10-16T10:00:02Z"; }

    /// A queued execution `id` of task "compile" at `fingerprint`, with a full definition.
    private TaskExecution sampleExecution(string id, string fingerprint = "fp1")
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
        execution.createdAt = "2026-10-16T10:00:00Z";
        return execution;
    }

    /// Dispatches an execution at `fingerprint` as the dispatcher does: claims the fingerprint's
    /// ledger (the claim must win, so any earlier execution there must have been folded), records
    /// `sampleExecution` under the claimed deterministic id and, given a queue, sends its message
    /// to the default pool queue. Returns the id.
    private string queueExecution(StateStores stores, DispatchQueue queue = null, string fingerprint = "fp1")
    {
        auto ledger = stores.ledgers.get(fingerprint);
        auto claimed = stores.ledgers.claim(fingerprint, ledger.isNull ? 0 : ledger.get.executionSeq);
        assert(claimed.outcome == ClaimOutcome.won, "The test dispatch's claim must win");
        const id = claimed.executionId;
        stores.executions.createIfAbsent(sampleExecution(id, fingerprint));
        if (queue !is null)
        {
            queue.ensureQueue(defaultPoolQueue);
            queue.send(defaultPoolQueue, serializeToJson(DispatchMessage(id)));
        }
        return id;
    }
}

unittest
{
    // A worker receives the full work order, built from the execution the message names; the
    // execution starts. A duplicate message for it is acknowledged and dropped; a redelivery after
    // the lease expired starts another attempt
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    const id = queueExecution(stores, queue);

    auto received = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w1", () => fixedNow());
    assert(received.length == 1 && received[0].receiveCount == 1);
    auto order = received[0].workOrder;
    assert(order.executionId == id && order.taskNode.id == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].config["script"].get!string == "make" && order.timeoutSeconds == 1200);
    assert(order.taskNode.environment == ["MODE": "release"]);
    assert(order.taskNode.outputs.artifacts == [OutputArtifactDecl("game.zip", "out/game.zip")]);
    assert(order.payload.inputs == sampleExecution(id).inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    auto running = stores.executions.get(id).get;
    assert(running.status == ExecutionStatus.running && running.attempts == 1 && running.worker == "w1");
    assert(running.startedAt == fixedNow() && running.sentAt == fixedNow(), "Receiving records the send it proves");

    // A second message for the running execution (it was sent again) is dropped
    queue.send(defaultPoolQueue, serializeToJson(DispatchMessage(id)));
    assert(receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w2").length == 0);
    assert(queue.receive(defaultPoolQueue, 10, 1.hours).length == 0, "The duplicate was acknowledged");
    assert(stores.executions.get(id).get.attempts == 1);

    // The first worker is lost: its message is delivered again and starts a second attempt
    queue.release(defaultPoolQueue, received[0].receipt);
    auto again = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w3");
    assert(again.length == 1 && again[0].receiveCount == 2 && again[0].workOrder.executionId == id);
    assert(stores.executions.get(id).get.attempts == 2 && stores.executions.get(id).get.worker == "w3");

    // A completion must be a finished status
    bool threw = false;
    try finishExecution(stores, id, ExecutionStatus.running, 0, null, null);
    catch (Exception e) threw = true;
    assert(threw && stores.executions.get(id).get.status == ExecutionStatus.running);

    // The outcome is recorded; a late message for it is dropped
    const finished = finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(finished.status == ExecutionStatus.succeeded && finished.fingerprint == "fp1");
    auto done = stores.executions.get(id).get;
    assert(done.status == ExecutionStatus.succeeded && done.finishedAt == fixedNow());
    queue.release(defaultPoolQueue, again[0].receipt);
    assert(receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w4").length == 0);
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
    // Two workers receiving duplicate messages for one queued execution at once: exactly one
    // starts it, by compare-and-set
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    Nullable!TaskExecution first;
    interleaving.beforeNextWrite = () { first = startExecution(stores.executions, id, 1, "w1", fixedNow()); };
    auto second = startExecution(racing.executions, id, 1, "w2", fixedNow());
    assert(!first.isNull && first.get.worker == "w1");
    assert(second.isNull, "The loser re-reads, finds it running, and drops its duplicate");
    assert(stores.executions.get(id).get.attempts == 1);
}

unittest
{
    // A message naming no execution, or one that does not exist, fails loudly, and every lease
    // is released rather than hidden
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    queue.ensureQueue(defaultPoolQueue);
    queue.send(defaultPoolQueue, serializeToJson(DispatchMessage("exe_missing")));
    bool threw = false;
    try receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w1");
    catch (Exception e) threw = e.msg.canFind("'exe_missing'");
    assert(threw);
    assert(queue.receive(defaultPoolQueue, 10, 1.hours).length == 1, "The lease was released");

    queue.send(defaultPoolQueue, serializeToJson(DispatchMessage("")));
    threw = false;
    try receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w1");
    catch (Exception e) threw = e.msg.canFind("names no execution");
    assert(threw);

    bool noWorker = false;
    try receiveWork(stores, queue, defaultPoolQueue, 1, 1.hours, "");
    catch (DispatchQueueUsageException) noWorker = true;
    assert(noWorker);
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
    // A completion racing a worker's start: the start lands between the completion's read and
    // its write, so the completion loses one compare-and-set, re-reads the running execution and
    // records its outcome on top of the start. This pins today's behaviour, not the desired end
    // state: completions are not yet fenced by attempt or worker
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores);

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { assert(!startExecution(stores.executions, id, 1, "w1", fixedNow()).isNull); };
    const done = finishExecution(racing, id, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(done.status == ExecutionStatus.succeeded && done.worker == "w1" && done.attempts == 1);
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
    const id = queueExecution(stores);

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
        assert(rejectedWith(result, "can report only succeeded, failed or cancelled"));
    }
    TaskExecutionResult otherTask;
    otherTask.taskId = "link";
    otherTask.status = ExecutionStatus.succeeded;
    assert(rejectedWith(otherTask, "names task 'link'"));
    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");

    // A completion is recorded on the execution named in the route; its outcome, exit code,
    // error and artifacts (stamped with the execution's fingerprint) are kept. Nothing else is
    // written: no cache entry, no chain re-evaluation
    TaskExecutionResult failed;
    failed.taskId = "compile";
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
    const id = queueExecution(stores);

    TaskExecutionResult succeeded;
    succeeded.taskId = "compile";
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
    /// Chains "a" and "b", both building compile at one fingerprint, each reconciled: "a" won the
    /// claim and dispatched, "b" lost it and waits. Both are clean.
    private string chainsSharingFingerprint(StateStores stores, InMemoryDispatchQueue queue)
    {
        createChain(stores, "a");
        createChain(stores, "b");
        intake(stores, "a", "ra", ["compile"], "2026-10-20T10:00:00Z");
        intake(stores, "b", "rb", ["compile"], "2026-10-20T10:00:01Z");
        auto reconciler = reconcilerOf(stores, queue);
        reconciler.reconcile("a");
        reconciler.reconcile("b");
        const fingerprint = fingerprintNow(stores, "a", "compile");
        assert(fingerprintNow(stores, "b", "compile") == fingerprint);
        assert(stores.ledgers.get(fingerprint).get.subscribers == ["a", "b"]);
        assert(!stores.chainStates.get("a").get.dirty && !stores.chainStates.get("b").get.dirty);
        return fingerprint;
    }
}

unittest
{
    // Chains A and B share a fingerprint and B lost the claim: A's execution ending in any way
    // (success, failure, cancel) folds into the ledger and wakes B, and drains the notices; B then
    // reconciles against the outcome
    foreach (status; [ExecutionStatus.succeeded, ExecutionStatus.failed, ExecutionStatus.cancelled])
    {
        auto stores = new StateStores(new InMemoryDocumentStore());
        const fingerprint = chainsSharingFingerprint(stores, new InMemoryDispatchQueue());
        const id = stores.ledgers.get(fingerprint).get.activeExecutionId;

        TaskExecutionResult result;
        result.status = status;
        result.errorMessage = status == ExecutionStatus.succeeded ? null : "stopped";
        completeExecution(stores, id, result, fixedNow());

        auto ledger = stores.ledgers.get(fingerprint).get;
        assert(ledger.activeExecutionId.length == 0, "The outcome was folded");
        assert(ledger.pendingNotify.length == 0, "The waiters were woken and the notices cleared");
        assert(ledger.lastSuccessExecutionId == (status == ExecutionStatus.succeeded ? id : ""));
        assert(ledger.lastStoppedExecutionId == (status == ExecutionStatus.succeeded ? "" : id));
        assert(stores.chainStates.get("a").get.dirty && stores.chainStates.get("b").get.dirty, "B is woken: " ~ cast(string) status);

        auto woken = reconcilerOf(stores, new InMemoryDispatchQueue()).reconcile("b");
        assert(woken.committed && !woken.state.dirty);
        const expected = status == ExecutionStatus.succeeded ? ChainTaskStatus.succeeded
            : status == ExecutionStatus.failed ? ChainTaskStatus.failed : ChainTaskStatus.cancelled;
        assert(taskOf(woken.state, "compile").status == expected);
    }
}

unittest
{
    // A coordinator restart between the terminal compare-and-set and the fold: the execution is
    // finished but unfolded and nobody is woken. After the restart, settling the ledger completes
    // the fold, and notifying its waiters wakes B
    auto documents = new InMemoryDocumentStore();
    auto before = new StateStores(documents);
    const fingerprint = chainsSharingFingerprint(before, new InMemoryDispatchQueue());
    const id = before.ledgers.get(fingerprint).get.activeExecutionId;
    auto current = before.executions.get(id).get;
    TaskExecution ended = current.value;
    ended.status = ExecutionStatus.succeeded;
    ended.finishedAt = fixedNow();
    before.executions.update(current, ended); // ... and the process dies before the fold

    auto after = new StateStores(documents.restart());
    assert(after.ledgers.get(fingerprint).get.activeExecutionId == id, "Nothing was folded");
    assert(!after.chainStates.get("b").get.dirty, "Nobody was woken");

    const settled = after.ledgers.settle(fingerprint);
    assert(settled.ledger.get.activeExecutionId.length == 0 && settled.ledger.get.lastSuccessExecutionId == id);
    assert(settled.ledger.get.pendingNotify.length == 2);
    notifyWaiters(after, fingerprint, settled.ledger.get.pendingNotify);
    assert(after.chainStates.get("b").get.dirty && after.ledgers.get(fingerprint).get.pendingNotify.length == 0);
    auto woken = reconcilerOf(after, new InMemoryDispatchQueue()).reconcile("b");
    assert(taskOf(woken.state, "compile").status == ChainTaskStatus.succeeded);

    // Repairing is idempotent: folding and notifying again writes nothing new
    const again = foldAndNotify(after, after.executions.get(id).get.value);
    assert(again.outcome == FoldOutcome.alreadyFolded && again.ledger.pendingNotify.length == 0);
}

unittest
{
    // The fold or the wake failing after the terminal compare-and-set: here a waiting chain has no
    // chain state. The completion answers OutcomeNotFoldedException (the cause chained), the
    // execution stays finished and a resent completion is stale; once the chain is repaired,
    // settling and notifying wakes it
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    const chain = createChainOnly(stores, "c");
    stores.ledgers.subscribe(stores.ledgers.get("fp1").get, "c");

    TaskExecutionResult result;
    result.status = ExecutionStatus.succeeded;
    bool unfolded = false;
    try completeExecution(stores, id, result, fixedNow());
    catch (OutcomeNotFoldedException e)
    {
        unfolded = e.executionId == id && e.next !is null && e.msg.canFind(id) && e.msg.canFind("is rejected as stale");
    }
    assert(unfolded);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
    assert(stores.ledgers.get("fp1").get.pendingNotify == [LedgerNotice("c", id)], "The notice stays for the repair");

    bool stale = false;
    try completeExecution(stores, id, result, fixedNow());
    catch (StaleCompletionException) stale = true;
    assert(stale);

    stores.chainStates.createFor(chain);
    notifyWaiters(stores, "fp1", stores.ledgers.settle("fp1").ledger.get.pendingNotify);
    assert(stores.chainStates.get("c").get.dirty && stores.ledgers.get("fp1").get.pendingNotify.length == 0);
}

unittest
{
    // One waiting chain that cannot be woken (no chain state) does not block the others: B is
    // marked dirty and its notice cleared, the failed chain's notice stays, and the error names it
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores);
    createChainOnly(stores, "x");
    createChain(stores, "b");
    auto ledger = stores.ledgers.get("fp1").get;
    ledger = stores.ledgers.subscribe(ledger, "x").ledger;
    stores.ledgers.subscribe(ledger, "b");
    TaskExecutionResult result;
    result.status = ExecutionStatus.succeeded;
    bool failed = false;
    try completeExecution(stores, id, result, fixedNow());
    catch (OutcomeNotFoldedException e)
    {
        auto wake = cast(WakeFailedException) e.next;
        failed = wake !is null && wake.failures.length == 1 && wake.failures[0].canFind("'x'") && e.msg.canFind("waking its waiters failed");
    }
    assert(failed);
    assert(stores.chainStates.get("b").get.dirty, "B is woken although X could not be");
    assert(stores.ledgers.get("fp1").get.pendingNotify == [LedgerNotice("x", id)]);
}
