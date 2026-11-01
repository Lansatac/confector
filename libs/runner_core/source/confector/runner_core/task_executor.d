module confector.runner_core.task_executor;

import confector.api.model;
import confector.runner_core.artifacts;
import confector.core.process : DeadlineException, LogDelegate, StopLimits, StopRequestedException, StopSignal;
import confector.runner_core.steps.step : productionStopLimits, StepContext, StepResult, StepRunner;

import std.format : format;
import std.algorithm.searching : canFind;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.time : Duration, MonoTime, seconds;
import vibe.core.log : logInfo;

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
    task.inputs["src"] = repositoryInput("game");
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

/// Throws StopRequestedException once `stop` has been requested, naming the point `what` the task
/// had reached; a null signal is never requested.
private void throwIfStopped(StopSignal stop, string taskId, string executionId, string what)
{
    if (stop !is null && stop.requested())
    {
        throw new StopRequestedException(format("Task '%s' of execution '%s' was asked to stop %s", taskId, executionId, what));
    }
}

/**
 * Core stateless executor capable of executing single nodes. Runs each step with the
 * `StepRunner` it is given.
 */
class TaskExecutor
{
    private ArtifactStorage m_artifactStorage;
    private StepRunner m_steps;

    /// How long a step's processes are given after the task's deadline.
    StopLimits stopLimits = productionStopLimits;

    /// Throws: Exception if `steps` is null.
    this(ArtifactStorage artifactStorage, StepRunner steps)
    {
        if (steps is null) throw new Exception("A task executor needs a step runner");
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
     *   timeout = The task's timeout, from the work order. It runs from the start of this call
     *             and covers staging its inputs and running its steps. Past it, the steps'
     *             processes are stopped and the task fails as timed out, with no outputs packed.
     *   inputs = The task's resolved inputs from the work order, one per declared input.
     *   repositoryAddresses = Where to fetch each repository input from, keyed by input name.
     *   logCallback = Receives each output line as it is produced; when null, lines are dropped.
     *   stop = Requested when the attempt is superseded or cancelled; null if it never is. No
     *          step starts after it is requested, and a running step is stopped (`StepContext.stop`).
     *   manageArtifacts = When true, the executor stages upstream artifacts and packs outputs.
     *
     * Throws: Exception if `fingerprint` is empty, `timeout` is not positive or `inputs` do not
     * match the task's declared inputs (see `bindInputs`); whatever the step runner throws for a
     * step it cannot run. StopRequestedException if `stop` is requested before a step starts or
     * while one runs; the attempt has no result to report.
     */
    TaskExecutionResult executeTask(
        string executionId,
        in TaskNode task,
        string workspaceDir,
        string fingerprint,
        Duration timeout,
        in ResolvedInput[] inputs,
        in string[string] repositoryAddresses = null,
        LogDelegate logCallback = null,
        StopSignal stop = null,
        bool manageArtifacts = true
    )
    {
        auto sw = StopWatch(AutoStart.yes);
        TaskExecutionResult result;
        result.taskId = task.id;
        LogDelegate log = logCallback !is null ? logCallback : (string line) {};

        logInfo("[executor] Starting executeTask for task '%s' (execution '%s', workspace '%s', manageArtifacts=%s)",
            task.id, executionId, workspaceDir, manageArtifacts);

        // 1. The fingerprint is the control plane's; outputs are stored under it.
        if (fingerprint.length == 0)
        {
            throw new Exception(format("Task '%s' of execution '%s' has no fingerprint; the work order must carry the one the control plane computed",
                task.id, executionId));
        }

        if (timeout <= Duration.zero)
        {
            throw new Exception(format("Task '%s' of execution '%s' has no positive timeout; the work order must carry the task's timeout",
                task.id, executionId));
        }
        const MonoTime deadline = MonoTime.currTime + timeout;

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
        //    (only when the executor owns artifact I/O). Each comes from the upstream task's
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

                throwIfStopped(stop, task.id, executionId, format("before staging upstream artifact '%s'", artId));
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
        stepCtx.deadline = deadline;
        stepCtx.stopLimits = stopLimits;
        stepCtx.stop = stop;
        foreach (name, address; repositoryAddresses) stepCtx.repositoryAddresses[name] = address;

        // A step that runs past the deadline has its processes stopped by the step runner, which
        // throws DeadlineException; a step that finishes after it, or none that starts after it,
        // leaves the task timed out
        bool timedOut = false;
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
                throwIfStopped(stop, task.id, executionId, format("before step %d", stepIdx + 1));
                if (MonoTime.currTime >= deadline)
                {
                    timedOut = true;
                    break;
                }
                string stepLabel = step.name.length > 0 ? step.name : format("Step %d (%s)", stepIdx + 1, step.type);
                log(format("[confector] Running build step [%d/%d]: %s", stepIdx + 1, task.steps.length, stepLabel));

                StepResult stepResult;
                try
                {
                    stepResult = m_steps.run(step, stepCtx);
                }
                catch (DeadlineException)
                {
                    timedOut = true;
                    break;
                }
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
            if (taskSuccess && MonoTime.currTime >= deadline) timedOut = true;
        }

        if (timedOut)
        {
            taskErrorMessage = format("Task '%s' timed out after %d seconds", task.id, timeout.total!"seconds");
            log(format("[confector] Error: %s", taskErrorMessage));
            result.status = ExecutionStatus.failed;
            result.exitCode = 1;
            result.errorMessage = taskErrorMessage;
            sw.stop();
            result.durationMs = sw.peek.total!"msecs";
            return result;
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
                    // Before the try: a stop must not be reported as a failed package
                    throwIfStopped(stop, task.id, executionId, format("before packing output artifact '%s'", artDecl.id));
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
        logInfo("[executor] executeTask completed for task '%s' (execution '%s', status: '%s', duration: %d ms, artifacts: %d)",
            task.id, executionId, result.status, result.durationMs, producedArtifacts.length);
        return result;
    }
}

version (unittest)
{
    /// A step runner for tests: runs each step's `command` config as a shell command in the
    /// step's working directory, sending its output to the step's log, and records each step it
    /// runs. The command's processes stop at the step's deadline.
    private final class ShellStepRunner : StepRunner
    {
        StepContext[] seen;

        StepResult run(in BuildStep step, ref StepContext context)
        {
            import std.process : environment;
            import confector.core.process : runProcess;
            import confector.testing.processes : shellArgs;

            seen ~= context;
            string[string] env = environment.toAA;
            foreach (key, value; context.environment) env[key] = value;
            StepResult res;
            const command = step.config["command"].get!string;
            const result = runProcess(shellArgs(command), context.workingDirectory, env,
                context.deadline, context.stopLimits, context.stop, context.log);
            if (result.outputAbandoned)
            {
                context.log(format("[confector] The output of '%s' was cut off: a process it started still held it open", command));
            }
            res.exitCode = result.exitCode;
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

    string testDir = "test_runner_core_executor_run";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto storage = new InMemoryArtifactStorage();
    auto steps = new ShellStepRunner();
    auto engine = new TaskExecutor(storage, steps);

    TaskNode node1;
    node1.id = "step1";
    node1.name = "Step 1";
    node1.steps = [shellStep("Write Output", "echo hello> output.txt")];
    node1.outputs.artifacts = [OutputArtifactDecl("output.txt", "output.txt")];

    string[] logged;
    auto res1 = engine.executeTask("exe_1", node1, testDir, "fp_step1", 60.seconds, [], null, (string line) { logged ~= line; });
    assert(res1.status == ExecutionStatus.succeeded, res1.errorMessage);
    assert(res1.producedArtifacts.length == 1);
    assert(res1.producedArtifacts[0].taskFingerprint == "fp_step1", "Outputs are stored under the work order's fingerprint");
    assert(res1.producedArtifacts[0].executionId == "exe_1", "Outputs name the execution that produced them");
    assert(storage.artifactExists("fp_step1", "output.txt"));
    assert(logged.canFind!(line => line.canFind("Running build step [1/1]: Write Output")), "Each step is announced in the log");
    assert(steps.seen.length == 1 && steps.seen[0].executionId == "exe_1" && steps.seen[0].taskId == "step1");

    // The runner never computes a fingerprint of its own
    bool threw = false;
    try engine.executeTask("exe_1", node1, testDir, "", 60.seconds, []);
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
    auto res2 = engine.executeTask("exe_2", node2, ws2, "fp_step2", 60.seconds, [ResolvedInput("out", InputKind.taskOutput, Json("fp_step1"))],
        null, (string line) { staged ~= line; });
    assert(res2.status == ExecutionStatus.succeeded, res2.errorMessage);
    assert(exists(buildPath(ws2, "output.txt")));
    assert(staged.canFind!(line => line.canFind("hello")), "The step read the staged artifact");

    // An upstream fingerprint with no such artifact fails the task
    auto res3 = engine.executeTask("exe_3", node2, ws2, "fp_step2", 60.seconds, [ResolvedInput("out", InputKind.taskOutput, Json("fp_other"))]);
    assert(res3.status == ExecutionStatus.failed && res3.errorMessage.canFind("fp_other"));
    assert(res3.errorMessage.canFind("'step1'") && res3.errorMessage.canFind("'output.txt'") && res3.errorMessage.canFind("Re-run task 'step1'"));

    // A failing step fails the task with its exit code, and later steps do not run
    TaskNode failing;
    failing.id = "failing";
    failing.steps = [shellStep("Fail", "exit 3"), shellStep("Never", "echo never")];
    steps.seen = null;
    auto res4 = engine.executeTask("exe_4", failing, testDir, "fp_failing", 60.seconds, []);
    assert(res4.status == ExecutionStatus.failed && res4.exitCode == 3, res4.errorMessage);
    assert(res4.errorMessage.canFind("'Fail'") && steps.seen.length == 1);

    // A task without steps fails rather than succeeding vacuously
    TaskNode empty;
    empty.id = "empty";
    auto res5 = engine.executeTask("exe_5", empty, testDir, "fp_empty", 60.seconds, []);
    assert(res5.status == ExecutionStatus.failed && res5.errorMessage.canFind("no build steps"));

    // An engine needs a step runner
    bool noRunner = false;
    try new TaskExecutor(storage, null);
    catch (Exception ex) noRunner = ex.msg.canFind("step runner");
    assert(noRunner);
}

unittest
{
    // Steps see the work order's inputs by name, and each repository input's address
    import vibe.data.json : Json;

    TaskNode task;
    task.id = "compile";
    task.inputs["src"] = repositoryInput("game");
    task.inputs["flavor"] = valueInput("internal");
    task.steps = [shellStep("Capture", "echo captured")];

    auto src = ResolvedInput("src", InputKind.repository, Json("1111111111111111111111111111111111111111"));
    auto flavor = ResolvedInput("flavor", InputKind.value, Json("internal"));
    auto steps = new ShellStepRunner();
    auto engine = new TaskExecutor(null, steps);
    auto res = engine.executeTask("exe_c", task, ".", "fp", 60.seconds, [flavor, src], ["src": "https://example.test/game.git"]);
    assert(res.status == ExecutionStatus.succeeded, res.errorMessage);
    assert(steps.seen.length == 1);
    auto seen = steps.seen[0];
    assert(seen.inputs.length == 2 && seen.inputs["src"] == src && seen.inputs["flavor"] == flavor);
    assert(seen.repositoryAddresses == ["src": "https://example.test/game.git"]);
    assert(seen.taskParameters == ["flavor": "internal"]);

    // Inputs that do not match the declaration are refused before any step runs
    steps.seen = null;
    bool threw = false;
    try engine.executeTask("exe_c", task, ".", "fp", 60.seconds, [flavor]);
    catch (Exception ex) threw = ex.msg.canFind("'src'");
    assert(threw && steps.seen.length == 0);
}

unittest
{
    // With the built-in step runner, a step type that is not built in fails the task.
    import confector.runner_core.steps.builtin : BuiltinStepRunner;

    TaskNode task;
    task.id = "package";
    BuildStep docker;
    docker.type = "docker:build";
    task.steps = [docker];
    string[] logged;
    auto engine = new TaskExecutor(null, new BuiltinStepRunner());
    auto res = engine.executeTask("exe_d", task, ".", "fp", 60.seconds, [], null, (string line) { logged ~= line; });
    assert(res.status == ExecutionStatus.failed && res.errorMessage.canFind("is not supported"), res.errorMessage);
    assert(logged.canFind!(line => line.canFind("is not supported")));
}

unittest
{
    // A task that runs past its timeout has its processes stopped, is reported failed as timed out,
    // and packs no outputs; a task that finishes in time succeeds. The timeout is short, and the
    // step that would outlast it is a process
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    import std.exception : assertThrown;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.processes : sleepingCommand;

    string testDir = "test_runner_core_executor_timeout";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto storage = new InMemoryArtifactStorage();
    auto steps = new ShellStepRunner();
    auto engine = new TaskExecutor(storage, steps);
    engine.stopLimits = StopLimits(1.seconds, 5.seconds, 5.seconds);

    TaskNode slow;
    slow.id = "slow";
    slow.outputs.artifacts = [OutputArtifactDecl("out.txt", "out.txt")];
    slow.steps = [
        shellStep("Write", "echo partial> out.txt"),
        shellStep("Wait", sleepingCommand),
        shellStep("Never", "echo never"),
    ];
    string[] logged;
    const started = MonoTime.currTime;
    auto res = engine.executeTask("exe_slow", slow, testDir, "fp_slow", 4.seconds, [], null, (string line) { logged ~= line; });
    assert(res.status == ExecutionStatus.failed, res.errorMessage);
    assert(res.errorMessage.canFind("'slow' timed out after 4 seconds"), res.errorMessage);
    assert(MonoTime.currTime - started < 60.seconds, "The task was not stopped at its timeout");
    assert(logged.canFind!(line => line.canFind("Running build step [2/3]: Wait")));
    assert(!logged.canFind!(line => line.canFind("[3/3]")), "A step after the timeout started");
    assert(!storage.artifactExists("fp_slow", "out.txt"), "A task that timed out packed its outputs");

    // A task that finishes within its timeout is unaffected
    TaskNode quick;
    quick.id = "quick";
    quick.steps = [shellStep("Quick", "echo done")];
    auto done = engine.executeTask("exe_quick", quick, testDir, "fp_quick", 60.seconds, []);
    assert(done.status == ExecutionStatus.succeeded && done.errorMessage.length == 0, done.errorMessage);

    // A timeout must be positive
    assertThrown!Exception(engine.executeTask("exe_quick", quick, testDir, "fp_quick", 0.seconds, []));
}

unittest
{
    // A stop requested while a step runs stops the step's processes, and the task throws
    // StopRequestedException: the step after the running one never starts
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import confector.core.process : StopSignal;
    import confector.testing.processes : sleepingCommand;

    string testDir = "test_runner_core_executor_stop";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto steps = new ShellStepRunner();
    auto engine = new TaskExecutor(null, steps);
    engine.stopLimits = StopLimits(1.seconds, 5.seconds, 5.seconds);

    // The first step leaves a marker once it runs, and the stop is requested only then
    TaskNode task;
    task.id = "stoppable";
    task.steps = [shellStep("Wait", "echo started > started.txt && " ~ sleepingCommand), shellStep("Never", "echo never > ran.txt")];
    auto stop = new StopSignal;
    const marker = buildPath(testDir, "started.txt");
    auto requester = new Thread({
        const waitUntil = MonoTime.currTime + 30.seconds;
        while (!exists(marker) && MonoTime.currTime < waitUntil) Thread.sleep(20.msecs);
        stop.request();
    });
    requester.start();

    bool stopped = false;
    const started = MonoTime.currTime;
    try engine.executeTask("exe_stop", task, testDir, "fp_stop", 60.seconds, [], null, null, stop);
    catch (StopRequestedException e) stopped = true;
    requester.join();
    assert(exists(marker), "The first step did not start");
    assert(stopped, "A task asked to stop did not throw StopRequestedException");
    assert(MonoTime.currTime - started < 30.seconds, "The running step was not stopped promptly");
    assert(steps.seen.length == 1 && steps.seen[0].taskId == "stoppable", "A step started after the stop was requested");
    assert(!exists(buildPath(testDir, "ran.txt")), "The step after the stopped one ran");
}

unittest
{
    // A stop requested by a step that has just finished is seen before the next step starts, and
    // before the task's outputs are packed. The stop comes from the step itself, so nothing races it
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    import confector.core.process : StopSignal;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;

    final class StopAfterStep : StepRunner
    {
        StopSignal stop;
        size_t runs;

        StepResult run(in BuildStep step, ref StepContext context)
        {
            ++runs;
            stop.request();
            StepResult result;
            return result;
        }
    }

    string testDir = "test_runner_core_executor_stop_between";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    // Between two steps: the second never starts
    auto stop = new StopSignal;
    auto steps = new StopAfterStep();
    steps.stop = stop;
    auto engine = new TaskExecutor(null, steps);
    TaskNode task;
    task.id = "between";
    task.steps = [shellStep("First", "unused"), shellStep("Second", "unused")];
    bool stopped = false;
    try engine.executeTask("exe_between", task, testDir, "fp_between", 60.seconds, [], null, null, stop);
    catch (StopRequestedException e) stopped = true;
    assert(stopped, "A task stopped between its steps did not throw StopRequestedException");
    assert(steps.runs == 1, format("%s steps ran after the stop was requested", steps.runs));

    // Before packing: the task's outputs are not packed or stored
    auto packStop = new StopSignal;
    auto packSteps = new StopAfterStep();
    packSteps.stop = packStop;
    auto storage = new InMemoryArtifactStorage();
    auto packer = new TaskExecutor(storage, packSteps);
    TaskNode packed;
    packed.id = "packed";
    packed.steps = [shellStep("Only", "unused")];
    packed.outputs.artifacts = [OutputArtifactDecl("out.txt", "out.txt")];
    stopped = false;
    try packer.executeTask("exe_packed", packed, testDir, "fp_packed", 60.seconds, [], null, null, packStop);
    catch (StopRequestedException e) stopped = true;
    assert(stopped, "A task stopped before packing did not throw StopRequestedException");
    assert(!storage.artifactExists("fp_packed", "out.txt"), "A stopped task stored its outputs");
}
