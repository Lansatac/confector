module confector.runner_core.engine;

import confector.core.model;
import confector.core.fingerprinter;
import confector.core.executor;
import confector.core.system;
import confector.core.plugin;
import confector.core.storage;
import confector.runner_core.logging;
import confector.runner_core.artifacts;

import std.file : exists, isFile;
import std.path : buildPath, isAbsolute;
import std.format : format;
import std.json : JSONType;
import std.algorithm.searching : canFind;
import std.datetime.stopwatch : StopWatch, AutoStart;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

/**
 * Result of a task execution.
 */
struct GraphExecutionResult
{
    string buildId;
    bool success;
    TaskExecutionResult[string] taskResults;
    string[] executedOrder;
}

/**
 * Core stateless execution engine capable of executing single nodes.
 */
class TaskEngine
{
    private ArtifactStorage m_artifactStorage;

    this(ArtifactStorage artifactStorage = null)
    {
        m_artifactStorage = artifactStorage;
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }
    @property void artifactStorage(ArtifactStorage storage) { m_artifactStorage = storage; }

    /**
     * Executes a single task node with fingerprint checking and optional artifact handling.
     *
     * Params:
     *   buildId = The build ID associated with this task.
     *   task = The task node definition to execute.
     *   workspaceDir = Workspace directory path where execution occurs.
     *   upstreamFingerprints = Map of upstream taskId -> task fingerprint (content-addressed).
     *   force = Whether to force execution regardless of caching.
     *   logCallback = Optional log callback receiving execution output lines.
     *   allowedRepositories = List of repository addresses/URLs permitted for checkout/fetch.
     *   repositoryMap = Mapping of logical repo names to physical URLs.
     *   precomputedFingerprint = When non-empty, used as authoritative node fingerprint.
     *   manageArtifacts = When true, engine stages upstream artifacts and packs outputs.
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

        // 1. Resolve input fingerprint (prefer precomputed value)
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

        // Effective working directory defaults to workspace directory
        string effectiveWorkingDir = workspaceDir;

        // 2. Input Resolution Systems pass
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

        // 3. Retrieve upstream artifacts into workspace (only when engine owns artifact I/O)
        if (manageArtifacts && task.inputs.upstreamArtifacts.length > 0)
        {
            if (m_artifactStorage is null)
            {
                result.status = TaskStatus.failed;
                result.errorMessage = "ArtifactStorage is null but task requires upstream artifacts";
                sw.stop();
                result.durationMs = sw.peek.total!"msecs";
                return result;
            }

            foreach (refArt; task.inputs.upstreamArtifacts)
            {
                string artId = refArt.effectiveArtifactId;
                string targetLocal = refArt.destination.length > 0
                    ? buildPath(effectiveWorkingDir, refArt.destination)
                    : effectiveWorkingDir;

                string upFp;
                if (upstreamFingerprints !is null && refArt.taskId in upstreamFingerprints)
                {
                    upFp = upstreamFingerprints[refArt.taskId];
                }

                if (upFp.length == 0 || !m_artifactStorage.artifactExists(upFp, artId))
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format(
                        "Upstream artifact '%s' from task '%s' (fingerprint '%s') not found in artifact storage",
                        artId, refArt.taskId, upFp
                    );
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                bool staged = ArtifactStager.stageUpstreamArtifact(m_artifactStorage, upFp, artId, targetLocal, refArt.sha256);
                if (!staged)
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format(
                        "Failed to extract upstream artifact '%s' from task '%s' into '%s' (checksum mismatch or corrupt archive)",
                        artId, refArt.taskId, targetLocal
                    );
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                if (logCallback !is null)
                {
                    logCallback(format("[confector] Staged upstream artifact '%s' (from task '%s') into '%s'", artId, refArt.taskId, targetLocal));
                }
            }
        }

        // 4. Execute Build Steps
        auto execLogger = new ExecutionLogger(logCallback);
        auto combinedLogger = execLogger.getLogDelegate();

        int taskExitCode = 0;
        bool taskSuccess = true;
        string taskErrorMessage = "";

        StepExecutionContext stepCtx;
        stepCtx.buildId = buildId;
        stepCtx.taskId = task.id;
        stepCtx.workspaceDir = workspaceDir;
        stepCtx.workingDirectory = effectiveWorkingDir;
        stepCtx.environment = task.environment.dup;
        stepCtx.taskParameters = task.inputs.parameters.dup;
        stepCtx.artifactStorage = m_artifactStorage;
        stepCtx.logCallback = combinedLogger;

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

        if (task.steps.length == 0 && task.script.length > 0)
        {
            import std.process : pipeShell, Redirect, Config, wait;
            combinedLogger(format("[confector] Running task script: %s", task.script));
            try
            {
                auto pipe = pipeShell(task.script, Redirect.stdout | Redirect.stderrToStdout, task.environment.length > 0 ? task.environment : null, Config.retainStderr, effectiveWorkingDir);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    combinedLogger(line);
                }
                taskExitCode = wait(pipe.pid);
                taskSuccess = (taskExitCode == 0);
                if (!taskSuccess)
                {
                    taskErrorMessage = format("Script execution failed with exit code %d", taskExitCode);
                    combinedLogger(format("[confector] %s", taskErrorMessage));
                }
            }
            catch (Exception e)
            {
                taskSuccess = false;
                taskExitCode = -1;
                taskErrorMessage = e.msg;
                combinedLogger(format("[confector] Error executing script: %s", e.msg));
            }
        }
        else
        {
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

        result.exitCode = taskExitCode;
        result.logs = execLogger.getLogs();

        if (!taskSuccess)
        {
            result.status = TaskStatus.failed;
            result.errorMessage = taskErrorMessage.length > 0 ? taskErrorMessage : format("Task execution failed with exit code %d", taskExitCode);
            sw.stop();
            result.durationMs = sw.peek.total!"msecs";
            return result;
        }

        // 5. Output Artifact Packaging
        ArtifactMetadata[] producedArtifacts;
        if (manageArtifacts && taskSuccess)
        {
            if (m_artifactStorage !is null && fingerprint.length > 0 && fingerprint != "unknown")
            {
                foreach (artDecl; task.outputs.artifacts)
                {
                    try
                    {
                        auto meta = ArtifactStager.packOutputArtifact(
                            m_artifactStorage, fingerprint, buildId, task.id, effectiveWorkingDir, artDecl
                        );
                        producedArtifacts ~= meta;
                    }
                    catch (Exception e)
                    {
                        result.status = TaskStatus.failed;
                        result.errorMessage = format("Failed to package output artifact '%s': %s", artDecl.effectiveId, e.msg);
                        sw.stop();
                        result.durationMs = sw.peek.total!"msecs";
                        return result;
                    }
                }
            }
        }

        result.producedArtifacts = producedArtifacts;
        result.status = TaskStatus.succeeded;
        sw.stop();
        result.durationMs = sw.peek.total!"msecs";
        logInfo("[engine] executeTask completed for task '%s' (build '%s', status: '%s', duration: %d ms, artifacts: %d)",
            task.id, buildId, result.status, result.durationMs, producedArtifacts.length);
        return result;
    }
}

unittest
{
    import std.file : exists, rmdirRecurse, mkdirRecurse, write;
    import std.path : buildPath;
    import std.process : pipeShell, Redirect, Config, wait;

    class MockStepRunner : Plugin, BuildStepSystem
    {
        @property string name() const pure nothrow @safe { return "mock_runner"; }
        @property string versionString() const pure nothrow @safe { return "1.0.0"; }
        @property string description() const pure nothrow @safe { return "Mock Step Runner"; }
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.runner; }
        @property string systemName() const pure nothrow @safe { return "mock-step-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecuteStep(in BuildStep step) const
        {
            return step.type == "process" || step.type == "mock";
        }

        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            string cmd = step.script.length > 0 ? step.script : step.command;
            try
            {
                auto pipe = pipeShell(cmd, Redirect.stdout | Redirect.stderrToStdout, context.environment.length > 0 ? context.environment : null, Config.retainStderr, context.workingDirectory);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (context.logCallback !is null) context.logCallback(line);
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
    }

    string testDir = "test_runner_core_engine_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockStepRunner());

    auto storage = new LocalArtifactStorage(buildPath(testDir, "storage"));
    auto engine = new TaskEngine(storage);

    TaskNode node1;
    node1.id = "step1";
    node1.name = "Step 1";
    version(Windows)
    {
        node1.steps = [BuildStep("Write Output", "process", null, "cmd /c \"echo hello > output.txt\"")];
    }
    else
    {
        node1.steps = [BuildStep("Write Output", "process", null, "echo hello > output.txt")];
    }
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "output.txt")];

    auto res1 = engine.executeTask("build_1", node1, testDir);
    assert(res1.status == TaskStatus.succeeded);
    assert(res1.producedArtifacts.length == 1);
    assert(storage.artifactExists(res1.fingerprint, "output.txt"));
}
