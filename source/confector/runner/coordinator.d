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
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }
    @property BuildStateRepository stateRepository() { return m_stateRepo; }
    @property WorkQueue workQueue() { return m_workQueue; }
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
            buildRecord.status = "running";
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

            // Evaluate initial root tasks
            evaluateReadyTasksLocked(buildId);

            return buildId;
        }
    }

    /**
     * Handles task completion results from local or remote workers.
     * Updates task and build status, saves cached fingerprints, and advances downstream dependents.
     */
    void onTaskCompleted(string buildId, string taskId, TaskExecutionResult result)
    {
        synchronized (m_mutex)
        {
            logInfo("[coordinator] Build '%s': Task '%s' completion received with status '%s' (exit code: %d, duration: %d ms, error: '%s')", buildId, taskId, result.status, result.exitCode, result.durationMs, result.errorMessage);

            try
            {
                // Record task execution record
                TaskExecutionRecord rec;
                rec.buildId = buildId;
                rec.taskId = taskId;
                rec.status = cast(string)result.status;
                rec.fingerprint = result.fingerprint;
                rec.exitCode = result.exitCode;
                rec.errorMessage = result.errorMessage;
                rec.durationMs = result.durationMs;
                rec.producedArtifacts = result.producedArtifacts;
                rec.finishedAt = Clock.currTime.toISOString();

                if (m_stateRepo !is null)
                {
                    m_stateRepo.recordTaskExecution(rec);
                    m_stateRepo.setTaskStatus(buildId, taskId, result.status, result.errorMessage);

                    foreach (line; result.logs)
                    {
                        m_stateRepo.appendBuildLog(buildId, line);
                    }

                    // If fingerprint is valid and artifacts exist, save to cache
                    if ((result.status == TaskStatus.succeeded || result.status == TaskStatus.cached)
                        && result.fingerprint.length > 0 && result.fingerprint != "unknown")
                    {
                        m_stateRepo.saveCachedFingerprint(taskId, result.fingerprint, result.producedArtifacts);
                    }

                    // Update build executedTasks list
                    BuildRecord b;
                    if (m_stateRepo.getBuild(buildId, b))
                    {
                        if (!b.executedTasks.canFind(taskId))
                        {
                            b.executedTasks ~= taskId;
                            m_stateRepo.recordBuild(b);
                        }
                    }
                }

                // Advance DAG progression
                evaluateReadyTasksLocked(buildId);
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
                    if (status == TaskStatus.pending || status == TaskStatus.running)
                    {
                        m_stateRepo.setTaskStatus(buildId, tId, TaskStatus.cancelled, "Build cancelled by user");
                    }
                }
            }

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
                    ProjectRecord proj;
                    if (m_stateRepo.getProject(b.projectId, proj))
                    {
                        ActiveBuild act;
                        act.buildId = buildId;
                        act.project = proj;
                        act.graph = new TaskGraph(proj);
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
                if (pStat is null || *pStat == TaskStatus.pending)
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

                // Only evaluate tasks that have not completed/failed/cancelled
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

                    // Collect upstream artifact hashes if present
                    if (m_stateRepo !is null)
                    {
                        TaskExecutionRecord depRec;
                        if (m_stateRepo.getTaskExecution(buildId, depId, depRec))
                        {
                            foreach (art; depRec.producedArtifacts)
                            {
                                upstreamHashes[art.filePath] = art.sha256;
                            }
                        }
                    }
                }

                if (!allDepsSatisfied)
                {
                    continue;
                }

                TaskNode node = active.graph.getTask(tId);

                // 3. Cache check
                if (!active.force)
                {
                    string fingerprint;
                    try
                    {
                        fingerprint = Fingerprinter.computeNodeFingerprint(node, active.workspaceDir, upstreamHashes);
                    }
                    catch (Exception)
                    {
                        fingerprint = "unknown";
                    }

                    if (fingerprint.length > 0 && fingerprint != "unknown" && m_stateRepo !is null)
                    {
                        ArtifactMetadata[] cachedArtifacts;
                        if (m_stateRepo.getCachedFingerprint(tId, fingerprint, cachedArtifacts))
                        {
                            // Verify artifacts exist in storage
                            bool allValid = true;
                            foreach (meta; cachedArtifacts)
                            {
                                if (m_artifactStorage !is null && !m_artifactStorage.artifactExists(meta.buildId, meta.taskId, meta.filePath))
                                {
                                    allValid = false;
                                    break;
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
                }

                // 4. Enqueue to WorkQueue
                TaskExecutionPayload payload;
                payload.repositoryUrl = active.project.repositoryUrl;
                payload.script = node.script;
                payload.environment = node.environment;
                payload.workspaceDir = active.workspaceDir;
                payload.force = active.force;
                payload.expectedOutputs = node.outputs.artifacts.dup;
                payload.upstreamArtifactHashes = upstreamHashes;

                if (m_callbackBaseUrl.length > 0)
                {
                    payload.callbackUrl = format("%s/api/v1/builds/%s/tasks/%s/complete", m_callbackBaseUrl, buildId, tId);
                }

                // Resolve upstream artifact input locations
                foreach (artRef; node.inputs.upstreamArtifacts)
                {
                    string target = artRef.path.length > 0 ? artRef.path : artRef.name;
                    InputArtifactRef inArt;
                    inArt.taskId = artRef.taskId;
                    inArt.targetPath = target;
                    payload.inputArtifacts ~= inArt;

                    UpstreamArtifactLocation loc;
                    loc.taskId = artRef.taskId;
                    loc.artifactPath = target;
                    loc.targetPath = target;
                    if (m_artifactStorage !is null)
                    {
                        ArtifactMetadata meta;
                        if (m_artifactStorage.getArtifactMetadata(buildId, artRef.taskId, target, meta))
                        {
                            loc.storageBackend = meta.storageBackend;
                            loc.storageUri = meta.storageUri;
                            loc.sha256 = meta.sha256;
                        }
                    }
                    payload.upstreamArtifactLocations ~= loc;
                }

                TaskQueueMessage msg;
                msg.messageId = "msg_" ~ randomUUID().toString();
                msg.buildId = buildId;
                msg.taskId = tId;
                msg.taskNode = node;
                msg.executionPayload = payload;
                msg.timeoutSeconds = node.timeoutSeconds;
                msg.createdAt = Clock.currTime.toISOString();

                pActive.enqueuedTasks[tId] = true;

                logInfo("[coordinator] Build '%s': Enqueuing ready task '%s' to work queue (timeout: %ds)", buildId, tId, node.timeoutSeconds);

                if (m_workQueue !is null)
                {
                    m_workQueue.enqueue(msg);
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
    singleTask.script = "echo linting";

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
    taskA.script = "echo A";

    TaskNode taskB;
    taskB.id = "B";
    taskB.dependsOn = ["A"];
    taskB.script = "echo B";

    TaskNode taskC;
    taskC.id = "C";
    taskC.dependsOn = ["B"];
    taskC.script = "echo C";

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
}
