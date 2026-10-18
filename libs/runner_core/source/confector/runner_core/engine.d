module confector.runner_core.engine;

import confector.plugin_api.model;
import confector.runner_core.artifacts;
import confector.runner_core.steps.step : StepContext, StepResult, StepRunner;

import std.format : format;
import std.algorithm.searching : canFind;
import std.datetime.stopwatch : StopWatch, AutoStart;
import confector.runner_core.logging : LogDelegate, logInfo;

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
 * Core stateless execution engine capable of executing single nodes. Runs each step with the
 * `StepRunner` it is given.
 */
class TaskEngine
{
    private ArtifactStorage m_artifactStorage;
    private StepRunner m_steps;

    /// Throws: Exception if `steps` is null.
    this(ArtifactStorage artifactStorage, StepRunner steps)
    {
        if (steps is null) throw new Exception("A task engine needs a step runner");
        m_artifactStorage = artifactStorage;
        m_steps = steps;
    }

    @property ArtifactStorage artifactStorage() { return m_artifactStorage; }

    /**
     * Executes a single task of a work order: stages the upstream artifacts its task_output
     * inputs name, runs its steps, and packs its declared outputs under `fingerprint`.
     *
     * Inputs are not materialized automatically. Steps see the bound inputs by name; the
     * built-in checkout step checks a repository input out at its pinned revision.
     *
     * Params:
     *   executionId = The execution this run is for (`WorkOrder.executionId`).
     *   task = The task node to execute; its declared inputs are the chain's.
     *   workspaceDir = Workspace directory path where execution occurs.
     *   fingerprint = The task's fingerprint from the work order, computed by the control
     *                 plane; the runner never computes its own. Required.
     *   inputs = The task's resolved inputs from the work order, one per declared input.
     *   repositoryAddresses = Where to fetch each repository input from, keyed by input name.
     *   logCallback = Receives each output line as it is produced; when null, lines are dropped.
     *   manageArtifacts = When true, engine stages upstream artifacts and packs outputs.
     *
     * Throws: Exception if `fingerprint` is empty or `inputs` do not match the task's declared
     * inputs (see `bindInputs`); whatever the step runner throws for a step it cannot run.
     */
    TaskExecutionResult executeTask(
        string executionId,
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
        LogDelegate log = logCallback !is null ? logCallback : (string line) {};

        logInfo("[engine] Starting executeTask for task '%s' (execution '%s', workspace '%s', manageArtifacts=%s)",
            task.id, executionId, workspaceDir, manageArtifacts);

        // 1. The fingerprint is the control plane's; outputs are stored under it.
        if (fingerprint.length == 0)
        {
            throw new Exception(format("Task '%s' of execution '%s' has no fingerprint; the work order must carry the one the control plane computed",
                task.id, executionId));
        }

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
                result.status = ExecutionStatus.failed;
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
                    result.status = ExecutionStatus.failed;
                    result.errorMessage = missingUpstreamArtifactMessage(upTaskId, upFp, artId);
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                bool staged = ArtifactStager.stageUpstreamArtifact(m_artifactStorage, upFp, artId, targetLocal);
                if (!staged)
                {
                    result.status = ExecutionStatus.failed;
                    result.errorMessage = format(
                        "Failed to extract upstream artifact '%s' from task '%s' into '%s' (checksum mismatch or corrupt archive)",
                        artId, upTaskId, targetLocal
                    );
                    sw.stop();
                    result.durationMs = sw.peek.total!"msecs";
                    return result;
                }

                log(format("[confector] Staged upstream artifact '%s' (from task '%s') into '%s'", artId, upTaskId, targetLocal));
            }
        }

        // 4. Execute Build Steps
        int taskExitCode = 0;
        bool taskSuccess = true;
        string taskErrorMessage = "";

        StepContext stepCtx;
        stepCtx.executionId = executionId;
        stepCtx.taskId = task.id;
        stepCtx.workspaceDir = workspaceDir;
        stepCtx.workingDirectory = effectiveWorkingDir;
        stepCtx.environment = task.environment.dup;
        stepCtx.taskParameters = valueInputs.dup;
        stepCtx.log = log;
        stepCtx.inputs = boundInputs;
        foreach (name, address; repositoryAddresses) stepCtx.repositoryAddresses[name] = address;

        if (task.steps.length == 0)
        {
            taskSuccess = false;
            taskExitCode = 1;
            taskErrorMessage = "Task has no build steps defined";
            log(format("[confector] Error: %s", taskErrorMessage));
        }
        else
        {
            foreach (size_t stepIdx, ref const(BuildStep) step; task.steps)
            {
                string stepLabel = step.name.length > 0 ? step.name : format("Step %d (%s)", stepIdx + 1, step.type);
                log(format("[confector] Running build step [%d/%d]: %s", stepIdx + 1, task.steps.length, stepLabel));

                StepResult stepResult = m_steps.run(step, stepCtx);
                if (!stepResult.success)
                {
                    taskSuccess = false;
                    taskExitCode = stepResult.exitCode != 0 ? stepResult.exitCode : 1;
                    taskErrorMessage = stepResult.errorMessage.length > 0
                        ? stepResult.errorMessage
                        : format("Build step '%s' failed with exit code %d", stepLabel, taskExitCode);
                    log(format("[confector] Build step '%s' failed: %s", stepLabel, taskErrorMessage));
                    break;
                }
            }
        }

        result.exitCode = taskExitCode;

        if (!taskSuccess)
        {
            result.status = ExecutionStatus.failed;
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
                            m_artifactStorage, fingerprint, executionId, task.id, effectiveWorkingDir, artDecl
                        );
                        producedArtifacts ~= meta;
                    }
                    catch (Exception e)
                    {
                        result.status = ExecutionStatus.failed;
                        result.errorMessage = format("Failed to package output artifact '%s': %s", artDecl.id, e.msg);
                        sw.stop();
                        result.durationMs = sw.peek.total!"msecs";
                        return result;
                    }
                }
            }
        }

        result.producedArtifacts = producedArtifacts;
        result.status = ExecutionStatus.succeeded;
        sw.stop();
        result.durationMs = sw.peek.total!"msecs";
        logInfo("[engine] executeTask completed for task '%s' (execution '%s', status: '%s', duration: %d ms, artifacts: %d)",
            task.id, executionId, result.status, result.durationMs, producedArtifacts.length);
        return result;
    }
}

version (unittest)
{
    /// A step runner for tests: runs each step's `command` config as a shell command in the
    /// step's working directory, sending its output to the step's log, and records each step it
    /// runs.
    private final class ShellStepRunner : StepRunner
    {
        StepContext[] seen;

        StepResult run(in BuildStep step, ref StepContext context)
        {
            import std.process : pipeShell, Redirect, Config, wait;

            seen ~= context;
            StepResult res;
            auto pipe = pipeShell(step.config["command"].get!string, Redirect.stdout | Redirect.stderrToStdout, null, Config.none, context.workingDirectory);
            foreach (line; pipe.stdout.byLineCopy) context.log(line);
            res.exitCode = wait(pipe.pid);
            res.success = res.exitCode == 0;
            return res;
        }
    }

    private BuildStep shellStep(string name, string command)
    {
        import vibe.data.json : Json;

        return BuildStep(name, "shell", Json(["command": Json(command)]));
    }
}

unittest
{
    import std.file : exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    import vibe.data.json : Json;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;

    string testDir = "test_runner_core_engine_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto storage = new InMemoryArtifactStorage();
    auto steps = new ShellStepRunner();
    auto engine = new TaskEngine(storage, steps);

    TaskNode node1;
    node1.id = "step1";
    node1.name = "Step 1";
    node1.steps = [shellStep("Write Output", "echo hello> output.txt")];
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "output.txt")];

    string[] logged;
    auto res1 = engine.executeTask("exe_1", node1, testDir, "fp_step1", [], null, (string line) { logged ~= line; });
    assert(res1.status == ExecutionStatus.succeeded, res1.errorMessage);
    assert(res1.producedArtifacts.length == 1);
    assert(res1.producedArtifacts[0].taskFingerprint == "fp_step1", "Outputs are stored under the work order's fingerprint");
    assert(res1.producedArtifacts[0].executionId == "exe_1", "Outputs name the execution that produced them");
    assert(storage.artifactExists("fp_step1", "output.txt"));
    assert(logged.canFind!(line => line.canFind("Running build step [1/1]: Write Output")), "Each step is announced in the log");
    assert(steps.seen.length == 1 && steps.seen[0].executionId == "exe_1" && steps.seen[0].taskId == "step1");

    // The runner never computes a fingerprint of its own
    bool threw = false;
    try engine.executeTask("exe_1", node1, testDir, "", []);
    catch (Exception ex) threw = ex.msg.canFind("no fingerprint");
    assert(threw);

    // A downstream task stages the artifact its task_output input names, from the upstream
    // fingerprint the input is pinned to
    TaskNode node2;
    node2.id = "step2";
    node2.inputs["out"] = taskOutputInput("step1", "output.txt");
    version (Windows) node2.steps = [shellStep("Check", "type output.txt")];
    else node2.steps = [shellStep("Check", "cat output.txt")];
    string ws2 = buildPath(testDir, "ws2");
    mkdirRecurse(ws2);
    string[] staged;
    auto res2 = engine.executeTask("exe_2", node2, ws2, "fp_step2", [ResolvedInput("out", InputKind.taskOutput, Json("fp_step1"))],
        null, (string line) { staged ~= line; });
    assert(res2.status == ExecutionStatus.succeeded, res2.errorMessage);
    assert(exists(buildPath(ws2, "output.txt")));
    assert(staged.canFind!(line => line.canFind("hello")), "The step read the staged artifact");

    // An upstream fingerprint with no such artifact fails the task
    auto res3 = engine.executeTask("exe_3", node2, ws2, "fp_step2", [ResolvedInput("out", InputKind.taskOutput, Json("fp_other"))]);
    assert(res3.status == ExecutionStatus.failed && res3.errorMessage.canFind("fp_other"));
    assert(res3.errorMessage.canFind("'step1'") && res3.errorMessage.canFind("'output.txt'") && res3.errorMessage.canFind("Re-run task 'step1'"));

    // A failing step fails the task with its exit code, and later steps do not run
    TaskNode failing;
    failing.id = "failing";
    failing.steps = [shellStep("Fail", "exit 3"), shellStep("Never", "echo never")];
    steps.seen = null;
    auto res4 = engine.executeTask("exe_4", failing, testDir, "fp_failing", []);
    assert(res4.status == ExecutionStatus.failed && res4.exitCode == 3, res4.errorMessage);
    assert(res4.errorMessage.canFind("'Fail'") && steps.seen.length == 1);

    // A task without steps fails rather than succeeding vacuously
    TaskNode empty;
    empty.id = "empty";
    auto res5 = engine.executeTask("exe_5", empty, testDir, "fp_empty", []);
    assert(res5.status == ExecutionStatus.failed && res5.errorMessage.canFind("no build steps"));

    // An engine needs a step runner
    bool noRunner = false;
    try new TaskEngine(storage, null);
    catch (Exception ex) noRunner = ex.msg.canFind("step runner");
    assert(noRunner);
}

unittest
{
    // Steps see the work order's inputs by name, and each repository input's address
    import vibe.data.json : Json;

    TaskNode task;
    task.id = "compile";
    task.inputs["src"] = repositoryInput("game", "main");
    task.inputs["flavor"] = valueInput("internal");
    task.steps = [shellStep("Capture", "echo captured")];

    auto src = ResolvedInput("src", InputKind.repository, Json("1111111111111111111111111111111111111111"));
    auto flavor = ResolvedInput("flavor", InputKind.value, Json("internal"));
    auto steps = new ShellStepRunner();
    auto engine = new TaskEngine(null, steps);
    auto res = engine.executeTask("exe_c", task, ".", "fp", [flavor, src], ["src": "https://example.test/game.git"]);
    assert(res.status == ExecutionStatus.succeeded, res.errorMessage);
    assert(steps.seen.length == 1);
    auto seen = steps.seen[0];
    assert(seen.inputs.length == 2 && seen.inputs["src"] == src && seen.inputs["flavor"] == flavor);
    assert(seen.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(seen.taskParameters == ["flavor": "internal"]);

    // Inputs that do not match the declaration are refused before any step runs
    steps.seen = null;
    bool threw = false;
    try engine.executeTask("exe_c", task, ".", "fp", [flavor]);
    catch (Exception ex) threw = ex.msg.canFind("'src'");
    assert(threw && steps.seen.length == 0);
}

unittest
{
    // With the built-in step runner, a step type that is not built in fails the task, naming
    // the bead that implements step programs
    import confector.runner_core.steps.builtin : BuiltinStepRunner;

    TaskNode task;
    task.id = "package";
    BuildStep docker;
    docker.type = "docker:build";
    task.steps = [docker];
    string[] logged;
    auto engine = new TaskEngine(null, new BuiltinStepRunner());
    auto res = engine.executeTask("exe_d", task, ".", "fp", [], null, (string line) { logged ~= line; });
    assert(res.status == ExecutionStatus.failed && res.errorMessage.canFind("confector-z7z.35.1"), res.errorMessage);
    assert(logged.canFind!(line => line.canFind("confector-z7z.35.1")));
}
