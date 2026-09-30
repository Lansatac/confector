module confector.runner.engine;

import confector.core.model;
import confector.core.dag;
import confector.core.fingerprinter;
import confector.core.executor;
import confector.core.plugin;
import confector.core.storage;

import std.file : exists, isFile;
import std.path : buildPath, isAbsolute;
import std.format : format;
import std.datetime.stopwatch : StopWatch, AutoStart;

/**
 * Result of a single task execution.
 */
struct TaskExecutionResult
{
    string taskId;
    string buildId;
    TaskStatus status;
    string fingerprint;
    int exitCode = 0;
    string[] logs;
    string errorMessage;
    ArtifactMetadata[] producedArtifacts;
    ulong durationMs;
}

/**
 * Result of a pipeline execution.
 */
struct PipelineExecutionResult
{
    string buildId;
    bool success;
    TaskExecutionResult[string] taskResults;
    string[] executedOrder;
}

/**
 * Core stateless execution engine capable of executing single nodes or graph slices.
 */
class TaskEngine
{
    private ArtifactStorage m_artifactStorage;
    private BuildStateRepository m_stateRepo;

    this(ArtifactStorage artifactStorage, BuildStateRepository stateRepo)
    {
        m_artifactStorage = artifactStorage;
        m_stateRepo = stateRepo;
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }
    @property BuildStateRepository stateRepository() { return m_stateRepo; }

    /**
     * Executes a single task node with fingerprint checking and artifact handling.
     */
    TaskExecutionResult executeTask(
        string buildId,
        in TaskNode task,
        string workspaceDir,
        in string[string] upstreamArtifactHashes = null,
        bool force = false,
        LogDelegate logCallback = null
    )
    {
        auto sw = StopWatch(AutoStart.yes);
        TaskExecutionResult result;
        result.taskId = task.id;
        result.buildId = buildId;

        // 1. Calculate input fingerprint
        string fingerprint;
        try
        {
            fingerprint = Fingerprinter.computeNodeFingerprint(task, workspaceDir, upstreamArtifactHashes);
        }
        catch (Exception e)
        {
            fingerprint = "unknown";
        }
        result.fingerprint = fingerprint;

        // 2. Check cache if not forced
        if (!force && fingerprint.length > 0 && fingerprint != "unknown")
        {
            ArtifactMetadata[] cachedArtifacts;
            if (m_stateRepo !is null && m_stateRepo.getCachedFingerprint(task.id, fingerprint, cachedArtifacts))
            {
                // Verify all artifacts exist in storage
                bool allArtifactsValid = true;
                foreach (meta; cachedArtifacts)
                {
                    if (m_artifactStorage !is null && !m_artifactStorage.artifactExists(meta.buildId, meta.taskId, meta.filePath))
                    {
                        allArtifactsValid = false;
                        break;
                    }
                }

                if (allArtifactsValid)
                {
                    result.status = TaskStatus.cached;
                    result.producedArtifacts = cachedArtifacts;
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.cached);
                    }
                    if (logCallback !is null)
                    {
                        logCallback(format("[confector] Task '%s' matched cache fingerprint (%s). Skipped execution.", task.id, fingerprint[0 .. 8]));
                    }
                    return result;
                }
            }
        }

        // 3. Mark task running
        if (m_stateRepo !is null)
        {
            m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.running);
        }

        // 4. Retrieve any upstream artifacts required into workspace
        if (m_artifactStorage !is null && task.inputs.upstreamArtifacts.length > 0)
        {
            foreach (refArt; task.inputs.upstreamArtifacts)
            {
                string targetLocal = buildPath(workspaceDir, refArt.name);
                if (m_artifactStorage.artifactExists(buildId, refArt.taskId, refArt.name))
                {
                    m_artifactStorage.retrieveArtifact(buildId, refArt.taskId, refArt.name, targetLocal);
                }
            }
        }

        // 5. Locate TaskRunner plugin
        auto runners = PluginRegistry.instance.getPluginsOfType!TaskRunner();
        if (runners.length == 0)
        {
            result.status = TaskStatus.failed;
            result.errorMessage = "No TaskRunner plugin registered in PluginRegistry";
            if (m_stateRepo !is null)
            {
                m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
            }
            sw.stop();
            result.durationMs = sw.peek.total!"msecs";
            return result;
        }

        TaskRunner runner = runners[0];

        // 6. Prepare ExecutionRequest
        ExecutionRequest req;
        req.command = task.script;
        req.workingDirectory = task.workingDirectory.length > 0
            ? (isAbsolute(task.workingDirectory) ? task.workingDirectory : buildPath(workspaceDir, task.workingDirectory))
            : workspaceDir;

        // Build environment
        foreach (k, v; task.environment)
        {
            req.environmentVariables[k] = v;
        }
        req.timeoutSeconds = task.timeoutSeconds;

        // Log capture collector
        string[] capturedLogs;
        LogDelegate combinedLogger = (string line) @trusted {
            capturedLogs ~= line;
            if (m_stateRepo !is null)
            {
                try { m_stateRepo.appendBuildLog(buildId, format("[%s] %s", task.id, line)); } catch (Exception) {}
            }
            if (logCallback !is null)
            {
                logCallback(line);
            }
        };

        // 7. Execute task
        ExecutionResult execResult = runner.execute(req, combinedLogger);
        result.exitCode = execResult.exitCode;
        result.logs = capturedLogs;

        if (!execResult.success)
        {
            result.status = TaskStatus.failed;
            result.errorMessage = execResult.errorMessage.length > 0
                ? execResult.errorMessage
                : format("Task execution exited with code %d", execResult.exitCode);

            if (m_stateRepo !is null)
            {
                m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
            }
            sw.stop();
            result.durationMs = sw.peek.total!"msecs";
            return result;
        }

        // 8. Capture and store declared output artifacts
        ArtifactMetadata[] producedArtifacts;
        if (m_artifactStorage !is null)
        {
            foreach (artDecl; task.outputs.artifacts)
            {
                string localArtifactPath = buildPath(req.workingDirectory, artDecl.path);
                if (exists(localArtifactPath) && isFile(localArtifactPath))
                {
                    auto meta = m_artifactStorage.storeArtifact(buildId, task.id, localArtifactPath, artDecl.type);
                    producedArtifacts ~= meta;
                }
            }
        }
        result.producedArtifacts = producedArtifacts;

        // 9. Save cached fingerprint
        if (m_stateRepo !is null && fingerprint.length > 0 && fingerprint != "unknown")
        {
            m_stateRepo.saveCachedFingerprint(task.id, fingerprint, producedArtifacts);
            m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.succeeded);
        }

        result.status = TaskStatus.succeeded;
        sw.stop();
        result.durationMs = sw.peek.total!"msecs";
        return result;
    }

    /**
     * Executes a pipeline or subgraph slice according to an ExecutionPlan.
     */
    PipelineExecutionResult executePipeline(
        string buildId,
        in PipelineDefinition pipeline,
        in ExecutionPlan plan,
        string workspaceDir,
        bool force = false,
        LogDelegate logCallback = null
    )
    {
        import std.datetime.systime : Clock;

        auto totalSw = StopWatch(AutoStart.yes);
        PipelineExecutionResult pipelineResult;
        pipelineResult.buildId = buildId;
        pipelineResult.success = true;

        BuildRecord buildRec;
        buildRec.buildId = buildId;
        buildRec.pipelineName = "default";
        buildRec.status = "running";
        buildRec.workspaceDir = workspaceDir;
        buildRec.startedAt = Clock.currTime.toISOString();
        if (m_stateRepo !is null)
        {
            m_stateRepo.recordBuild(buildRec);
            m_stateRepo.appendBuildLog(buildId, format("[pipeline] Starting build %s with %d tasks", buildId, plan.orderedTaskIds.length));
        }

        const(TaskNode)*[string] taskMap;
        foreach (ref task; pipeline.tasks)
        {
            taskMap[task.id] = &task;
        }

        string[string] currentArtifactHashes;
        bool allCached = true;

        foreach (taskId; plan.orderedTaskIds)
        {
            pipelineResult.executedOrder ~= taskId;
            auto pTask = taskId in taskMap;
            if (pTask is null)
            {
                pipelineResult.success = false;
                break;
            }

            // Check if explicitly marked cached in plan and not forced
            bool isCachedInPlan = false;
            foreach (cId; plan.cachedTaskIds)
            {
                if (cId == taskId)
                {
                    isCachedInPlan = true;
                    break;
                }
            }

            auto taskRes = executeTask(
                buildId,
                **pTask,
                workspaceDir,
                currentArtifactHashes,
                force ? true : false,
                logCallback
            );

            pipelineResult.taskResults[taskId] = taskRes;

            if (taskRes.status != TaskStatus.cached)
            {
                allCached = false;
            }

            // Track produced artifact hashes for downstream tasks
            foreach (art; taskRes.producedArtifacts)
            {
                currentArtifactHashes[art.filePath] = art.sha256;
            }

            if (taskRes.status == TaskStatus.failed)
            {
                pipelineResult.success = false;
                if (m_stateRepo !is null)
                {
                    m_stateRepo.appendBuildLog(buildId, format("[pipeline] Build failed at task '%s': %s", taskId, taskRes.errorMessage));
                }
                break;
            }
        }

        totalSw.stop();
        buildRec.finishedAt = Clock.currTime.toISOString();
        buildRec.durationMs = totalSw.peek.total!"msecs";
        buildRec.executedTasks = pipelineResult.executedOrder;

        if (!pipelineResult.success)
        {
            buildRec.status = "failed";
            buildRec.errorMessage = "One or more tasks failed execution";
        }
        else if (allCached && pipelineResult.executedOrder.length > 0)
        {
            buildRec.status = "cached";
        }
        else
        {
            buildRec.status = "succeeded";
        }

        if (m_stateRepo !is null)
        {
            m_stateRepo.recordBuild(buildRec);
            m_stateRepo.appendBuildLog(buildId, format("[pipeline] Build completed with status '%s' in %d ms", buildRec.status, buildRec.durationMs));
        }

        return pipelineResult;
    }
}

unittest
{
    import confector.plugins.process_runner;
    import std.file : rmdirRecurse, mkdirRecurse, write;

    string testDir = "test_engine_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Register process runner plugin
    PluginRegistry.instance.registerPlugin(new ProcessTaskRunnerPlugin());

    auto storage = new LocalArtifactStorage(buildPath(testDir, "storage"));
    auto stateRepo = new InMemoryBuildStateRepository();
    auto engine = new TaskEngine(storage, stateRepo);

    // Define a task that writes an output file
    TaskNode node1;
    node1.id = "step1";
    node1.name = "Step 1";
    version(Windows)
    {
        node1.script = "cmd /c \"echo hello > output.txt\"";
    }
    else
    {
        node1.script = "echo hello > output.txt";
    }
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "file")];

    // First execution: should execute and succeed
    auto res1 = engine.executeTask("build_1", node1, testDir);
    assert(res1.status == TaskStatus.succeeded);
    assert(res1.producedArtifacts.length == 1);
    assert(storage.artifactExists("build_1", "step1", "output.txt"));

    // Second execution (same buildId or new buildId): should be cached
    auto res2 = engine.executeTask("build_2", node1, testDir);
    assert(res2.status == TaskStatus.cached);
    assert(res2.producedArtifacts.length == 1);

    // Forced execution: should re-run
    auto res3 = engine.executeTask("build_3", node1, testDir, null, true);
    assert(res3.status == TaskStatus.succeeded);
}
