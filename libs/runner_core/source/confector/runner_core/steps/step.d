module confector.runner_core.steps.step;

import confector.api.model : BuildStep, ResolvedInput;
import confector.core.process : LogDelegate, StopLimits;
import confector.core.worker_token : workerTokenGrace;
import core.time : Duration, MonoTime, seconds;

/**
 * How long a process is given after the task's deadline, and why the worker token still covers
 * it. The token lives for the task's timeout plus `workerTokenGrace`, so everything that follows
 * the deadline (the stop below, then reporting the failure) must fit in that grace.
 *
 * At the deadline the process is asked to stop and given `stopGrace` to do so. Then its whole
 * tree is killed and given `reapLimit` to disappear, and its output given `drainLimit` to end.
 * The worst case is the sum, `postDeadlineBudget`, a small fraction of the token's grace.
 */
enum Duration productionStopGrace = 20.seconds;
enum Duration productionReapLimit = 5.seconds; /// ditto
enum Duration productionDrainLimit = 5.seconds; /// ditto
enum Duration postDeadlineBudget = productionStopGrace + productionReapLimit + productionDrainLimit; /// ditto
static assert(postDeadlineBudget * 10 <= workerTokenGrace, "Stopping a process must leave most of the token's grace for reporting");

/// The waits the runner gives a process after a task's deadline.
enum StopLimits productionStopLimits = StopLimits(productionStopGrace, productionReapLimit, productionDrainLimit);

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
    /// When the task's timeout runs out. A step's processes are stopped at this time
    /// (`runProcess`), and the step then throws DeadlineException. Must be set: the default
    /// is rejected rather than read as a deadline that has passed.
    MonoTime deadline;
    /// How long `runProcess` waits after the deadline.
    StopLimits stopLimits = productionStopLimits;
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
 * Runs the steps of a task. The executor is given one explicitly, so tests can supply fakes.
 *
 * A step that starts a process must do so through `runProcess` (confector.core.process)
 * with `StepContext.deadline`. That is what stops the process, and everything it started, when the
 * task times out; a process started any other way outlives the timeout.
 */
interface StepRunner
{
    /// Runs `step`. A step that fails returns a failed result; one that cannot run at all throws.
    StepResult run(in BuildStep step, ref StepContext context);
}
