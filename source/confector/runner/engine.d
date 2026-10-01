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

        // 5. Retrieve any upstream artifacts required into workspace
        if (task.inputs.upstreamArtifacts.length > 0)
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

            foreach (refArt; task.inputs.upstreamArtifacts)
            {
                if (!m_artifactStorage.artifactExists(buildId, refArt.taskId, refArt.name))
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format("Missing upstream artifact '%s' from task '%s'", refArt.name, refArt.taskId);
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

                string targetLocal = buildPath(effectiveWorkingDir, refArt.name);
                m_artifactStorage.retrieveArtifact(buildId, refArt.taskId, refArt.name, targetLocal);
                if (logCallback !is null)
                {
                    logCallback(format("[confector] Staged upstream artifact '%s' from task '%s' to '%s'", refArt.name, refArt.taskId, targetLocal));
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

        // 8. Capture and store declared output artifacts via ArtifactPublishingSystem or default storage
        ArtifactMetadata[] producedArtifacts;
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
            foreach (artDecl; task.outputs.artifacts)
            {
                string localArtifactPath = buildPath(effectiveWorkingDir, artDecl.path);
                if (exists(localArtifactPath) && isFile(localArtifactPath))
                {
                    auto meta = m_artifactStorage.storeArtifact(buildId, task.id, localArtifactPath, artDecl.type);
                    producedArtifacts ~= meta;
                    if (logCallback !is null)
                    {
                        logCallback(format("[confector] Stored output artifact '%s' (SHA256: %s)", artDecl.path, meta.sha256[0 .. 8]));
                    }
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
        LogDelegate logCallback = null
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

        const(TaskNode)*[string] taskMap;
        foreach (ref task; tasks)
        {
            taskMap[task.id] = &task;
        }

        string[string] currentArtifactHashes;
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

            auto taskRes = executeTask(
                buildId,
                **pTask,
                workspaceDir,
                currentArtifactHashes,
                force ? true : false,
                logCallback
            );

            graphResult.taskResults[taskId] = taskRes;

            if (taskRes.status != TaskStatus.cached)
            {
                allCached = false;
            }

            // Track produced artifact hashes for downstream tasks
            foreach (art; taskRes.producedArtifacts)
            {
                import std.path : baseName;
                currentArtifactHashes[art.filePath] = art.sha256;
                currentArtifactHashes[baseName(art.filePath)] = art.sha256;
                currentArtifactHashes[format("%s:%s", art.taskId, baseName(art.filePath))] = art.sha256;
                currentArtifactHashes[format("%s:%s", art.taskId, art.filePath)] = art.sha256;
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
    import confector.plugins.process_runner;
    import confector.plugins.bash;
    import confector.plugins.powershell;
    import std.file : rmdirRecurse, mkdirRecurse, write;

    string testDir = "test_engine_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Register plugins
    PluginRegistry.instance.registerPlugin(new ProcessTaskRunnerPlugin());
    PluginRegistry.instance.registerPlugin(new BashPlugin());
    PluginRegistry.instance.registerPlugin(new PowerShellPlugin());

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
    node2.outputs.artifacts = [OutputArtifactDecl("result.txt", "file")];

    TaskNode[] taskList = [node1, node2];

    ExecutionPlan plan;
    plan.orderedTaskIds = ["step1", "step2"];

    // Execute full graph
    auto graphRes1 = engine.executeTasks("build_graph_1", taskList, plan, testDir, "proj-1", "My Project");
    assert(graphRes1.success);
    assert(graphRes1.executedOrder == ["step1", "step2"]);
    assert(graphRes1.taskResults["step2"].status == TaskStatus.succeeded);
    assert(storage.artifactExists("build_graph_1", "step2", "result.txt"));

    // Second execution without changes: all nodes should be cached
    auto graphRes2 = engine.executeTasks("build_graph_2", taskList, plan, testDir, "proj-1", "My Project");
    assert(graphRes2.success);
    assert(graphRes2.taskResults["step1"].status == TaskStatus.cached);
    assert(graphRes2.taskResults["step2"].status == TaskStatus.cached);

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
    stepTask.outputs.artifacts = [OutputArtifactDecl("seq.txt", "file")];

    auto stepRes = engine.executeTask("build_steps_1", stepTask, testDir);
    assert(stepRes.status == TaskStatus.succeeded);
    assert(stepRes.producedArtifacts.length == 1);
    assert(storage.artifactExists("build_steps_1", "multi_step_task", "seq.txt"));

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
    scriptPluginTask.outputs.artifacts = [OutputArtifactDecl("bash.txt", "file")];

    auto scriptPluginRes = engine.executeTask("build_script_plugins", scriptPluginTask, testDir);
    assert(scriptPluginRes.status == TaskStatus.succeeded);
    assert(exists(buildPath(testDir, "bash.txt")));
    version(Windows)
    {
        assert(exists(buildPath(testDir, "ps.txt")));
    }

    // Executor Provider & Persistence Integration Test
    import confector.plugins.local_executor : LocalExecutorPlugin;
    import confector.core.executor : ExecutorRecord, ExecutorProvider, TaskExecutor;
    import controller.executor_controller : executorRouter;

    auto localExecPlugin = new LocalExecutorPlugin();
    PluginRegistry.instance.registerPlugin(localExecPlugin);

    auto providers = PluginRegistry.instance.getExecutorProviders();
    assert(providers.length >= 1);
    auto foundLocal = PluginRegistry.instance.getExecutorProvider("local");
    assert(foundLocal !is null);
    assert(foundLocal.supportedStepTypes.length >= 4);

    // Verify sub-template generation
    auto localDefConfig = foundLocal.defaultConfig();
    string formHtml = foundLocal.renderConfigFormHtml(localDefConfig);
    assert(formHtml.length > 0);

    // Verify newly instantiated executor is disabled by default
    ExecutorRecord execRecord;
    execRecord.id = "exec_integ_1";
    execRecord.name = "Integration Test Runner";
    execRecord.providerType = "local";
    execRecord.description = "Test runner instance";
    execRecord.enabled = false;
    execRecord.configuration = localDefConfig;

    stateRepo.saveExecutor(execRecord);
    ExecutorRecord fetchedExec;
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
