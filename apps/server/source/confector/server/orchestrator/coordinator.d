module confector.server.orchestrator.coordinator;

import confector.core.model;
import confector.core.dag;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;
import confector.core.chain_resolver : resolveChain;
import confector.core.definition_hash : recordDefinition;
import confector.core.executor : CapacityBroker;
import confector.core.execution_dispatcher : DispatchOutcome, DispatchResult, ExecutionDispatchException, ExecutionDispatcher,
    PlannedExecution, defaultPoolQueue;
import confector.core.work_orders : finishClaimedExecution, finishExecution, requireClaimingExecution;
import confector.core.input_resolution : GraphResolution, RerunGenerations, chainGraph;
import confector.core.rerun_generations : readChainResolution;
import confector.plugin_api.dispatch_queue;
import confector.plugin_api.input_resolver : RepositoryResolver;

import std.algorithm : canFind, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.uuid : randomUUID;
import core.sync.mutex : Mutex;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

/**
 * Evaluates `chain`'s resolved inputs and fingerprints with every task at rerun generation 0.
 * This coordinator has no rerun generation store: no rerun can be requested yet (the rerun
 * action is bead confector-z7z.20.14), and it is being replaced by the ChainEvaluator (bead
 * confector-z7z.23.2), which reads generations through RerunGenerationStore. Whoever adds the
 * rerun action must replace this before reruns can take effect here.
 */
private GraphResolution chainResolutionBeforeReruns(string projectId, in ChainTask[] chain)
{
    return readChainResolution(projectId, chain, (in string[] bases) {
        RerunGenerations generations;
        foreach (base; bases) generations[base] = 0;
        return generations;
    });
}

/**
 * The execution status a completion's task status records. Throws if it is not a finished status.
 */
private ExecutionStatus finishedExecutionStatus(TaskStatus status)
{
    switch (status)
    {
        case TaskStatus.succeeded:
        case TaskStatus.cached:
            return ExecutionStatus.succeeded;
        case TaskStatus.failed:
            return ExecutionStatus.failed;
        case TaskStatus.cancelled:
            return ExecutionStatus.cancelled;
        default:
            throw new Exception(format("A task completion reported status '%s', which is not a finished status", status));
    }
}

/**
 * Metadata tracked for an active or recorded build graph execution.
 */
struct ActiveBuild
{
    string buildId;
    /// The project the build's configuration (steps, environment, outputs) is read from.
    ProjectRecord project;
    /// The build's chain: its frozen tasks, the graph they form, and every task's resolved inputs
    /// and fingerprint, which are computed from the chain alone (never from the project).
    ChainTask[] chain;
    TaskGraph graph;
    GraphResolution resolution;
    /// Address of each repository input of every task the build runs (task id -> input name ->
    /// address), looked up once when the build starts so dispatch does not depend on live
    /// repository records.
    string[string][string] repositoryAddresses;
    string[] targetTaskIds;
    bool force = false;
    string workspaceDir;
    /// Tasks planned for dispatch (and so recorded queued), by task id.
    bool[string] enqueuedTasks;
}

/**
 * Subscription of a build and task to an in-flight execution.
 */
struct InFlightSubscription
{
    string buildId;
    string taskId;
}

/**
 * Registry tracking actively queued or running task executions by fingerprint,
 * supporting multi-build subscription and in-flight deduplication (single-flight pattern).
 */
class InFlightTaskRegistry
{
    private InFlightSubscription[][string] m_inFlight; // fingerprint -> subscriptions
    private string[string] m_taskToFingerprint;         // "buildId:taskId" -> fingerprint

    private static string taskKey(string buildId, string taskId) pure nothrow @safe
    {
        return buildId ~ ":" ~ taskId;
    }

    /**
     * Checks whether a task with the given fingerprint is currently in flight.
     */
    bool isInFlight(string fingerprint) const pure nothrow @safe
    {
        if (fingerprint.length == 0) return false;
        auto p = fingerprint in m_inFlight;
        return p !is null && p.length > 0;
    }

    /**
     * Registers a build task execution or attaches it to an existing in-flight execution.
     * Returns true if newly registered (caller must enqueue work),
     * or false if already in flight (coalesced; caller attaches without duplicate work).
     */
    bool registerOrSubscribe(string fingerprint, string buildId, string taskId)
    {
        m_taskToFingerprint[taskKey(buildId, taskId)] = fingerprint;

        if (fingerprint.length == 0)
        {
            m_inFlight[fingerprint] ~= InFlightSubscription(buildId, taskId);
            return true;
        }

        if (auto pSubs = fingerprint in m_inFlight)
        {
            bool found = false;
            foreach (sub; *pSubs)
            {
                if (sub.buildId == buildId && sub.taskId == taskId)
                {
                    found = true;
                    break;
                }
            }
            if (!found)
            {
                *pSubs ~= InFlightSubscription(buildId, taskId);
            }
            return false;
        }
        else
        {
            m_inFlight[fingerprint] = [InFlightSubscription(buildId, taskId)];
            return true;
        }
    }

    /**
     * Retrieves all current subscribers for a given fingerprint.
     */
    InFlightSubscription[] getSubscribers(string fingerprint) const
    {
        if (auto p = fingerprint in m_inFlight)
        {
            return (*p).dup;
        }
        return [];
    }

    /**
     * Looks up the registered fingerprint for a specific build task.
     */
    bool getFingerprintForTask(string buildId, string taskId, out string fingerprint) const
    {
        if (auto p = taskKey(buildId, taskId) in m_taskToFingerprint)
        {
            fingerprint = *p;
            return true;
        }
        return false;
    }

    /**
     * Completes and removes an in-flight execution, returning all subscribed builds and tasks.
     */
    InFlightSubscription[] completeTask(string fingerprint)
    {
        InFlightSubscription[] subs;
        if (auto p = fingerprint in m_inFlight)
        {
            subs = *p;
            m_inFlight.remove(fingerprint);
            foreach (sub; subs)
            {
                m_taskToFingerprint.remove(taskKey(sub.buildId, sub.taskId));
            }
        }
        return subs;
    }

    /**
     * Unsubscribes a build from all in-flight tasks upon cancellation.
     */
    void unsubscribeBuild(string buildId)
    {
        string[] emptyFingerprints;
        foreach (fp, ref subs; m_inFlight)
        {
            InFlightSubscription[] remaining;
            foreach (sub; subs)
            {
                if (sub.buildId == buildId)
                {
                    m_taskToFingerprint.remove(taskKey(sub.buildId, sub.taskId));
                }
                else
                {
                    remaining ~= sub;
                }
            }
            if (remaining.length == 0)
            {
                emptyFingerprints ~= fp;
            }
            else
            {
                subs = remaining;
            }
        }
        foreach (fp; emptyFingerprints)
        {
            m_inFlight.remove(fp);
        }
    }

    /**
     * Returns count of currently in-flight unique task fingerprints.
     */
    size_t inFlightCount() const pure nothrow @safe
    {
        return m_inFlight.length;
    }
}

/**
 * Centralized Build Coordinator that orchestrates dynamic DAG progression, evaluates task
 * readiness, hands ready tasks to the ExecutionDispatcher, and processes asynchronous task
 * completions over network-safe boundaries.
 *
 * Evaluation runs under m_mutex and only plans dispatches (`m_toDispatch`); the public entry
 * points dispatch them after releasing it (`dispatchPending`), so claiming, recording and sending
 * executions and evaluating capacity never hold up other builds (bug confector-sit).
 */
class BuildCoordinator
{
    private ArtifactStorage m_artifactStorage;
    private StateStores m_stores;
    private DispatchQueue m_dispatchQueue;
    private ExecutionDispatcher m_dispatcher;
    private Mutex m_mutex;
    private ActiveBuild[string] m_activeBuilds;
    private InFlightTaskRegistry m_inFlightRegistry;
    /// The definition each in-flight execution was dispatched with, by fingerprint, to record
    /// on its result. Lost on restart; see `completedDefinition`.
    private TaskNode[string] m_dispatchedDefinitions;
    /// Executions planned under m_mutex, for `dispatchPending` to dispatch outside it.
    private PlannedExecution[] m_toDispatch;
    private RepositoryResolver m_repositoryResolver;

    /**
     * `capacityBroker`, when given, is asked to evaluate demand after executions are sent.
     * `repositoryResolver` resolves every repository input when a build chain is created. Git
     * is the only built-in provider, so one resolver serves every repository; when repositories
     * record their provider, `selectResolver` picks by it. Without a resolver, creating a chain
     * whose tasks declare repository inputs fails loudly.
     *
     * Throws: Exception if `stores` or `dispatchQueue` is null.
     */
    this(
        ArtifactStorage artifactStorage,
        StateStores stores,
        DispatchQueue dispatchQueue,
        CapacityBroker capacityBroker = null,
        RepositoryResolver repositoryResolver = null
    )
    {
        m_repositoryResolver = repositoryResolver;
        m_artifactStorage = artifactStorage;
        m_stores = stores;
        m_dispatchQueue = dispatchQueue;
        m_dispatcher = new ExecutionDispatcher(stores, dispatchQueue,
            capacityBroker !is null ? &capacityBroker.evaluateDemand : null);
        m_mutex = new Mutex();
        m_inFlightRegistry = new InFlightTaskRegistry();
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }
    @property StateStores stores() { return m_stores; }
    @property DispatchQueue dispatchQueue() { return m_dispatchQueue; }
    @property InFlightTaskRegistry inFlightRegistry() { return m_inFlightRegistry; }

    /**
     * Initiates a new build for the given project and optional target task: creates a build
     * chain by resolving every input of the whole project DAG once, then evaluates the chain's
     * initial roots and sends ready tasks to the dispatch queue. Returns the generated build ID,
     * which also identifies the chain.
     *
     * Throws: InputResolutionException if any input cannot be resolved; nothing is recorded
     * or dispatched then.
     */
    string startBuild(
        ProjectRecord project,
        string targetTaskId = null,
        bool force = false,
        string triggerSource = "manual",
        string workspaceDir = null
    )
    {
        // Resolve the whole DAG once; this is the only place a chain's inputs are resolved. It
        // runs before the lock is taken: resolvers do network I/O, and a slow remote must not
        // stall completions and evaluations of other builds. It needs only the repository
        // lookup and the resolver, and records nothing, so a failure leaves no trace.
        InputPin[InputDecl] noPins;
        ChainTask[] chain = resolveChain(new TaskGraph(project), noPins,
            &lookupRepository, &selectResolver);

        string buildId = "bld_" ~ randomUUID().toString()[0 .. 8];

        // Persist project if not already saved
        if (project.id.length > 0 && m_stores !is null)
        {
            m_stores.projects.put(project);
        }

        return startOnChain(project, chain, buildId, buildId, targetTaskId, force, triggerSource, workspaceDir);
    }

    /**
     * Builds `targetTaskId` (and its upstream tasks) of the existing chain that build
     * `chainBuildId` belongs to, against the chain's frozen inputs: nothing is resolved again
     * and the project's current inputs are ignored. Build configuration is read from the
     * project as it is now. Returns the new build's ID.
     *
     * Throws: Exception if the build or its project does not exist, the build has no chain, or
     * `targetTaskId` is not a task of the chain (it was added to the project later).
     */
    string buildInChain(
        string chainBuildId,
        string targetTaskId,
        bool force = false,
        string triggerSource = "manual",
        string workspaceDir = null
    )
    {
        // Reads only persisted state, so it needs no lock
        if (m_stores is null)
        {
            throw new Exception("Cannot build in an existing chain without state stores");
        }
        BuildRecord origin;
        if (!m_stores.legacyBuilds.getBuild(chainBuildId, origin))
        {
            throw new Exception(format("Build '%s' does not exist", chainBuildId));
        }
        if (origin.chainTasks.length == 0 || origin.chainId.length == 0)
        {
            throw new Exception(format("Build '%s' has no build chain", chainBuildId));
        }
        ProjectRecord project;
        if (!m_stores.projects.get(origin.projectId).tryValue(project))
        {
            throw new Exception(format("Project '%s' of build '%s' does not exist", origin.projectId, chainBuildId));
        }

        string buildId = "bld_" ~ randomUUID().toString()[0 .. 8];
        return startOnChain(project, origin.chainTasks, origin.chainId, buildId, targetTaskId, force,
            triggerSource, workspaceDir);
    }

    /// Records build `buildId` on chain `chainId`, starts evaluating it and dispatches its ready
    /// tasks. Validating the request, looking up repository addresses and recording the build
    /// happen before m_mutex is taken; only registering and evaluating the build hold it.
    private string startOnChain(
        ProjectRecord project,
        ChainTask[] chain,
        string chainId,
        string buildId,
        string targetTaskId,
        bool force,
        string triggerSource,
        string workspaceDir
    )
    {
        TaskGraph graph = chainGraph(chain);
        GraphResolution resolution = chainResolutionBeforeReruns(project.id, chain);

        string[] targetTaskIds;
        if (targetTaskId.length > 0)
        {
            if (!graph.allTaskIds().canFind(targetTaskId))
            {
                throw new Exception(format("Task '%s' is not part of build chain '%s'", targetTaskId, chainId));
            }
            targetTaskIds = graph.resolveSubgraph(targetTaskId);
        }
        else
        {
            targetTaskIds = graph.topologicalSort();
        }

        // Every task to run must still exist in the project, which supplies its configuration.
        // Check before anything is recorded so a deleted task leaves no orphaned build.
        foreach (tId; targetTaskIds)
        {
            if (!project.tasks.canFind!(t => t.id == tId))
            {
                throw new Exception(format("Task '%s' of build chain '%s' was deleted from project '%s' after the chain was created",
                    tId, chainId, project.id));
            }
        }

        // Every repository input of every task to run must have an address to check out from.
        // Look them up now, before anything is recorded, so a missing repository fails the
        // request instead of stranding a recorded build mid-dispatch.
        string[string][string] addresses = chainRepositoryAddresses(graph, targetTaskIds);

        // Create and persist initial BuildRecord
        BuildRecord buildRecord;
        buildRecord.buildId = buildId;
        buildRecord.chainId = chainId;
        buildRecord.chainTasks = chain;
        buildRecord.projectId = project.id;
        buildRecord.projectName = project.name.length > 0 ? project.name : "default";
        buildRecord.status = "queued";
        buildRecord.triggerSource = triggerSource;
        buildRecord.targetTaskId = targetTaskId;
        buildRecord.workspaceDir = workspaceDir;
        buildRecord.startedAt = Clock.currTime.toISOString();
        buildRecord.executedTasks = [];

        if (m_stores !is null)
        {
            // The build first: a task record takes its project from its build.
            m_stores.legacyBuilds.createBuild(buildRecord);
            foreach (tId; targetTaskIds)
            {
                m_stores.legacyBuilds.setTaskStatus(buildId, tId, TaskStatus.pending);
            }
        }

        ActiveBuild active;
        active.buildId = buildId;
        active.project = project;
        active.chain = chain;
        active.graph = graph;
        active.resolution = resolution;
        active.repositoryAddresses = addresses;
        active.targetTaskIds = targetTaskIds;
        active.force = force;
        active.workspaceDir = workspaceDir;

        logInfo("[coordinator] Starting build '%s' on chain '%s' for project '%s' (target: %s, %d tasks in DAG)", buildId, chainId, project.name.length > 0 ? project.name : (project.id.length > 0 ? project.id : "default"), targetTaskId.length > 0 ? targetTaskId : "all", targetTaskIds.length);

        synchronized (m_mutex)
        {
            m_activeBuilds[buildId] = active;
            // Evaluate initial root tasks & resolve cached nodes upfront
            evaluateReadyTasksLocked(buildId);
        }
        dispatchPending();

        return buildId;
    }

    /// Looks up a repository record for input resolution. Throws if it is not registered.
    private RepositoryRecord lookupRepository(string repositoryId)
    {
        if (m_stores is null)
        {
            throw new Exception("no state stores are configured to look repositories up in");
        }
        RepositoryRecord repository;
        if (!m_stores.repositories.get(repositoryId).tryValue(repository))
        {
            throw new Exception(format("repository '%s' is not registered", repositoryId));
        }
        return repository;
    }

    /// Chooses the resolver for a repository; see the constructor.
    private RepositoryResolver selectResolver(in RepositoryRecord repository)
    {
        return m_repositoryResolver;
    }

    /// Returns task `taskId`'s fingerprint in `active`'s chain. Throws if it has none.
    private static string chainFingerprint(ref ActiveBuild active, string taskId)
    {
        auto fingerprint = taskId in active.resolution.fingerprints;
        if (fingerprint is null)
        {
            throw new Exception(format("Build '%s' has no fingerprint for task '%s'", active.buildId, taskId));
        }
        return *fingerprint;
    }

    /**
     * Records task `taskId` of build `buildId` as failed because it could not be dispatched, and
     * forgets that it was planned. If its fingerprint was registered in flight
     * (`registeredFingerprint`, empty if not yet), every build task attached to that fingerprint
     * fails too, since no execution will complete for them. The records carry the task's
     * definition when it is known (`node` is null if the task was deleted). Returns the builds
     * whose tasks failed, to evaluate again. Must be called with m_mutex held.
     */
    private string[] failDispatch(string buildId, string taskId, string registeredFingerprint, string error, const(TaskNode)* node)
    {
        InFlightSubscription[] failing = [InFlightSubscription(buildId, taskId)];
        if (registeredFingerprint.length > 0)
        {
            foreach (sub; m_inFlightRegistry.completeTask(registeredFingerprint))
            {
                if (!failing.canFind(sub)) failing ~= sub;
            }
            m_dispatchedDefinitions.remove(registeredFingerprint);
        }

        string[] builds;
        foreach (sub; failing)
        {
            string message = format("Task '%s' could not be dispatched: %s", sub.taskId, error);
            logError("[coordinator] Build '%s': %s", sub.buildId, message);
            if (auto active = sub.buildId in m_activeBuilds)
            {
                active.enqueuedTasks.remove(sub.taskId);
            }

            TaskExecutionRecord rec;
            rec.status = cast(string) TaskStatus.failed;
            rec.errorMessage = message;
            rec.exitCode = 1;
            rec.finishedAt = Clock.currTime.toISOString();
            if (node !is null) recordDefinition(rec, *node);
            recordTaskResult(sub.buildId, sub.taskId, rec);
            if (!builds.canFind(sub.buildId)) builds ~= sub.buildId;
        }
        return builds;
    }

    /**
     * Dispatches the executions that evaluations planned (`m_toDispatch`), outside m_mutex:
     * claiming, recording and sending executions and evaluating capacity are I/O that must not
     * hold up other builds (bug confector-sit). A task whose execution failed or could not be sent
     * fails, with every build task attached to it, so its builds fail instead of waiting forever
     * for a completion (bug confector-z7z.23.11); an execution that could not be sent is failed
     * too and its claim released. An execution that was sent but whose `sentAt` could not be
     * recorded counts as sent (the dispatcher logs it).
     */
    private void dispatchPending()
    {
        while (true)
        {
            PlannedExecution[] batch;
            synchronized (m_mutex)
            {
                batch = m_toDispatch;
                m_toDispatch = null;
            }
            if (batch.length == 0) return;

            DispatchOutcome[] outcomes;
            try
            {
                outcomes = m_dispatcher.dispatch(batch);
            }
            catch (ExecutionDispatchException e)
            {
                // Not dropped: every failed task fails its builds below, with the error recorded.
                logError("[coordinator] %s", e.msg);
                outcomes = e.outcomes;
            }

            // This coordinator fails a task whose execution was not sent rather than waiting for
            // a later evaluation to send it, so the execution is failed too (and its claim
            // released): the task and its execution agree, and a later build dispatches afresh.
            foreach (ref outcome; outcomes)
            {
                if (outcome.result != DispatchResult.notSent) continue;
                try
                {
                    m_dispatcher.abandon(outcome.fingerprint, outcome.executionId, outcome.error);
                }
                catch (Exception e)
                {
                    // Recorded with the task's failure below; the execution stays queued and
                    // unsent, and the next dispatch of its fingerprint sends it.
                    outcome.error ~= format(" Recording execution '%s' as failed also failed: %s", outcome.executionId, e.msg);
                }
            }

            synchronized (m_mutex)
            {
                string[] toEvaluate;
                foreach (ref outcome; outcomes)
                {
                    final switch (outcome.result)
                    {
                        case DispatchResult.sent:
                            logInfo("[coordinator] Task '%s' sent as execution '%s' (fingerprint: %s)", outcome.taskId, outcome.executionId, outcome.fingerprint);
                            break;
                        case DispatchResult.attached:
                            logInfo("[coordinator] Task '%s' attached to execution '%s' (fingerprint: %s)", outcome.taskId, outcome.executionId, outcome.fingerprint);
                            break;
                        case DispatchResult.failed:
                        case DispatchResult.notSent:
                            TaskNode node;
                            bool haveNode = false;
                            if (auto p = outcome.fingerprint in m_dispatchedDefinitions)
                            {
                                node = *p;
                                haveNode = true;
                            }
                            string planner;
                            foreach (ref planned; batch)
                            {
                                if (planned.fingerprint == outcome.fingerprint) planner = planned.legacyBuildId;
                            }
                            foreach (b; failDispatch(planner, outcome.taskId, outcome.fingerprint, outcome.error, haveNode ? &node : null))
                            {
                                if (!toEvaluate.canFind(b)) toEvaluate ~= b;
                            }
                            break;
                    }
                }
                // The failed tasks fail their builds and cancel what is left
                foreach (b; toEvaluate) evaluateReadyTasksLocked(b);
            }
        }
    }

    /**
     * Records the outcome in `result` (status, fingerprint, exit code, error, duration,
     * artifacts, finish time and definition) on task `taskId`'s record in build `buildId`, by
     * compare-and-set so a concurrent status change is not lost. The record is created first if
     * the build never recorded the task.
     */
    private void recordTaskResult(string buildId, string taskId, TaskExecutionRecord result)
    {
        TaskExecutionRecord existing;
        if (!m_stores.legacyBuilds.getTaskExecution(buildId, taskId, existing))
        {
            m_stores.legacyBuilds.setTaskStatus(buildId, taskId, TaskStatus.pending);
        }
        m_stores.legacyBuilds.updateTaskExecution(buildId, taskId, (ref TaskExecutionRecord rec) {
            rec.status = result.status;
            rec.fingerprint = result.fingerprint;
            rec.exitCode = result.exitCode;
            rec.errorMessage = result.errorMessage;
            rec.durationMs = result.durationMs;
            rec.producedArtifacts = result.producedArtifacts;
            rec.finishedAt = result.finishedAt;
            rec.definition = result.definition;
            rec.definitionHash = result.definitionHash;
        });
    }

    /// Applies `change` to build `buildId`'s record, if it exists, by compare-and-set.
    private void updateBuildIfRecorded(string buildId, void delegate(ref BuildRecord) change)
    {
        BuildRecord existing;
        if (m_stores.legacyBuilds.getBuild(buildId, existing))
        {
            m_stores.legacyBuilds.updateBuild(buildId, change);
        }
    }

    /// Adds `taskId` to build `buildId`'s executed tasks, if the build is recorded.
    private void recordExecutedTask(string buildId, string taskId)
    {
        updateBuildIfRecorded(buildId, (ref BuildRecord b) {
            if (!b.executedTasks.canFind(taskId)) b.executedTasks ~= taskId;
        });
    }

    /**
     * Throws if a task_output input of `node` (task `taskId`) requests an artifact that the
     * recorded result of its upstream task, at the fingerprint the input is pinned to, does not
     * contain. Build configuration is not fingerprinted, so a cached result can predate a change
     * to the upstream task's output declarations. An upstream result with no record here is left
     * to the runner, which checks the artifact store when it stages the artifact.
     */
    private void requireUpstreamArtifacts(ref ActiveBuild active, in TaskNode node, string taskId)
    {
        if (m_stores is null) return;
        foreach (input; chainInputs(active, taskId))
        {
            if (input.kind != InputKind.taskOutput) continue;
            const decl = node.inputs.get(input.name, InputDecl.init);
            if (decl.spec.artifact.length == 0) continue;

            string upstreamFingerprint = input.pinned.get!string;
            CachedResult upstream;
            if (!m_stores.resultCache.get(upstreamFingerprint, upstream)) continue;
            if (!upstream.artifacts.canFind!(meta => (meta.artifactId.length > 0 ? meta.artifactId : meta.filePath) == decl.spec.artifact))
            {
                throw new Exception(missingUpstreamArtifactMessage(decl.spec.task, upstreamFingerprint, decl.spec.artifact));
            }
        }
    }

    /// Returns task `taskId`'s resolved inputs in `active`'s chain, sorted by name. Throws if
    /// it has none (every task of a chain has an entry, empty when it declares no inputs).
    private static ResolvedInput[] chainInputs(ref ActiveBuild active, string taskId)
    {
        auto inputs = taskId in active.resolution.inputs;
        if (inputs is null)
        {
            throw new Exception(format("Build '%s' has no resolved inputs for task '%s'", active.buildId, taskId));
        }
        return (*inputs).dup;
    }

    /**
     * Returns the address of the repository each repository input of each of `taskIds` names
     * (task id -> input name -> address; tasks without repository inputs have no entry), read
     * from the repository records now: an address says how to fetch, not what, so it is
     * configuration rather than part of the chain. Inputs come from the chain's `graph`.
     *
     * Throws: Exception if a repository is not registered or has no address.
     */
    private string[string][string] chainRepositoryAddresses(TaskGraph graph, in string[] taskIds)
    {
        string[string][string] addresses;
        foreach (tId; taskIds)
        {
            foreach (name, decl; graph.getTask(tId).inputs)
            {
                if (decl.kind != InputKind.repository) continue;
                RepositoryRecord repository = lookupRepository(decl.spec.repository);
                if (repository.address.length == 0)
                {
                    throw new Exception(format("Task '%s' input '%s': repository '%s' has no address to check out from",
                        tId, name, decl.spec.repository));
                }
                addresses[tId][name] = repository.address;
            }
        }
        return addresses;
    }

    /**
     * Returns the task to dispatch: its build configuration as the build's project defines it,
     * its inputs as the chain froze them. Throws if the task was deleted from the project after
     * the chain was created.
     */
    private static TaskNode dispatchTask(ref ActiveBuild active, string taskId)
    {
        foreach (ref task; active.project.tasks)
        {
            if (task.id != taskId) continue;
            TaskNode node = task;
            node.inputs = active.graph.getTask(taskId).inputs;
            return node;
        }
        throw new Exception(format("Task '%s' of build '%s' was deleted from project '%s' after its build chain was created",
            taskId, active.buildId, active.project.id));
    }

    /**
     * Returns the build configuration of task `taskId` of build `buildId` as the project defines it
     * now. Used to record a result's definition when the one the task was dispatched with is
     * unknown, as after a restart, so it is the best available rather than certain. Throws if
     * the build, its project or the task no longer exists.
     */
    private TaskNode completedDefinition(string buildId, string taskId)
    {
        if (auto active = buildId in m_activeBuilds)
        {
            return dispatchTask(*active, taskId);
        }
        BuildRecord build;
        if (!m_stores.legacyBuilds.getBuild(buildId, build))
        {
            throw new Exception(format("Build '%s' does not exist", buildId));
        }
        ProjectRecord project;
        if (!m_stores.projects.get(build.projectId).tryValue(project))
        {
            throw new Exception(format("Project '%s' of build '%s' does not exist", build.projectId, buildId));
        }
        foreach (task; project.tasks)
        {
            if (task.id == taskId) return task;
        }
        throw new Exception(format("Task '%s' of build '%s' was deleted from project '%s'", taskId, buildId, build.projectId));
    }

    /**
     * Steps DAG progression for a given build: evaluates dependencies,
     * resolves cached nodes, and enqueues newly unblocked WorkOrders.
     */
    void stepBuild(string buildId)
    {
        synchronized (m_mutex)
        {
            evaluateReadyTasksLocked(buildId);
        }
        dispatchPending();
    }

    /**
     * Handles task completion results from local or remote workers.
     * Updates task and build status, saves cached fingerprints, and advances downstream dependents
     * for all builds subscribed to the completed task execution.
     */
    void onTaskCompleted(string fingerprint, TaskExecutionResult result, string receiptHandle = null)
    {
        if (result.fingerprint.length == 0)
        {
            result.fingerprint = fingerprint;
        }
        if (receiptHandle.length > 0 && result.receiptHandle.length == 0)
        {
            result.receiptHandle = receiptHandle;
        }
        onTaskCompleted(result.buildId, result.taskId, result, receiptHandle);
    }

    void onTaskCompleted(TaskExecutionResult result, string receiptHandle = null)
    {
        if (receiptHandle.length > 0 && result.receiptHandle.length == 0)
        {
            result.receiptHandle = receiptHandle;
        }
        onTaskCompleted(result.buildId, result.taskId, result, receiptHandle);
    }

    /**
     * Records a worker's completion of task `taskId` of build `buildId`. A result naming its
     * execution (`result.executionId`) is recorded only if that execution still holds its
     * fingerprint's claim, and its fingerprint is the execution record's; one that does not name
     * it falls back to the fingerprint this process knows, or the worker's.
     *
     * Everything is recorded (every attached build's result, then the execution's outcome)
     * before the in-flight registration is dropped and the receipt acknowledged, so a failure
     * part-way leaves nothing forgotten: the report is rejected, the worker does not acknowledge
     * its lease, and the work order is delivered again (another attempt of the execution).
     *
     * Throws: StaleCompletionException if the result's execution no longer holds its
     * fingerprint's claim; Exception if recording fails, or `result.status` is not a finished
     * status.
     */
    void onTaskCompleted(string buildId, string taskId, TaskExecutionResult result, string receiptHandle = null)
    {
        synchronized (m_mutex)
        {
            logInfo("[coordinator] Build '%s': Task '%s' completion received with status '%s' (exit code: %d, duration: %d ms, error: '%s')", buildId, taskId, result.status, result.exitCode, result.durationMs, result.errorMessage);
            const executionStatus = finishedExecutionStatus(result.status);

            // Which execution this is, and its fingerprint: the execution record's when the
            // result names it (never the worker's); otherwise the one this process knows for the
            // task, or the worker's only after a restart.
            string fingerprint;
            if (result.executionId.length > 0)
            {
                fingerprint = requireClaimingExecution(m_stores, result.executionId).fingerprint;
            }
            else
            {
                m_inFlightRegistry.getFingerprintForTask(buildId, taskId, fingerprint);
                if (fingerprint.length == 0)
                {
                    if (auto active = buildId in m_activeBuilds)
                    {
                        fingerprint = active.resolution.fingerprints.get(taskId, null);
                    }
                }
                if (fingerprint.length == 0)
                {
                    fingerprint = result.fingerprint;
                }
            }

            // The builds attached to it; nothing is dropped until all are recorded
            InFlightSubscription[] subscribers;
            if (fingerprint.length > 0)
            {
                subscribers = m_inFlightRegistry.getSubscribers(fingerprint);
            }

            // Only use fallback for legacy/unknown-fingerprint completions if the original build is still non-terminal
            if (subscribers.length == 0)
            {
                BuildRecord origBuild;
                bool origBuildExists = (m_stores !is null && m_stores.legacyBuilds.getBuild(buildId, origBuild));
                bool origBuildNonTerminal = origBuildExists &&
                    (origBuild.status != "cancelled" && origBuild.status != "failed" && origBuild.status != "succeeded");

                if (origBuildNonTerminal)
                {
                    subscribers = [InFlightSubscription(buildId, taskId)];
                }
            }

            // The definition the execution was dispatched with, if this process dispatched it
            TaskNode dispatched;
            bool haveDispatched = false;
            if (auto p = fingerprint in m_dispatchedDefinitions)
            {
                dispatched = *p;
                haveDispatched = true;
            }

            string[] buildsToEvaluate;
            foreach (sub; subscribers)
            {
                string subBuildId = sub.buildId;
                string subTaskId = sub.taskId;

                // Record task execution record
                TaskExecutionRecord rec;
                // A missing definition must never drop the completion
                try
                {
                    recordDefinition(rec, haveDispatched ? dispatched : completedDefinition(subBuildId, subTaskId));
                }
                catch (Exception e)
                {
                    logError("[coordinator] Build '%s': recording task '%s' without its definition: %s", subBuildId, subTaskId, e.msg);
                }
                rec.status = cast(string)result.status;
                rec.fingerprint = fingerprint.length > 0 ? fingerprint : result.fingerprint;
                rec.exitCode = result.exitCode;
                rec.errorMessage = result.errorMessage;
                rec.durationMs = result.durationMs;
                rec.producedArtifacts = result.producedArtifacts;
                rec.finishedAt = Clock.currTime.toISOString();

                recordTaskResult(subBuildId, subTaskId, rec);

                // If fingerprint is valid and artifacts exist/succeeded, save to cache
                if ((result.status == TaskStatus.succeeded || result.status == TaskStatus.cached)
                    && rec.fingerprint.length > 0)
                {
                    m_stores.resultCache.save(rec.fingerprint,
                        CachedResult(result.producedArtifacts, rec.definition, rec.definitionHash));
                }

                recordExecutedTask(subBuildId, subTaskId);

                // Logs last, after the state they describe is recorded
                foreach (line; result.logs)
                {
                    m_stores.logs.appendBuildLog(subBuildId, line);
                }

                if (!buildsToEvaluate.canFind(subBuildId))
                {
                    buildsToEvaluate ~= subBuildId;
                }
            }

            // Then the execution's outcome, releasing its fingerprint's claim so the fingerprint
            // can be dispatched again (a forced build, a retry)
            if (result.executionId.length > 0)
            {
                finishExecution(m_stores, result.executionId, executionStatus, result.exitCode,
                    result.errorMessage, result.producedArtifacts);
            }
            else if (fingerprint.length > 0)
            {
                finishClaimedExecution(m_stores, fingerprint, executionStatus, result.exitCode,
                    result.errorMessage, result.producedArtifacts);
            }

            // Everything is recorded: forget the in-flight execution
            if (fingerprint.length > 0)
            {
                m_inFlightRegistry.completeTask(fingerprint);
                m_dispatchedDefinitions.remove(fingerprint);
            }

            // Advance DAG progression for all subscribed builds
            foreach (bId; buildsToEvaluate)
            {
                evaluateReadyTasksLocked(bId);
            }

            // Acknowledge the work order last, once its completion is recorded
            string effectiveReceiptHandle = receiptHandle.length > 0 ? receiptHandle : result.receiptHandle;
            if (effectiveReceiptHandle.length > 0 && m_dispatchQueue !is null)
            {
                try
                {
                    m_dispatchQueue.ack(defaultPoolQueue, effectiveReceiptHandle);
                }
                catch (LeaseLostException e)
                {
                    // Expected when the worker acknowledged the work order itself.
                    logDebug("[coordinator] Queue acknowledgment note for receipt handle '%s': %s", effectiveReceiptHandle, e.msg);
                }
                catch (DispatchQueueUsageException e)
                {
                    // A malformed receipt is the caller's bug: reject the completion loudly.
                    throw e;
                }
                catch (Exception e)
                {
                    // The completion is recorded; the message will be redelivered, and receiving
                    // an execution that already finished drops it.
                    logError("[coordinator] Failed to acknowledge receipt handle '%s': %s", effectiveReceiptHandle, e.msg);
                }
            }
        }
        dispatchPending();
    }

    /**
     * Cancels an in-flight build and marks all pending/running tasks as cancelled.
     */
    void cancelBuild(string buildId)
    {
        synchronized (m_mutex)
        {
            if (m_stores !is null)
            {
                updateBuildIfRecorded(buildId, (ref BuildRecord b) {
                    b.status = "cancelled";
                    b.finishedAt = Clock.currTime.toISOString();
                });

                auto statuses = m_stores.legacyBuilds.getTaskStatusesForBuild(buildId);
                foreach (tId, status; statuses)
                {
                    if (status == TaskStatus.pending || status == TaskStatus.queued || status == TaskStatus.running)
                    {
                        m_stores.legacyBuilds.setTaskStatus(buildId, tId, TaskStatus.cancelled, "Build cancelled by user");
                    }
                }
            }

            m_inFlightRegistry.unsubscribeBuild(buildId);
            m_activeBuilds.remove(buildId);
        }
    }

    /**
     * Internal DAG progression evaluation. Must be called with m_mutex held.
     */
    private void evaluateReadyTasksLocked(string buildId)
    {
        ActiveBuild* pActive = buildId in m_activeBuilds;
        if (pActive is null)
        {
            // Try to reconstruct active build from repository
            if (m_stores !is null)
            {
                BuildRecord b;
                if (m_stores.legacyBuilds.getBuild(buildId, b))
                {
                    if (b.status == "cancelled" || b.status == "failed" || b.status == "succeeded")
                    {
                        return;
                    }
                    // Structure and fingerprints come from the build's chain, never from the
                    // project, which may have changed since; only configuration is read live.
                    if (b.chainTasks.length == 0)
                    {
                        throw new Exception(format("Build '%s' has no build chain and cannot be resumed", buildId));
                    }
                    ProjectRecord proj;
                    if (!m_stores.projects.get(b.projectId).tryValue(proj))
                    {
                        throw new Exception(format("Project '%s' of build '%s' does not exist", b.projectId, buildId));
                    }
                    ActiveBuild act;
                    act.buildId = buildId;
                    act.project = proj;
                    act.chain = b.chainTasks;
                    act.graph = chainGraph(b.chainTasks);
                    act.resolution = chainResolutionBeforeReruns(b.projectId, b.chainTasks);
                    if (b.targetTaskId.length > 0)
                    {
                        act.targetTaskIds = act.graph.resolveSubgraph(b.targetTaskId);
                    }
                    else
                    {
                        act.targetTaskIds = act.graph.topologicalSort();
                    }
                    act.workspaceDir = b.workspaceDir;
                    try
                    {
                        act.repositoryAddresses = chainRepositoryAddresses(act.graph, act.targetTaskIds);
                    }
                    catch (Exception e)
                    {
                        // Nothing of this build can be dispatched any more: fail it rather
                        // than leave it running forever.
                        logError("[coordinator] Build '%s' cannot be resumed: %s", buildId, e.msg);
                        m_stores.legacyBuilds.updateBuild(buildId, (ref BuildRecord failed) {
                            failed.status = "failed";
                            failed.errorMessage = e.msg;
                            failed.finishedAt = Clock.currTime.toISOString();
                        });
                        return;
                    }
                    m_activeBuilds[buildId] = act;
                    pActive = buildId in m_activeBuilds;
                }
            }
        }

        if (pActive is null)
        {
            return;
        }

        ActiveBuild active = *pActive;
        TaskStatus[string] statuses;
        if (m_stores !is null)
        {
            statuses = m_stores.legacyBuilds.getTaskStatusesForBuild(buildId);
        }

        // 1. Check for failure termination
        bool hasFailure = false;
        string failureMsg;
        foreach (tId; active.targetTaskIds)
        {
            auto pStat = tId in statuses;
            if (pStat !is null && *pStat == TaskStatus.failed)
            {
                hasFailure = true;
                TaskExecutionRecord taskRec;
                if (m_stores.legacyBuilds.getTaskExecution(buildId, tId, taskRec))
                {
                    failureMsg = taskRec.errorMessage;
                }
                break;
            }
        }

        if (hasFailure)
        {
            logWarn("[coordinator] Build '%s' failing early due to task failure: %s", buildId, failureMsg);

            // Cancel unstarted downstream tasks
            foreach (tId; active.targetTaskIds)
            {
                auto pStat = tId in statuses;
                if (pStat is null || *pStat == TaskStatus.pending || *pStat == TaskStatus.queued)
                {
                    if (m_stores !is null)
                    {
                        m_stores.legacyBuilds.setTaskStatus(buildId, tId, TaskStatus.cancelled, "Cancelled due to upstream task failure");
                    }
                }
            }

            // Update build status
            if (m_stores !is null)
            {
                updateBuildIfRecorded(buildId, (ref BuildRecord b) {
                    b.status = "failed";
                    b.finishedAt = Clock.currTime.toISOString();
                    if (failureMsg.length > 0)
                    {
                        b.errorMessage = failureMsg;
                    }
                });
            }

            m_inFlightRegistry.unsubscribeBuild(buildId);
            m_activeBuilds.remove(buildId);
            return;
        }

        // 2. Identify ready tasks and evaluate cache or enqueue
        bool stateChanged = false;
        bool dispatchFailed = false;
        string[] otherFailedBuilds;
        do
        {
            stateChanged = false;
            if (m_stores !is null)
            {
                statuses = m_stores.legacyBuilds.getTaskStatusesForBuild(buildId);
            }

            foreach (tId; active.targetTaskIds)
            {
                TaskStatus currentStatus = statuses.get(tId, TaskStatus.pending);

                // Only evaluate tasks that have not completed/failed/cancelled/queued
                if (currentStatus != TaskStatus.pending)
                {
                    continue;
                }

                // Check if already sent to the dispatch queue
                if (pActive.enqueuedTasks.get(tId, false))
                {
                    continue;
                }

                // Check if all upstream dependencies in targetTaskIds are satisfied
                string[] deps = active.graph.getDependencies(tId);
                bool allDepsSatisfied = true;

                foreach (depId; deps)
                {
                    if (!active.targetTaskIds.canFind(depId))
                    {
                        continue;
                    }

                    TaskStatus depStatus = statuses.get(depId, TaskStatus.pending);
                    if (depStatus != TaskStatus.succeeded && depStatus != TaskStatus.cached)
                    {
                        allDepsSatisfied = false;
                        break;
                    }
                }

                if (!allDepsSatisfied)
                {
                    continue;
                }

                string registeredFingerprint;
                TaskNode node;
                bool haveNode = false;
                try
                {
                    node = dispatchTask(active, tId);
                    haveNode = true;

                    // 3. Cache check using the fingerprint computed from the build's chain
                    string fingerprint = chainFingerprint(active, tId);

                    if (!active.force && fingerprint.length > 0 && m_stores !is null)
                    {
                        CachedResult cachedResult;
                        if (m_stores.resultCache.get(fingerprint, cachedResult))
                        {
                            auto cachedArtifacts = cachedResult.artifacts;
                            // Verify artifacts exist in stream storage by (taskFingerprint, artifactId)
                            bool allValid = true;
                            foreach (meta; cachedArtifacts)
                            {
                                if (m_artifactStorage !is null)
                                {
                                    string effectiveFp = meta.taskFingerprint.length > 0 ? meta.taskFingerprint : fingerprint;
                                    string effectiveArtId = meta.artifactId.length > 0 ? meta.artifactId : meta.filePath;
                                    if (!m_artifactStorage.artifactExists(effectiveFp, effectiveArtId))
                                    {
                                        allValid = false;
                                        break;
                                    }
                                }
                            }

                            if (allValid)
                            {
                                logInfo("[coordinator] Build '%s': Task '%s' resolved from cache (fingerprint: %s)", buildId, tId, fingerprint);

                                // Resolve immediately as cached
                                TaskExecutionRecord cacheRec;
                                cacheRec.definition = cachedResult.definition;
                                cacheRec.definitionHash = cachedResult.definitionHash;
                                cacheRec.status = "cached";
                                cacheRec.fingerprint = fingerprint;
                                cacheRec.producedArtifacts = cachedArtifacts;
                                cacheRec.finishedAt = Clock.currTime.toISOString();

                                recordTaskResult(buildId, tId, cacheRec);
                                recordExecutedTask(buildId, tId);

                                stateChanged = true;
                                continue;
                            }
                        }
                    }

                    // Fail now, rather than on a worker, if an upstream result lacks a requested artifact
                    requireUpstreamArtifacts(active, node, tId);

                    // The execution records the task's resolved inputs from the chain (task outputs
                    // pinned to upstream fingerprints, which address the artifacts to stage) and where
                    // to fetch each repository input from (looked up when the build started);
                    // nothing else names a repository.
                    ResolvedInput[] inputs = chainInputs(active, tId);
                    string[string] addresses = active.repositoryAddresses.get(tId, null);

                    // 4. In-flight coalescing, then plan the dispatch; dispatchPending dispatches
                    // it after m_mutex is released
                    bool shouldEnqueue = m_inFlightRegistry.registerOrSubscribe(fingerprint, buildId, tId);
                    pActive.enqueuedTasks[tId] = true;

                    if (!shouldEnqueue)
                    {
                        logInfo("[coordinator] Build '%s': Task '%s' coalesced with in-flight execution (fingerprint: %s)", buildId, tId, fingerprint);
                        continue;
                    }
                    registeredFingerprint = fingerprint;
                    m_dispatchedDefinitions[fingerprint] = node;

                    PlannedExecution planned;
                    planned.projectId = active.project.id;
                    planned.taskId = tId;
                    planned.fingerprint = fingerprint;
                    planned.definition = node;
                    planned.inputs = inputs;
                    planned.repositoryAddresses = addresses;
                    planned.legacyBuildId = buildId;

                    logInfo("[coordinator] Build '%s': Dispatching ready task '%s' (fingerprint: %s, timeout: %ds)", buildId, tId, fingerprint, node.timeoutSeconds);

                    // Mark the task queued before it is sent: a worker may receive it (moving the
                    // task to running) as soon as it is sent.
                    m_stores.legacyBuilds.setTaskStatus(buildId, tId, TaskStatus.queued);
                    m_toDispatch ~= planned;
                }
                catch (Exception e)
                {
                    // A task that cannot be dispatched fails, so the build fails rather than
                    // waiting forever for a work order that was never sent.
                    if (m_stores is null) throw e;
                    foreach (b; failDispatch(buildId, tId, registeredFingerprint, e.msg, haveNode ? &node : null))
                    {
                        if (b != buildId && !otherFailedBuilds.canFind(b)) otherFailedBuilds ~= b;
                    }
                    dispatchFailed = true;
                    continue;
                }
            }
        }
        while (stateChanged);

        if (dispatchFailed)
        {
            // Re-evaluate: the failed task fails the build (and any other build attached to its
            // fingerprint) and cancels what is left
            foreach (b; otherFailedBuilds) evaluateReadyTasksLocked(b);
            evaluateReadyTasksLocked(buildId);
            return;
        }

        // 5. Check if all target tasks are finished
        if (m_stores !is null)
        {
            statuses = m_stores.legacyBuilds.getTaskStatusesForBuild(buildId);
        }

        bool allCompleted = true;
        bool allCached = true;

        foreach (tId; active.targetTaskIds)
        {
            TaskStatus st = statuses.get(tId, TaskStatus.pending);
            if (st != TaskStatus.succeeded && st != TaskStatus.cached)
            {
                allCompleted = false;
                break;
            }
            if (st != TaskStatus.cached)
            {
                allCached = false;
            }
        }

        if (allCompleted)
        {
            string finalStatus = allCached ? "cached" : "succeeded";
            logInfo("[coordinator] Build '%s' completed successfully with status '%s'", buildId, finalStatus);

            if (m_stores !is null)
            {
                updateBuildIfRecorded(buildId, (ref BuildRecord b) {
                    b.status = finalStatus;
                    b.finishedAt = Clock.currTime.toISOString();
                });
            }

            m_inFlightRegistry.unsubscribeBuild(buildId);
            m_activeBuilds.remove(buildId);
        }
    }
}


version (unittest)
{
    import confector.core.work_orders : ReceivedWorkOrder, receiveWork;

    /// Receives up to maxMessages work orders from the default pool queue as a worker does, for
    /// tests.
    ReceivedWorkOrder[] receiveWorkOrders(StateStores stores, DispatchQueue queue, size_t maxMessages)
    {
        import core.time : hours;

        return receiveWork(stores, queue, defaultPoolQueue, maxMessages, 1.hours, "test-worker");
    }

    /// Counts the receivable work orders on the default pool queue by receiving and then
    /// releasing them all, for tests. (The dispatch queue offers no way to inspect it.)
    size_t countReceivable(DispatchQueue queue)
    {
        import core.time : hours;

        Lease[] leases;
        while (true)
        {
            auto batch = queue.receive(defaultPoolQueue, maxReceiveBatch, 1.hours);
            if (batch.length == 0)
            {
                break;
            }
            leases ~= batch;
        }
        foreach (lease; leases)
        {
            queue.release(defaultPoolQueue, lease.receipt);
        }
        return leases.length;
    }
}

unittest
{
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;

    // Unit tests for BuildCoordinator
    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(storage, stores, queue);

    // 1. Single Task Graph
    TaskNode singleTask;
    singleTask.id = "lint";
    singleTask.steps = [BuildStep("Lint", "bash", null, "echo linting")];

    ProjectRecord proj1;
    proj1.id = "proj_single";
    proj1.name = "Single Task Project";
    proj1.tasks = [singleTask];

    string b1 = coordinator.startBuild(proj1);
    assert(b1.length > 0);
    assert(countReceivable(queue) == 1);

    auto dequeued = receiveWorkOrders(stores, queue, 1);
    assert(dequeued.length == 1);
    assert(dequeued[0].workOrder.taskId == "lint");
    assert(dequeued[0].workOrder.buildId == b1);

    TaskExecutionResult res1;
    res1.taskId = "lint";
    res1.buildId = b1;
    res1.status = TaskStatus.succeeded;
    res1.fingerprint = "fp_lint_1";
    coordinator.onTaskCompleted(b1, "lint", res1);

    BuildRecord b1Rec;
    assert(stores.legacyBuilds.getBuild(b1, b1Rec));
    assert(b1Rec.status == "succeeded");
    assert(b1Rec.executedTasks == ["lint"]);

    // 2. Linear Pipeline: A -> B -> C
    TaskNode taskA;
    taskA.id = "A";
    taskA.steps = [BuildStep("A", "bash", null, "echo A")];

    TaskNode taskB;
    taskB.id = "B";
    taskB.inputs["A"] = taskOutputInput("A");
    taskB.steps = [BuildStep("B", "bash", null, "echo B")];

    TaskNode taskC;
    taskC.id = "C";
    taskC.inputs["B"] = taskOutputInput("B");
    taskC.steps = [BuildStep("C", "bash", null, "echo C")];

    ProjectRecord projLinear;
    projLinear.id = "proj_linear";
    projLinear.name = "Linear Project";
    projLinear.tasks = [taskA, taskB, taskC];

    string bLinear = coordinator.startBuild(projLinear, null, true); // force execution
    assert(countReceivable(queue) == 1); // Only A is ready initially

    auto deqA = receiveWorkOrders(stores, queue, 1);
    assert(deqA[0].workOrder.taskId == "A");

    TaskExecutionResult resA;
    resA.taskId = "A";
    resA.buildId = bLinear;
    resA.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "A", resA);

    assert(countReceivable(queue) == 1); // B is now unblocked
    auto deqB = receiveWorkOrders(stores, queue, 1);
    assert(deqB[0].workOrder.taskId == "B");

    TaskExecutionResult resB;
    resB.taskId = "B";
    resB.buildId = bLinear;
    resB.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "B", resB);

    assert(countReceivable(queue) == 1); // C is now unblocked
    auto deqC = receiveWorkOrders(stores, queue, 1);
    assert(deqC[0].workOrder.taskId == "C");

    TaskExecutionResult resC;
    resC.taskId = "C";
    resC.buildId = bLinear;
    resC.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "C", resC);

    BuildRecord bLinearRec;
    assert(stores.legacyBuilds.getBuild(bLinear, bLinearRec));
    assert(bLinearRec.status == "succeeded");
    assert(bLinearRec.executedTasks.length == 3);

    // 3. Diamond Dependency / Fan-Out Fan-In: Root -> (Branch1, Branch2) -> Merge
    TaskNode rootNode;
    rootNode.id = "root";

    TaskNode branch1;
    branch1.id = "branch1";
    branch1.inputs["root"] = taskOutputInput("root");

    TaskNode branch2;
    branch2.id = "branch2";
    branch2.inputs["root"] = taskOutputInput("root");

    TaskNode mergeNode;
    mergeNode.id = "merge";
    mergeNode.inputs["branch1"] = taskOutputInput("branch1"); mergeNode.inputs["branch2"] = taskOutputInput("branch2");

    ProjectRecord projDiamond;
    projDiamond.id = "proj_diamond";
    projDiamond.tasks = [rootNode, branch1, branch2, mergeNode];

    string bDiamond = coordinator.startBuild(projDiamond, null, true);
    assert(countReceivable(queue) == 1); // Only root

    auto deqRoot = receiveWorkOrders(stores, queue, 1);
    assert(deqRoot[0].workOrder.taskId == "root");

    TaskExecutionResult resRoot;
    resRoot.taskId = "root";
    resRoot.buildId = bDiamond;
    resRoot.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "root", resRoot);

    // Fan-out: both branch1 and branch2 should be enqueued simultaneously
    assert(countReceivable(queue) == 2);
    auto deqBranches = receiveWorkOrders(stores, queue, 2);
    assert(deqBranches.length == 2);

    // Complete branch1 only
    TaskExecutionResult resBr1;
    resBr1.taskId = "branch1";
    resBr1.buildId = bDiamond;
    resBr1.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "branch1", resBr1);

    // Merge must NOT be enqueued yet because branch2 is still pending
    assert(countReceivable(queue) == 0);

    // Complete branch2
    TaskExecutionResult resBr2;
    resBr2.taskId = "branch2";
    resBr2.buildId = bDiamond;
    resBr2.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "branch2", resBr2);

    // Fan-in: merge is now enqueued
    assert(countReceivable(queue) == 1);
    auto deqMerge = receiveWorkOrders(stores, queue, 1);
    assert(deqMerge[0].workOrder.taskId == "merge");

    TaskExecutionResult resMerge;
    resMerge.taskId = "merge";
    resMerge.buildId = bDiamond;
    resMerge.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "merge", resMerge);

    BuildRecord bDiamondRec;
    assert(stores.legacyBuilds.getBuild(bDiamond, bDiamondRec));
    assert(bDiamondRec.status == "succeeded");

    // 4. Failure Early Termination
    string bFail = coordinator.startBuild(projLinear, null, true);
    auto deqFailA = receiveWorkOrders(stores, queue, 1);
    assert(deqFailA[0].workOrder.taskId == "A");

    TaskExecutionResult resFailA;
    resFailA.taskId = "A";
    resFailA.buildId = bFail;
    resFailA.status = TaskStatus.failed;
    resFailA.errorMessage = "Compiler syntax error";
    coordinator.onTaskCompleted(bFail, "A", resFailA);

    // Downstream tasks B and C must not be enqueued
    assert(countReceivable(queue) == 0);

    BuildRecord bFailRec;
    assert(stores.legacyBuilds.getBuild(bFail, bFailRec));
    assert(bFailRec.status == "failed");
    assert(bFailRec.errorMessage == "Compiler syntax error");

    TaskStatus statusB;
    assert(stores.legacyBuilds.getTaskStatus(bFail, "B", statusB));
    assert(statusB == TaskStatus.cancelled);

    // 5. In-Flight Task Coalescing & Multi-Build Notification
    {
        auto coord5 = new BuildCoordinator(storage, stores, queue);

        TaskNode taskRoot;
        taskRoot.id = "fetch";
        taskRoot.steps = [BuildStep("Fetch", "bash", null, "echo fetching data")];

        TaskNode taskProc;
        taskProc.id = "process";
        taskProc.inputs["fetch"] = taskOutputInput("fetch");
        taskProc.steps = [BuildStep("Process", "bash", null, "echo processing")];

        ProjectRecord projCoalesce;
        projCoalesce.id = "proj_coalesce";
        projCoalesce.tasks = [taskRoot, taskProc];

        // Start Build 1 targeting entire pipeline (fetch -> process)
        string b1_coalesce = coord5.startBuild(projCoalesce, null, true);
        assert(countReceivable(queue) == 1); // "fetch" is enqueued for b1

        // Start Build 2 targeting only "fetch" while "fetch" is still in-flight
        string b2_coalesce = coord5.startBuild(projCoalesce, "fetch", true);
        // Deduplication check: queue should STILL have pending count == 1, not 2!
        assert(countReceivable(queue) == 1);

        auto deqFetch = receiveWorkOrders(stores, queue, 1);
        assert(deqFetch.length == 1);
        assert(deqFetch[0].workOrder.taskId == "fetch");

        // Complete "fetch" task
        TaskExecutionResult resFetch;
        resFetch.taskId = "fetch";
        resFetch.buildId = deqFetch[0].workOrder.buildId;
        resFetch.status = TaskStatus.succeeded;
        resFetch.fingerprint = deqFetch[0].workOrder.fingerprint;
        coord5.onTaskCompleted(deqFetch[0].workOrder.buildId, "fetch", resFetch);

        // Build 2 (targeting only "fetch") should now be completed!
        BuildRecord b2Rec;
        assert(stores.legacyBuilds.getBuild(b2_coalesce, b2Rec));
        assert(b2Rec.status == "succeeded");
        assert(b2Rec.executedTasks.canFind("fetch"));

        // Build 1 should now have "process" unblocked and sent to the dispatch queue
        assert(countReceivable(queue) == 1);
        auto deqProc = receiveWorkOrders(stores, queue, 1);
        assert(deqProc[0].workOrder.taskId == "process");
        assert(deqProc[0].workOrder.buildId == b1_coalesce);

        TaskExecutionResult resProc;
        resProc.taskId = "process";
        resProc.buildId = b1_coalesce;
        resProc.status = TaskStatus.succeeded;
        resProc.fingerprint = deqProc[0].workOrder.fingerprint;
        coord5.onTaskCompleted(b1_coalesce, "process", resProc);

        BuildRecord b1Rec_c;
        assert(stores.legacyBuilds.getBuild(b1_coalesce, b1Rec_c));
        assert(b1Rec_c.status == "succeeded");
        assert(b1Rec_c.executedTasks.length == 2);
    }

    // 6. Cache Hit Subgraph Short-Circuiting
    {
        auto coord6 = new BuildCoordinator(storage, stores, queue);

        TaskNode taskAlpha;
        taskAlpha.id = "alpha";
        taskAlpha.steps = [BuildStep("Alpha", "bash", null, "echo alpha source")];

        TaskNode taskBeta;
        taskBeta.id = "beta";
        taskBeta.inputs["alpha"] = taskOutputInput("alpha");
        taskBeta.steps = [BuildStep("Beta", "bash", null, "echo beta build")];

        ProjectRecord projCache;
        projCache.id = "proj_cache_test";
        projCache.tasks = [taskAlpha, taskBeta];

        // First run: execute both tasks to populate cache
        string bFirst = coord6.startBuild(projCache, null, false);
        assert(countReceivable(queue) == 1);

        auto deqAlpha = receiveWorkOrders(stores, queue, 1);
        assert(deqAlpha[0].workOrder.taskId == "alpha");
        TaskExecutionResult resAlpha;
        resAlpha.taskId = "alpha";
        resAlpha.buildId = bFirst;
        resAlpha.status = TaskStatus.succeeded;
        resAlpha.fingerprint = deqAlpha[0].workOrder.fingerprint;
        coord6.onTaskCompleted(bFirst, "alpha", resAlpha);

        assert(countReceivable(queue) == 1);
        auto deqBeta = receiveWorkOrders(stores, queue, 1);
        assert(deqBeta[0].workOrder.taskId == "beta");
        TaskExecutionResult resBeta;
        resBeta.taskId = "beta";
        resBeta.buildId = bFirst;
        resBeta.status = TaskStatus.succeeded;
        resBeta.fingerprint = deqBeta[0].workOrder.fingerprint;
        coord6.onTaskCompleted(bFirst, "beta", resBeta);

        BuildRecord bFirstRec;
        assert(stores.legacyBuilds.getBuild(bFirst, bFirstRec));
        assert(bFirstRec.status == "succeeded");

        // Second run with identical inputs and force=false: full cache hit!
        string bCached = coord6.startBuild(projCache, null, false);
        // Zero tasks should be sent to the dispatch queue
        assert(countReceivable(queue) == 0);

        BuildRecord bCachedRec;
        assert(stores.legacyBuilds.getBuild(bCached, bCachedRec));
        assert(bCachedRec.status == "cached");

        TaskStatus stAlpha, stBeta;
        assert(stores.legacyBuilds.getTaskStatus(bCached, "alpha", stAlpha));
        assert(stAlpha == TaskStatus.cached);
        assert(stores.legacyBuilds.getTaskStatus(bCached, "beta", stBeta));
        assert(stBeta == TaskStatus.cached);
    }

    // 7. Multi-Build In-Flight Cancellation Isolation
    {
        auto coord7 = new BuildCoordinator(storage, stores, queue);

        TaskNode taskShared;
        taskShared.id = "shared_task";
        taskShared.steps = [BuildStep("Shared", "bash", null, "echo shared")];

        ProjectRecord projCancel;
        projCancel.id = "proj_cancel_test";
        projCancel.tasks = [taskShared];

        string bCancel1 = coord7.startBuild(projCancel, null, true);
        string bCancel2 = coord7.startBuild(projCancel, null, true);

        assert(countReceivable(queue) == 1);
        auto deqShared = receiveWorkOrders(stores, queue, 1);

        // Cancel build 1 while task is in flight
        coord7.cancelBuild(bCancel1);

        BuildRecord bCancel1Rec;
        assert(stores.legacyBuilds.getBuild(bCancel1, bCancel1Rec));
        assert(bCancel1Rec.status == "cancelled");

        // Complete shared task
        TaskExecutionResult resShared;
        resShared.taskId = "shared_task";
        resShared.buildId = deqShared[0].workOrder.buildId;
        resShared.status = TaskStatus.succeeded;
        resShared.fingerprint = deqShared[0].workOrder.fingerprint;
        coord7.onTaskCompleted(deqShared[0].workOrder.buildId, "shared_task", resShared);

        // Build 1 was NOT cancelled and should receive completion successfully
        BuildRecord bCancel2Rec;
        assert(stores.legacyBuilds.getBuild(bCancel2, bCancel2Rec));
        assert(bCancel2Rec.status == "succeeded");

        // Build 1 must remain cancelled
        BuildRecord bCancel1RecAfter;
        assert(stores.legacyBuilds.getBuild(bCancel1, bCancel1RecAfter));
        assert(bCancel1RecAfter.status == "cancelled");
    }

    // 8. Only-Subscriber Cancellation Edge Case: Cancelled build should not be overwritten by completion
    {
        auto coord8 = new BuildCoordinator(storage, stores, queue);

        TaskNode taskSolo;
        taskSolo.id = "solo_task";
        taskSolo.steps = [BuildStep("Solo", "bash", null, "echo solo")];

        ProjectRecord projSolo;
        projSolo.id = "proj_solo_cancel_test";
        projSolo.tasks = [taskSolo];

        // Start a single build
        string bSolo = coord8.startBuild(projSolo, null, true);
        assert(countReceivable(queue) == 1);
        auto deqSolo = receiveWorkOrders(stores, queue, 1);

        // Cancel the only build while task is in flight
        coord8.cancelBuild(bSolo);

        BuildRecord bSoloRecCancelled;
        assert(stores.legacyBuilds.getBuild(bSolo, bSoloRecCancelled));
        assert(bSoloRecCancelled.status == "cancelled");

        // Worker reports completion for the task
        TaskExecutionResult resSolo;
        resSolo.taskId = "solo_task";
        resSolo.buildId = deqSolo[0].workOrder.buildId;
        resSolo.status = TaskStatus.succeeded;
        resSolo.fingerprint = deqSolo[0].workOrder.fingerprint;
        coord8.onTaskCompleted(deqSolo[0].workOrder.buildId, "solo_task", resSolo);

        // Build must remain cancelled, not be overwritten to succeeded
        BuildRecord bSoloRecAfter;
        assert(stores.legacyBuilds.getBuild(bSolo, bSoloRecAfter));
        assert(bSoloRecAfter.status == "cancelled", "Cancelled build should remain cancelled after task completion");

        // Task status should also remain cancelled, not be overwritten to succeeded
        TaskStatus taskStatusAfter;
        assert(stores.legacyBuilds.getTaskStatus(bSolo, "solo_task", taskStatusAfter));
        assert(taskStatusAfter == TaskStatus.cancelled, "Task status should remain cancelled for cancelled build");
    }

    // 9. Structured WorkOrder Construction & Tag Resolution
    {
        auto coord9 = new BuildCoordinator(storage, stores, queue);

        TaskNode gpuTask;
        gpuTask.id = "train_model";
        gpuTask.steps = [BuildStep("Train", "bash", null, "python train.py")];
        gpuTask.timeoutSeconds = 1200;
        gpuTask.setCustomComponent("executor", JSONValue("aws-ecs"));

        JSONValue reqsObj = JSONValue(["gpu": JSONValue("true"), "arch": JSONValue("x86_64"), "cuda": JSONValue("12.0")]);
        gpuTask.setCustomComponent("requirements", reqsObj);

        ProjectRecord projWorkOrder;
        projWorkOrder.id = "proj_work_order_test";
        projWorkOrder.name = "WorkOrder Tagging Project";
        projWorkOrder.tasks = [gpuTask];

        string bWorkOrder = coord9.startBuild(projWorkOrder, null, true);
        assert(countReceivable(queue) == 1);

        auto deqGpu = receiveWorkOrders(stores, queue, 1);
        assert(deqGpu.length == 1);
        assert(deqGpu[0].workOrder.taskId == "train_model");
        assert(deqGpu[0].workOrder.buildId == bWorkOrder);

        // Verify WorkOrder structure and metadata
        WorkOrder wo = deqGpu[0].workOrder;
        assert(wo.buildId == bWorkOrder);
        assert(wo.taskId == "train_model");
        assert(wo.fingerprint == deqGpu[0].workOrder.fingerprint);
        assert(wo.executorType == "aws-ecs");
        assert(wo.requirements["gpu"] == "true");
        assert(wo.requirements["arch"] == "x86_64");
        assert(wo.requirements["cuda"] == "12.0");
        assert(wo.timeoutSeconds == 1200);

        // Complete the task and verify build completion
        TaskExecutionResult resGpu;
        resGpu.taskId = "train_model";
        resGpu.buildId = bWorkOrder;
        resGpu.status = TaskStatus.succeeded;
        resGpu.fingerprint = wo.fingerprint;
        coord9.onTaskCompleted(bWorkOrder, "train_model", resGpu);

        BuildRecord bWorkOrderRec;
        assert(stores.legacyBuilds.getBuild(bWorkOrder, bWorkOrderRec));
        assert(bWorkOrderRec.status == "succeeded");
    }

    // 10. Queue Message Acknowledgment & stepBuild Progression
    {
        auto coord10 = new BuildCoordinator(storage, stores, queue);

        TaskNode step1;
        step1.id = "step1";
        step1.steps = [BuildStep("Step1", "bash", null, "echo step 1")];

        TaskNode step2;
        step2.id = "step2";
        step2.inputs["step1"] = taskOutputInput("step1");
        step2.steps = [BuildStep("Step2", "bash", null, "echo step 2")];

        ProjectRecord projAck;
        projAck.id = "proj_ack_test";
        projAck.tasks = [step1, step2];

        string bAck = coord10.startBuild(projAck, null, true);
        assert(countReceivable(queue) == 1);

        // Dequeue step1 message - will receive a receiptHandle
        auto deqStep1 = receiveWorkOrders(stores, queue, 1);
        assert(deqStep1.length == 1);
        string rHandle = deqStep1[0].receipt;
        assert(rHandle.length > 0);

        // Complete step1 providing receiptHandle directly in TaskExecutionResult
        TaskExecutionResult resStep1;
        resStep1.taskId = "step1";
        resStep1.buildId = bAck;
        resStep1.status = TaskStatus.succeeded;
        resStep1.fingerprint = deqStep1[0].workOrder.fingerprint;
        resStep1.receiptHandle = rHandle;
        coord10.onTaskCompleted(bAck, "step1", resStep1);

        // Downstream step2 is now ready in queue
        assert(countReceivable(queue) == 1);

        // Explicit stepBuild invocation succeeds without errors
        coord10.stepBuild(bAck);
        assert(countReceivable(queue) == 1);

        auto deqStep2 = receiveWorkOrders(stores, queue, 1);
        assert(deqStep2[0].workOrder.taskId == "step2");

        // Complete step2 passing receiptHandle via parameter overload
        TaskExecutionResult resStep2;
        resStep2.taskId = "step2";
        resStep2.buildId = bAck;
        resStep2.status = TaskStatus.succeeded;
        resStep2.fingerprint = deqStep2[0].workOrder.fingerprint;
        coord10.onTaskCompleted(bAck, "step2", resStep2, deqStep2[0].receipt);

        BuildRecord bAckRec;
        assert(stores.legacyBuilds.getBuild(bAck, bAckRec));
        assert(bAckRec.status == "succeeded");
    }
}

version (unittest)
{
    import confector.plugin_api.input_resolver : RepositoryResolver;

    /// A repository resolver that answers with a settable "live" revision and counts its calls.
    class FakeRepositoryResolver : RepositoryResolver
    {
        string liveSha = "aaa111";
        bool fail;
        size_t calls;

        InputPin resolve(in RepositoryRecord repository, in InputDecl input)
        {
            import vibe.data.json : Json;

            ++calls;
            if (fail) throw new Exception("remote unreachable");
            return InputPin(Json(liveSha), ["ref": input.spec.refSelector]);
        }
    }

    /// Completes the one work order waiting on `queue` for `taskId` as succeeded, and returns it.
    WorkOrder completeNext(BuildCoordinator coordinator, DispatchQueue queue, string taskId)
    {
        auto received = receiveWorkOrders(coordinator.stores, queue, 1);
        assert(received.length == 1, "expected a work order for " ~ taskId);
        auto wo = received[0].workOrder;
        assert(wo.taskId == taskId, "expected " ~ taskId ~ ", got " ~ wo.taskId);
        TaskExecutionResult res;
        res.taskId = wo.taskId;
        res.buildId = wo.buildId;
        res.status = TaskStatus.succeeded;
        res.fingerprint = wo.fingerprint;
        res.executionId = wo.executionId;
        coordinator.onTaskCompleted(wo.buildId, wo.taskId, res, received[0].receipt);
        return wo;
    }

    /// A project with a shared source repository, a compile task and two variants of it.
    ProjectRecord variantsProject()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.inputs["src"] = repositoryInput("game", "main");
        compile.steps = [BuildStep("Compile", "bash", null, "echo compile")];

        TaskNode internal;
        internal.id = "internal";
        internal.inputs["bin"] = taskOutputInput("compile");
        internal.inputs["src"] = repositoryInput("game", "main");
        internal.inputs["flavor"] = valueInput("internal");
        internal.steps = [BuildStep("Internal", "bash", null, "echo internal")];

        TaskNode external;
        external.id = "external";
        external.inputs["bin"] = taskOutputInput("compile");
        external.inputs["flavor"] = valueInput("external");
        external.steps = [BuildStep("External", "bash", null, "echo external")];

        ProjectRecord project;
        project.id = "proj_variants";
        project.tasks = [compile, internal, external];
        return project;
    }

    RepositoryRecord gameRepository()
    {
        RepositoryRecord game;
        game.name = "game";
        game.address = "https://example.test/game.git";
        return game;
    }
}

unittest
{
    // A chain resolves the whole DAG once, stores resolved inputs for every task, and later
    // requests on the chain reuse them without resolving again or reading the edited project
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import vibe.data.json : Json;

    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto queue = new InMemoryDispatchQueue();
    auto resolver = new FakeRepositoryResolver();
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue, null, resolver);

    auto project = variantsProject();
    string internalBuild = coordinator.startBuild(project, "internal");
    assert(resolver.calls == 1, "game@main is declared three times but must be resolved once");

    BuildRecord chainRecord;
    assert(stores.legacyBuilds.getBuild(internalBuild, chainRecord));
    assert(chainRecord.chainId == internalBuild);
    assert(chainRecord.chainTasks.length == 3, "Every task is in the chain, including the untargeted external build");
    foreach (ref task; chainRecord.chainTasks)
    {
        foreach (ref input; task.resolvedInputs)
        {
            if (input.kind == InputKind.repository) assert(input.pinned == Json("aaa111"));
        }
    }
    assert(chainRecord.chainTasks[1].id == "external" && chainRecord.chainTasks[1].resolvedInputs.length == 1);
    auto expected = chainResolutionBeforeReruns(project.id, chainRecord.chainTasks).fingerprints;

    auto compileOrder = completeNext(coordinator, queue, "compile");
    assert(compileOrder.fingerprint == expected["compile"]);
    auto internalOrder = completeNext(coordinator, queue, "internal");
    assert(internalOrder.fingerprint == expected["internal"]);
    assert(countReceivable(queue) == 0);

    // A work order carries exactly the task's resolved inputs from the chain, and the address of
    // each repository input by input name; nothing else names a repository
    assert(compileOrder.payload.inputs == [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])]);
    assert(compileOrder.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(internalOrder.payload.inputs == chainResolutionBeforeReruns(project.id, chainRecord.chainTasks).inputs["internal"]);
    assert(internalOrder.payload.inputs.length == 3 && internalOrder.payload.inputs[0].name == "bin"
        && internalOrder.payload.inputs[0].kind == InputKind.taskOutput
        && internalOrder.payload.inputs[0].pinned == Json(expected["compile"]));
    assert(internalOrder.payload.repositoryAddresses == ["src": "https://example.test/game.git"]);

    // The branch moves on and the project inputs are edited; the chain must not notice
    resolver.liveSha = "bbb222";
    ProjectRecord edited = project;
    edited.tasks = project.tasks.dup;
    edited.tasks[0].inputs = ["src": repositoryInput("game", "release")];
    edited.tasks[2].inputs = ["bin": taskOutputInput("compile"), "flavor": valueInput("changed")];
    edited.tasks[2].steps = [BuildStep("External", "bash", null, "echo external v2")];
    stores.projects.put(edited);

    // Building the not-yet-run external task in the chain: no resolution, chain fingerprints,
    // compile reused from cache, frozen inputs with the current configuration
    string externalBuild = coordinator.buildInChain(internalBuild, "external");
    assert(resolver.calls == 1, "Building a task of an existing chain must not resolve again");

    BuildRecord externalRecord;
    assert(stores.legacyBuilds.getBuild(externalBuild, externalRecord));
    assert(externalRecord.chainId == internalBuild);
    assert(chainResolutionBeforeReruns(project.id, externalRecord.chainTasks).fingerprints == expected);

    TaskStatus compileStatus;
    assert(stores.legacyBuilds.getTaskStatus(externalBuild, "compile", compileStatus) && compileStatus == TaskStatus.cached);
    auto external = completeNext(coordinator, queue, "external");
    assert(external.fingerprint == expected["external"]);
    assert(external.taskNode.inputs["flavor"] == valueInput("external"), "Inputs come from the chain");
    assert(external.taskNode.steps[0].script == "echo external v2", "Configuration comes from the project");
    assert(external.payload.inputs == [
        ResolvedInput("bin", InputKind.taskOutput, Json(expected["compile"])),
        ResolvedInput("flavor", InputKind.value, Json("external")),
    ], "Task outputs pin to the upstream fingerprint, which addresses the artifacts to stage");
    assert(external.payload.repositoryAddresses.length == 0);

    BuildRecord externalDone;
    assert(stores.legacyBuilds.getBuild(externalBuild, externalDone) && externalDone.status == "succeeded");

    // A task that is not in the chain cannot be built in it
    bool threw = false;
    try coordinator.buildInChain(internalBuild, "added_later");
    catch (Exception ex) threw = ex.msg.canFind("not part of build chain");
    assert(threw);

    // A new chain from the edited project resolves again and pins the new revision
    // (the edited project declares game at two refs, release and main: two resolutions)
    string newBuild = coordinator.startBuild(edited, "compile", true);
    assert(resolver.calls == 3);
    BuildRecord newRecord;
    assert(stores.legacyBuilds.getBuild(newBuild, newRecord) && newRecord.chainId == newBuild);
    assert(chainResolutionBeforeReruns(edited.id, newRecord.chainTasks).fingerprints["compile"] != expected["compile"]);
}

unittest
{
    // A restarted coordinator resumes a build from its chain: no resolution and no fingerprints
    // or structure from the project as edited meanwhile (bug confector-3qh)
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto storage = new InMemoryArtifactStorage();
    auto queue = new InMemoryDispatchQueue();
    auto project = variantsProject();

    auto before = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());
    string buildId = before.startBuild(project, "internal", true);
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record));
    auto expected = chainResolutionBeforeReruns(project.id, record.chainTasks).fingerprints;

    auto compileOrder = receiveWorkOrders(stores, queue, 1)[0];

    ProjectRecord edited = project;
    edited.tasks = project.tasks.dup;
    edited.tasks[1].inputs = ["bin": taskOutputInput("compile"), "src": repositoryInput("game", "release"),
        "flavor": valueInput("internal"), "extra": valueInput("x")];
    stores.projects.put(edited);

    auto resolverAfter = new FakeRepositoryResolver();
    resolverAfter.liveSha = "ccc333";
    auto after = new BuildCoordinator(storage, stores, queue, null, resolverAfter);
    TaskExecutionResult done;
    done.taskId = "compile";
    done.buildId = buildId;
    done.status = TaskStatus.succeeded;
    done.fingerprint = compileOrder.workOrder.fingerprint;
    after.onTaskCompleted(buildId, "compile", done, compileOrder.receipt);

    auto internal = completeNext(after, queue, "internal");
    assert(resolverAfter.calls == 0, "Resuming a build must not resolve");
    assert(internal.fingerprint == expected["internal"]);
    assert("extra" !in internal.taskNode.inputs && internal.taskNode.inputs["src"] == repositoryInput("game", "main"));

    // A task deleted from the project fails loudly when its chain asks to build it
    ProjectRecord shrunk = project;
    shrunk.tasks = project.tasks[0 .. 2].dup;
    stores.projects.put(shrunk);
    const buildsBefore = stores.legacyBuilds.listBuilds().length;
    bool threw = false;
    try after.buildInChain(buildId, "external");
    catch (Exception ex) threw = ex.msg.canFind("deleted from project");
    assert(threw);
    assert(stores.legacyBuilds.listBuilds().length == buildsBefore, "A rejected request must not record a build");
    assert(countReceivable(queue) == 0, "A rejected request must not dispatch work");
}

unittest
{
    // A failed resolution fails chain creation loudly: nothing is recorded or dispatched
    import confector.core.input_resolution : InputResolutionException;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto queue = new InMemoryDispatchQueue();
    auto resolver = new FakeRepositoryResolver();
    resolver.fail = true;
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue, null, resolver);

    string failure(BuildCoordinator c, ProjectRecord p)
    {
        try c.startBuild(p);
        catch (InputResolutionException ex) return ex.msg;
        assert(false, "expected InputResolutionException");
    }

    auto msg = failure(coordinator, variantsProject());
    assert(msg.canFind("'game'") && msg.canFind("'main'") && msg.canFind("remote unreachable"));
    assert(resolver.calls == 1);

    // An unregistered repository, or no resolver at all
    resolver.fail = false;
    auto unknown = variantsProject();
    unknown.tasks[0].inputs = ["src": repositoryInput("tools", "main")];
    assert(failure(coordinator, unknown).canFind("'tools'"));
    auto noResolver = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    assert(failure(noResolver, variantsProject()).canFind("no repository resolver"));

    // An empty ref selector: there is no default branch
    auto noRef = variantsProject();
    noRef.tasks[0].inputs = ["src": repositoryInput("game", "")];
    const callsBefore = resolver.calls;
    assert(failure(coordinator, noRef).canFind("no ref selector"));
    assert(resolver.calls == callsBefore);

    assert(stores.legacyBuilds.listBuilds().length == 0, "A failed chain creation must not record a build");
    assert(countReceivable(queue) == 0, "A failed chain creation must not dispatch work");
}

unittest
{
    // A repository input whose repository has no address cannot be dispatched: there would be
    // nothing to check it out from
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    RepositoryRecord noAddress = gameRepository();
    noAddress.address = "";
    stores.repositories.put(noAddress);
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue, null, new FakeRepositoryResolver());

    bool threw = false;
    try coordinator.startBuild(variantsProject(), "compile");
    catch (Exception ex) threw = ex.msg.canFind("'src'") && ex.msg.canFind("no address");
    assert(threw);
    assert(countReceivable(queue) == 0);
    assert(stores.legacyBuilds.listBuilds().length == 0, "The request must fail before a build is recorded");
    assert(coordinator.m_activeBuilds.length == 0, "No active build may remain");
}

unittest
{
    // A task that cannot be dispatched mid-build fails, and so does its build, instead of the
    // build waiting forever: here a restarted coordinator resumes a build whose next task was
    // deleted from the project meanwhile
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto storage = new InMemoryArtifactStorage();
    auto queue = new InMemoryDispatchQueue();
    auto project = variantsProject();

    auto before = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());
    string buildId = before.startBuild(project, "internal", true);
    auto compileOrder = receiveWorkOrders(stores, queue, 1)[0];

    ProjectRecord shrunk = project;
    shrunk.tasks = [project.tasks[0], project.tasks[2]];
    stores.projects.put(shrunk);

    auto after = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());
    TaskExecutionResult done;
    done.taskId = "compile";
    done.buildId = buildId;
    done.status = TaskStatus.succeeded;
    done.fingerprint = compileOrder.workOrder.fingerprint;
    after.onTaskCompleted(buildId, "compile", done, compileOrder.receipt);

    TaskStatus internalStatus;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "internal", internalStatus) && internalStatus == TaskStatus.failed);
    TaskExecutionRecord internalRec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "internal", internalRec) && internalRec.errorMessage.canFind("deleted from project"));
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "failed");
    assert(after.m_activeBuilds.length == 0 && after.inFlightRegistry.inFlightCount() == 0);
    assert(countReceivable(queue) == 0);
}

unittest
{
    // A task_output input requesting an artifact the upstream result lacks (output declarations
    // changed since a cached result) fails the downstream task before dispatch, naming the
    // upstream task, its fingerprint and the artifact; an artifact it has dispatches normally
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());

    auto project = variantsProject();
    project.tasks[1].inputs["bin"] = taskOutputInput("compile", "game.zip");
    project.tasks[2].inputs["bin"] = taskOutputInput("compile", "tools.zip");

    string buildId = coordinator.startBuild(project, "internal");
    auto compileOrder = receiveWorkOrders(stores, queue, 1)[0];
    storage.storeArtifactStream(compileOrder.workOrder.fingerprint, "game.zip", (void delegate(const(ubyte)[]) sink) { sink([1, 2, 3]); });
    ArtifactMetadata produced;
    produced.artifactId = "game.zip";
    TaskExecutionResult done;
    done.taskId = "compile";
    done.buildId = buildId;
    done.status = TaskStatus.succeeded;
    done.fingerprint = compileOrder.workOrder.fingerprint;
    done.producedArtifacts = [produced];
    coordinator.onTaskCompleted(buildId, "compile", done, compileOrder.receipt);

    // internal wants game.zip, which compile produced
    auto internalOrder = receiveWorkOrders(stores, queue, 1);
    assert(internalOrder.length == 1 && internalOrder[0].workOrder.taskId == "internal");

    // external, built later in the chain, wants tools.zip, which the cached compile result lacks
    string externalBuild = coordinator.buildInChain(buildId, "external");
    TaskStatus externalStatus;
    assert(stores.legacyBuilds.getTaskStatus(externalBuild, "external", externalStatus) && externalStatus == TaskStatus.failed);
    TaskExecutionRecord externalRec;
    assert(stores.legacyBuilds.getTaskExecution(externalBuild, "external", externalRec));
    assert(externalRec.definitionHash.length == 64 && externalRec.definition.id == "external", "A task that could not be dispatched still records its definition");
    assert(externalRec.errorMessage.canFind("'compile'") && externalRec.errorMessage.canFind(compileOrder.workOrder.fingerprint)
        && externalRec.errorMessage.canFind("'tools.zip'") && externalRec.errorMessage.canFind("Re-run task 'compile'"), externalRec.errorMessage);
    BuildRecord externalRecord;
    assert(stores.legacyBuilds.getBuild(externalBuild, externalRecord) && externalRecord.status == "failed");
    assert(countReceivable(queue) == 0, "A task with a missing upstream artifact must not be dispatched");
}

unittest
{
    // Every execution result records the definition it ran with and its hash: an executed
    // result, a failed one, and one resolved from the cache
    import confector.core.definition_hash : computeDefinitionHash;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());

    auto project = variantsProject();
    string buildId = coordinator.startBuild(project, "internal");
    auto compileOrder = receiveWorkOrders(stores, queue, 1)[0];
    TaskExecutionResult done;
    done.taskId = "compile";
    done.buildId = buildId;
    done.status = TaskStatus.succeeded;
    done.fingerprint = compileOrder.workOrder.fingerprint;
    coordinator.onTaskCompleted(buildId, "compile", done, compileOrder.receipt);

    TaskExecutionRecord compileRec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "compile", compileRec));
    assert(compileRec.definitionHash == computeDefinitionHash(project.tasks[0]));
    assert(compileRec.definition.steps[0].script == "echo compile");

    auto internalOrder = receiveWorkOrders(stores, queue, 1)[0];
    TaskExecutionResult failed;
    failed.taskId = "internal";
    failed.buildId = buildId;
    failed.status = TaskStatus.failed;
    failed.fingerprint = internalOrder.workOrder.fingerprint;
    coordinator.onTaskCompleted(buildId, "internal", failed, internalOrder.receipt);
    TaskExecutionRecord internalRec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "internal", internalRec));
    assert(internalRec.status == "failed" && internalRec.definitionHash == computeDefinitionHash(project.tasks[1]));

    // The compile step is edited; the fingerprint does not change, so compile is resolved from
    // the cache, and that record carries the definition of the execution that built it
    ProjectRecord edited = project;
    edited.tasks = project.tasks.dup;
    edited.tasks[0].steps = [BuildStep("Compile", "bash", null, "echo compile v2")];
    stores.projects.put(edited);
    string externalBuild = coordinator.buildInChain(buildId, "external");
    TaskExecutionRecord cachedRec;
    assert(stores.legacyBuilds.getTaskExecution(externalBuild, "compile", cachedRec));
    assert(cachedRec.status == "cached" && cachedRec.definitionHash == computeDefinitionHash(project.tasks[0]));
    assert(cachedRec.definitionHash != computeDefinitionHash(edited.tasks[0]));
    assert(cachedRec.definition.steps[0].script == "echo compile");
}

unittest
{
    // A result is recorded with the definition its task was dispatched with, even if the project
    // is edited while it runs; and a definition that cannot be found (here, after a restart the
    // task was deleted from the project) never drops the completion
    import confector.core.definition_hash : computeDefinitionHash;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    stores.repositories.put(gameRepository());
    auto queue = new InMemoryDispatchQueue();
    auto project = variantsProject();

    auto first = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());
    string buildId = first.startBuild(project, "internal");
    auto compileOrder = receiveWorkOrders(stores, queue, 1)[0];

    ProjectRecord edited = project;
    edited.tasks = project.tasks.dup;
    edited.tasks[0].steps = [BuildStep("Compile", "bash", null, "echo compile v2")];
    stores.projects.put(edited);

    TaskExecutionResult done;
    done.taskId = "compile";
    done.buildId = buildId;
    done.status = TaskStatus.succeeded;
    done.fingerprint = compileOrder.workOrder.fingerprint;
    first.onTaskCompleted(buildId, "compile", done, compileOrder.receipt);
    TaskExecutionRecord compileRec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "compile", compileRec));
    assert(compileRec.definitionHash == computeDefinitionHash(project.tasks[0]), "Recorded as dispatched, not as edited since");

    // Restart: the new coordinator has no dispatched definition, and the task is gone
    auto internalOrder = receiveWorkOrders(stores, queue, 1)[0];
    ProjectRecord shrunk = project;
    shrunk.tasks = [project.tasks[0], project.tasks[2]];
    stores.projects.put(shrunk);
    auto second = new BuildCoordinator(storage, stores, queue, null, new FakeRepositoryResolver());
    TaskExecutionResult internalDone;
    internalDone.taskId = "internal";
    internalDone.buildId = buildId;
    internalDone.status = TaskStatus.succeeded;
    internalDone.fingerprint = internalOrder.workOrder.fingerprint;
    second.onTaskCompleted(buildId, "internal", internalDone, internalOrder.receipt);

    TaskStatus internalStatus;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "internal", internalStatus) && internalStatus == TaskStatus.succeeded);
    TaskExecutionRecord internalRec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "internal", internalRec));
    assert(internalRec.status == "succeeded" && internalRec.definitionHash.length == 0);
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "succeeded", "The completion must still advance the build");
    CachedResult cached;
    assert(stores.resultCache.get(internalOrder.workOrder.fingerprint, cached));
}

unittest
{
    // Bug confector-z7z.23.11: a task whose definition would make a work order larger than the
    // dispatch queue's 64 KiB limit still dispatches, because the queue carries only the
    // execution id; the worker receives the full definition from the execution's record
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.array : replicate;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);

    TaskNode big;
    big.id = "big";
    big.steps = [BuildStep("Big", "bash", null, "echo " ~ replicate("x", 100 * 1024))];
    ProjectRecord project;
    project.id = "proj_big";
    project.tasks = [big];

    string buildId = coordinator.startBuild(project);
    auto received = receiveWorkOrders(stores, queue, 1);
    assert(received.length == 1, "The oversized task was dispatched");
    assert(received[0].workOrder.taskNode.steps[0].script.length > 100 * 1024);
    assert(received[0].workOrder.executionId.length > 0 && received[0].workOrder.buildId == buildId);
    TaskStatus status;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "big", status) && status == TaskStatus.queued);
}

version (unittest)
{
    /// A dispatch queue whose sends fail while `sendError` is set, for tests.
    final class FailingSendQueue : DispatchQueue
    {
        import core.time : Duration;
        import vibe.data.json : Json;

        DispatchQueue inner;
        Exception sendError;

        this(DispatchQueue inner, Exception sendError) { this.inner = inner; this.sendError = sendError; }

        void ensureQueue(string queue) { inner.ensureQueue(queue); }
        void send(string queue, Json message, Duration delay = Duration.zero)
        {
            if (sendError !is null) throw sendError;
            inner.send(queue, message, delay);
        }
        Lease[] receive(string queue, size_t maxMessages, Duration visibility) { return inner.receive(queue, maxMessages, visibility); }
        size_t acks;
        void ack(string queue, string receipt) { ++acks; inner.ack(queue, receipt); }
        void extend(string queue, string receipt, Duration visibility) { inner.extend(queue, receipt, visibility); }
        void release(string queue, string receipt, Duration delay = Duration.zero) { inner.release(queue, receipt, delay); }
    }

    /// A document store whose replaces in `collection` fail while `failReplaces` is set, for tests.
    import confector.plugin_api.document_store : DocumentStore;

    final class FailingReplaceStore : DocumentStore
    {
        import confector.plugin_api.document_store : CollectionSpec, Document, DocumentStore, IndexQuery, QueryPage;
        import std.typecons : Nullable;
        import vibe.data.json : Json;

        DocumentStore inner;
        string collection;
        bool failReplaces;

        this(DocumentStore inner, string collection) { this.inner = inner; this.collection = collection; }

        override void declare(const(CollectionSpec)[] collections) { inner.declare(collections); }
        override Nullable!Document get(string c, string id) { return inner.get(c, id); }
        override Document create(string c, string id, Json content) { return inner.create(c, id, content); }
        override Document replace(string c, string id, Json content, ulong expectedVersion)
        {
            if (failReplaces && c == collection) throw new Exception("store unavailable");
            return inner.replace(c, id, content, expectedVersion);
        }
        override void remove(string c, string id, ulong expectedVersion) { inner.remove(c, id, expectedVersion); }
        override QueryPage query(string c, const IndexQuery lookup) { return inner.query(c, lookup); }
    }
}

unittest
{
    // Bug confector-z7z.23.11: a send that fails fails the task and its build, loudly, instead
    // of leaving them pending forever, and fails the execution too
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto inner = new InMemoryDispatchQueue();
    auto queue = new FailingSendQueue(inner, new Exception("database unreachable"));
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);

    TaskNode task;
    task.id = "compile";
    task.steps = [BuildStep("Compile", "bash", null, "make")];
    TaskNode downstream;
    downstream.id = "package";
    downstream.inputs["bin"] = taskOutputInput("compile");
    ProjectRecord project;
    project.id = "proj_send";
    project.tasks = [task, downstream];

    string buildId = coordinator.startBuild(project, null, true);
    TaskStatus status;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "compile", status) && status == TaskStatus.failed);
    TaskExecutionRecord rec;
    assert(stores.legacyBuilds.getTaskExecution(buildId, "compile", rec) && rec.errorMessage.canFind("database unreachable"), rec.errorMessage);
    assert(stores.legacyBuilds.getTaskStatus(buildId, "package", status) && status == TaskStatus.cancelled);
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "failed");
    assert(coordinator.m_activeBuilds.length == 0 && coordinator.inFlightRegistry.inFlightCount() == 0);

    // The execution agrees with the task: failed, with the reason, and its claim released
    auto fingerprint = chainResolutionBeforeReruns(project.id, record.chainTasks).fingerprints["compile"];
    auto executions = stores.executions.listForFingerprint(fingerprint);
    assert(executions.length == 1 && executions[0].status == ExecutionStatus.failed && executions[0].sentAt.length == 0);
    assert(executions[0].errorMessage.canFind("database unreachable"));
    assert(stores.claims.get(fingerprint).get.executionId.length == 0);

    // Once the queue recovers, a later build dispatches a new execution
    queue.sendError = null;
    string retry = coordinator.startBuild(project, "compile", true);
    auto received = receiveWorkOrders(stores, inner, 1);
    assert(received.length == 1 && received[0].workOrder.buildId == retry && received[0].workOrder.executionId != executions[0].id);
}

unittest
{
    // A message the queue rejects as invalid fails the task's execution too, and releases its
    // claim, so a later build dispatches a new one
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new FailingSendQueue(new InMemoryDispatchQueue(), new DispatchQueueUsageException("Message for queue 'default' is too large"));
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    TaskNode task;
    task.id = "compile";
    ProjectRecord project;
    project.id = "proj_reject";
    project.tasks = [task];

    string buildId = coordinator.startBuild(project, null, true);
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "failed");
    auto fingerprint = chainResolutionBeforeReruns(project.id, record.chainTasks).fingerprints["compile"];
    auto executions = stores.executions.listForFingerprint(fingerprint);
    assert(executions.length == 1 && executions[0].status == ExecutionStatus.failed && executions[0].errorMessage.canFind("too large"));
    assert(stores.claims.get(fingerprint).get.executionId.length == 0);
}

unittest
{
    // Bug confector-sit: capacity is evaluated once per dispatch, after it and outside the
    // coordinator's mutex (another thread can take it meanwhile), from executions in the state
    // store
    import confector.core.execution_dispatcher : queuedDemand;
    import confector.core.executor : ComputeProvisioner;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import core.thread : Thread;

    class ProbingBroker : CapacityBroker
    {
        BuildCoordinator coordinator;
        StateStores stores;
        size_t evaluations;
        bool mutexWasFree = true;
        size_t demandSeen;

        @property ComputeProvisioner[] provisioners() { return null; }
        @property size_t activeInstanceCount() const { return 0; }
        @property size_t maxCapacity() const { return 0; }
        void registerProvisioner(ComputeProvisioner provisioner) {}
        void evaluateDemand()
        {
            ++evaluations;
            bool free;
            auto probe = new Thread({
                free = coordinator.m_mutex.tryLock();
                if (free) coordinator.m_mutex.unlock();
            });
            probe.start();
            probe.join();
            mutexWasFree &= free;
            demandSeen = queuedDemand(stores.executions).length;
        }
    }

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto broker = new ProbingBroker();
    broker.stores = stores;
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue, broker);
    broker.coordinator = coordinator;

    TaskNode a; a.id = "a";
    TaskNode b; b.id = "b";
    TaskNode c; c.id = "c"; c.inputs["a"] = taskOutputInput("a"); c.inputs["b"] = taskOutputInput("b");
    ProjectRecord project;
    project.id = "proj_sit";
    project.tasks = [a, b, c];

    string buildId = coordinator.startBuild(project, null, true);
    assert(broker.evaluations == 1, "Capacity is evaluated once per dispatch, not once per task");
    assert(broker.mutexWasFree);
    assert(broker.demandSeen == 2, "Demand is the two sent executions");

    auto received = receiveWorkOrders(stores, queue, 2);
    assert(received.length == 2);
    assert(queuedDemand(stores.executions).length == 0, "Received executions are no longer demand");
    foreach (item; received)
    {
        TaskExecutionResult done;
        done.status = TaskStatus.succeeded;
        coordinator.onTaskCompleted(buildId, item.workOrder.taskId, done, item.receipt);
    }
    assert(broker.evaluations == 2 && broker.mutexWasFree && broker.demandSeen == 1);
    foreach (ref execution; stores.executions.listForTask("proj_sit", "a", 10)) assert(execution.status == ExecutionStatus.succeeded);
}

unittest
{
    // A completion that cannot be recorded is rejected without forgetting anything: the
    // execution stays running with its claim, the build stays attached, and the receipt is not
    // acknowledged, so the redelivered work order completes it later
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto inner = new InMemoryDocumentStore();
    auto stores = new StateStores(inner);
    auto queue = new FailingSendQueue(new InMemoryDispatchQueue(), null);
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    TaskNode task;
    task.id = "compile";
    ProjectRecord project;
    project.id = "proj_wedge";
    project.tasks = [task];

    string buildId = coordinator.startBuild(project, null, true);
    auto order = receiveWorkOrders(stores, queue, 1)[0];

    // Recording fails: legacy task records live in their own collection, written by replace
    auto failing = new FailingReplaceStore(inner, "legacy_task_records");
    auto failingStores = new StateStores(failing);
    auto broken = new BuildCoordinator(new InMemoryArtifactStorage(), failingStores, queue);
    // Give the broken coordinator the in-flight registration a dispatching process would have
    broken.m_inFlightRegistry.registerOrSubscribe(order.workOrder.fingerprint, buildId, "compile");
    failing.failReplaces = true;

    TaskExecutionResult done;
    done.status = TaskStatus.succeeded;
    done.executionId = order.workOrder.executionId;
    bool threw = false;
    try broken.onTaskCompleted(buildId, "compile", done, order.receipt);
    catch (Exception e) threw = true;
    assert(threw, "The report is rejected");
    assert(queue.acks == 0, "The receipt is not acknowledged");
    assert(stores.executions.get(order.workOrder.executionId).get.status == ExecutionStatus.running);
    assert(stores.claims.get(order.workOrder.fingerprint).get.executionId == order.workOrder.executionId);
    assert(broken.inFlightRegistry.getSubscribers(order.workOrder.fingerprint).length == 1, "The build stays attached");

    // Reported again once the store recovers: recorded, finished, acknowledged
    failing.failReplaces = false;
    broken.onTaskCompleted(buildId, "compile", done, order.receipt);
    assert(queue.acks == 1);
    assert(stores.executions.get(order.workOrder.executionId).get.status == ExecutionStatus.succeeded);
    assert(broken.inFlightRegistry.inFlightCount() == 0);
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "succeeded");
}

unittest
{
    // Stale completion guard: a completion naming an execution that no longer holds its
    // fingerprint (here failed and the fingerprint re-claimed by a later execution) is rejected
    // loudly and records nothing; a completion naming the current execution is recorded against
    // the execution's own fingerprint, whatever fingerprint the worker reports
    import confector.core.work_orders : StaleCompletionException;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    TaskNode task;
    task.id = "compile";
    ProjectRecord project;
    project.id = "proj_stale";
    project.tasks = [task];

    string buildId = coordinator.startBuild(project, null, true);
    auto order = receiveWorkOrders(stores, queue, 1)[0].workOrder;
    const fingerprint = order.fingerprint;
    assert(finishClaimedExecution(stores, fingerprint, ExecutionStatus.failed, 1, "lease expired", null));
    assert(stores.claims.claim(fingerprint, "exe_later").won);

    TaskExecutionResult stale;
    stale.status = TaskStatus.succeeded;
    stale.executionId = order.executionId;
    bool rejected = false;
    try coordinator.onTaskCompleted(buildId, "compile", stale);
    catch (StaleCompletionException e) rejected = true;
    assert(rejected);
    TaskStatus status;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "compile", status) && status != TaskStatus.succeeded);
    assert(stores.claims.get(fingerprint).get.executionId == "exe_later");
    CachedResult cached;
    assert(!stores.resultCache.get(fingerprint, cached), "Nothing was recorded");

    // A current execution with a wrong worker-reported fingerprint finishes the right one
    // (another coordinator: this one still holds the first build attached to the fingerprint)
    stores.claims.release(fingerprint, "exe_later");
    auto other = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    string again = other.startBuild(project, null, true);
    auto current = receiveWorkOrders(stores, queue, 1)[0].workOrder;
    TaskExecutionResult done;
    done.status = TaskStatus.succeeded;
    done.executionId = current.executionId;
    done.fingerprint = "worker-made-this-up";
    other.onTaskCompleted(again, "compile", done);
    assert(stores.executions.get(current.executionId).get.status == ExecutionStatus.succeeded);
    assert(stores.resultCache.get(fingerprint, cached) && !stores.resultCache.get("worker-made-this-up", cached));
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(again, record) && record.status == "succeeded");
}

unittest
{
    // Recording sentAt failing after the send succeeded does not fail the build: the work order
    // is on the queue and completes normally
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    auto failing = new FailingReplaceStore(new InMemoryDocumentStore(), "task_executions");
    auto stores = new StateStores(failing);
    auto queue = new InMemoryDispatchQueue();
    auto coordinator = new BuildCoordinator(new InMemoryArtifactStorage(), stores, queue);
    TaskNode task;
    task.id = "compile";
    ProjectRecord project;
    project.id = "proj_marksent";
    project.tasks = [task];

    failing.failReplaces = true;
    string buildId = coordinator.startBuild(project, null, true);
    failing.failReplaces = false;
    TaskStatus status;
    assert(stores.legacyBuilds.getTaskStatus(buildId, "compile", status) && status == TaskStatus.queued, "Not failed as undispatched");

    completeNext(coordinator, queue, "compile");
    BuildRecord record;
    assert(stores.legacyBuilds.getBuild(buildId, record) && record.status == "succeeded");
}
