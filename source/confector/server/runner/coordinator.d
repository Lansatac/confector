module confector.runner.coordinator;

import confector.core.model;
import confector.core.dag;
import confector.core.storage;
import confector.core.fingerprinter;
import confector.queue.queue;

import std.algorithm : canFind, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.uuid : randomUUID;
import core.sync.mutex : Mutex;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

/**
 * Metadata tracked for an active or recorded build graph execution.
 */
struct ActiveBuild
{
    string buildId;
    ProjectRecord project;
    TaskGraph graph;
    string[] targetTaskIds;
    bool force = false;
    string workspaceDir;
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
        if (fingerprint.length == 0 || fingerprint == "unknown") return false;
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

        if (fingerprint.length == 0 || fingerprint == "unknown")
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
 * Centralized Build Coordinator that orchestrates dynamic DAG progression,
 * evaluates task readiness, enqueues self-contained task work units to WorkQueue,
 * and processes asynchronous task completions over network-safe boundaries.
 */
class BuildCoordinator
{
    private ArtifactStorage m_artifactStorage;
    private BuildStateRepository m_stateRepo;
    private WorkQueue m_workQueue;
    private string m_callbackBaseUrl;
    private Mutex m_mutex;
    private ActiveBuild[string] m_activeBuilds;
    private InFlightTaskRegistry m_inFlightRegistry;

    this(
        ArtifactStorage artifactStorage,
        BuildStateRepository stateRepo,
        WorkQueue workQueue,
        string callbackBaseUrl = ""
    )
    {
        m_artifactStorage = artifactStorage;
        m_stateRepo = stateRepo;
        m_workQueue = workQueue;
        m_callbackBaseUrl = callbackBaseUrl;
        m_mutex = new Mutex();
        m_inFlightRegistry = new InFlightTaskRegistry();
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }
    @property BuildStateRepository stateRepository() { return m_stateRepo; }
    @property WorkQueue workQueue() { return m_workQueue; }
    @property InFlightTaskRegistry inFlightRegistry() { return m_inFlightRegistry; }
    @property string callbackBaseUrl() const { return m_callbackBaseUrl; }
    @property void callbackBaseUrl(string url) { m_callbackBaseUrl = url; }

    /**
     * Initiates a new build execution for the given project and optional target task.
     * Evaluates initial DAG roots and pushes ready tasks to WorkQueue.
     * Returns the generated build ID.
     */
    string startBuild(
        ProjectRecord project,
        string targetTaskId = null,
        bool force = false,
        string triggerSource = "manual",
        string workspaceDir = null
    )
    {
        synchronized (m_mutex)
        {
            string buildId = "bld_" ~ randomUUID().toString()[0 .. 8];
            TaskGraph graph = new TaskGraph(project);
            if (workspaceDir.length > 0)
            {
                graph.computeFingerprints(workspaceDir);
            }

            string[] targetTaskIds;
            if (targetTaskId.length > 0)
            {
                targetTaskIds = graph.resolveSubgraph(targetTaskId);
            }
            else
            {
                targetTaskIds = graph.topologicalSort();
            }

            // Persist project if not already saved
            if (project.id.length > 0 && m_stateRepo !is null)
            {
                m_stateRepo.saveProject(project);
            }

            // Create and persist initial BuildRecord
            BuildRecord buildRecord;
            buildRecord.buildId = buildId;
            buildRecord.projectId = project.id;
            buildRecord.projectName = project.name.length > 0 ? project.name : "default";
            buildRecord.status = "queued";
            buildRecord.triggerSource = triggerSource;
            buildRecord.targetTaskId = targetTaskId;
            buildRecord.workspaceDir = workspaceDir;
            buildRecord.startedAt = Clock.currTime.toISOString();
            buildRecord.executedTasks = [];

            if (m_stateRepo !is null)
            {
                foreach (tId; targetTaskIds)
                {
                    m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.pending);
                }
                m_stateRepo.recordBuild(buildRecord);
            }

            ActiveBuild active;
            active.buildId = buildId;
            active.project = project;
            active.graph = graph;
            active.targetTaskIds = targetTaskIds;
            active.force = force;
            active.workspaceDir = workspaceDir;

            m_activeBuilds[buildId] = active;

            logInfo("[coordinator] Starting build '%s' for project '%s' (target: %s, %d tasks in DAG)", buildId, project.name.length > 0 ? project.name : (project.id.length > 0 ? project.id : "default"), targetTaskId.length > 0 ? targetTaskId : "all", targetTaskIds.length);

            // Evaluate initial root tasks & resolve cached nodes upfront
            evaluateReadyTasksLocked(buildId);

            return buildId;
        }
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
    }

    /**
     * Handles task completion results from local or remote workers.
     * Updates task and build status, saves cached fingerprints, and advances downstream dependents
     * for all builds subscribed to the completed task execution.
     */
    void onTaskCompleted(string fingerprint, TaskExecutionResult result, string receiptHandle = null)
    {
        if (result.fingerprint.length == 0 || result.fingerprint == "unknown")
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

    void onTaskCompleted(string buildId, string taskId, TaskExecutionResult result, string receiptHandle = null)
    {
        synchronized (m_mutex)
        {
            logInfo("[coordinator] Build '%s': Task '%s' completion received with status '%s' (exit code: %d, duration: %d ms, error: '%s')", buildId, taskId, result.status, result.exitCode, result.durationMs, result.errorMessage);

            // Acknowledge queue message if receipt handle provided
            string effectiveReceiptHandle = receiptHandle.length > 0 ? receiptHandle : result.receiptHandle;
            if (effectiveReceiptHandle.length > 0 && m_workQueue !is null)
            {
                try
                {
                    m_workQueue.ack(effectiveReceiptHandle);
                }
                catch (Exception e)
                {
                    logDebug("[coordinator] Queue acknowledgment note for receipt handle '%s': %s", effectiveReceiptHandle, e.msg);
                }
            }

            try
            {
                string fingerprint = result.fingerprint;
                if (fingerprint.length == 0 || fingerprint == "unknown")
                {
                    m_inFlightRegistry.getFingerprintForTask(buildId, taskId, fingerprint);
                }
                if ((fingerprint.length == 0 || fingerprint == "unknown") && (buildId in m_activeBuilds))
                {
                    try
                    {
                        fingerprint = m_activeBuilds[buildId].graph.getFingerprint(taskId);
                    }
                    catch (Exception) {}
                }

                // Retrieve all subscribed builds/tasks for this fingerprint
                InFlightSubscription[] subscribers;
                if (fingerprint.length > 0 && fingerprint != "unknown")
                {
                    subscribers = m_inFlightRegistry.completeTask(fingerprint);
                }
                
                // Only use fallback for legacy/unknown-fingerprint completions if the original build is still non-terminal
                if (subscribers.length == 0)
                {
                    BuildRecord origBuild;
                    bool origBuildExists = (m_stateRepo !is null && m_stateRepo.getBuild(buildId, origBuild));
                    bool origBuildNonTerminal = origBuildExists && 
                        (origBuild.status != "cancelled" && origBuild.status != "failed" && origBuild.status != "succeeded");
                    
                    if (origBuildNonTerminal)
                    {
                        subscribers = [InFlightSubscription(buildId, taskId)];
                    }
                }

                string[] buildsToEvaluate;

                foreach (sub; subscribers)
                {
                    string subBuildId = sub.buildId;
                    string subTaskId = sub.taskId;

                    // Record task execution record
                    TaskExecutionRecord rec;
                    rec.buildId = subBuildId;
                    rec.taskId = subTaskId;
                    rec.status = cast(string)result.status;
                    rec.fingerprint = (result.fingerprint.length > 0 && result.fingerprint != "unknown") ? result.fingerprint : fingerprint;
                    rec.exitCode = result.exitCode;
                    rec.errorMessage = result.errorMessage;
                    rec.durationMs = result.durationMs;
                    rec.producedArtifacts = result.producedArtifacts;
                    rec.finishedAt = Clock.currTime.toISOString();

                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.recordTaskExecution(rec);
                        m_stateRepo.setTaskStatus(subBuildId, subTaskId, result.status, result.errorMessage);

                        foreach (line; result.logs)
                        {
                            m_stateRepo.appendBuildLog(subBuildId, line);
                        }

                        // If fingerprint is valid and artifacts exist/succeeded, save to cache
                        if ((result.status == TaskStatus.succeeded || result.status == TaskStatus.cached)
                            && rec.fingerprint.length > 0 && rec.fingerprint != "unknown")
                        {
                            m_stateRepo.saveCachedFingerprint(subTaskId, rec.fingerprint, result.producedArtifacts);
                        }

                        // Update build executedTasks list
                        BuildRecord b;
                        if (m_stateRepo.getBuild(subBuildId, b))
                        {
                            if (!b.executedTasks.canFind(subTaskId))
                            {
                                b.executedTasks ~= subTaskId;
                                m_stateRepo.recordBuild(b);
                            }
                        }
                    }

                    if (!buildsToEvaluate.canFind(subBuildId))
                    {
                        buildsToEvaluate ~= subBuildId;
                    }
                }

                // Advance DAG progression for all subscribed builds
                foreach (bId; buildsToEvaluate)
                {
                    evaluateReadyTasksLocked(bId);
                }
            }
            catch (Exception e)
            {
                logError("[coordinator] Exception in onTaskCompleted (build '%s', task '%s'): %s\n%s", buildId, taskId, e.msg, e.toString());
            }
        }
    }

    /**
     * Cancels an in-flight build and marks all pending/running tasks as cancelled.
     */
    void cancelBuild(string buildId)
    {
        synchronized (m_mutex)
        {
            if (m_stateRepo !is null)
            {
                BuildRecord b;
                if (m_stateRepo.getBuild(buildId, b))
                {
                    b.status = "cancelled";
                    b.finishedAt = Clock.currTime.toISOString();
                    m_stateRepo.recordBuild(b);
                }

                auto statuses = m_stateRepo.getTaskStatusesForBuild(buildId);
                foreach (tId, status; statuses)
                {
                    if (status == TaskStatus.pending || status == TaskStatus.queued || status == TaskStatus.running)
                    {
                        m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.cancelled, "Build cancelled by user");
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
            if (m_stateRepo !is null)
            {
                BuildRecord b;
                if (m_stateRepo.getBuild(buildId, b))
                {
                    if (b.status == "cancelled" || b.status == "failed" || b.status == "succeeded")
                    {
                        return;
                    }
                    ProjectRecord proj;
                    if (m_stateRepo.getProject(b.projectId, proj))
                    {
                        ActiveBuild act;
                        act.buildId = buildId;
                        act.project = proj;
                        act.graph = new TaskGraph(proj);
                        if (b.workspaceDir.length > 0)
                        {
                            act.graph.computeFingerprints(b.workspaceDir);
                        }
                        if (b.targetTaskId.length > 0)
                        {
                            act.targetTaskIds = act.graph.resolveSubgraph(b.targetTaskId);
                        }
                        else
                        {
                            act.targetTaskIds = act.graph.topologicalSort();
                        }
                        act.workspaceDir = b.workspaceDir;
                        m_activeBuilds[buildId] = act;
                        pActive = buildId in m_activeBuilds;
                    }
                }
            }
        }

        if (pActive is null)
        {
            return;
        }

        ActiveBuild active = *pActive;
        TaskStatus[string] statuses;
        if (m_stateRepo !is null)
        {
            statuses = m_stateRepo.getTaskStatusesForBuild(buildId);
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
                if (m_stateRepo.getTaskExecution(buildId, tId, taskRec))
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
                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.cancelled, "Cancelled due to upstream task failure");
                    }
                }
            }

            // Update build status
            if (m_stateRepo !is null)
            {
                BuildRecord b;
                if (m_stateRepo.getBuild(buildId, b))
                {
                    b.status = "failed";
                    b.finishedAt = Clock.currTime.toISOString();
                    if (failureMsg.length > 0)
                    {
                        b.errorMessage = failureMsg;
                    }
                    m_stateRepo.recordBuild(b);
                }
            }

            m_inFlightRegistry.unsubscribeBuild(buildId);
            m_activeBuilds.remove(buildId);
            return;
        }

        // 2. Identify ready tasks and evaluate cache or enqueue
        bool stateChanged = false;
        do
        {
            stateChanged = false;
            if (m_stateRepo !is null)
            {
                statuses = m_stateRepo.getTaskStatusesForBuild(buildId);
            }

            foreach (tId; active.targetTaskIds)
            {
                TaskStatus currentStatus = statuses.get(tId, TaskStatus.pending);

                // Only evaluate tasks that have not completed/failed/cancelled/queued
                if (currentStatus != TaskStatus.pending)
                {
                    continue;
                }

                // Check if already enqueued to WorkQueue
                if (pActive.enqueuedTasks.get(tId, false))
                {
                    continue;
                }

                // Check if all upstream dependencies in targetTaskIds are satisfied
                string[] deps = active.graph.getDependencies(tId);
                bool allDepsSatisfied = true;
                string[string] upstreamHashes;

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

                    // Collect upstream task fingerprints for content-addressed artifact lookup
                    try
                    {
                        upstreamHashes[depId] = active.graph.getFingerprint(depId);
                    }
                    catch (Exception)
                    {
                        if (m_stateRepo !is null)
                        {
                            TaskExecutionRecord depRec;
                            if (m_stateRepo.getTaskExecution(buildId, depId, depRec) && depRec.fingerprint.length > 0)
                            {
                                upstreamHashes[depId] = depRec.fingerprint;
                            }
                        }
                    }
                }

                if (!allDepsSatisfied)
                {
                    continue;
                }

                TaskNode node = active.graph.getTask(tId);

                // 3. Cache check using precomputed deterministic fingerprint
                string fingerprint;
                try
                {
                    fingerprint = active.graph.getFingerprint(tId);
                }
                catch (Exception)
                {
                    fingerprint = "unknown";
                }

                if (!active.force && fingerprint.length > 0 && fingerprint != "unknown" && m_stateRepo !is null)
                {
                    ArtifactMetadata[] cachedArtifacts;
                    if (m_stateRepo.getCachedFingerprint(tId, fingerprint, cachedArtifacts))
                    {
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
                            cacheRec.buildId = buildId;
                            cacheRec.taskId = tId;
                            cacheRec.status = "cached";
                            cacheRec.fingerprint = fingerprint;
                            cacheRec.producedArtifacts = cachedArtifacts;
                            cacheRec.finishedAt = Clock.currTime.toISOString();

                            m_stateRepo.recordTaskExecution(cacheRec);
                            m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.cached);

                            BuildRecord b;
                            if (m_stateRepo.getBuild(buildId, b))
                            {
                                if (!b.executedTasks.canFind(tId))
                                {
                                    b.executedTasks ~= tId;
                                    m_stateRepo.recordBuild(b);
                                }
                            }

                            stateChanged = true;
                            continue;
                        }
                    }
                }

                // 4. In-Flight Coalescing & Enqueue to WorkQueue
                bool shouldEnqueue = m_inFlightRegistry.registerOrSubscribe(fingerprint, buildId, tId);
                pActive.enqueuedTasks[tId] = true;

                if (!shouldEnqueue)
                {
                    logInfo("[coordinator] Build '%s': Task '%s' coalesced with in-flight execution (fingerprint: %s)", buildId, tId, fingerprint);
                    continue;
                }

                string[] allowedRepos;
                string[string] repoMap;

                if (m_stateRepo !is null)
                {
                    try
                    {
                        foreach (repoRec; m_stateRepo.listRepositories())
                        {
                            if (repoRec.name.length > 0 && repoRec.address.length > 0)
                            {
                                repoMap[repoRec.name] = repoRec.address;
                            }
                        }
                    }
                    catch (Exception) {}
                }

                if (active.project.repositoryUrl.length > 0)
                {
                    allowedRepos ~= active.project.repositoryUrl;
                    if (active.project.id.length > 0 && active.project.id !in repoMap)
                    {
                        repoMap[active.project.id] = active.project.repositoryUrl;
                    }
                }
                if (active.graph !is null)
                {
                    try
                    {
                        auto ancestors = active.graph.resolveSubgraph(tId);
                        foreach (ancId; ancestors)
                        {
                            auto ancTask = active.graph.getTask(ancId);
                            foreach (r; ancTask.inputs.repositories)
                            {
                                if (!allowedRepos.canFind(r)) allowedRepos ~= r;
                                if (r in repoMap && !allowedRepos.canFind(repoMap[r]))
                                {
                                    allowedRepos ~= repoMap[r];
                                }
                            }
                            if (ancTask.hasCustomComponent("git_source"))
                            {
                                import std.json : JSONType;
                                auto comp = ancTask.getCustomComponent("git_source");
                                if (comp.type == JSONType.object && "url" in comp)
                                {
                                    string u = comp["url"].str;
                                    if (!allowedRepos.canFind(u)) allowedRepos ~= u;
                                }
                            }
                        }
                    }
                    catch (Exception) {}
                }
                foreach (r; node.inputs.repositories)
                {
                    if (!allowedRepos.canFind(r)) allowedRepos ~= r;
                    if (r in repoMap && !allowedRepos.canFind(repoMap[r]))
                    {
                        allowedRepos ~= repoMap[r];
                    }
                }
                if (node.hasCustomComponent("git_source"))
                {
                    import std.json : JSONType;
                    auto comp = node.getCustomComponent("git_source");
                    if (comp.type == JSONType.object && "url" in comp)
                    {
                        string u = comp["url"].str;
                        if (!allowedRepos.canFind(u)) allowedRepos ~= u;
                    }
                }

                TaskExecutionPayload payload;
                payload.repositoryUrl = active.project.repositoryUrl;
                payload.allowedRepositories = allowedRepos;
                payload.repositoryMap = repoMap;
                payload.environment = node.environment;
                payload.workspaceDir = active.workspaceDir;
                payload.force = active.force;
                payload.expectedOutputs = node.outputs.artifacts.dup;
                payload.upstreamArtifactHashes = upstreamHashes;
                payload.nodeFingerprint = fingerprint;

                if (m_callbackBaseUrl.length > 0)
                {
                    payload.callbackUrl = format("%s/api/v1/builds/%s/tasks/%s/complete", m_callbackBaseUrl, buildId, tId);
                }

                // Single authoritative upstream artifact list: (taskFingerprint, artifactId, destination)
                foreach (artRef; node.inputs.upstreamArtifacts)
                {
                    string artId = artRef.effectiveArtifactId;
                    string upFp;
                    try
                    {
                        upFp = active.graph.getFingerprint(artRef.taskId);
                    }
                    catch (Exception)
                    {
                        if (artRef.taskId in upstreamHashes)
                        {
                            upFp = upstreamHashes[artRef.taskId];
                        }
                    }

                    InputArtifactRef inArt;
                    inArt.taskId = artRef.taskId;
                    inArt.taskFingerprint = upFp;
                    inArt.artifactId = artId;
                    // Empty destination means unpack into workspace root
                    inArt.destination = artRef.destination;
                    payload.inputArtifacts ~= inArt;
                }

                // Resolve executorType and requirements tags from TaskNode components or definitions
                string executorType = "local";
                string[string] requirements;

                if (node.hasCustomComponent("executor"))
                {
                    auto comp = node.getCustomComponent("executor");
                    if (comp.type == JSONType.string) executorType = comp.str;
                    else if (comp.type == JSONType.object && "type" in comp) executorType = comp["type"].str;
                }
                else if (node.hasCustomComponent("executor_type"))
                {
                    auto comp = node.getCustomComponent("executor_type");
                    if (comp.type == JSONType.string) executorType = comp.str;
                }
                else if (node.components !is null && "executor_type" in node.components)
                {
                    executorType = node.components["executor_type"];
                }
                else if (node.components !is null && "executor" in node.components)
                {
                    executorType = node.components["executor"];
                }

                if (node.hasCustomComponent("requirements"))
                {
                    auto comp = node.getCustomComponent("requirements");
                    if (comp.type == JSONType.object)
                    {
                        foreach (k, v; comp.object)
                        {
                            if (v.type == JSONType.string) requirements[k] = v.str;
                            else requirements[k] = v.toString();
                        }
                    }
                }

                WorkOrder workOrder;
                workOrder.buildId = buildId;
                workOrder.taskId = tId;
                workOrder.fingerprint = fingerprint;
                workOrder.executorType = executorType;
                workOrder.requirements = requirements;
                workOrder.payload = payload;
                workOrder.timeoutSeconds = node.timeoutSeconds;
                workOrder.createdAt = Clock.currTime.toISOString();

                TaskQueueMessage msg;
                msg.id = "msg_" ~ randomUUID().toString();
                msg.workOrder = workOrder;
                msg.status = "enqueued";
                msg.taskNode = node;
                msg.timeoutSeconds = node.timeoutSeconds;
                msg.maxAttempts = 3;
                msg.visibleAfterUnix = Clock.currTime.toUnixTime();
                msg.createdAt = workOrder.createdAt;

                logInfo("[coordinator] Build '%s': Enqueuing ready task '%s' to work queue (fingerprint: %s, executor: %s, timeout: %ds)", buildId, tId, fingerprint, executorType, node.timeoutSeconds);

                if (m_workQueue !is null)
                {
                    m_workQueue.enqueue(msg);
                }

                // Mark task as queued — it will transition to running when a worker picks it up
                if (m_stateRepo !is null)
                {
                    m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.queued);
                }
            }
        }
        while (stateChanged);

        // 5. Check if all target tasks are finished
        if (m_stateRepo !is null)
        {
            statuses = m_stateRepo.getTaskStatusesForBuild(buildId);
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

            if (m_stateRepo !is null)
            {
                BuildRecord b;
                if (m_stateRepo.getBuild(buildId, b))
                {
                    b.status = finalStatus;
                    b.finishedAt = Clock.currTime.toISOString();
                    m_stateRepo.recordBuild(b);
                }
            }

            m_inFlightRegistry.unsubscribeBuild(buildId);
            m_activeBuilds.remove(buildId);
        }
    }
}

unittest
{
    // Unit tests for BuildCoordinator
    auto storage = new LocalArtifactStorage(".confector/test_coord_artifacts");
    auto stateRepo = new InMemoryBuildStateRepository();
    auto queue = new InMemoryWorkQueue();
    auto coordinator = new BuildCoordinator(storage, stateRepo, queue, "http://127.0.0.1:8080");

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
    assert(queue.getPendingCount() == 1);

    auto dequeued = queue.dequeue(1);
    assert(dequeued.length == 1);
    assert(dequeued[0].taskId == "lint");
    assert(dequeued[0].buildId == b1);

    TaskExecutionResult res1;
    res1.taskId = "lint";
    res1.buildId = b1;
    res1.status = TaskStatus.succeeded;
    res1.fingerprint = "fp_lint_1";
    coordinator.onTaskCompleted(b1, "lint", res1);

    BuildRecord b1Rec;
    assert(stateRepo.getBuild(b1, b1Rec));
    assert(b1Rec.status == "succeeded");
    assert(b1Rec.executedTasks == ["lint"]);

    // 2. Linear Pipeline: A -> B -> C
    TaskNode taskA;
    taskA.id = "A";
    taskA.steps = [BuildStep("A", "bash", null, "echo A")];

    TaskNode taskB;
    taskB.id = "B";
    taskB.dependsOn = ["A"];
    taskB.steps = [BuildStep("B", "bash", null, "echo B")];

    TaskNode taskC;
    taskC.id = "C";
    taskC.dependsOn = ["B"];
    taskC.steps = [BuildStep("C", "bash", null, "echo C")];

    ProjectRecord projLinear;
    projLinear.id = "proj_linear";
    projLinear.name = "Linear Project";
    projLinear.tasks = [taskA, taskB, taskC];

    string bLinear = coordinator.startBuild(projLinear, null, true); // force execution
    assert(queue.getPendingCount() == 1); // Only A is ready initially

    auto deqA = queue.dequeue(1);
    assert(deqA[0].taskId == "A");

    TaskExecutionResult resA;
    resA.taskId = "A";
    resA.buildId = bLinear;
    resA.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "A", resA);

    assert(queue.getPendingCount() == 1); // B is now unblocked
    auto deqB = queue.dequeue(1);
    assert(deqB[0].taskId == "B");

    TaskExecutionResult resB;
    resB.taskId = "B";
    resB.buildId = bLinear;
    resB.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "B", resB);

    assert(queue.getPendingCount() == 1); // C is now unblocked
    auto deqC = queue.dequeue(1);
    assert(deqC[0].taskId == "C");

    TaskExecutionResult resC;
    resC.taskId = "C";
    resC.buildId = bLinear;
    resC.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bLinear, "C", resC);

    BuildRecord bLinearRec;
    assert(stateRepo.getBuild(bLinear, bLinearRec));
    assert(bLinearRec.status == "succeeded");
    assert(bLinearRec.executedTasks.length == 3);

    // 3. Diamond Dependency / Fan-Out Fan-In: Root -> (Branch1, Branch2) -> Merge
    TaskNode rootNode;
    rootNode.id = "root";

    TaskNode branch1;
    branch1.id = "branch1";
    branch1.dependsOn = ["root"];

    TaskNode branch2;
    branch2.id = "branch2";
    branch2.dependsOn = ["root"];

    TaskNode mergeNode;
    mergeNode.id = "merge";
    mergeNode.dependsOn = ["branch1", "branch2"];

    ProjectRecord projDiamond;
    projDiamond.id = "proj_diamond";
    projDiamond.tasks = [rootNode, branch1, branch2, mergeNode];

    string bDiamond = coordinator.startBuild(projDiamond, null, true);
    assert(queue.getPendingCount() == 1); // Only root

    auto deqRoot = queue.dequeue(1);
    assert(deqRoot[0].taskId == "root");

    TaskExecutionResult resRoot;
    resRoot.taskId = "root";
    resRoot.buildId = bDiamond;
    resRoot.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "root", resRoot);

    // Fan-out: both branch1 and branch2 should be enqueued simultaneously
    assert(queue.getPendingCount() == 2);
    auto deqBranches = queue.dequeue(2);
    assert(deqBranches.length == 2);

    // Complete branch1 only
    TaskExecutionResult resBr1;
    resBr1.taskId = "branch1";
    resBr1.buildId = bDiamond;
    resBr1.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "branch1", resBr1);

    // Merge must NOT be enqueued yet because branch2 is still pending
    assert(queue.getPendingCount() == 0);

    // Complete branch2
    TaskExecutionResult resBr2;
    resBr2.taskId = "branch2";
    resBr2.buildId = bDiamond;
    resBr2.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "branch2", resBr2);

    // Fan-in: merge is now enqueued
    assert(queue.getPendingCount() == 1);
    auto deqMerge = queue.dequeue(1);
    assert(deqMerge[0].taskId == "merge");

    TaskExecutionResult resMerge;
    resMerge.taskId = "merge";
    resMerge.buildId = bDiamond;
    resMerge.status = TaskStatus.succeeded;
    coordinator.onTaskCompleted(bDiamond, "merge", resMerge);

    BuildRecord bDiamondRec;
    assert(stateRepo.getBuild(bDiamond, bDiamondRec));
    assert(bDiamondRec.status == "succeeded");

    // 4. Failure Early Termination
    string bFail = coordinator.startBuild(projLinear, null, true);
    auto deqFailA = queue.dequeue(1);
    assert(deqFailA[0].taskId == "A");

    TaskExecutionResult resFailA;
    resFailA.taskId = "A";
    resFailA.buildId = bFail;
    resFailA.status = TaskStatus.failed;
    resFailA.errorMessage = "Compiler syntax error";
    coordinator.onTaskCompleted(bFail, "A", resFailA);

    // Downstream tasks B and C must not be enqueued
    assert(queue.getPendingCount() == 0);

    BuildRecord bFailRec;
    assert(stateRepo.getBuild(bFail, bFailRec));
    assert(bFailRec.status == "failed");
    assert(bFailRec.errorMessage == "Compiler syntax error");

    TaskStatus statusB;
    assert(stateRepo.getTaskStatus(bFail, "B", statusB));
    assert(statusB == TaskStatus.cancelled);

    // 5. In-Flight Task Coalescing & Multi-Build Notification
    {
        auto coord5 = new BuildCoordinator(storage, stateRepo, queue);

        TaskNode taskRoot;
        taskRoot.id = "fetch";
        taskRoot.steps = [BuildStep("Fetch", "bash", null, "echo fetching data")];

        TaskNode taskProc;
        taskProc.id = "process";
        taskProc.dependsOn = ["fetch"];
        taskProc.steps = [BuildStep("Process", "bash", null, "echo processing")];

        ProjectRecord projCoalesce;
        projCoalesce.id = "proj_coalesce";
        projCoalesce.tasks = [taskRoot, taskProc];

        // Start Build 1 targeting entire pipeline (fetch -> process)
        string b1_coalesce = coord5.startBuild(projCoalesce, null, true);
        assert(queue.getPendingCount() == 1); // "fetch" is enqueued for b1

        // Start Build 2 targeting only "fetch" while "fetch" is still in-flight
        string b2_coalesce = coord5.startBuild(projCoalesce, "fetch", true);
        // Deduplication check: queue should STILL have pending count == 1, not 2!
        assert(queue.getPendingCount() == 1);

        auto deqFetch = queue.dequeue(1);
        assert(deqFetch.length == 1);
        assert(deqFetch[0].taskId == "fetch");

        // Complete "fetch" task
        TaskExecutionResult resFetch;
        resFetch.taskId = "fetch";
        resFetch.buildId = deqFetch[0].buildId;
        resFetch.status = TaskStatus.succeeded;
        resFetch.fingerprint = deqFetch[0].nodeFingerprint;
        coord5.onTaskCompleted(deqFetch[0].buildId, "fetch", resFetch);

        // Build 2 (targeting only "fetch") should now be completed!
        BuildRecord b2Rec;
        assert(stateRepo.getBuild(b2_coalesce, b2Rec));
        assert(b2Rec.status == "succeeded");
        assert(b2Rec.executedTasks.canFind("fetch"));

        // Build 1 should now have "process" unblocked and enqueued in WorkQueue
        assert(queue.getPendingCount() == 1);
        auto deqProc = queue.dequeue(1);
        assert(deqProc[0].taskId == "process");
        assert(deqProc[0].buildId == b1_coalesce);

        TaskExecutionResult resProc;
        resProc.taskId = "process";
        resProc.buildId = b1_coalesce;
        resProc.status = TaskStatus.succeeded;
        resProc.fingerprint = deqProc[0].nodeFingerprint;
        coord5.onTaskCompleted(b1_coalesce, "process", resProc);

        BuildRecord b1Rec_c;
        assert(stateRepo.getBuild(b1_coalesce, b1Rec_c));
        assert(b1Rec_c.status == "succeeded");
        assert(b1Rec_c.executedTasks.length == 2);
    }

    // 6. Cache Hit Subgraph Short-Circuiting
    {
        auto coord6 = new BuildCoordinator(storage, stateRepo, queue);

        TaskNode taskAlpha;
        taskAlpha.id = "alpha";
        taskAlpha.steps = [BuildStep("Alpha", "bash", null, "echo alpha source")];

        TaskNode taskBeta;
        taskBeta.id = "beta";
        taskBeta.dependsOn = ["alpha"];
        taskBeta.steps = [BuildStep("Beta", "bash", null, "echo beta build")];

        ProjectRecord projCache;
        projCache.id = "proj_cache_test";
        projCache.tasks = [taskAlpha, taskBeta];

        // First run: execute both tasks to populate cache
        string bFirst = coord6.startBuild(projCache, null, false);
        assert(queue.getPendingCount() == 1);

        auto deqAlpha = queue.dequeue(1);
        assert(deqAlpha[0].taskId == "alpha");
        TaskExecutionResult resAlpha;
        resAlpha.taskId = "alpha";
        resAlpha.buildId = bFirst;
        resAlpha.status = TaskStatus.succeeded;
        resAlpha.fingerprint = deqAlpha[0].nodeFingerprint;
        coord6.onTaskCompleted(bFirst, "alpha", resAlpha);

        assert(queue.getPendingCount() == 1);
        auto deqBeta = queue.dequeue(1);
        assert(deqBeta[0].taskId == "beta");
        TaskExecutionResult resBeta;
        resBeta.taskId = "beta";
        resBeta.buildId = bFirst;
        resBeta.status = TaskStatus.succeeded;
        resBeta.fingerprint = deqBeta[0].nodeFingerprint;
        coord6.onTaskCompleted(bFirst, "beta", resBeta);

        BuildRecord bFirstRec;
        assert(stateRepo.getBuild(bFirst, bFirstRec));
        assert(bFirstRec.status == "succeeded");

        // Second run with identical inputs and force=false: full cache hit!
        string bCached = coord6.startBuild(projCache, null, false);
        // Zero tasks should be placed in WorkQueue
        assert(queue.getPendingCount() == 0);

        BuildRecord bCachedRec;
        assert(stateRepo.getBuild(bCached, bCachedRec));
        assert(bCachedRec.status == "cached");

        TaskStatus stAlpha, stBeta;
        assert(stateRepo.getTaskStatus(bCached, "alpha", stAlpha));
        assert(stAlpha == TaskStatus.cached);
        assert(stateRepo.getTaskStatus(bCached, "beta", stBeta));
        assert(stBeta == TaskStatus.cached);
    }

    // 7. Multi-Build In-Flight Cancellation Isolation
    {
        auto coord7 = new BuildCoordinator(storage, stateRepo, queue);

        TaskNode taskShared;
        taskShared.id = "shared_task";
        taskShared.steps = [BuildStep("Shared", "bash", null, "echo shared")];

        ProjectRecord projCancel;
        projCancel.id = "proj_cancel_test";
        projCancel.tasks = [taskShared];

        string bCancel1 = coord7.startBuild(projCancel, null, true);
        string bCancel2 = coord7.startBuild(projCancel, null, true);

        assert(queue.getPendingCount() == 1);
        auto deqShared = queue.dequeue(1);

        // Cancel build 1 while task is in flight
        coord7.cancelBuild(bCancel1);

        BuildRecord bCancel1Rec;
        assert(stateRepo.getBuild(bCancel1, bCancel1Rec));
        assert(bCancel1Rec.status == "cancelled");

        // Complete shared task
        TaskExecutionResult resShared;
        resShared.taskId = "shared_task";
        resShared.buildId = deqShared[0].buildId;
        resShared.status = TaskStatus.succeeded;
        resShared.fingerprint = deqShared[0].nodeFingerprint;
        coord7.onTaskCompleted(deqShared[0].buildId, "shared_task", resShared);

        // Build 1 was NOT cancelled and should receive completion successfully
        BuildRecord bCancel2Rec;
        assert(stateRepo.getBuild(bCancel2, bCancel2Rec));
        assert(bCancel2Rec.status == "succeeded");

        // Build 1 must remain cancelled
        BuildRecord bCancel1RecAfter;
        assert(stateRepo.getBuild(bCancel1, bCancel1RecAfter));
        assert(bCancel1RecAfter.status == "cancelled");
    }

    // 8. Only-Subscriber Cancellation Edge Case: Cancelled build should not be overwritten by completion
    {
        auto coord8 = new BuildCoordinator(storage, stateRepo, queue);

        TaskNode taskSolo;
        taskSolo.id = "solo_task";
        taskSolo.steps = [BuildStep("Solo", "bash", null, "echo solo")];

        ProjectRecord projSolo;
        projSolo.id = "proj_solo_cancel_test";
        projSolo.tasks = [taskSolo];

        // Start a single build
        string bSolo = coord8.startBuild(projSolo, null, true);
        assert(queue.getPendingCount() == 1);
        auto deqSolo = queue.dequeue(1);

        // Cancel the only build while task is in flight
        coord8.cancelBuild(bSolo);

        BuildRecord bSoloRecCancelled;
        assert(stateRepo.getBuild(bSolo, bSoloRecCancelled));
        assert(bSoloRecCancelled.status == "cancelled");

        // Worker reports completion for the task
        TaskExecutionResult resSolo;
        resSolo.taskId = "solo_task";
        resSolo.buildId = deqSolo[0].buildId;
        resSolo.status = TaskStatus.succeeded;
        resSolo.fingerprint = deqSolo[0].nodeFingerprint;
        coord8.onTaskCompleted(deqSolo[0].buildId, "solo_task", resSolo);

        // Build must remain cancelled, not be overwritten to succeeded
        BuildRecord bSoloRecAfter;
        assert(stateRepo.getBuild(bSolo, bSoloRecAfter));
        assert(bSoloRecAfter.status == "cancelled", "Cancelled build should remain cancelled after task completion");

        // Task status should also remain cancelled, not be overwritten to succeeded
        TaskStatus taskStatusAfter;
        assert(stateRepo.getTaskStatus(bSolo, "solo_task", taskStatusAfter));
        assert(taskStatusAfter == TaskStatus.cancelled, "Task status should remain cancelled for cancelled build");
    }

    // 9. Structured WorkOrder Construction & Tag Resolution
    {
        auto coord9 = new BuildCoordinator(storage, stateRepo, queue);

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
        assert(queue.getPendingCount() == 1);

        auto deqGpu = queue.dequeue(1);
        assert(deqGpu.length == 1);
        assert(deqGpu[0].taskId == "train_model");
        assert(deqGpu[0].buildId == bWorkOrder);

        // Verify WorkOrder structure and metadata
        WorkOrder wo = deqGpu[0].workOrder;
        assert(wo.buildId == bWorkOrder);
        assert(wo.taskId == "train_model");
        assert(wo.fingerprint == deqGpu[0].nodeFingerprint);
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
        assert(stateRepo.getBuild(bWorkOrder, bWorkOrderRec));
        assert(bWorkOrderRec.status == "succeeded");
    }

    // 10. Queue Message Acknowledgment & stepBuild Progression
    {
        auto coord10 = new BuildCoordinator(storage, stateRepo, queue);

        TaskNode step1;
        step1.id = "step1";
        step1.steps = [BuildStep("Step1", "bash", null, "echo step 1")];

        TaskNode step2;
        step2.id = "step2";
        step2.dependsOn = ["step1"];
        step2.steps = [BuildStep("Step2", "bash", null, "echo step 2")];

        ProjectRecord projAck;
        projAck.id = "proj_ack_test";
        projAck.tasks = [step1, step2];

        string bAck = coord10.startBuild(projAck, null, true);
        assert(queue.getPendingCount() == 1);

        // Dequeue step1 message - will receive a receiptHandle
        auto deqStep1 = queue.dequeue(1);
        assert(deqStep1.length == 1);
        string rHandle = deqStep1[0].receiptHandle;
        assert(rHandle.length > 0);

        // Complete step1 providing receiptHandle directly in TaskExecutionResult
        TaskExecutionResult resStep1;
        resStep1.taskId = "step1";
        resStep1.buildId = bAck;
        resStep1.status = TaskStatus.succeeded;
        resStep1.fingerprint = deqStep1[0].nodeFingerprint;
        resStep1.receiptHandle = rHandle;
        coord10.onTaskCompleted(bAck, "step1", resStep1);

        // Downstream step2 is now ready in queue
        assert(queue.getPendingCount() == 1);

        // Explicit stepBuild invocation succeeds without errors
        coord10.stepBuild(bAck);
        assert(queue.getPendingCount() == 1);

        auto deqStep2 = queue.dequeue(1);
        assert(deqStep2[0].taskId == "step2");

        // Complete step2 passing receiptHandle via parameter overload
        TaskExecutionResult resStep2;
        resStep2.taskId = "step2";
        resStep2.buildId = bAck;
        resStep2.status = TaskStatus.succeeded;
        resStep2.fingerprint = deqStep2[0].nodeFingerprint;
        coord10.onTaskCompleted(bAck, "step2", resStep2, deqStep2[0].receiptHandle);

        BuildRecord bAckRec;
        assert(stateRepo.getBuild(bAck, bAckRec));
        assert(bAckRec.status == "succeeded");
    }
}
