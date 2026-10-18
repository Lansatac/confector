module confector.runner_core.steps.step;

import confector.core.model : BuildStep, ResolvedInput;
import confector.runner_core.logging : LogDelegate;

/**
 * What a step sees of the task it runs in.
 */
struct StepContext
{
    /// The execution the step runs for (`WorkOrder.executionId`).
    string executionId;
    string taskId;
    /// The execution's workspace; a step must not write outside it.
    string workspaceDir;
    string workingDirectory;
    /// The task's environment; the runner's own environment is not included.
    string[string] environment;
    /// The task's value inputs, keyed by input name.
    string[string] taskParameters;
    /// The task's resolved inputs, keyed by input name, exactly as the work order pinned them.
    /// Inputs are not materialized automatically: a step that needs one (the built-in checkout
    /// step) looks it up by name.
    ResolvedInput[string] inputs;
    /// Address of the repository each repository input names, keyed by input name. Used only
    /// by the built-in checkout step.
    string[string] repositoryAddresses;
    /// Receives each line of the step's output as it is produced. Never null.
    LogDelegate log;
}

/**
 * The outcome of one step. Its output went to `StepContext.log` as it ran.
 */
struct StepResult
{
    bool success = true;
    int exitCode = 0;
    string errorMessage;
}

/**
 * Runs the steps of a task. The engine is given one explicitly, so tests can supply fakes.
 */
interface StepRunner
{
    /// Runs `step`. A step that fails returns a failed result; one that cannot run at all throws.
    StepResult run(in BuildStep step, ref StepContext context);
}
