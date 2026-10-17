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
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.document_collection : Versioned;
import confector.core.execution_dispatcher : DispatchMessage, ExecutionDispatcher, executionDemand, releaseClaim, utcNow;
import confector.core.model;
import confector.core.state_stores : StateStores;
import confector.plugin_api.dispatch_queue : DispatchQueue, DispatchQueueUsageException, Lease;
import confector.plugin_api.document_store : DocumentConflictException;

import core.time : Duration;
import std.format : format;
import std.typecons : Nullable;
import vibe.core.log : logError;
import vibe.data.json : Json, deserializeJson;

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
 * The work order for `execution`: its definition, fingerprint, resolved inputs and repository
 * addresses, and the compute it needs. Pure.
 */
WorkOrder workOrderFor(in TaskExecution execution) @trusted
{
    WorkOrder order;
    order.executionId = execution.id;
    order.taskId = execution.taskId;
    order.taskNode = cast(TaskNode) execution.definition;
    order.fingerprint = execution.fingerprint;
    const demand = executionDemand(execution.definition);
    order.executorType = demand.executorType;
    order.requirements = cast(string[string]) demand.requirements;
    order.payload.inputs = (cast(ResolvedInput[]) execution.inputs).dup;
    foreach (name, address; execution.repositoryAddresses) order.payload.repositoryAddresses[name] = address;
    foreach (name, value; execution.definition.environment) order.payload.environment[name] = value;
    order.payload.expectedOutputs = (cast(OutputArtifactDecl[]) execution.definition.outputs.artifacts).dup;
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
    foreach (attempt; 0 .. ExecutionDispatcher.maxWriteAttempts)
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
        executionId, ExecutionDispatcher.maxWriteAttempts));
}

/**
 * A worker reported the outcome of an execution that has nothing left to report: it finished
 * already (a duplicate or late completion), or it was failed or replaced while the worker ran it,
 * so it no longer holds its fingerprint's claim. Its report is rejected and nothing is recorded.
 */
class StaleCompletionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
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
 * active and holds the claim on its fingerprint. The execution record is the only source of the
 * completion's fingerprint and task: a worker never names them.
 *
 * Throws: StaleCompletionException if it is not active or does not hold the claim;
 * UnknownExecutionException if `executionId` is empty or names no execution.
 */
TaskExecution requireClaimingExecution(StateStores stores, string executionId)
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
    auto claim = stores.claims.get(found.get.fingerprint);
    const holder = claim.isNull ? null : claim.get.executionId;
    if (holder != executionId || !ExecutionStore.isActive(found.get.status))
    {
        throw new StaleCompletionException(format(
            "Execution '%s' (%s) no longer holds fingerprint %s (held by '%s'); its completion is rejected",
            executionId, found.get.status, found.get.fingerprint, holder));
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
 * The artifacts a worker reported for `execution`, each stamped with the execution's fingerprint.
 * An artifact may leave its fingerprint empty; one naming another fingerprint is rejected, so a
 * completion cannot place artifacts under a cache key the control plane did not compute. Pure.
 *
 * Throws: ForeignArtifactException if an artifact names a fingerprint other than the execution's.
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
        ArtifactMetadata stamped = artifact;
        stamped.taskFingerprint = execution.fingerprint;
        own ~= stamped;
    }
    return own;
}

/**
 * Records the outcome a worker reported for execution `executionId` (`status`, which must be
 * terminal, with its exit code, error and artifacts, see `executionArtifacts`) by compare-and-set, then releases its
 * fingerprint's claim, and returns the finished execution. A terminal execution never changes:
 * a completion that loses the compare-and-set to another one is rejected, not merged.
 *
 * A crash after the outcome is recorded but before the claim is released leaves a terminal
 * execution holding the claim; the next dispatch of the fingerprint releases it.
 *
 * Throws: StaleCompletionException if the execution is not active or no longer holds its
 * fingerprint's claim (see `requireClaimingExecution`), including when a concurrent completion
 * finishes it first; ForeignArtifactException if an artifact names another fingerprint;
 * UnknownExecutionException if `executionId` names no execution; Exception if `status` is not
 * terminal.
 */
TaskExecution finishExecution(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    auto own = executionArtifacts(requireClaimingExecution(stores, executionId), artifacts);
    return recordOutcome(stores, executionId, status, exitCode, errorMessage, own, now.length > 0 ? now : utcNow());
}

/**
 * The execution status a worker's reported task status records: succeeded, failed or cancelled.
 * A worker ran the execution, so it can never report a cache hit.
 *
 * Throws: InvalidCompletionException if `status` is not one of those three.
 */
ExecutionStatus reportedExecutionStatus(TaskStatus status) pure @safe
{
    switch (status)
    {
        case TaskStatus.succeeded:
            return ExecutionStatus.succeeded;
        case TaskStatus.failed:
            return ExecutionStatus.failed;
        case TaskStatus.cancelled:
            return ExecutionStatus.cancelled;
        default:
            throw new InvalidCompletionException(format("A completion reported status '%s'; a worker can report only succeeded, failed or cancelled",
                cast(string) status));
    }
}

/**
 * Records the completion a worker reported for execution `executionId` (see `finishExecution`)
 * and returns the finished execution. The execution record is the only source of the
 * fingerprint and task: a `result` naming a different task is rejected.
 *
 * This is everything a completion does until the fingerprint ledger's fold lands (beads
 * confector-z7z.49.x): the execution is finished by compare-and-set and its fingerprint's claim
 * released. Nothing is cached and no chain is re-evaluated. `result.logs` is not recorded: the
 * worker streams its log lines to the execution's log as it runs.
 *
 * Throws: as `finishExecution`, and InvalidCompletionException if `result.status` is not a
 * status a worker can report or `result.taskId` names another task; in every case nothing is
 * recorded.
 */
TaskExecution completeExecution(StateStores stores, string executionId, in TaskExecutionResult result, string now = null)
{
    const status = reportedExecutionStatus(result.status);
    const execution = requireClaimingExecution(stores, executionId);
    if (result.taskId.length > 0 && result.taskId != execution.taskId)
    {
        throw new InvalidCompletionException(format("A completion of execution '%s' (task '%s') names task '%s'; it is rejected",
            executionId, execution.taskId, result.taskId));
    }
    auto own = executionArtifacts(execution, (cast(ArtifactMetadata[]) result.producedArtifacts).dup);
    return recordOutcome(stores, executionId, status, result.exitCode, result.errorMessage, own,
        now.length > 0 ? now : utcNow());
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
    foreach (attempt; 0 .. ExecutionDispatcher.maxWriteAttempts)
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
        releaseClaim(stores, finished.fingerprint, executionId);
        return finished;
    }
    throw new Exception(format("Could not record the outcome of execution '%s': it lost %s compare-and-sets in a row",
        executionId, ExecutionDispatcher.maxWriteAttempts));
}

version (unittest)
{
    import confector.core.execution_dispatcher : PlannedExecution, defaultPoolQueue;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import core.time : hours;
    import std.algorithm.searching : canFind;
    import vibe.data.json : serializeToJson;

    private string fixedNow() { return "2026-10-16T10:00:02Z"; }

    private PlannedExecution samplePlan(string fingerprint = "fp1")
    {
        PlannedExecution p;
        p.projectId = "p";
        p.taskId = "compile";
        p.fingerprint = fingerprint;
        p.definition.id = "compile";
        p.definition.inputs["src"] = repositoryInput("game", "main");
        p.definition.steps = [BuildStep("Compile", "bash", null, "make")];
        p.definition.environment = ["MODE": "release"];
        p.definition.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];
        p.definition.timeoutSeconds = 1200;
        p.definition.setCustomComponent("executor", JSONValue("aws-ecs"));
        p.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
        p.repositoryAddresses = ["src": "https://example.test/game.git"];
        return p;
    }

    import std.json : JSONValue;
}

unittest
{
    // A worker receives the full work order, built from the execution the message names; the
    // execution starts. A duplicate message for it is acknowledged and dropped; a redelivery after
    // the lease expired starts another attempt
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

    auto received = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w1", () => fixedNow());
    assert(received.length == 1 && received[0].receiveCount == 1);
    auto order = received[0].workOrder;
    assert(order.executionId == id && order.taskId == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].script == "make" && order.timeoutSeconds == 1200 && order.executorType == "aws-ecs");
    assert(order.payload.inputs == samplePlan().inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(order.payload.environment == ["MODE": "release"] && order.payload.expectedOutputs.length == 1);
    auto running = stores.executions.get(id).get;
    assert(running.status == ExecutionStatus.running && running.attempts == 1 && running.worker == "w1");

    // A second message for the running execution (a dispatcher re-sent it) is dropped
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

    // The outcome is recorded and the claim released; a late message for it is dropped
    const finished = finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(finished.status == ExecutionStatus.succeeded && finished.fingerprint == "fp1");
    auto done = stores.executions.get(id).get;
    assert(done.status == ExecutionStatus.succeeded && done.finishedAt == fixedNow());
    assert(stores.claims.get("fp1").get.executionId.length == 0);
    queue.release(defaultPoolQueue, again[0].receipt);
    assert(receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w4").length == 0);
}

unittest
{
    // A failed or cancelled outcome records when it finished even when the caller gives no time.
    // This pins existing behaviour (recordOutcome always stamps finishedAt), guarding the
    // completion paths against regressions.
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const cancelledId = dispatcher.dispatch([samplePlan()])[0].executionId;
    finishExecution(stores, cancelledId, ExecutionStatus.cancelled, 0, "stopped", null);
    auto cancelled = stores.executions.get(cancelledId).get;
    assert(cancelled.status == ExecutionStatus.cancelled && cancelled.finishedAt.length > 0);

    const failedId = dispatcher.dispatch([samplePlan()])[0].executionId;
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
    auto queue = new InMemoryDispatchQueue();
    const id = new ExecutionDispatcher(stores, queue, null, () => fixedNow()).dispatch([samplePlan()])[0].executionId;

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
}

unittest
{
    // A completion naming its execution is recorded only while that execution holds its
    // fingerprint's claim: a stale one (the fingerprint was re-claimed by a later execution) is
    // rejected loudly and records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    const first = dispatcher.dispatch([samplePlan()])[0].executionId;

    // The first execution is failed meanwhile and the fingerprint dispatched again
    finishExecution(stores, first, ExecutionStatus.failed, 1, "worker lost", null, fixedNow());
    const second = dispatcher.dispatch([samplePlan()])[0].executionId;
    assert(second != first && stores.claims.get("fp1").get.executionId == second);

    bool stale = false;
    try finishExecution(stores, first, ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) stale = e.msg.canFind(first) && e.msg.canFind(second);
    assert(stale);
    assert(stores.executions.get(second).get.status == ExecutionStatus.queued, "The current execution is untouched");
    assert(stores.claims.get("fp1").get.executionId == second);

    finishExecution(stores, second, ExecutionStatus.succeeded, 0, null, null, fixedNow());
    assert(stores.executions.get(second).get.status == ExecutionStatus.succeeded);
    assert(stores.claims.get("fp1").get.executionId.length == 0);

    bool missing = false;
    try finishExecution(stores, "exe_nope", ExecutionStatus.succeeded, 0, null, null);
    catch (Exception e) missing = e.msg.canFind("does not exist");
    assert(missing);
    bool noWorker = false;
    try receiveWork(stores, queue, defaultPoolQueue, 1, 1.hours, "");
    catch (DispatchQueueUsageException) noWorker = true;
    assert(noWorker);
}

unittest
{
    // Bug confector-1oj: a completion is identified only by its execution id. One naming no
    // execution, or an execution that does not exist, is rejected loudly and records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

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
    assert(stores.claims.get("fp1").get.executionId == id);
    assert(stores.executions.get("exe_unknown").isNull);
}

unittest
{
    // A duplicate or late completion of an execution that already finished is rejected loudly:
    // a terminal execution is never overwritten
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;
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
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, null, fixedNow()); };
    bool rejected = false;
    try finishExecution(racing, id, ExecutionStatus.failed, 1, "duplicate", null, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected, "The loser re-reads, finds it finished, and is rejected");
    auto kept = stores.executions.get(id).get;
    assert(kept.status == ExecutionStatus.succeeded && kept.errorMessage.length == 0);
    assert(stores.claims.get("fp1").get.executionId.length == 0, "The winner released the claim");
}

unittest
{
    // Crash point: the outcome is recorded but the claim is never released (the process died in
    // between). A retried completion is rejected as late; the next dispatch of the fingerprint
    // releases the terminal execution's claim and dispatches afresh
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;
    auto current = stores.executions.get(id).get;
    TaskExecution failed = current.value;
    failed.status = ExecutionStatus.failed;
    failed.finishedAt = fixedNow();
    stores.executions.update(current, failed);
    assert(stores.claims.get("fp1").get.executionId == id, "Crashed before releasing");

    bool rejected = false;
    try finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, null);
    catch (StaleCompletionException e) rejected = true;
    assert(rejected && stores.executions.get(id).get.status == ExecutionStatus.failed);

    const next = dispatcher.dispatch([samplePlan()])[0].executionId;
    assert(next != id && stores.claims.get("fp1").get.executionId == next);
}

unittest
{
    // A completion cannot place artifacts under another fingerprint: one naming a fingerprint
    // other than its execution's is rejected and records nothing; unnamed ones are stamped with
    // the execution's
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

    ArtifactMetadata foreign;
    foreign.artifactId = "game.zip";
    foreign.taskFingerprint = "fp_somebody_else";
    bool rejected = false;
    try finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, [foreign]);
    catch (ForeignArtifactException e) rejected = e.msg.canFind("fp_somebody_else") && e.msg.canFind(id);
    assert(rejected);
    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");

    ArtifactMetadata unnamed;
    unnamed.artifactId = "game.zip";
    ArtifactMetadata own = unnamed;
    own.artifactId = "tools.zip";
    own.taskFingerprint = "fp1";
    const done = finishExecution(stores, id, ExecutionStatus.succeeded, 0, null, [unnamed, own]);
    assert(done.artifacts.length == 2 && done.artifacts[0].taskFingerprint == "fp1" && done.artifacts[1].taskFingerprint == "fp1");
}

unittest
{
    // A worker's completion: the reported status maps to the execution's outcome, a worker cannot
    // report a cache hit or an unfinished status, and a completion naming another task is
    // rejected. Each rejection records nothing and keeps the claim
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

    assert(reportedExecutionStatus(TaskStatus.succeeded) == ExecutionStatus.succeeded);
    assert(reportedExecutionStatus(TaskStatus.failed) == ExecutionStatus.failed);
    assert(reportedExecutionStatus(TaskStatus.cancelled) == ExecutionStatus.cancelled);

    bool rejectedWith(TaskExecutionResult result, string text)
    {
        try completeExecution(stores, id, result);
        catch (InvalidCompletionException e) return e.msg.canFind(text);
        return false;
    }

    foreach (status; [TaskStatus.cached, TaskStatus.running, TaskStatus.pending, TaskStatus.queued])
    {
        TaskExecutionResult result;
        result.status = status;
        assert(rejectedWith(result, "can report only succeeded, failed or cancelled"));
    }
    TaskExecutionResult otherTask;
    otherTask.taskId = "link";
    otherTask.status = TaskStatus.succeeded;
    assert(rejectedWith(otherTask, "names task 'link'"));
    assert(stores.executions.get(id).get.status == ExecutionStatus.queued, "Nothing was recorded");
    assert(stores.claims.get("fp1").get.executionId == id);

    // A completion is recorded on the execution named in the route; its outcome, exit code,
    // error and artifacts (stamped with the execution's fingerprint) are kept and the claim is
    // released. Nothing else is written: no cache entry, no chain re-evaluation
    TaskExecutionResult failed;
    failed.taskId = "compile";
    failed.status = TaskStatus.failed;
    failed.exitCode = 2;
    failed.errorMessage = "make: *** [all] Error 2";
    failed.producedArtifacts = [ArtifactMetadata("partial.log")];
    failed.logs = ["not recorded here"];
    const done = completeExecution(stores, id, failed, fixedNow());
    assert(done.id == id && done.status == ExecutionStatus.failed && done.exitCode == 2);
    assert(done.errorMessage == "make: *** [all] Error 2" && done.finishedAt == fixedNow());
    assert(done.artifacts.length == 1 && done.artifacts[0].taskFingerprint == "fp1");
    assert(stores.executions.get(id).get.status == ExecutionStatus.failed);
    assert(stores.claims.get("fp1").get.executionId.length == 0);

    // A task id is optional; a duplicate is rejected as stale, an unknown execution as unknown
    bool unknownExecution = false;
    try completeExecution(stores, "exe_nope", failed);
    catch (UnknownExecutionException e) unknownExecution = e.msg.canFind("exe_nope");
    assert(unknownExecution);
    TaskExecutionResult again;
    again.status = TaskStatus.succeeded;
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
    auto dispatcher = new ExecutionDispatcher(stores, new InMemoryDispatchQueue(), null, () => fixedNow());
    const id = dispatcher.dispatch([samplePlan()])[0].executionId;

    TaskExecutionResult succeeded;
    succeeded.taskId = "compile";
    succeeded.status = TaskStatus.succeeded;
    TaskExecutionResult cancelled = succeeded;
    cancelled.status = TaskStatus.cancelled;

    auto interleaving = new InterleavingDocumentStore(documents);
    auto racing = new StateStores(interleaving);
    interleaving.beforeNextWrite = () { completeExecution(stores, id, succeeded, fixedNow()); };
    bool rejected = false;
    try completeExecution(racing, id, cancelled, fixedNow());
    catch (StaleCompletionException e) rejected = e.msg.canFind("finished succeeded");
    assert(rejected);
    assert(stores.executions.get(id).get.status == ExecutionStatus.succeeded);
    assert(stores.claims.get("fp1").get.executionId.length == 0);
}
