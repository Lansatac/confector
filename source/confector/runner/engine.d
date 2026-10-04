module confector.runner.engine;

import confector.core.model;
import confector.core.dag;
import confector.core.fingerprinter;
import confector.core.executor;
import confector.core.system;
import confector.core.plugin;
import confector.core.storage;

import std.file : exists, isFile;
import std.path : buildPath, isAbsolute;
import std.format : format;
import std.datetime.stopwatch : StopWatch, AutoStart;
import vibe.core.log : logInfo, logError, logWarn, logDebug;


/**
 * Result of a task graph or build execution.
 */
struct GraphExecutionResult
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
     * Executes a single task node with fingerprint checking and optional artifact handling.
     *
     * Params:
     *   upstreamFingerprints = Map of upstream taskId -> task fingerprint (content-addressed).
     *   precomputedFingerprint = When non-empty, used as the authoritative node fingerprint
     *                            (e.g. coordinator/graph fingerprint) instead of recomputing.
     *   manageArtifacts = When true, engine stages upstream artifacts and packs outputs.
     *                     When false (queued worker path), caller owns artifact I/O and
     *                     engine acts purely as a step/script execution helper.
     */
    TaskExecutionResult executeTask(
        string buildId,
        in TaskNode task,
        string workspaceDir,
        in string[string] upstreamFingerprints = null,
        bool force = false,
        LogDelegate logCallback = null,
        in string[] allowedRepositories = null,
        in string[string] repositoryMap = null,
        string precomputedFingerprint = null,
        bool manageArtifacts = true
    )
    {
        auto sw = StopWatch(AutoStart.yes);
        TaskExecutionResult result;
        result.taskId = task.id;
        result.buildId = buildId;

        logInfo("[engine] Starting executeTask for task '%s' (build '%s', workspace '%s', force=%s, manageArtifacts=%s)",
            task.id, buildId, workspaceDir, force, manageArtifacts);

        // 1. Resolve input fingerprint (prefer coordinator/graph precomputed value)
        string fingerprint;
        if (precomputedFingerprint.length > 0 && precomputedFingerprint != "unknown")
        {
            fingerprint = precomputedFingerprint;
        }
        else
        {
            try
            {
                fingerprint = Fingerprinter.computeNodeFingerprint(task, workspaceDir, upstreamFingerprints);
            }
            catch (Exception e)
            {
                fingerprint = "unknown";
            }
        }
        result.fingerprint = fingerprint;

        // 2. Check cache if not forced
        if (!force && fingerprint.length > 0 && fingerprint != "unknown")
        {
            ArtifactMetadata[] cachedArtifacts;
            if (m_stateRepo !is null && m_stateRepo.getCachedFingerprint(task.id, fingerprint, cachedArtifacts))
            {
                // Verify all artifacts exist in stream storage by (taskFingerprint, artifactId)
                bool allArtifactsValid = true;
                foreach (meta; cachedArtifacts)
                {
                    if (m_artifactStorage !is null)
                    {
                        string effectiveFp = meta.taskFingerprint.length > 0 ? meta.taskFingerprint : fingerprint;
                        string effectiveArtId = meta.artifactId.length > 0 ? meta.artifactId : meta.filePath;
                        if (!m_artifactStorage.artifactExists(effectiveFp, effectiveArtId))
                        {
                            allArtifactsValid = false;
                            break;
                        }
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

        // Effective working directory defaults to workspace directory
        string effectiveWorkingDir = workspaceDir;

        // 4. Input Resolution Systems pass
        InputResolutionContext inputCtx;
        inputCtx.buildId = buildId;
        inputCtx.workspaceDir = workspaceDir;
        inputCtx.effectiveWorkingDir = effectiveWorkingDir;
        inputCtx.artifactStorage = m_artifactStorage;
        inputCtx.logCallback = logCallback;
        foreach (k, v; task.inputs.parameters)
        {
            inputCtx.parameters[k] = v;
        }

        foreach (resolver; PluginRegistry.instance.getInputResolvers())
        {
            if (resolver.canResolve(task))
            {
                resolver.resolveInputs(task, inputCtx);
            }
        }

        // 5. Retrieve upstream artifacts into workspace (only when engine owns artifact I/O)
        if (manageArtifacts && task.inputs.upstreamArtifacts.length > 0)
        {
            if (m_artifactStorage is null)
            {
                result.status = TaskStatus.failed;
                result.errorMessage = "ArtifactStorage is null but task requires upstream artifacts";
                if (m_stateRepo !is null)
                {
                    m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
                }
                sw.stop();
                result.durationMs = sw.peek.total!"msecs";
                return result;
            }

            import confector.core.zip_packager : ZipPackager;
            import std.array : Appender;

            foreach (refArt; task.inputs.upstreamArtifacts)
            {
                string artId = refArt.effectiveArtifactId;
                // Empty destination means unpack into workspace root
                string targetLocal = refArt.destination.length > 0
                    ? buildPath(effectiveWorkingDir, refArt.destination)
                    : effectiveWorkingDir;

                string upFp;
                if (upstreamFingerprints !is null && refArt.taskId in upstreamFingerprints)
                {
                    upFp = upstreamFingerprints[refArt.taskId];
                }
                if (upFp.length == 0 && m_stateRepo !is null)
                {
                    TaskExecutionRecord depRec;
                    if (m_stateRepo.getTaskExecution(buildId, refArt.taskId, depRec) && depRec.fingerprint.length > 0)
                    {
                        upFp = depRec.fingerprint;
                    }
                }

                if (upFp.length == 0 || !m_artifactStorage.artifactExists(upFp, artId))
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format(
                        "Missing upstream artifact '%s' from task '%s' (fingerprint: %s)",
                        artId, refArt.taskId, upFp.length > 0 ? upFp : "<unknown>");
                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
                        m_stateRepo.appendBuildLog(buildId, format("[%s] Error: %s", task.id, result.errorMessage));
                    }
                    if (logCallback !is null)
                    {
                        logCallback(format("[confector] Task '%s' failed: %s", task.id, result.errorMessage));
                    }
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                try
                {
                    Appender!(ubyte[]) zipBuf;
                    m_artifactStorage.retrieveArtifactStream(upFp, artId, (const(ubyte)[] chunk) {
                        zipBuf.put(chunk);
                    });
                    ZipPackager.unpack(zipBuf.data, targetLocal);
                    if (logCallback !is null)
                    {
                        auto fpPreview = upFp.length >= 8 ? upFp[0 .. 8] : upFp;
                        logCallback(format("[confector] Unpacked upstream artifact '%s' (fp: %s) to '%s'", artId, fpPreview, targetLocal));
                    }
                }
                catch (Exception e)
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format("Failed unpacking upstream artifact '%s' from task '%s': %s", artId, refArt.taskId, e.msg);
                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
                    }
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }
            }
        }

        // 6. Log capture collector
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

        // 7. Execute task build steps or fallback script
        int taskExitCode = 0;
        bool taskSuccess = true;
        string taskErrorMessage;

        if (task.steps.length > 0)
        {
            StepExecutionContext stepCtx;
            stepCtx.buildId = buildId;
            stepCtx.taskId = task.id;
            stepCtx.workspaceDir = workspaceDir;
            stepCtx.workingDirectory = effectiveWorkingDir;
            stepCtx.artifactStorage = m_artifactStorage;
            stepCtx.logCallback = combinedLogger;
            foreach (k, v; task.environment) stepCtx.environment[k] = v;
            foreach (k, v; task.inputs.parameters) stepCtx.taskParameters[k] = v;

            import std.algorithm.searching : canFind;
            import std.json : JSONType;
            string[] effectiveAllowedRepos;
            string[string] effectiveRepoMap;
            if (repositoryMap !is null)
            {
                foreach (k, v; repositoryMap)
                {
                    effectiveRepoMap[k] = v;
                    if (!effectiveAllowedRepos.canFind(k)) effectiveAllowedRepos ~= k;
                    if (!effectiveAllowedRepos.canFind(v)) effectiveAllowedRepos ~= v;
                }
            }
            if (allowedRepositories !is null)
            {
                foreach (r; allowedRepositories)
                {
                    if (!effectiveAllowedRepos.canFind(r)) effectiveAllowedRepos ~= r;
                    if (r in effectiveRepoMap && !effectiveAllowedRepos.canFind(effectiveRepoMap[r]))
                    {
                        effectiveAllowedRepos ~= effectiveRepoMap[r];
                    }
                }
            }
            foreach (r; task.inputs.repositories)
            {
                if (!effectiveAllowedRepos.canFind(r)) effectiveAllowedRepos ~= r;
                if (r in effectiveRepoMap && !effectiveAllowedRepos.canFind(effectiveRepoMap[r]))
                {
                    effectiveAllowedRepos ~= effectiveRepoMap[r];
                }
            }
            if (task.hasCustomComponent("git_source"))
            {
                auto comp = task.getCustomComponent("git_source");
                if (comp.type == JSONType.object && "url" in comp)
                {
                    string u = comp["url"].str;
                    if (!effectiveAllowedRepos.canFind(u)) effectiveAllowedRepos ~= u;
                }
            }
            stepCtx.allowedRepositories = effectiveAllowedRepos;
            stepCtx.repositoryMap = effectiveRepoMap;

            foreach (size_t stepIdx, ref const(BuildStep) step; task.steps)
            {
                string stepLabel = step.name.length > 0 ? step.name : format("Step %d (%s)", stepIdx + 1, step.type);
                combinedLogger(format("[confector] Running build step [%d/%d]: %s", stepIdx + 1, task.steps.length, stepLabel));

                auto stepSystem = PluginRegistry.instance.findStepSystem(step);
                if (stepSystem is null)
                {
                    taskSuccess = false;
                    taskExitCode = 1;
                    taskErrorMessage = format("No plugin registered to handle build step type '%s' (step: '%s')", step.type, stepLabel);
                    combinedLogger(format("[confector] Error: %s", taskErrorMessage));
                    break;
                }

                auto stepResult = stepSystem.executeStep(step, stepCtx);
                if (!stepResult.success)
                {
                    taskSuccess = false;
                    taskExitCode = stepResult.exitCode != 0 ? stepResult.exitCode : 1;
                    taskErrorMessage = stepResult.errorMessage.length > 0
                        ? stepResult.errorMessage
                        : format("Build step '%s' failed with exit code %d", stepLabel, taskExitCode);
                    combinedLogger(format("[confector] Build step '%s' failed: %s", stepLabel, taskErrorMessage));
                    break;
                }
            }
        }
        else
        {
            // Fallback script execution via TaskExecutionSystem or TaskRunner
            auto execSystem = PluginRegistry.instance.findExecutionSystem(task);
            TaskRunner fallbackRunner = null;
            if (execSystem is null)
            {
                auto runners = PluginRegistry.instance.getPluginsOfType!TaskRunner();
                if (runners.length == 0)
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = "No TaskExecutionSystem or TaskRunner plugin registered in PluginRegistry";
                    if (m_stateRepo !is null)
                    {
                        m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
                    }
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }
                fallbackRunner = runners[0];
            }

            ExecutionRequest req;
            req.command = task.script;
            req.workingDirectory = effectiveWorkingDir;
            foreach (k, v; task.environment)
            {
                req.environmentVariables[k] = v;
            }
            req.timeoutSeconds = task.timeoutSeconds;

            ExecutionResult execResult;
            if (execSystem !is null)
            {
                execResult = execSystem.executeTask(task, req, combinedLogger);
            }
            else
            {
                execResult = fallbackRunner.execute(req, combinedLogger);
            }

            taskExitCode = execResult.exitCode;
            taskSuccess = execResult.success;
            taskErrorMessage = execResult.errorMessage;
        }

        result.exitCode = taskExitCode;
        result.logs = capturedLogs;

        if (!taskSuccess)
        {
            result.status = TaskStatus.failed;
            result.errorMessage = taskErrorMessage.length > 0
                ? taskErrorMessage
                : format("Task execution exited with code %d", taskExitCode);

            if (m_stateRepo !is null)
            {
                m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
            }
            sw.stop();
            result.durationMs = sw.peek.total!"msecs";
            return result;
        }

        // 8. Capture and store declared output artifacts (only when engine owns artifact I/O)
        ArtifactMetadata[] producedArtifacts;
        if (manageArtifacts)
        {
            bool publishedViaSystem = false;
            foreach (pubSys; PluginRegistry.instance.getArtifactPublishers())
            {
                if (pubSys.canPublish(task))
                {
                    auto metaList = pubSys.publishArtifacts(task, buildId, effectiveWorkingDir, m_artifactStorage, logCallback);
                    producedArtifacts ~= metaList;
                    publishedViaSystem = true;
                }
            }

            if (!publishedViaSystem && m_artifactStorage !is null)
            {
                import confector.core.zip_packager : ZipPackager;
                import std.datetime.systime : Clock;

                foreach (artDecl; task.outputs.artifacts)
                {
                    string artId = artDecl.effectiveId;
                    string artPath = artDecl.effectivePath;

                    if (fingerprint.length == 0 || fingerprint == "unknown")
                    {
                        continue;
                    }

                    try
                    {
                        m_artifactStorage.storeArtifactStream(fingerprint, artId, (void delegate(const(ubyte)[]) sink) {
                            ZipPackager.pack(effectiveWorkingDir, artPath, sink);
                        });

                        ArtifactMetadata meta;
                        meta.artifactId = artId;
                        meta.taskFingerprint = fingerprint;
                        meta.buildId = buildId;
                        meta.taskId = task.id;
                        meta.filePath = artPath;
                        meta.storageBackend = "local";
                        meta.storageUri = format(".confector/artifacts/%s/%s.zip", fingerprint, artId);
                        meta.createdAt = Clock.currTime.toISOString();
                        producedArtifacts ~= meta;

                        if (logCallback !is null)
                        {
                            logCallback(format("[confector] Stored output artifact '%s' (ID: %s, fp: %s)", artPath, artId, fingerprint[0 .. (fingerprint.length >= 8 ? 8 : fingerprint.length)]));
                        }
                    }
                    catch (Exception e)
                    {
                        result.status = TaskStatus.failed;
                        result.errorMessage = format("Failed packaging output artifact '%s' (%s): %s", artId, artPath, e.msg);
                        if (m_stateRepo !is null)
                        {
                            m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.failed, result.errorMessage);
                        }
                        sw.stop();
                        result.durationMs = sw.peek.total!"msecs";
                        return result;
                    }
                }
            }

            // Save cached fingerprint only when this layer produced/owns artifacts
            if (m_stateRepo !is null && fingerprint.length > 0 && fingerprint != "unknown")
            {
                m_stateRepo.saveCachedFingerprint(task.id, fingerprint, producedArtifacts);
            }
        }

        result.producedArtifacts = producedArtifacts;

        // 9. Mark succeeded
        if (m_stateRepo !is null)
        {
            m_stateRepo.setTaskStatus(buildId, task.id, TaskStatus.succeeded);
        }

        result.status = TaskStatus.succeeded;
        sw.stop();
        result.durationMs = sw.peek.total!"msecs";
        logInfo("[engine] executeTask completed for task '%s' (build '%s', status: '%s', duration: %d ms, artifacts: %d)", task.id, buildId, result.status, result.durationMs, producedArtifacts.length);
        return result;
    }

    /**
     * Executes a task graph or subgraph slice according to an ExecutionPlan.
     */
    GraphExecutionResult executeTasks(
        string buildId,
        in TaskNode[] tasks,
        in ExecutionPlan plan,
        string workspaceDir,
        string projectId = null,
        string projectName = null,
        string targetTaskId = null,
        bool force = false,
        LogDelegate logCallback = null,
        in string[string] repositoryMap = null
    )
    {
        import std.datetime.systime : Clock;

        auto totalSw = StopWatch(AutoStart.yes);
        GraphExecutionResult graphResult;
        graphResult.buildId = buildId;
        graphResult.success = true;

        BuildRecord buildRec;
        buildRec.buildId = buildId;
        buildRec.projectId = projectId;
        buildRec.projectName = projectName.length > 0 ? projectName : "default";
        buildRec.targetTaskId = targetTaskId;
        buildRec.status = "running";
        buildRec.workspaceDir = workspaceDir;
        buildRec.startedAt = Clock.currTime.toISOString();
        if (m_stateRepo !is null)
        {
            m_stateRepo.recordBuild(buildRec);
            m_stateRepo.appendBuildLog(buildId, format("[engine] Starting build %s with %d tasks", buildId, plan.orderedTaskIds.length));
        }

        string[string] effectiveRepoMap;
        if (repositoryMap !is null)
        {
            foreach (k, v; repositoryMap) effectiveRepoMap[k] = v;
        }
        if (m_stateRepo !is null)
        {
            try
            {
                foreach (repoRec; m_stateRepo.listRepositories())
                {
                    if (repoRec.name.length > 0 && repoRec.address.length > 0)
                    {
                        effectiveRepoMap[repoRec.name] = repoRec.address;
                    }
                }
            }
            catch (Exception) {}
        }

        const(TaskNode)*[string] taskMap;
        foreach (ref task; tasks)
        {
            taskMap[task.id] = &task;
        }

        TaskGraph taskGraph = null;
        try { taskGraph = new TaskGraph(tasks); } catch (Exception) {}

        // Upstream taskId -> fingerprint map for content-addressed artifact lookup
        string[string] currentUpstreamFingerprints;
        bool allCached = true;

        foreach (taskId; plan.orderedTaskIds)
        {
            graphResult.executedOrder ~= taskId;
            auto pTask = taskId in taskMap;
            if (pTask is null)
            {
                graphResult.success = false;
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

            import std.algorithm.searching : canFind;
            string[] taskAllowedRepos;
            if (taskGraph !is null)
            {
                try
                {
                    auto ancestors = taskGraph.resolveSubgraph(taskId);
                    foreach (ancId; ancestors)
                    {
                        auto ancTask = taskGraph.getTask(ancId);
                        foreach (r; ancTask.inputs.repositories)
                        {
                            if (!taskAllowedRepos.canFind(r)) taskAllowedRepos ~= r;
                            if (r in effectiveRepoMap && !taskAllowedRepos.canFind(effectiveRepoMap[r]))
                            {
                                taskAllowedRepos ~= effectiveRepoMap[r];
                            }
                        }
                        if (ancTask.hasCustomComponent("git_source"))
                        {
                            import std.json : JSONType;
                            auto comp = ancTask.getCustomComponent("git_source");
                            if (comp.type == JSONType.object && "url" in comp)
                            {
                                string u = comp["url"].str;
                                if (!taskAllowedRepos.canFind(u)) taskAllowedRepos ~= u;
                            }
                        }
                    }
                }
                catch (Exception) {}
            }

            // Prefer graph-computed fingerprint when available so engine and coordinator agree
            string graphFp;
            if (taskGraph !is null)
            {
                try
                {
                    graphFp = taskGraph.getFingerprint(taskId);
                }
                catch (Exception) {}
            }

            auto taskRes = executeTask(
                buildId,
                **pTask,
                workspaceDir,
                currentUpstreamFingerprints,
                force ? true : false,
                logCallback,
                taskAllowedRepos,
                effectiveRepoMap,
                graphFp,
                true // manageArtifacts: direct engine path owns packaging
            );

            graphResult.taskResults[taskId] = taskRes;

            if (taskRes.status != TaskStatus.cached)
            {
                allCached = false;
            }

            // Track upstream task fingerprints for downstream content-addressed lookup
            if (taskRes.fingerprint.length > 0 && taskRes.fingerprint != "unknown")
            {
                currentUpstreamFingerprints[taskId] = taskRes.fingerprint;
            }

            if (taskRes.status == TaskStatus.failed)
            {
                graphResult.success = false;
                if (m_stateRepo !is null)
                {
                    m_stateRepo.appendBuildLog(buildId, format("[engine] Build failed at task '%s': %s", taskId, taskRes.errorMessage));
                }
                break;
            }
        }

        totalSw.stop();
        buildRec.finishedAt = Clock.currTime.toISOString();
        buildRec.durationMs = totalSw.peek.total!"msecs";
        buildRec.executedTasks = graphResult.executedOrder;

        if (!graphResult.success)
        {
            buildRec.status = "failed";
            buildRec.errorMessage = "One or more tasks failed execution";
        }
        else if (allCached && graphResult.executedOrder.length > 0)
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
            m_stateRepo.appendBuildLog(buildId, format("[engine] Build completed with status '%s' in %d ms", buildRec.status, buildRec.durationMs));
        }

        return graphResult;
    }
}

unittest
{
    import std.file : rmdirRecurse, mkdirRecurse, write;
    import std.process : pipeShell, Redirect, Config, wait;

    class MockEnginePlugin : Plugin, TaskRunner, TaskExecutionSystem, BuildStepSystem
    {
        @property string name() const { return "mock-engine-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock engine runner plugin"; }
        @property PluginCategory category() const { return PluginCategory.runner; }
        @property string runnerType() const { return "process"; }
        @property string systemName() const { return "mock-engine-system"; }
        @property string stepType() const { return "process"; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecute(in ExecutionRequest request) const { return true; }
        bool canExecute(in TaskNode task) const { return true; }

        ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
        {
            ExecutionResult res;
            try
            {
                auto pipe = pipeShell(request.command, Redirect.stdout | Redirect.stderrToStdout, request.environmentVariables.length > 0 ? request.environmentVariables : null, Config.retainStderr, request.workingDirectory);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (logCallback !is null) logCallback(line);
                }
                res.exitCode = wait(pipe.pid);
                res.success = (res.exitCode == 0);
            }
            catch (Exception e)
            {
                res.exitCode = -1;
                res.success = false;
                res.errorMessage = e.msg;
            }
            return res;
        }

        ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null)
        {
            ExecutionResult res;
            try
            {
                auto pipe = pipeShell(task.script, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr, request.workingDirectory);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (logCallback !is null) logCallback(line);
                }
                res.exitCode = wait(pipe.pid);
                res.success = (res.exitCode == 0);
            }
            catch (Exception e)
            {
                res.exitCode = -1;
                res.success = false;
                res.errorMessage = e.msg;
            }
            return res;
        }

        bool canExecuteStep(in BuildStep step) const
        {
            return step.type == "process" || step.type == "bash" || step.type == "powershell" || step.type == "sh" || step.type == "pwsh";
        }

        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            import std.process : pipeProcess, ProcessPipes;
            StepExecutionResult res;
            string cmd = step.script.length > 0 ? step.script : step.command;
            if (cmd.length == 0)
            {
                res.exitCode = 1;
                res.errorMessage = "Empty command";
                return res;
            }
            try
            {
                ProcessPipes pipe;
                if (step.type == "powershell" || step.type == "pwsh")
                {
                    version(Windows)
                    {
                        string[] args = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", cmd];
                        pipe = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr, context.workingDirectory);
                    }
                    else
                    {
                        string[] args = ["pwsh", "-NoProfile", "-NonInteractive", "-Command", cmd];
                        pipe = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr, context.workingDirectory);
                    }
                }
                else
                {
                    pipe = pipeShell(cmd, Redirect.stdout | Redirect.stderrToStdout, context.environment.length > 0 ? context.environment : null, Config.retainStderr, context.workingDirectory);
                }

                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (context.logCallback !is null) context.logCallback(line);
                }
                res.exitCode = wait(pipe.pid);
                res.success = (res.exitCode == 0);
                if (!res.success) res.errorMessage = format("Step exited with code %d", res.exitCode);
            }
            catch (Exception e)
            {
                res.exitCode = -1;
                res.success = false;
                res.errorMessage = e.msg;
            }
            return res;
        }
    }

    string testDir = "test_engine_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Register decoupled mock plugin
    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockEnginePlugin());

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
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "output.txt")];

    // First execution: should execute and succeed
    auto res1 = engine.executeTask("build_1", node1, testDir);
    assert(res1.status == TaskStatus.succeeded);
    assert(res1.producedArtifacts.length == 1);
    assert(res1.fingerprint.length > 0 && res1.fingerprint != "unknown");
    assert(storage.artifactExists(res1.fingerprint, "output.txt"));
    assert(res1.producedArtifacts[0].taskFingerprint == res1.fingerprint);
    assert(res1.producedArtifacts[0].artifactId == "output.txt");

    // Second execution (same buildId or new buildId): should be cached
    auto res2 = engine.executeTask("build_2", node1, testDir);
    assert(res2.status == TaskStatus.cached);
    assert(res2.producedArtifacts.length == 1);
    assert(res2.fingerprint == res1.fingerprint);

    // Forced execution: should re-run
    auto res3 = engine.executeTask("build_3", node1, testDir, null, true);
    assert(res3.status == TaskStatus.succeeded);
    assert(storage.artifactExists(res3.fingerprint, "output.txt"));

    // Multi-node task graph test with artifact staging
    TaskNode node2;
    node2.id = "step2";
    node2.name = "Step 2";
    node2.dependsOn = ["step1"];
    node2.inputs.upstreamArtifacts = [UpstreamArtifactRef("step1", "output.txt")];
    version(Windows)
    {
        node2.script = "cmd /c \"type output.txt > result.txt\"";
    }
    else
    {
        node2.script = "cat output.txt > result.txt";
    }
    node2.outputs.artifacts = [OutputArtifactDecl("result.txt", "result.txt")];

    TaskNode[] taskList = [node1, node2];

    ExecutionPlan plan;
    plan.orderedTaskIds = ["step1", "step2"];

    // Execute full graph in a fresh workspace so step2 must retrieve from stream storage
    string graphWs = buildPath(testDir, "graph_ws");
    mkdirRecurse(graphWs);
    auto graphRes1 = engine.executeTasks("build_graph_1", taskList, plan, graphWs, "proj-1", "My Project");
    assert(graphRes1.success);
    assert(graphRes1.executedOrder == ["step1", "step2"]);
    assert(graphRes1.taskResults["step2"].status == TaskStatus.succeeded);
    auto step1Fp = graphRes1.taskResults["step1"].fingerprint;
    auto step2Fp = graphRes1.taskResults["step2"].fingerprint;
    assert(storage.artifactExists(step1Fp, "output.txt"));
    assert(storage.artifactExists(step2Fp, "result.txt"));

    // Second execution without changes: all nodes should be cached
    auto graphRes2 = engine.executeTasks("build_graph_2", taskList, plan, graphWs, "proj-1", "My Project");
    assert(graphRes2.success);
    assert(graphRes2.taskResults["step1"].status == TaskStatus.cached);
    assert(graphRes2.taskResults["step2"].status == TaskStatus.cached);
    assert(graphRes2.taskResults["step1"].fingerprint == step1Fp);
    assert(graphRes2.taskResults["step2"].fingerprint == step2Fp);

    // Missing upstream artifact failure test
    TaskNode nodeBad;
    nodeBad.id = "bad_step";
    nodeBad.inputs.upstreamArtifacts = [UpstreamArtifactRef("non_existent_task", "missing.txt")];
    nodeBad.script = "cmd /c \"echo should not run\"";
    auto badRes = engine.executeTask("build_bad", nodeBad, testDir);
    assert(badRes.status == TaskStatus.failed);
    assert(badRes.errorMessage.length > 0);

    // Multi-step ordered execution test
    TaskNode stepTask;
    stepTask.id = "multi_step_task";
    stepTask.name = "Ordered Steps Task";
    version(Windows)
    {
        stepTask.steps = [
            BuildStep("Step 1", "process", null, "cmd /c \"echo first_step > seq.txt\""),
            BuildStep("Step 2", "process", null, "cmd /c \"echo second_step >> seq.txt\"")
        ];
    }
    else
    {
        stepTask.steps = [
            BuildStep("Step 1", "process", null, "echo first_step > seq.txt"),
            BuildStep("Step 2", "process", null, "echo second_step >> seq.txt")
        ];
    }
    stepTask.outputs.artifacts = [OutputArtifactDecl("seq.txt", "seq.txt")];

    auto stepRes = engine.executeTask("build_steps_1", stepTask, testDir);
    assert(stepRes.status == TaskStatus.succeeded);
    assert(stepRes.producedArtifacts.length == 1);
    assert(storage.artifactExists(stepRes.fingerprint, "seq.txt"));

    // Step failure halting execution test
    TaskNode failingStepTask;
    failingStepTask.id = "failing_step_task";
    version(Windows)
    {
        failingStepTask.steps = [
            BuildStep("Fail Step", "process", null, "cmd /c \"exit 1\""),
            BuildStep("Never Run Step", "process", null, "cmd /c \"echo should_not_exist > never.txt\"")
        ];
    }
    else
    {
        failingStepTask.steps = [
            BuildStep("Fail Step", "process", null, "exit 1"),
            BuildStep("Never Run Step", "process", null, "echo should_not_exist > never.txt")
        ];
    }
    auto failStepRes = engine.executeTask("build_steps_fail", failingStepTask, testDir);
    assert(failStepRes.status == TaskStatus.failed);
    assert(!exists(buildPath(testDir, "never.txt")));

    // Unknown step system failure test
    TaskNode unknownStepTask;
    unknownStepTask.id = "unknown_step_task";
    unknownStepTask.steps = [
        BuildStep("Unknown Step", "non_existent_plugin_step")
    ];
    auto unknownStepRes = engine.executeTask("build_unknown_step", unknownStepTask, testDir);
    assert(unknownStepRes.status == TaskStatus.failed);
    assert(unknownStepRes.errorMessage.length > 0);

    // Bash and PowerShell step plugin execution test
    TaskNode scriptPluginTask;
    scriptPluginTask.id = "script_plugins_task";
    version(Windows)
    {
        scriptPluginTask.steps = [
            BuildStep("Bash Step", "bash", null, "echo bash_output > bash.txt"),
            BuildStep("PowerShell Step", "powershell", null, "Write-Output 'ps_output' | Out-File -FilePath ps.txt -Encoding ascii")
        ];
    }
    else
    {
        scriptPluginTask.steps = [
            BuildStep("Bash Step", "bash", null, "echo bash_output > bash.txt")
        ];
    }
    scriptPluginTask.outputs.artifacts = [OutputArtifactDecl("bash.txt", "bash.txt")];

    auto scriptPluginRes = engine.executeTask("build_script_plugins", scriptPluginTask, testDir);
    assert(scriptPluginRes.status == TaskStatus.succeeded);
    assert(exists(buildPath(testDir, "bash.txt")));
    version(Windows)
    {
        assert(exists(buildPath(testDir, "ps.txt")));
    }

    // Compute Provider & Persistence Integration Test
    import confector.core.executor : WorkerRecord, ComputeProvider, ComputeInstance;
    import controller.executor_controller : executorRouter;
    import std.json : JSONValue;

    class MockEngineComputeProvider : Plugin, ComputeProvider
    {
        @property string name() const { return "mock-local-executor-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock local executor plugin"; }
        @property PluginCategory category() const { return PluginCategory.worker; }
        @property string providerType() const { return "local"; }
        @property string displayName() const { return "Local Process Executor"; }
        @property string[] supportedStepTypes() const { return ["process", "bash", "powershell", "git"]; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        JSONValue defaultConfig() const
        {
            JSONValue c = JSONValue(["maxConcurrency": JSONValue(4), "workspaceDir": JSONValue(".confector/workspaces"), "defaultShell": JSONValue("powershell")]);
            return c;
        }

        string[] validateConfig(in JSONValue config) const { return null; }
        string renderConfigFormHtml(in JSONValue currentConfig) const { return "<div>Local Config</div>"; }

        ComputeInstance createExecutor(in WorkerRecord record)
        {
            class MockComputeInstance : ComputeInstance
            {
                WorkerRecord m_rec;
                this(in WorkerRecord rec) { m_rec = cast()rec; }
                @property string id() const { return m_rec.id; }
                @property string providerType() const { return m_rec.providerType; }
                @property bool isEnabled() const { return m_rec.enabled; }
                @property string[] supportedStepTypes() const { return ["process", "bash", "powershell", "git"]; }

                ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
                {
                    ExecutionResult res;
                    if (!m_rec.enabled)
                    {
                        res.exitCode = -1;
                        res.success = false;
                        res.errorMessage = "Executor is disabled";
                        return res;
                    }
                    res.exitCode = 0;
                    res.success = true;
                    res.outputLines = ["Mock execution output"];
                    if (logCallback !is null) logCallback("Mock execution output");
                    return res;
                }
            }
            return new MockComputeInstance(record);
        }
    }

    auto localExecPlugin = new MockEngineComputeProvider();
    PluginRegistry.instance.registerPlugin(localExecPlugin);

    auto providers = PluginRegistry.instance.getComputeProviders();
    assert(providers.length >= 1);
    auto foundLocal = PluginRegistry.instance.getComputeProvider("local");
    assert(foundLocal !is null);
    assert(foundLocal.supportedStepTypes.length >= 4);

    // Verify sub-template generation
    auto localDefConfig = foundLocal.defaultConfig();
    string formHtml = foundLocal.renderConfigFormHtml(localDefConfig);
    assert(formHtml.length > 0);

    // Verify newly instantiated executor is disabled by default
    WorkerRecord execRecord;
    execRecord.id = "exec_integ_1";
    execRecord.name = "Integration Test Runner";
    execRecord.providerType = "local";
    execRecord.description = "Test runner instance";
    execRecord.enabled = false;
    execRecord.configuration = localDefConfig;

    stateRepo.saveExecutor(execRecord);
    WorkerRecord fetchedExec;
    assert(stateRepo.getExecutor("exec_integ_1", fetchedExec));
    assert(!fetchedExec.enabled);

    auto taskExec = foundLocal.createExecutor(fetchedExec);
    assert(!taskExec.isEnabled);

    ExecutionRequest execReq;
    execReq.command = "echo local_integration_exec";
    auto disabledExecRes = taskExec.execute(execReq);
    assert(!disabledExecRes.success);
    assert(disabledExecRes.exitCode != 0);

    // Toggle enabled and execute
    fetchedExec.enabled = true;
    stateRepo.saveExecutor(fetchedExec);
    auto enabledTaskExec = foundLocal.createExecutor(fetchedExec);
    assert(enabledTaskExec.isEnabled);
    auto enabledExecRes = enabledTaskExec.execute(execReq);
    assert(enabledExecRes.success);
    assert(enabledExecRes.exitCode == 0);

    // Test controller router creation
    auto execRouter = executorRouter(stateRepo, PluginRegistry.instance);
    assert(execRouter !is null);
}
