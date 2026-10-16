module confector.runner_core.engine;

import confector.core.model;
import confector.core.executor;
import confector.core.system;
import confector.core.plugin;
import confector.plugin_api.model : ArtifactStorage;
import confector.runner_core.logging;
import confector.runner_core.artifacts;

import std.file : exists, isFile;
import std.format : format;
import std.algorithm.searching : canFind;
import std.datetime.stopwatch : StopWatch, AutoStart;
import confector.runner_core.logging : logInfo, logError, logWarn, logDebug;

/**
 * Binds a work order's resolved inputs to the task's declared inputs, keyed by input name.
 * Pure. The work order must pin exactly the declared inputs: one resolved input per declared
 * input, of the declared kind; a value input pinned to its declared value; a task_output input
 * pinned to a non-empty upstream fingerprint (a string). `repositoryAddresses` may only name
 * repository inputs.
 *
 * Throws: Exception naming the task and input on any mismatch.
 */
ResolvedInput[string] bindInputs(in TaskNode task, in ResolvedInput[] inputs, in string[string] repositoryAddresses = null) @trusted
{
    import vibe.data.json : Json;

    ResolvedInput[string] bound;
    foreach (ref input; inputs)
    {
        if (input.name in bound)
        {
            throw new Exception(format("Task '%s' work order pins input '%s' more than once", task.id, input.name));
        }
        auto decl = input.name in task.inputs;
        if (decl is null)
        {
            throw new Exception(format("Task '%s' work order pins input '%s', which the task does not declare", task.id, input.name));
        }
        if (decl.kind != input.kind)
        {
            throw new Exception(format("Task '%s' input '%s' is declared as %s but pinned as %s",
                task.id, input.name, cast(string) decl.kind, cast(string) input.kind));
        }
        if (input.pinned.type == Json.Type.undefined || input.pinned.type == Json.Type.null_)
        {
            throw new Exception(format("Task '%s' input '%s' has no pinned value", task.id, input.name));
        }
        if (input.kind == InputKind.value && input.pinned != Json(decl.spec.value))
        {
            throw new Exception(format("Task '%s' value input '%s' is pinned to a value other than its declared one", task.id, input.name));
        }
        if (input.kind == InputKind.taskOutput
            && (input.pinned.type != Json.Type.string || input.pinned.get!string.length == 0))
        {
            throw new Exception(format("Task '%s' input '%s' is not pinned to the fingerprint of upstream task '%s'",
                task.id, input.name, decl.spec.task));
        }
        bound[input.name] = ResolvedInput(input.name, input.kind, input.pinned.clone, cast(string[string]) input.info.dup);
    }
    foreach (name, decl; task.inputs)
    {
        if (name !in bound)
        {
            throw new Exception(format("Task '%s' input '%s' is declared but the work order does not pin it", task.id, name));
        }
    }
    foreach (name, address; repositoryAddresses)
    {
        auto decl = name in task.inputs;
        if (decl is null || decl.kind != InputKind.repository)
        {
            throw new Exception(format("Task '%s' work order gives a repository address for '%s', which is not a repository input of the task",
                task.id, name));
        }
    }
    return bound;
}

unittest
{
    import vibe.data.json : Json;

    TaskNode task;
    task.id = "package";
    task.inputs["src"] = repositoryInput("game", "main");
    task.inputs["bin"] = taskOutputInput("compile", "binaries");
    task.inputs["flavor"] = valueInput("external");

    auto src = ResolvedInput("src", InputKind.repository, Json("1111111111111111111111111111111111111111"), ["ref": "refs/heads/main"]);
    auto bin = ResolvedInput("bin", InputKind.taskOutput, Json("fp_compile"));
    auto flavor = ResolvedInput("flavor", InputKind.value, Json("external"));

    auto bound = bindInputs(task, [bin, flavor, src], ["src": "https://example.test/game.git"]);
    assert(bound.length == 3 && bound["src"] == src && bound["bin"] == bin && bound["flavor"] == flavor);

    bool rejects(in ResolvedInput[] inputs, string expected, string[string] addresses = null)
    {
        try bindInputs(task, inputs, addresses);
        catch (Exception ex) return ex.msg.canFind(expected);
        return false;
    }

    assert(rejects([bin, flavor], "'src' is declared but the work order does not pin it"));
    assert(rejects([bin, flavor, src, ResolvedInput("ghost", InputKind.value, Json("x"))], "does not declare"));
    assert(rejects([bin, flavor, src, src], "more than once"));
    assert(rejects([bin, flavor, ResolvedInput("src", InputKind.value, Json("x"))], "declared as repository but pinned as value"));
    assert(rejects([bin, ResolvedInput("flavor", InputKind.value, Json("internal")), src], "other than its declared"));
    assert(rejects([ResolvedInput("bin", InputKind.taskOutput, Json("")), flavor, src], "upstream task 'compile'"));
    assert(rejects([bin, flavor, ResolvedInput("src", InputKind.repository, Json(null))], "no pinned value"));
    assert(rejects([bin, flavor, src], "not a repository input", ["flavor": "https://example.test/x.git"]));
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
     * Executes a single task of a work order: stages the upstream artifacts its task_output
     * inputs name, runs its steps, and packs its declared outputs under `fingerprint`.
     *
     * Inputs are not materialized automatically. Steps see the bound inputs by name; the
     * built-in checkout step checks a repository input out at its pinned revision.
     *
     * Params:
     *   buildId = The build ID associated with this task.
     *   task = The task node to execute; its declared inputs are the chain's.
     *   workspaceDir = Workspace directory path where execution occurs.
     *   fingerprint = The task's fingerprint from the work order, computed by the control
     *                 plane; the runner never computes its own. Required.
     *   inputs = The task's resolved inputs from the work order, one per declared input.
     *   repositoryAddresses = Where to fetch each repository input from, keyed by input name.
     *   logCallback = Optional log callback receiving execution output lines.
     *   manageArtifacts = When true, engine stages upstream artifacts and packs outputs.
     *
     * Throws: Exception if `fingerprint` is empty or `inputs` do not match the task's declared
     * inputs (see `bindInputs`).
     */
    TaskExecutionResult executeTask(
        string buildId,
        in TaskNode task,
        string workspaceDir,
        string fingerprint,
        in ResolvedInput[] inputs,
        in string[string] repositoryAddresses = null,
        LogDelegate logCallback = null,
        bool manageArtifacts = true
    )
    {
        auto sw = StopWatch(AutoStart.yes);
        TaskExecutionResult result;
        result.taskId = task.id;
        result.buildId = buildId;

        logInfo("[engine] Starting executeTask for task '%s' (build '%s', workspace '%s', manageArtifacts=%s)",
            task.id, buildId, workspaceDir, manageArtifacts);

        // 1. The fingerprint is the control plane's; outputs are stored under it.
        if (fingerprint.length == 0)
        {
            throw new Exception(format("Task '%s' of build '%s' has no fingerprint; the work order must carry the one the control plane computed",
                task.id, buildId));
        }
        result.fingerprint = fingerprint;

        // 2. Bind the work order's resolved inputs to the task's declared inputs
        ResolvedInput[string] boundInputs = bindInputs(task, inputs, repositoryAddresses);

        // Effective working directory defaults to workspace directory
        string effectiveWorkingDir = workspaceDir;

        // Value inputs are exposed to steps as task parameters, keyed by input name
        string[string] valueInputs;
        foreach (name, decl; task.inputs)
        {
            if (decl.kind == InputKind.value) valueInputs[name] = decl.spec.value;
        }

        // 3. Retrieve upstream artifacts named by task_output inputs into the workspace root
        //    (only when engine owns artifact I/O). Each comes from the upstream task's
        //    fingerprint, which is the input's pinned value.
        string[] artifactInputs;
        foreach (name, decl; task.inputs)
        {
            if (decl.kind == InputKind.taskOutput && decl.spec.artifact.length > 0) artifactInputs ~= name;
        }
        if (manageArtifacts && artifactInputs.length > 0)
        {
            if (m_artifactStorage is null)
            {
                result.status = TaskStatus.failed;
                result.errorMessage = "ArtifactStorage is null but task requires upstream artifacts";
                sw.stop();
                result.durationMs = sw.peek.total!"msecs";
                return result;
            }

            foreach (name; artifactInputs)
            {
                const decl = task.inputs[name];
                string upTaskId = decl.spec.task;
                string artId = decl.spec.artifact;
                string targetLocal = effectiveWorkingDir;
                string upFp = boundInputs[name].pinned.get!string;

                if (!m_artifactStorage.artifactExists(upFp, artId))
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = missingUpstreamArtifactMessage(upTaskId, upFp, artId);
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                bool staged = ArtifactStager.stageUpstreamArtifact(m_artifactStorage, upFp, artId, targetLocal);
                if (!staged)
                {
                    result.status = TaskStatus.failed;
                    result.errorMessage = format(
                        "Failed to extract upstream artifact '%s' from task '%s' into '%s' (checksum mismatch or corrupt archive)",
                        artId, upTaskId, targetLocal
                    );
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                if (logCallback !is null)
                {
                    logCallback(format("[confector] Staged upstream artifact '%s' (from task '%s') into '%s'", artId, upTaskId, targetLocal));
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
        stepCtx.taskParameters = valueInputs.dup;
        stepCtx.artifactStorage = m_artifactStorage;
        stepCtx.logCallback = combinedLogger;
        stepCtx.inputs = boundInputs;
        foreach (name, address; repositoryAddresses) stepCtx.repositoryAddresses[name] = address;

        if (task.steps.length == 0)
        {
            taskSuccess = false;
            taskExitCode = 1;
            taskErrorMessage = "Task has no build steps defined; only plugin-defined build steps are supported";
            combinedLogger(format("[confector] Error: %s", taskErrorMessage));
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
            if (m_artifactStorage !is null)
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
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.step_executor; }
        ConfigDefinition[] configDefinitions() const { return null; }
        @property string systemName() const pure nothrow @safe { return "mock-step-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecuteStep(in BuildStep step) const
        {
            return step.type == "bash" || step.type == "mock";
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

    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new MockStepRunner());

    auto storage = new InMemoryArtifactStorage();
    auto engine = new TaskEngine(storage);

    TaskNode node1;
    node1.id = "step1";
    node1.name = "Step 1";
    version(Windows)
    {
        node1.steps = [BuildStep("Write Output", "bash", null, "cmd /c \"echo hello > output.txt\"")];
    }
    else
    {
        node1.steps = [BuildStep("Write Output", "bash", null, "echo hello > output.txt")];
    }
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "output.txt")];

    auto res1 = engine.executeTask("build_1", node1, testDir, "fp_step1", []);
    assert(res1.fingerprint == "fp_step1", "Outputs are stored under the work order's fingerprint");
    assert(res1.status == TaskStatus.succeeded);
    assert(res1.producedArtifacts.length == 1);
    assert(storage.artifactExists("fp_step1", "output.txt"));

    // The runner never computes a fingerprint of its own
    bool threw = false;
    try engine.executeTask("build_1", node1, testDir, "", []);
    catch (Exception ex) threw = ex.msg.canFind("no fingerprint");
    assert(threw);

    // A downstream task stages the artifact its task_output input names, from the upstream
    // fingerprint the input is pinned to
    TaskNode node2;
    node2.id = "step2";
    node2.inputs["out"] = taskOutputInput("step1", "output.txt");
    version(Windows) node2.steps = [BuildStep("Check", "bash", null, "cmd /c \"type output.txt\"")];
    else node2.steps = [BuildStep("Check", "bash", null, "cat output.txt")];
    string ws2 = buildPath(testDir, "ws2");
    mkdirRecurse(ws2);
    import vibe.data.json : Json;
    auto res2 = engine.executeTask("build_1", node2, ws2, "fp_step2", [ResolvedInput("out", InputKind.taskOutput, Json("fp_step1"))]);
    assert(res2.status == TaskStatus.succeeded, res2.errorMessage);
    assert(exists(buildPath(ws2, "output.txt")));

    // An upstream fingerprint with no such artifact fails the task
    auto res3 = engine.executeTask("build_1", node2, ws2, "fp_step2", [ResolvedInput("out", InputKind.taskOutput, Json("fp_other"))]);
    assert(res3.status == TaskStatus.failed && res3.errorMessage.canFind("fp_other"));
    assert(res3.errorMessage.canFind("'step1'") && res3.errorMessage.canFind("'output.txt'") && res3.errorMessage.canFind("Re-run task 'step1'"));
}

unittest
{
    // Steps see the work order's inputs by name, and each repository input's address
    import vibe.data.json : Json;

    static ResolvedInput[string] seenInputs;
    static string[string] seenAddresses;
    static string[string] seenParameters;

    class CapturingStepRunner : Plugin, BuildStepSystem
    {
        @property string name() const pure nothrow @safe { return "capturing_runner"; }
        @property string versionString() const pure nothrow @safe { return "1.0.0"; }
        @property string description() const pure nothrow @safe { return "Captures the step context"; }
        @property PluginCategory category() const pure nothrow @safe { return PluginCategory.step_executor; }
        ConfigDefinition[] configDefinitions() const { return null; }
        @property string systemName() const pure nothrow @safe { return "capturing-step-system"; }
        void initialize(PluginContext context = null) {}
        void shutdown() {}
        bool canExecuteStep(in BuildStep step) const { return step.type == "capture"; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            seenInputs = context.inputs.dup;
            seenAddresses = context.repositoryAddresses.dup;
            seenParameters = context.taskParameters.dup;
            return StepExecutionResult();
        }
    }

    PluginRegistry.instance.shutdownAll();
    PluginRegistry.instance.registerPlugin(new CapturingStepRunner());
    scope(exit) PluginRegistry.instance.shutdownAll();

    TaskNode task;
    task.id = "compile";
    task.inputs["src"] = repositoryInput("game", "main");
    task.inputs["flavor"] = valueInput("internal");
    task.steps = [BuildStep("Capture", "capture")];

    auto src = ResolvedInput("src", InputKind.repository, Json("1111111111111111111111111111111111111111"));
    auto flavor = ResolvedInput("flavor", InputKind.value, Json("internal"));
    auto engine = new TaskEngine(null);
    auto res = engine.executeTask("b", task, ".", "fp", [flavor, src], ["src": "https://example.test/game.git"]);
    assert(res.status == TaskStatus.succeeded, res.errorMessage);
    assert(seenInputs.length == 2 && seenInputs["src"] == src && seenInputs["flavor"] == flavor);
    assert(seenAddresses == ["src": "https://example.test/game.git"]);
    assert(seenParameters == ["flavor": "internal"]);

    // Inputs that do not match the declaration are refused before any step runs
    seenInputs = null;
    bool threw = false;
    try engine.executeTask("b", task, ".", "fp", [flavor]);
    catch (Exception ex) threw = ex.msg.canFind("'src'");
    assert(threw && seenInputs is null);
}
