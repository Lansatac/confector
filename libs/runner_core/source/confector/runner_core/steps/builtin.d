module confector.runner_core.steps.builtin;

import confector.core.builtin_steps : checkoutStepType;
import confector.api.model : BuildStep;
import confector.core.not_implemented : NotImplementedException;
import confector.runner_core.steps.step;
import confector.runner_core.steps.checkout : runCheckout;

import std.format : format;

/**
 * The runner's built-in steps, chosen by step type: `checkout` checks a repository input out at
 * its pinned revision. A step of any other type fails, since steps that are programs are not
 * implemented yet.
 */
final class BuiltinStepRunner : StepRunner
{
    StepResult run(in BuildStep step, ref StepContext context)
    {
        switch (step.type)
        {
            case checkoutStepType:
                return runCheckout(step, context);
            case "bash":
            case "powershell":
                throw new NotImplementedException("Built-in bash/PowerShell step");
            default:
                StepResult result;
                result.success = false;
                result.exitCode = 1;
                result.errorMessage = format("Step type '%s' is not supported: the runner has only the built-in checkout step until step programs are implemented",
                    step.type);
                context.log(format("[confector] Error: %s", result.errorMessage));
                return result;
        }
    }
}

unittest
{
    import std.algorithm.searching : canFind;

    string[] logged;
    StepContext context;
    context.taskId = "compile";
    context.log = (string line) { logged ~= line; };
    auto runner = new BuiltinStepRunner();

    // Steps that are programs fail the task
    BuildStep docker;
    docker.type = "docker:build";
    auto result = runner.run(docker, context);
    assert(!result.success && result.exitCode != 0);
    assert(result.errorMessage.canFind("'docker:build'") && result.errorMessage.canFind("is not supported"));
    assert(logged.length == 1 && logged[0].canFind("is not supported"));

    // Built-in bash and PowerShell are not implemented yet
    foreach (type; ["bash", "powershell"])
    {
        BuildStep script;
        script.type = type;
        string message;
        try runner.run(script, context);
        catch (NotImplementedException e) message = e.msg;
        assert(message == "Built-in bash/PowerShell step is not implemented yet", type);
    }

    // checkout runs the built-in checkout step, which fails here before running git: the step
    // names no input
    BuildStep checkout;
    checkout.type = "checkout";
    auto checkoutResult = runner.run(checkout, context);
    assert(!checkoutResult.success && checkoutResult.errorMessage.canFind("no 'input'"), checkoutResult.errorMessage);
}
