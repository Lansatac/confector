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
 * addresses, the compute it needs, and `legacyBuildId` as routing (see
 * DispatchMessage.legacyBuildId). Pure.
 */
WorkOrder workOrderFor(in TaskExecution execution, string legacyBuildId) @trusted
{
    WorkOrder order;
    order.executionId = execution.id;
    order.buildId = legacyBuildId;
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
            received ~= ReceivedWorkOrder(lease.receipt, lease.receiveCount, workOrderFor(started.get, message.legacyBuildId));
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
 * A worker reported the outcome of an execution that no longer holds its fingerprint's claim
 * (it finished already, or was failed or replaced while the worker ran it). Its report is
 * rejected and nothing is recorded.
 */
class StaleCompletionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Reads execution `executionId`, which a worker reports the outcome of, and checks it is still
 * active and holds the claim on its fingerprint (the fingerprint is the execution record's,
 * never the worker's).
 *
 * Throws: StaleCompletionException if it does not; Exception if it does not exist.
 */
TaskExecution requireClaimingExecution(StateStores stores, string executionId)
{
    auto found = stores.executions.get(executionId);
    if (found.isNull)
    {
        throw new Exception(format("A completion names execution '%s', which does not exist", executionId));
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
 * Records the outcome a worker reported for execution `executionId` (`status`, which must be
 * terminal, with its exit code, error and artifacts), then releases its fingerprint's claim.
 *
 * Throws: StaleCompletionException if the execution no longer holds its fingerprint's claim
 * (see `requireClaimingExecution`); Exception if `status` is not terminal or the execution does
 * not exist.
 */
void finishExecution(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    const fingerprint = requireClaimingExecution(stores, executionId).fingerprint;
    recordOutcome(stores, executionId, fingerprint, status, exitCode, errorMessage, artifacts, now.length > 0 ? now : utcNow());
}

/**
 * Records the outcome a worker reported on the execution holding the claim on `fingerprint`,
 * then releases the claim. Returns false, writing nothing, if no recorded execution holds the
 * claim: its outcome was already recorded, or it was never recorded (the next dispatch of the
 * fingerprint repairs that).
 *
 * Only for BuildCoordinator completions that do not name their execution (a worker without an
 * execution id); `finishExecution` is used when they do. Removed with completions by execution
 * id (bead confector-z7z.23.4).
 *
 * Throws: Exception if `status` is not terminal.
 */
bool finishClaimedExecution(StateStores stores, string fingerprint, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    auto claim = stores.claims.get(fingerprint);
    if (claim.isNull || claim.get.executionId.length == 0) return false;
    if (stores.executions.get(claim.get.executionId).isNull) return false;
    recordOutcome(stores, claim.get.executionId, fingerprint, status, exitCode, errorMessage, artifacts,
        now.length > 0 ? now : utcNow());
    return true;
}

private void requireTerminal(ExecutionStatus status)
{
    if (ExecutionStore.isActive(status))
    {
        throw new Exception(format("A finished execution cannot be %s", status));
    }
}

private void recordOutcome(StateStores stores, string executionId, string fingerprint, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now)
{
    foreach (attempt; 0 .. ExecutionDispatcher.maxWriteAttempts)
    {
        auto current = stores.executions.get(executionId);
        if (current.isNull || !ExecutionStore.isActive(current.get.status)) break;
        TaskExecution next = current.get.value;
        next.status = status;
        next.exitCode = exitCode;
        next.errorMessage = errorMessage;
        next.artifacts = artifacts;
        next.finishedAt = now;
        try
        {
            stores.executions.update(current.get, next);
            break;
        }
        catch (DocumentConflictException)
        {
            if (attempt + 1 == ExecutionDispatcher.maxWriteAttempts)
            {
                throw new Exception(format("Could not record the outcome of execution '%s': it lost %s compare-and-sets in a row",
                    executionId, ExecutionDispatcher.maxWriteAttempts));
            }
        }
    }
    releaseClaim(stores, fingerprint, executionId);
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
        p.legacyBuildId = "bld_1";
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
    assert(order.executionId == id && order.buildId == "bld_1" && order.taskId == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].script == "make" && order.timeoutSeconds == 1200 && order.executorType == "aws-ecs");
    assert(order.payload.inputs == samplePlan().inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(order.payload.environment == ["MODE": "release"] && order.payload.expectedOutputs.length == 1);
    auto running = stores.executions.get(id).get;
    assert(running.status == ExecutionStatus.running && running.attempts == 1 && running.worker == "w1");

    // A second message for the running execution (a dispatcher re-sent it) is dropped
    queue.send(defaultPoolQueue, serializeToJson(DispatchMessage(id, "bld_2")));
    assert(receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w2").length == 0);
    assert(queue.receive(defaultPoolQueue, 10, 1.hours).length == 0, "The duplicate was acknowledged");
    assert(stores.executions.get(id).get.attempts == 1);

    // The first worker is lost: its message is delivered again and starts a second attempt
    queue.release(defaultPoolQueue, received[0].receipt);
    auto again = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w3");
    assert(again.length == 1 && again[0].receiveCount == 2 && again[0].workOrder.executionId == id);
    assert(stores.executions.get(id).get.attempts == 2 && stores.executions.get(id).get.worker == "w3");

    // The outcome is recorded and the claim released; a late message for it is dropped
    assert(finishClaimedExecution(stores, "fp1", ExecutionStatus.succeeded, 0, null, null, fixedNow()));
    auto done = stores.executions.get(id).get;
    assert(done.status == ExecutionStatus.succeeded && done.finishedAt == fixedNow());
    assert(stores.claims.get("fp1").get.executionId.length == 0);
    assert(!finishClaimedExecution(stores, "fp1", ExecutionStatus.succeeded, 0, null, null), "Already recorded");
    queue.release(defaultPoolQueue, again[0].receipt);
    assert(receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w4").length == 0);

    bool threw = false;
    try finishClaimedExecution(stores, "fp1", ExecutionStatus.running, 0, null, null);
    catch (Exception e) threw = true;
    assert(threw);
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
    assert(finishClaimedExecution(stores, "fp1", ExecutionStatus.failed, 1, "worker lost", null, fixedNow()));
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
