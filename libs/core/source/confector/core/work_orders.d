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
 * A completion finishes its execution by compare-and-set and does nothing else: folding the
 * outcome into the fingerprint's ledger and waking the chains waiting on it is bead
 * confector-z7z.49.4.
 */

import confector.core.build_stores : ExecutionStore;
import confector.core.document_collection : Versioned;
import confector.core.model;
import confector.core.state_stores : StateStores;
import confector.plugin_api.dispatch_queue : DispatchQueue, DispatchQueueUsageException, Lease;
import confector.plugin_api.document_store : DocumentConflictException;

import core.time : Duration;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.format : format;
import std.json : JSONType;
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
 * The work order for `execution`: its definition, fingerprint, resolved inputs and repository
 * addresses, and the compute it needs: its executor type ("local" unless the task's `executor`
 * or `executor_type` component names another) and its requirements (the `requirements`
 * component, an object of strings). Pure.
 */
WorkOrder workOrderFor(in TaskExecution execution) @trusted
{
    WorkOrder order;
    order.executionId = execution.id;
    order.taskId = execution.taskId;
    order.taskNode = cast(TaskNode) execution.definition;
    order.fingerprint = execution.fingerprint;
    order.executorType = executorTypeOf(execution.definition);
    order.requirements = requirementsOf(execution.definition);
    order.payload.inputs = (cast(ResolvedInput[]) execution.inputs).dup;
    foreach (name, address; execution.repositoryAddresses) order.payload.repositoryAddresses[name] = address;
    foreach (name, value; execution.definition.environment) order.payload.environment[name] = value;
    order.payload.expectedOutputs = (cast(OutputArtifactDecl[]) execution.definition.outputs.artifacts).dup;
    order.timeoutSeconds = execution.definition.timeoutSeconds;
    order.createdAt = execution.createdAt;
    return order;
}

private string executorTypeOf(in TaskNode definition) @trusted
{
    if (definition.hasCustomComponent("executor"))
    {
        auto comp = definition.getCustomComponent("executor");
        if (comp.type == JSONType.string) return comp.str;
        if (comp.type == JSONType.object && "type" in comp) return comp["type"].str;
    }
    else if (definition.hasCustomComponent("executor_type"))
    {
        auto comp = definition.getCustomComponent("executor_type");
        if (comp.type == JSONType.string) return comp.str;
    }
    return "local";
}

private string[string] requirementsOf(in TaskNode definition) @trusted
{
    string[string] requirements;
    if (definition.hasCustomComponent("requirements"))
    {
        auto comp = definition.getCustomComponent("requirements");
        if (comp.type == JSONType.object)
        {
            foreach (k, v; comp.object)
            {
                requirements[k] = v.type == JSONType.string ? v.str : v.toString();
            }
        }
    }
    return requirements;
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
 * compare-and-set, and returns the finished execution. A terminal execution never changes: a
 * completion that loses the compare-and-set to another one is rejected, not merged.
 *
 * Throws: StaleCompletionException if the execution is not active (see
 * `requireActiveExecution`), including when a concurrent completion finishes it first; ForeignArtifactException if an artifact names another fingerprint;
 * UnknownExecutionException if `executionId` names no execution; Exception if `status` is not
 * terminal.
 */
TaskExecution finishExecution(StateStores stores, string executionId, ExecutionStatus status, int exitCode,
    string errorMessage, ArtifactMetadata[] artifacts, string now = null)
{
    requireTerminal(status);
    auto own = executionArtifacts(requireActiveExecution(stores, executionId), artifacts);
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
 * This is everything a completion does until the fingerprint ledger's fold lands (bead
 * confector-z7z.49.4): the execution is finished by compare-and-set. Nothing is cached and no
 * chain is re-evaluated. Log lines are not part of a completion: the worker streams them to the
 * execution's log as it runs.
 *
 * Throws: as `finishExecution`, and InvalidCompletionException if `result.status` is not a
 * status a worker can report or `result.taskId` names another task; in every case nothing is
 * recorded.
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
        try
        {
            return stores.executions.update(current.get, next).value;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not record the outcome of execution '%s': it lost %s compare-and-sets in a row",
        executionId, maxWriteAttempts));
}

version (unittest)
{
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import core.time : hours;
    import std.algorithm.searching : canFind;
    import std.json : JSONValue;
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
        execution.definition.inputs["src"] = repositoryInput("game", "main");
        execution.definition.steps = [BuildStep("Compile", "bash", null, "make")];
        execution.definition.environment = ["MODE": "release"];
        execution.definition.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];
        execution.definition.timeoutSeconds = 1200;
        execution.definition.setCustomComponent("executor", JSONValue("aws-ecs"));
        execution.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
        execution.repositoryAddresses = ["src": "https://example.test/game.git"];
        execution.createdAt = "2026-10-16T10:00:00Z";
        return execution;
    }

    /// Records `sampleExecution(id, fingerprint)` and, given a queue, sends its message to the
    /// default pool queue, as dispatching does. Returns `id`.
    private string queueExecution(StateStores stores, string id, DispatchQueue queue = null, string fingerprint = "fp1")
    {
        stores.executions.create(sampleExecution(id, fingerprint));
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
    const id = queueExecution(stores, "exe_1", queue);

    auto received = receiveWork(stores, queue, defaultPoolQueue, 10, 1.hours, "w1", () => fixedNow());
    assert(received.length == 1 && received[0].receiveCount == 1);
    auto order = received[0].workOrder;
    assert(order.executionId == id && order.taskId == "compile" && order.fingerprint == "fp1");
    assert(order.taskNode.steps[0].script == "make" && order.timeoutSeconds == 1200 && order.executorType == "aws-ecs");
    assert(order.payload.inputs == sampleExecution(id).inputs);
    assert(order.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(order.payload.environment == ["MODE": "release"] && order.payload.expectedOutputs.length == 1);
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
    // The executor type and requirements come from the definition's components; without them a
    // task runs on the local executor with no requirements
    auto plain = sampleExecution("exe_1");
    plain.definition = TaskNode.init;
    plain.definition.id = "compile";
    assert(workOrderFor(plain).executorType == "local" && workOrderFor(plain).requirements.length == 0);

    auto typed = plain;
    typed.definition.setCustomComponent("executor", JSONValue(["type": JSONValue("kubernetes")]));
    typed.definition.setCustomComponent("requirements", JSONValue(["gpu": JSONValue("true"), "cores": JSONValue(8)]));
    assert(workOrderFor(typed).executorType == "kubernetes");
    assert(workOrderFor(typed).requirements == ["gpu": "true", "cores": "8"]);

    auto legacyKey = plain;
    legacyKey.definition.setCustomComponent("executor_type", JSONValue("ecs"));
    assert(workOrderFor(legacyKey).executorType == "ecs");
}

unittest
{
    // A failed or cancelled outcome records when it finished even when the caller gives no time
    auto stores = new StateStores(new InMemoryDocumentStore());
    const cancelledId = queueExecution(stores, "exe_cancelled");
    finishExecution(stores, cancelledId, ExecutionStatus.cancelled, 0, "stopped", null);
    auto cancelled = stores.executions.get(cancelledId).get;
    assert(cancelled.status == ExecutionStatus.cancelled && cancelled.finishedAt.length > 0);

    const failedId = queueExecution(stores, "exe_failed");
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
    const id = queueExecution(stores, "exe_1");

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
    const first = queueExecution(stores, "exe_first");
    finishExecution(stores, first, ExecutionStatus.failed, 1, "worker lost", null, fixedNow());
    const second = queueExecution(stores, "exe_second");

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
    const id = queueExecution(stores, "exe_1");

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
    const id = queueExecution(stores, "exe_1");
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
    const id = queueExecution(stores, "exe_1");

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
    // state: completions are not yet fenced by attempt or worker (beads confector-z7z.23.14 and
    // confector-z7z.49.4)
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    const id = queueExecution(stores, "exe_1");

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
    const id = queueExecution(stores, "exe_1");

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
    // A worker's completion: the reported status maps to the execution's outcome, a worker cannot
    // report a cache hit or an unfinished status, and a completion naming another task is
    // rejected. Each rejection records nothing
    auto stores = new StateStores(new InMemoryDocumentStore());
    const id = queueExecution(stores, "exe_1");

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

    // A completion is recorded on the execution named in the route; its outcome, exit code,
    // error and artifacts (stamped with the execution's fingerprint) are kept. Nothing else is
    // written: no cache entry, no chain re-evaluation
    TaskExecutionResult failed;
    failed.taskId = "compile";
    failed.status = TaskStatus.failed;
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
    const id = queueExecution(stores, "exe_1");

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
}
