module confector.core.execution_dispatcher;

/**
 * The execution dispatcher (design records: beads confector-z7z.2 and confector-z7z.4; AGENTS.md,
 * "Coordinating builds" and "Backend interfaces"): the shell that turns the fingerprints the chain
 * evaluator says need dispatching into executions on the dispatch queue.
 *
 * For each needed fingerprint it claims the fingerprint by compare-and-set
 * (FingerprintClaimStore), records the TaskExecution, sends a DispatchMessage naming the
 * execution to the pool's dispatch queue and stamps the execution `sentAt`; once everything is
 * dispatched it emits capacity demand. It holds no lock and keeps no state between calls:
 * correctness depends only on reads by id and compare-and-set on single documents, so any number
 * of dispatchers (instances, serverless invocations) may run at once, and every step is
 * idempotent:
 *
 * - **Losers do nothing.** A dispatcher that loses a compare-and-set on the claim or on creating
 *   the execution leaves the fingerprint to the winner.
 * - **A half-done dispatch is finished by the next one.** The claim is written first, then the
 *   execution, then the message, then `sentAt`. A dispatcher that finds the claim held by an
 *   execution that was never recorded records it under the claimed id (if the original
 *   dispatcher is merely slow, exactly one of the two creates wins, and only the winner sends); one
 *   that finds the claim held by a queued execution that was never sent sends it; one that finds
 *   the claim held by a finished execution (its completion did not release the claim) releases
 *   it and claims afresh. The chain evaluator reports both unrecorded and unsent executions as
 *   needed, so the next evaluation repairs a dispatcher that crashed at any point.
 * - **A send that fails never leaves a task silently pending.** A message the queue rejects as
 *   invalid (DispatchQueueUsageException: it would be rejected again) fails the execution, with
 *   the reason recorded on it, and releases the claim. Any other send failure leaves the execution
 *   queued and unsent, for the next evaluation to send. Either way `dispatch` throws
 *   ExecutionDispatchException after dispatching everything else, so the failure reaches the
 *   caller.
 *
 * Messages are tiny (an execution id and routing; never the task definition), so they stay far
 * below the queue's message limit. Workers receive work orders built from the execution's record
 * (confector.core.work_orders.receiveWork).
 *
 * Duplicate messages are possible (a repair can race a slow original dispatcher), as the dispatch
 * queue's at-least-once contract already allows; receiving an execution a worker already holds
 * drops the duplicate.
 */

import confector.core.build_stores : ClaimResult, ExecutionStore;
import confector.core.chain_evaluator : ChainEvaluation;
import confector.core.definition_hash : recordDefinition;
import confector.core.document_collection : Versioned, tryValue;
import confector.core.model;
import confector.core.state_stores : StateStores;
import confector.plugin_api.dispatch_queue : DispatchQueue, DispatchQueueUsageException;
import confector.plugin_api.document_store : DocumentConflictException;

import std.algorithm.searching : find;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.format : format;
import std.json : JSONType;
import std.uuid : randomUUID;
import vibe.core.log : logError;
import vibe.data.json : serializeToJson;
import vibe.data.serialization : asName = name, optional;

/**
 * The dispatch queue every execution is sent to. Until compute pools exist (bead
 * confector-z7z.31.5) there is one pool, and so one queue.
 */
enum string defaultPoolQueue = "default";

/**
 * The message sent to a pool's dispatch queue: the execution to run, and routing. Everything else
 * a worker needs is read from the execution's record when the message is received.
 */
struct DispatchMessage
{
    /// The execution to run (`TaskExecution.id`).
    @asName("execution_id") string executionId;
    /// The BuildCoordinator build that dispatched the execution, which the worker reports its
    /// completion against until completions name the execution (bead confector-z7z.23.4).
    /// Removed with the BuildCoordinator (bead confector-z7z.23.10).
    @optional @asName("build_id") string legacyBuildId;
}

/**
 * One fingerprint to dispatch, with everything needed to record its execution. Plain data: built
 * by `planExecutions` from a chain evaluation, or by the BuildCoordinator from its build.
 */
struct PlannedExecution
{
    string projectId;
    string taskId;
    string fingerprint;
    /// The task's build configuration as the project defines it now, with the declared inputs
    /// the chain froze.
    TaskNode definition;
    /// The task's resolved inputs, sorted by name, as the chain pins them.
    ResolvedInput[] inputs;
    /// Where to fetch each repository input from, by input name.
    string[string] repositoryAddresses;
    /// Why the task cannot be dispatched (it was deleted from the project, or names a repository
    /// that cannot be checked out); empty when it can. The dispatcher records the execution as
    /// failed with this reason instead of sending it, so the failure shows on the task.
    string unavailable;
    /// Routing for the BuildCoordinator; see `DispatchMessage.legacyBuildId`.
    string legacyBuildId;
}

/**
 * Plans the dispatch of every fingerprint `evaluation` (an evaluation of `chain`) says is needed:
 * each task's build configuration from `project` as it is now, its declared inputs from the
 * chain, its resolved inputs from the evaluation, and the address of each repository input from
 * `repositories` (keyed by repository id; it needs those the needed tasks name). A task deleted
 * from the project, or naming a repository that is not registered or has no address, is planned
 * as unavailable. Pure.
 *
 * Throws: Exception if `project` is not the chain's project, or the evaluation names a task the
 * chain does not have or has no resolved inputs for it (it is not an evaluation of `chain`).
 */
PlannedExecution[] planExecutions(in BuildChain chain, in ChainEvaluation evaluation, in ProjectRecord project,
    in RepositoryRecord[string] repositories) @trusted
{
    if (project.id != chain.projectId)
    {
        throw new Exception(format("Chain '%s' belongs to project '%s', not '%s'", chain.id, chain.projectId, project.id));
    }

    PlannedExecution[] planned;
    foreach (ref needed; evaluation.needed)
    {
        auto chainTask = chain.tasks.find!(t => t.id == needed.taskId);
        auto inputs = needed.taskId in evaluation.resolution.inputs;
        if (chainTask.length == 0 || inputs is null)
        {
            throw new Exception(format("The evaluation needs task '%s', which chain '%s' does not have", needed.taskId, chain.id));
        }

        PlannedExecution p;
        p.projectId = chain.projectId;
        p.taskId = needed.taskId;
        p.fingerprint = needed.fingerprint;
        p.inputs = (cast(ResolvedInput[]) *inputs).dup;

        auto task = project.tasks.find!(t => t.id == needed.taskId);
        if (task.length == 0)
        {
            p.unavailable = format("Task '%s' of build #%s was deleted from project '%s' after the build was created",
                needed.taskId, chain.number, chain.projectId);
            planned ~= p;
            continue;
        }
        p.definition = cast(TaskNode) task[0];
        InputDecl[string] declared;
        foreach (name, decl; chainTask[0].inputs) declared[name] = decl;
        p.definition.inputs = declared;

        foreach (name, decl; chainTask[0].inputs)
        {
            if (decl.kind != InputKind.repository) continue;
            auto repository = decl.spec.repository in repositories;
            if (repository is null)
            {
                p.unavailable = format("Input '%s' of task '%s' names repository '%s', which is not registered",
                    name, needed.taskId, decl.spec.repository);
                break;
            }
            if (repository.address.length == 0)
            {
                p.unavailable = format("Input '%s' of task '%s': repository '%s' has no address to check out from",
                    name, needed.taskId, decl.spec.repository);
                break;
            }
            p.repositoryAddresses[name] = repository.address;
        }
        planned ~= p;
    }
    return planned;
}

/**
 * What dispatching one fingerprint did.
 */
enum DispatchResult : string
{
    /// A message for the fingerprint's execution was sent: a new execution, or one that was
    /// recorded but never sent. `DispatchOutcome.error` is set if recording `sentAt` then
    /// failed (logged; the next evaluation may send a duplicate, which receiving drops).
    sent = "sent",
    /// Another execution holds the fingerprint and was sent, or a concurrent dispatcher won the
    /// claim (or the execution's creation) and dispatches it. Nothing was done.
    attached = "attached",
    /// The execution was recorded as failed: the task is unavailable, or the dispatch queue
    /// rejected its message as invalid. Its claim is released.
    failed = "failed",
    /// Dispatching failed part-way (sending, or reading or writing the state store); the
    /// execution, if it was recorded, stays queued and unsent, and the next evaluation repairs
    /// it.
    notSent = "not_sent"
}

/**
 * The outcome of dispatching one fingerprint.
 */
struct DispatchOutcome
{
    string taskId;
    string fingerprint;
    /// The execution that holds the fingerprint (sent, attached to, or failed); empty if the
    /// dispatcher failed before claiming it.
    string executionId;
    DispatchResult result;
    /// Why it failed or was not sent; empty otherwise.
    string error;
}

/**
 * Some fingerprints could not be dispatched. Every other fingerprint was dispatched, and capacity
 * demand was emitted for those, before this was thrown.
 */
class ExecutionDispatchException : Exception
{
    /// The outcome of every fingerprint dispatched, including those that succeeded.
    DispatchOutcome[] outcomes;

    this(DispatchOutcome[] outcomes, string file = __FILE__, size_t line = __LINE__)
    {
        string message = "Could not dispatch:";
        foreach (ref outcome; outcomes)
        {
            if (outcome.result == DispatchResult.failed || outcome.result == DispatchResult.notSent)
            {
                message ~= format("\n- task '%s' (fingerprint %s, execution '%s'): %s", outcome.taskId, outcome.fingerprint,
                    outcome.executionId, outcome.error);
            }
        }
        super(message, file, line);
        this.outcomes = outcomes;
    }
}

/**
 * The current time as the build model records it: ISO 8601 in UTC.
 */
string utcNow()
{
    return Clock.currTime(UTC()).toISOExtString();
}

/**
 * Claims fingerprints, records executions and sends them to the dispatch queue. See the module
 * documentation.
 */
final class ExecutionDispatcher
{
    /// How many times a write that loses a compare-and-set to a concurrent writer of the same
    /// execution or claim re-reads and retries. Every lost attempt means another write
    /// succeeded, so this is reached only under sustained contention on one document.
    enum maxWriteAttempts = 10;

    private StateStores m_stores;
    private DispatchQueue m_queue;
    private void delegate() m_emitDemand;
    private string delegate() m_now;

    /**
     * Dispatches through `stores` and `queue`, ensuring the pool's queue exists. `emitDemand`,
     * called after anything was sent, tells capacity provisioning there is new work (normally
     * CapacityBroker.evaluateDemand); null when nothing provisions capacity on demand (workers
     * that poll on their own, or tests). `now` gives the current time (default `utcNow`); tests
     * pass a fixed clock.
     */
    this(StateStores stores, DispatchQueue queue, void delegate() emitDemand = null, string delegate() now = null)
    {
        if (stores is null) throw new Exception("The execution dispatcher requires the state stores");
        if (queue is null) throw new Exception("The execution dispatcher requires a dispatch queue");
        m_stores = stores;
        m_queue = queue;
        m_emitDemand = emitDemand;
        m_now = now !is null ? now : () => utcNow();
        m_queue.ensureQueue(defaultPoolQueue);
    }

    /**
     * Dispatches every fingerprint `evaluation` (an evaluation of `chain`) says is needed, with
     * build configuration from the chain's project as it is now and repository addresses as
     * registered now.
     *
     * Throws: Exception if the chain's project does not exist; otherwise as `dispatch`.
     */
    DispatchOutcome[] dispatchChain(in BuildChain chain, in ChainEvaluation evaluation)
    {
        if (evaluation.needed.length == 0) return null;
        ProjectRecord project;
        if (!m_stores.projects.get(chain.projectId).tryValue(project))
        {
            throw new Exception(format("Project '%s' of chain '%s' does not exist", chain.projectId, chain.id));
        }
        RepositoryRecord[string] repositories;
        foreach (ref needed; evaluation.needed)
        {
            foreach (ref task; chain.tasks)
            {
                if (task.id != needed.taskId) continue;
                foreach (decl; task.inputs.byValue)
                {
                    if (decl.kind != InputKind.repository || decl.spec.repository in repositories) continue;
                    RepositoryRecord repository;
                    if (m_stores.repositories.get(decl.spec.repository).tryValue(repository))
                    {
                        repositories[decl.spec.repository] = repository;
                    }
                }
            }
        }
        return dispatch(planExecutions(chain, evaluation, project, repositories));
    }

    /**
     * Dispatches each of `planned`, then emits capacity demand if anything was sent. Returns
     * each fingerprint's outcome, in order.
     *
     * Throws: ExecutionDispatchException, after dispatching everything else and emitting demand,
     * if any fingerprint failed or could not be sent. A failure emitting demand is logged, never
     * thrown.
     */
    DispatchOutcome[] dispatch(in PlannedExecution[] planned)
    {
        DispatchOutcome[] outcomes;
        bool anySent = false;
        bool anyFailed = false;
        foreach (ref p; planned)
        {
            DispatchOutcome outcome;
            outcome.taskId = p.taskId;
            outcome.fingerprint = p.fingerprint;
            try
            {
                dispatchOne(p, outcome);
            }
            catch (Exception e)
            {
                // Reported in the ExecutionDispatchException thrown below, never dropped.
                outcome.result = DispatchResult.notSent;
                outcome.error = e.msg;
            }
            anySent |= outcome.result == DispatchResult.sent;
            anyFailed |= outcome.result == DispatchResult.failed || outcome.result == DispatchResult.notSent;
            outcomes ~= outcome;
        }

        // Capacity is evaluated after the decision and outside any lock (bug confector-sit). It
        // is a notification about work already committed, so its failure is logged rather than
        // thrown: throwing would fail a request whose executions were recorded and sent, and a
        // client retrying it would build twice. Demand is read from the state store, so the next
        // evaluation (any later dispatch, or the scheduler's /broker/evaluate) picks it up.
        if (anySent && m_emitDemand !is null)
        {
            try m_emitDemand();
            catch (Exception e)
            {
                logError("[dispatcher] Capacity demand evaluation failed after sending executions; provisioning waits for the next evaluation: %s", e.msg);
            }
        }
        if (anyFailed) throw new ExecutionDispatchException(outcomes);
        return outcomes;
    }

    private void dispatchOne(in PlannedExecution p, ref DispatchOutcome outcome)
    {
        if (p.projectId.length == 0 || p.taskId.length == 0 || p.fingerprint.length == 0)
        {
            throw new Exception(format("A planned execution needs a project, a task and a fingerprint (task '%s', fingerprint '%s')",
                p.taskId, p.fingerprint));
        }

        auto claim = m_stores.claims.get(p.fingerprint);
        const holder = claim.isNull ? null : claim.get.executionId;
        if (holder.length > 0)
        {
            outcome.executionId = holder;
            auto existing = m_stores.executions.get(holder);
            if (existing.isNull)
            {
                // Claimed, but the execution was never recorded: its dispatcher crashed, or is
                // between claiming and recording right now. Record it under the claimed id; if
                // the other dispatcher gets there first, this create loses and it sends.
                recordAndSend(p, holder, outcome);
                return;
            }
            if (ExecutionStore.isActive(existing.get.status))
            {
                if (existing.get.sentAt.length > 0)
                {
                    outcome.result = DispatchResult.attached;
                    return;
                }
                send(existing.get.value, p.legacyBuildId, outcome);
                return;
            }
            // Finished, but its completion did not release the claim
            bool released;
            try released = m_stores.claims.release(p.fingerprint, holder);
            catch (DocumentConflictException) released = false;
            if (!released)
            {
                lostRace(p, outcome);
                return;
            }
        }

        const id = "exe_" ~ randomUUID().toString();
        ClaimResult claimed;
        try claimed = m_stores.claims.claim(p.fingerprint, id);
        catch (DocumentConflictException)
        {
            lostRace(p, outcome);
            return;
        }
        if (!claimed.won)
        {
            outcome.executionId = claimed.claim.executionId;
            outcome.result = DispatchResult.attached;
            return;
        }
        outcome.executionId = id;
        recordAndSend(p, id, outcome);
    }

    /// A concurrent dispatcher won a compare-and-set on the fingerprint: leave it to that one.
    private void lostRace(in PlannedExecution p, ref DispatchOutcome outcome)
    {
        auto claim = m_stores.claims.get(p.fingerprint);
        outcome.executionId = claim.isNull ? null : claim.get.executionId;
        outcome.result = DispatchResult.attached;
    }

    private void recordAndSend(in PlannedExecution p, string id, ref DispatchOutcome outcome)
    {
        TaskExecution execution;
        execution.id = id;
        execution.projectId = p.projectId;
        execution.taskId = p.taskId;
        execution.fingerprint = p.fingerprint;
        execution.status = ExecutionStatus.queued;
        execution.createdAt = m_now();
        if (p.unavailable.length == 0)
        {
            recordDefinition(execution, p.definition);
            execution.inputs = (cast(ResolvedInput[]) p.inputs).dup;
            foreach (name, address; p.repositoryAddresses) execution.repositoryAddresses[name] = address;
        }

        try m_stores.executions.create(execution);
        catch (DocumentConflictException)
        {
            // A concurrent dispatcher recorded it first; that one sends it.
            outcome.result = DispatchResult.attached;
            return;
        }

        if (p.unavailable.length > 0)
        {
            fail(id, p.fingerprint, p.unavailable, outcome);
            return;
        }
        send(execution, p.legacyBuildId, outcome);
    }

    private void send(in TaskExecution execution, string legacyBuildId, ref DispatchOutcome outcome)
    {
        auto message = serializeToJson(DispatchMessage(execution.id, legacyBuildId));
        try
        {
            m_queue.send(defaultPoolQueue, message);
        }
        catch (DispatchQueueUsageException e)
        {
            // Sending it again cannot succeed
            fail(execution.id, execution.fingerprint, format("The dispatch queue rejected the execution's message: %s", e.msg), outcome);
            return;
        }
        catch (Exception e)
        {
            outcome.result = DispatchResult.notSent;
            // The execution stays queued and unsent; see DispatchResult.notSent
            outcome.error = format("Sending execution '%s' to dispatch queue '%s' failed: %s", execution.id, defaultPoolQueue, e.msg);
            return;
        }
        outcome.result = DispatchResult.sent;
        try
        {
            markSent(execution.id);
        }
        catch (Exception e)
        {
            // The message is on the queue, so the execution is dispatched; only its `sentAt` is
            // missing. The next evaluation sends it again, and receiving drops the duplicate.
            outcome.error = format("Execution '%s' was sent, but recording that failed: %s. The next evaluation may send it again; the duplicate is dropped when received.",
                execution.id, e.msg);
            logError("[dispatcher] %s", outcome.error);
        }
    }

    /// Stamps `sentAt` on execution `id`, unless it is no longer queued or a worker's receipt
    /// already stamped it.
    private void markSent(string id)
    {
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = requireExecution(id);
            if (current.status != ExecutionStatus.queued || current.sentAt.length > 0) return;
            TaskExecution next = current.value;
            next.sentAt = m_now();
            try
            {
                m_stores.executions.update(current, next);
                return;
            }
            catch (DocumentConflictException)
            {
                continue;
            }
        }
        throw new Exception(format("Execution '%s' was sent, but recording that lost %s compare-and-sets in a row", id, maxWriteAttempts));
    }

    /// Records execution `id` as failed with `reason`, unless it already finished, and releases
    /// its claim on `fingerprint`.
    private void fail(string id, string fingerprint, string reason, ref DispatchOutcome outcome)
    {
        outcome.result = DispatchResult.failed;
        outcome.error = reason;
        foreach (attempt; 0 .. maxWriteAttempts)
        {
            auto current = requireExecution(id);
            if (!ExecutionStore.isActive(current.status)) break;
            TaskExecution next = current.value;
            next.status = ExecutionStatus.failed;
            next.errorMessage = reason;
            next.finishedAt = m_now();
            try
            {
                m_stores.executions.update(current, next);
                break;
            }
            catch (DocumentConflictException)
            {
                if (attempt + 1 == maxWriteAttempts)
                {
                    throw new Exception(format("Could not record execution '%s' as failed (%s): it lost %s compare-and-sets in a row",
                        id, reason, maxWriteAttempts));
                }
            }
        }
        releaseClaim(m_stores, fingerprint, id);
    }

    /**
     * Gives up on dispatching execution `executionId` at `fingerprint` (an outcome that was not
     * sent): records it failed with `reason`, unless it already finished, and releases its claim,
     * so the execution agrees with a caller that fails the task instead of leaving the execution
     * for the next evaluation to send. Nothing is written for an execution that was never
     * recorded beyond releasing its claim.
     */
    void abandon(string fingerprint, string executionId, string reason)
    {
        if (executionId.length == 0) return;
        if (m_stores.executions.get(executionId).isNull)
        {
            releaseClaim(m_stores, fingerprint, executionId);
            return;
        }
        DispatchOutcome ignored;
        fail(executionId, fingerprint, reason, ignored);
    }

    private Versioned!TaskExecution requireExecution(string id)
    {
        auto found = m_stores.executions.get(id);
        if (found.isNull) throw new Exception(format("Execution '%s' does not exist", id));
        return found.get;
    }
}

/**
 * Releases the claim on `fingerprint` if execution `executionId` holds it, retrying after losing
 * a compare-and-set to a concurrent write that left it the holder.
 */
void releaseClaim(StateStores stores, string fingerprint, string executionId)
{
    foreach (attempt; 0 .. ExecutionDispatcher.maxWriteAttempts)
    {
        try
        {
            stores.claims.release(fingerprint, executionId);
            return;
        }
        catch (DocumentConflictException)
        {
            continue;
        }
    }
    throw new Exception(format("Could not release the claim of execution '%s' on fingerprint %s: it lost %s compare-and-sets in a row",
        executionId, fingerprint, ExecutionDispatcher.maxWriteAttempts));
}

/**
 * The compute an execution of `definition` needs: its executor type ("local" unless the task's
 * `executor` or `executor_type` component names another) and its requirements (the
 * `requirements` component, an object of strings), as one unit of demand.
 */
QueueDemand executionDemand(in TaskNode definition) @trusted
{
    string executorType = "local";
    if (definition.hasCustomComponent("executor"))
    {
        auto comp = definition.getCustomComponent("executor");
        if (comp.type == JSONType.string) executorType = comp.str;
        else if (comp.type == JSONType.object && "type" in comp) executorType = comp["type"].str;
    }
    else if (definition.hasCustomComponent("executor_type"))
    {
        auto comp = definition.getCustomComponent("executor_type");
        if (comp.type == JSONType.string) executorType = comp.str;
    }

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
    return QueueDemand(executorType, 1, requirements);
}

/**
 * The compute demand of the work waiting for a worker: one QueueDemand per execution that was
 * sent to the dispatch queue and not yet received. Computed from the state store, never from the
 * queue (bead confector-z7z.4). Discovery: may lag behind writes. When dispatch becomes just in
 * time (bead confector-z7z.31.21), demand counts every queued execution, sent or not.
 */
QueueDemand[] queuedDemand(ExecutionStore executions)
{
    QueueDemand[] demand;
    foreach (ref execution; executions.listActive(ExecutionStatus.queued, size_t.max))
    {
        if (execution.sentAt.length > 0) demand ~= executionDemand(execution.definition);
    }
    return demand;
}

version (unittest)
{
    import confector.core.chain_evaluator : ChainTaskStatus, evaluateChain;
    import confector.core.dag : TaskGraph;
    import confector.core.input_resolution : RerunGenerations, freezeChain, resolveGraphInputs, unreadRerunBases;
    import confector.plugin_api.dispatch_queue : Lease;
    import confector.plugin_api.document_store : DocumentStore;
    import std.json : JSONValue;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    import core.time : Duration, hours;
    import std.algorithm.searching : canFind;
    import vibe.data.json : Json, deserializeJson;

    /// A dispatch queue that can be made to fail sends, and counts them.
    private final class FlakyDispatchQueue : DispatchQueue
    {
        DispatchQueue inner;
        /// Thrown by the next send, if set (then cleared).
        Exception failNextSend;
        size_t sends;

        this(DispatchQueue inner) { this.inner = inner; }

        void ensureQueue(string queue) { inner.ensureQueue(queue); }
        void send(string queue, Json message, Duration delay = Duration.zero)
        {
            ++sends;
            if (failNextSend !is null)
            {
                auto e = failNextSend;
                failNextSend = null;
                throw e;
            }
            inner.send(queue, message, delay);
        }
        Lease[] receive(string queue, size_t maxMessages, Duration visibility) { return inner.receive(queue, maxMessages, visibility); }
        void ack(string queue, string receipt) { inner.ack(queue, receipt); }
        void extend(string queue, string receipt, Duration visibility) { inner.extend(queue, receipt, visibility); }
        void release(string queue, string receipt, Duration delay = Duration.zero) { inner.release(queue, receipt, delay); }
    }

    /// Every message waiting on the default pool queue, received and left leased.
    private DispatchMessage[] drain(DispatchQueue queue)
    {
        DispatchMessage[] messages;
        for (auto batch = queue.receive(defaultPoolQueue, 10, 1.hours); batch.length > 0; batch = queue.receive(defaultPoolQueue, 10, 1.hours))
        {
            foreach (lease; batch) messages ~= deserializeJson!DispatchMessage(lease.message);
        }
        return messages;
    }

    /// compile (from repository "game") -> package, as chain "c1" of project "p", with a project
    /// defining both tasks and the repository registered.
    private BuildChain sampleChain()
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
        TaskNode package_; package_.id = "package"; package_.inputs["bin"] = taskOutputInput("compile");
        auto graph = new TaskGraph([compile, package_]);
        InputPin[InputDecl] none;
        InputPin[InputDecl] pins = [repositoryInput("game", "main"): InputPin(Json("aaa111"))];
        BuildChain chain;
        chain.id = "c1";
        chain.projectId = "p";
        chain.number = 7;
        chain.snapshotHash = "snap";
        chain.tasks = freezeChain(graph, resolveGraphInputs(graph, none, pins));
        chain.createdAt = "2026-10-16T10:00:00Z";
        return chain;
    }

    private ProjectRecord sampleProject()
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
        compile.steps = [BuildStep("Compile", "bash", null, "make")];
        TaskNode package_; package_.id = "package"; package_.inputs["bin"] = taskOutputInput("compile");
        package_.steps = [BuildStep("Package", "bash", null, "zip")];
        ProjectRecord project;
        project.id = "p";
        project.tasks = [compile, package_];
        return project;
    }

    private StateStores sampleStores(DocumentStore documents)
    {
        auto stores = new StateStores(documents);
        stores.projects.put(sampleProject());
        RepositoryRecord game;
        game.name = "game";
        game.address = "https://example.test/game.git";
        stores.repositories.put(game);
        return stores;
    }

    /// Evaluates chain `chain` with one request for `targets`, loading executions from `stores`
    /// as the shell does.
    private ChainEvaluation evaluateFromStore(StateStores stores, in BuildChain chain, string[] targets)
    {
        BuildRequest request;
        request.id = "r1";
        request.projectId = chain.projectId;
        request.chainId = chain.id;
        request.targets = targets;
        request.intent = BuildIntent.build;
        request.trigger.type = TriggerType.manual;
        request.requestedBy = "jason";
        request.requestedAt = "2026-10-16T10:00:01Z";

        RerunGenerations generations;
        for (auto unread = unreadRerunBases(chain.projectId, chain.tasks, generations); unread.length > 0;
            unread = unreadRerunBases(chain.projectId, chain.tasks, generations))
        {
            foreach (base; unread) generations[base] = 0;
        }
        auto fingerprints = evaluateChain(chain, [request], generations, null).resolution.fingerprints.values;
        return evaluateChain(chain, [request], generations, stores.executions.listForFingerprints(fingerprints));
    }

    private string fixedNow() { return "2026-10-16T10:00:02Z"; }

    private ExecutionDispatchException dispatchFailure(scope void delegate() run)
    {
        try run();
        catch (ExecutionDispatchException e) return e;
        assert(false, "expected ExecutionDispatchException");
    }
}

unittest
{
    // A needed fingerprint is claimed, its execution recorded with the definition, inputs and
    // repository addresses, and a tiny message naming it sent; demand is emitted after. The next
    // evaluation attaches to it, and dispatching again does nothing
    auto stores = sampleStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    size_t demands;
    auto dispatcher = new ExecutionDispatcher(stores, queue, () { ++demands; }, () => fixedNow());
    auto chain = sampleChain();

    auto evaluation = evaluateFromStore(stores, chain, ["package"]);
    assert(evaluation.needed.length == 1 && evaluation.needed[0].taskId == "compile");
    auto outcomes = dispatcher.dispatchChain(chain, evaluation);
    assert(outcomes.length == 1 && outcomes[0].result == DispatchResult.sent && demands == 1);

    const fp = evaluation.needed[0].fingerprint;
    const id = outcomes[0].executionId;
    assert(stores.claims.get(fp).get.executionId == id);
    auto execution = stores.executions.get(id).get;
    assert(execution.status == ExecutionStatus.queued && execution.fingerprint == fp && execution.taskId == "compile");
    assert(execution.definition.steps[0].script == "make" && execution.definitionHash.length == 64);
    assert(execution.definition.inputs["src"] == repositoryInput("game", "main"), "Declared inputs come from the chain");
    assert(execution.inputs == evaluation.resolution.inputs["compile"]);
    assert(execution.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(execution.createdAt == fixedNow() && execution.sentAt == fixedNow());

    auto messages = drain(queue);
    assert(messages == [DispatchMessage(id)]);
    assert(serializeToJson(messages[0]).toString().length < 200, "Messages carry ids, never definitions");

    auto next = evaluateFromStore(stores, chain, ["package"]);
    assert(next.needed.length == 0 && next.tasks["compile"].executionId == id);
    auto again = dispatcher.dispatch(planExecutions(chain, evaluation, sampleProject(), ["game": stores.repositories.get("game").get.value]));
    assert(again[0].result == DispatchResult.attached && again[0].executionId == id && demands == 1, "Nothing new: no demand");
    assert(drain(queue).length == 0);
}

unittest
{
    // Two dispatchers racing for one fingerprint create exactly one execution and send it once;
    // the loser does nothing. Forced at each compare-and-set: the claim's create, and the
    // execution's create
    auto documents = new InMemoryDocumentStore();
    auto stores = sampleStores(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto loserStores = new StateStores(interleaving);
    auto queue = new InMemoryDispatchQueue();
    auto winner = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    auto loser = new ExecutionDispatcher(loserStores, queue, null, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);
    const fp = evaluation.needed[0].fingerprint;

    // The winner dispatches entirely between the loser's read of the claim and its write
    DispatchOutcome[] won;
    interleaving.beforeNextWrite = () { won = winner.dispatchChain(chain, evaluation); };
    auto lost = loser.dispatchChain(chain, evaluation);
    assert(won[0].result == DispatchResult.sent);
    assert(lost[0].result == DispatchResult.attached && lost[0].executionId == won[0].executionId);
    assert(stores.executions.listForFingerprint(fp).length == 1);
    assert(drain(queue).length == 1);
}

unittest
{
    // A claim held by an execution that was never recorded (the dispatcher crashed between
    // claiming and recording) is repaired by the next evaluation: the execution is recorded
    // under the claimed id and sent. If the original dispatcher is merely slow and records it
    // first, the repairer's create loses and it does nothing
    auto documents = new InMemoryDocumentStore();
    auto stores = sampleStores(documents);
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);
    const fp = evaluation.needed[0].fingerprint;

    assert(stores.claims.claim(fp, "exe_crashed").won);
    auto repaired = evaluateFromStore(stores, chain, ["compile"]);
    assert(repaired.needed.length == 1, "No execution was recorded, so the fingerprint is still needed");
    auto outcome = dispatcher.dispatchChain(chain, repaired)[0];
    assert(outcome.result == DispatchResult.sent && outcome.executionId == "exe_crashed");
    assert(stores.executions.get("exe_crashed").get.sentAt.length > 0);
    assert(drain(queue) == [DispatchMessage("exe_crashed")]);

    // The slow original wins the execution's create
    auto interleaving = new InterleavingDocumentStore(documents);
    auto repairer = new ExecutionDispatcher(new StateStores(interleaving), queue, null, () => fixedNow());
    auto plan = planExecutions(chain, evaluation, sampleProject(), ["game": stores.repositories.get("game").get.value]);
    plan[0].fingerprint = "fp-slow";
    assert(stores.claims.claim("fp-slow", "exe_slow").won);
    interleaving.beforeNextWrite = () {
        TaskExecution slow;
        slow.id = "exe_slow";
        slow.projectId = "p";
        slow.taskId = "compile";
        slow.fingerprint = "fp-slow";
        slow.status = ExecutionStatus.queued;
        slow.createdAt = fixedNow();
        stores.executions.create(slow);
    };
    auto deferred = repairer.dispatch(plan)[0];
    assert(deferred.result == DispatchResult.attached && deferred.executionId == "exe_slow");
    assert(drain(queue).length == 0, "Only the execution's creator sends it");
}

unittest
{
    // Crash between persisting and enqueuing: a send that fails transiently leaves the execution
    // queued and unsent, and the dispatcher throws after dispatching the rest (emitting demand for
    // those). The next evaluation needs the fingerprint again and the dispatcher sends the same
    // execution: no second one
    auto stores = sampleStores(new InMemoryDocumentStore());
    auto queue = new FlakyDispatchQueue(new InMemoryDispatchQueue());
    size_t demands;
    auto dispatcher = new ExecutionDispatcher(stores, queue, () { ++demands; }, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);
    const fp = evaluation.needed[0].fingerprint;

    auto plan = planExecutions(chain, evaluation, sampleProject(), ["game": stores.repositories.get("game").get.value]);
    auto otherTask = plan[0];
    otherTask.fingerprint = "fp-other";
    queue.failNextSend = new Exception("connection reset");
    auto failure = dispatchFailure({ dispatcher.dispatch(plan ~ otherTask); });
    assert(failure.outcomes.length == 2);
    assert(failure.outcomes[0].result == DispatchResult.notSent && failure.outcomes[0].error.canFind("connection reset"));
    assert(failure.msg.canFind("connection reset") && failure.msg.canFind("'compile'"));
    assert(failure.outcomes[1].result == DispatchResult.sent, "One failed send does not stop the others");
    assert(demands == 1, "Demand is emitted for what was sent");

    const id = failure.outcomes[0].executionId;
    auto unsent = stores.executions.get(id).get;
    assert(unsent.status == ExecutionStatus.queued && unsent.sentAt.length == 0);
    assert(stores.claims.get(fp).get.executionId == id);

    auto next = evaluateFromStore(stores, chain, ["compile"]);
    assert(next.needed.length == 1 && next.tasks["compile"].executionId == id, "An unsent execution is needed again");
    auto repaired = dispatcher.dispatchChain(chain, next)[0];
    assert(repaired.result == DispatchResult.sent && repaired.executionId == id);
    assert(stores.executions.listForFingerprint(fp).length == 1);
    assert(stores.executions.get(id).get.sentAt.length > 0);
    assert(evaluateFromStore(stores, chain, ["compile"]).needed.length == 0);
    auto sentIds = drain(queue.inner);
    assert(sentIds.length == 2 && sentIds.canFind(DispatchMessage(id)));
}

unittest
{
    // A message the queue rejects as invalid fails the execution loudly and releases the claim,
    // so the task shows failed instead of pending forever; a later request (a retry) gets a new
    // execution
    auto stores = sampleStores(new InMemoryDocumentStore());
    auto queue = new FlakyDispatchQueue(new InMemoryDispatchQueue());
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);
    const fp = evaluation.needed[0].fingerprint;

    queue.failNextSend = new DispatchQueueUsageException("Message for queue 'default' is 70000 bytes; the limit is 65536");
    auto failure = dispatchFailure({ dispatcher.dispatchChain(chain, evaluation); });
    auto outcome = failure.outcomes[0];
    assert(outcome.result == DispatchResult.failed && outcome.error.canFind("70000 bytes"));
    auto failed = stores.executions.get(outcome.executionId).get;
    assert(failed.status == ExecutionStatus.failed && failed.errorMessage.canFind("rejected") && failed.finishedAt.length > 0);
    assert(stores.claims.get(fp).get.executionId.length == 0, "The claim is released");
    assert(evaluateFromStore(stores, chain, ["compile"]).tasks["compile"].status == ChainTaskStatus.failed);

    // A claim left held by a finished execution (its completion crashed before releasing it) is
    // released by the next dispatch, which claims the fingerprint afresh
    assert(stores.claims.claim(fp, outcome.executionId).won);
    auto retried = dispatcher.dispatch(planExecutions(chain, evaluation, sampleProject(), ["game": stores.repositories.get("game").get.value]))[0];
    assert(retried.result == DispatchResult.sent && retried.executionId != outcome.executionId);
    assert(stores.claims.get(fp).get.executionId == retried.executionId);
}

unittest
{
    // A task that cannot be dispatched (deleted from the project, or naming a repository with no
    // address) gets an execution that fails at once with the reason; nothing is sent
    auto stores = sampleStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);

    RepositoryRecord noAddress;
    noAddress.name = "game";
    auto plans = planExecutions(chain, evaluation, sampleProject(), ["game": noAddress]);
    assert(plans[0].unavailable.canFind("no address"));
    assert(planExecutions(chain, evaluation, sampleProject(), null)[0].unavailable.canFind("not registered"));
    ProjectRecord shrunk = sampleProject();
    shrunk.tasks = shrunk.tasks[1 .. $];
    assert(planExecutions(chain, evaluation, shrunk, null)[0].unavailable.canFind("deleted from project 'p'"));

    auto failure = dispatchFailure({ dispatcher.dispatch(plans); });
    assert(failure.outcomes[0].result == DispatchResult.failed);
    auto failed = stores.executions.get(failure.outcomes[0].executionId).get;
    assert(failed.status == ExecutionStatus.failed && failed.errorMessage.canFind("no address"));
    assert(drain(queue).length == 0);
    assert(evaluateFromStore(stores, chain, ["compile"]).tasks["compile"].status == ChainTaskStatus.failed);

    ProjectRecord other;
    other.id = "q";
    bool threw = false;
    try planExecutions(chain, evaluation, other, null);
    catch (Exception e) threw = e.msg.canFind("belongs to project 'p'");
    assert(threw);
}

unittest
{
    // Demand counts executions sent and not yet received, by executor type and requirements
    import confector.core.build_stores : ExecutionStore;

    TaskNode gpu;
    gpu.id = "train";
    gpu.setCustomComponent("executor", JSONValue("aws-ecs"));
    gpu.setCustomComponent("requirements", JSONValue(["gpu": JSONValue("true"), "cores": JSONValue(8)]));
    auto demand = executionDemand(gpu);
    assert(demand.executorType == "aws-ecs" && demand.pendingWorkOrderCount == 1);
    assert(demand.requirements == ["gpu": "true", "cores": "8"]);
    TaskNode plain;
    assert(executionDemand(plain).executorType == "local");

    auto stores = new StateStores(new InMemoryDocumentStore());
    TaskExecution sent;
    sent.id = "e1";
    sent.projectId = "p";
    sent.taskId = "train";
    sent.fingerprint = "fp1";
    sent.status = ExecutionStatus.queued;
    sent.definition = gpu;
    sent.createdAt = fixedNow();
    sent.sentAt = fixedNow();
    stores.executions.create(sent);
    TaskExecution unsent = sent;
    unsent.id = "e2";
    unsent.fingerprint = "fp2";
    unsent.sentAt = null;
    stores.executions.create(unsent);
    assert(queuedDemand(stores.executions) == [demand]);
}

unittest
{
    // A failure emitting demand after work was sent is logged, never thrown: the work is
    // committed, and a retried request would dispatch it twice
    auto stores = sampleStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, () { throw new Exception("provisioner down"); }, () => fixedNow());
    auto chain = sampleChain();
    auto outcomes = dispatcher.dispatchChain(chain, evaluateFromStore(stores, chain, ["compile"]));
    assert(outcomes[0].result == DispatchResult.sent);
    assert(drain(queue).length == 1);
}

version (unittest)
{
    /// A document store whose replaces fail while `failReplaces` is set, for tests.
    private final class FailingReplaceStore : DocumentStore
    {
        import confector.plugin_api.document_store : CollectionSpec, Document, IndexQuery, QueryPage;
        import std.typecons : Nullable;

        DocumentStore inner;
        bool failReplaces;

        this(DocumentStore inner) { this.inner = inner; }

        override void declare(const(CollectionSpec)[] collections) { inner.declare(collections); }
        override Nullable!Document get(string collection, string id) { return inner.get(collection, id); }
        override Document create(string collection, string id, Json content) { return inner.create(collection, id, content); }
        override Document replace(string collection, string id, Json content, ulong expectedVersion)
        {
            if (failReplaces) throw new Exception("store unavailable");
            return inner.replace(collection, id, content, expectedVersion);
        }
        override void remove(string collection, string id, ulong expectedVersion) { inner.remove(collection, id, expectedVersion); }
        override QueryPage query(string collection, const IndexQuery lookup) { return inner.query(collection, lookup); }
    }
}

unittest
{
    // Recording sentAt failing after a successful send still counts as sent (nothing is thrown);
    // the next evaluation sends the same execution again, and receiving drops the duplicate.
    // Abandoning an unsent execution fails it and releases its claim
    auto failing = new FailingReplaceStore(new InMemoryDocumentStore());
    auto stores = sampleStores(failing);
    auto queue = new InMemoryDispatchQueue();
    auto dispatcher = new ExecutionDispatcher(stores, queue, null, () => fixedNow());
    auto chain = sampleChain();
    auto evaluation = evaluateFromStore(stores, chain, ["compile"]);

    failing.failReplaces = true;
    auto outcome = dispatcher.dispatchChain(chain, evaluation)[0];
    failing.failReplaces = false;
    assert(outcome.result == DispatchResult.sent && outcome.error.canFind("store unavailable"));
    assert(stores.executions.get(outcome.executionId).get.sentAt.length == 0);
    auto again = dispatcher.dispatchChain(chain, evaluateFromStore(stores, chain, ["compile"]))[0];
    assert(again.result == DispatchResult.sent && again.executionId == outcome.executionId);
    assert(drain(queue) == [DispatchMessage(outcome.executionId), DispatchMessage(outcome.executionId)]);

    const fp = evaluation.needed[0].fingerprint;
    dispatcher.abandon(fp, outcome.executionId, "gave up");
    auto abandoned = stores.executions.get(outcome.executionId).get;
    assert(abandoned.status == ExecutionStatus.failed && abandoned.errorMessage == "gave up");
    assert(stores.claims.get(fp).get.executionId.length == 0);

    // An execution claimed but never recorded: only the claim is released
    assert(stores.claims.claim(fp, "exe_never").won);
    dispatcher.abandon(fp, "exe_never", "gave up");
    assert(stores.claims.get(fp).get.executionId.length == 0 && stores.executions.get("exe_never").isNull);
}
