module confector.plugins.powershell;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import vibe.core.log;
import vibe.data.json : Json;

import confector.core.model;
import confector.core.plugin;
import confector.core.system : TaskExecutionSystem, BuildStepSystem, StepExecutionContext, StepExecutionResult;
import confector.core.executor : TaskRunner, ExecutionRequest, ExecutionResult, LogDelegate;

/**
 * PowerShell script execution plugin.
 * Implements TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces for PowerShell / pwsh scripts.
 */
class PowerShellPlugin : TaskRunner, TaskExecutionSystem, BuildStepSystem
{
    @property string name() const { return "powershell-plugin"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "PowerShell script execution build step and runner plugin"; }
    @property string runnerType() const { return "powershell"; }
    @property string systemName() const { return "powershell-step-system"; }
    @property string stepType() const { return "powershell"; }

    void initialize() {}
    void shutdown() {}

    private string getExecutable(string stepType = "powershell", in string[string] parameters = null) const
    {
        if (parameters !is null && "executable" in parameters && parameters["executable"].length > 0)
        {
            return parameters["executable"];
        }

        if (stepType == "pwsh")
        {
            return "pwsh";
        }

        version(Windows)
        {
            return "powershell";
        }
        else
        {
            return "pwsh";
        }
    }

    private string[] buildProcessArgs(string executable, string command) const
    {
        version(Windows)
        {
            return [executable, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command];
        }
        else
        {
            return [executable, "-NoProfile", "-NonInteractive", "-Command", command];
        }
    }

    bool canExecute(in ExecutionRequest request) const
    {
        return request.command.length > 0;
    }

    bool canExecute(in TaskNode task) const
    {
        if (task.hasCustomComponent("powershell") || task.hasCustomComponent("pwsh")) return true;
        if (task.script.length > 0)
        {
            if (task.hasCustomComponent("shell"))
            {
                auto shellComp = task.getCustomComponent("shell");
                if (shellComp.type == Json.Type.string &&
                    (shellComp.get!string == "powershell" || shellComp.get!string == "pwsh" || shellComp.get!string == "ps1"))
                {
                    return true;
                }
            }
            if (task.hasCustomComponent("runner"))
            {
                auto runnerComp = task.getCustomComponent("runner");
                if (runnerComp.type == Json.Type.string &&
                    (runnerComp.get!string == "powershell" || runnerComp.get!string == "pwsh"))
                {
                    return true;
                }
            }
        }
        return false;
    }

    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
    {
        ExecutionResult result;
        try
        {
            string executable = getExecutable("powershell");
            string[] args = buildProcessArgs(executable, request.command);

            auto pipe = pipeProcess(args,
                Redirect.stdout | Redirect.stderrToStdout,
                request.environmentVariables.length > 0 ? request.environmentVariables : null,
                Config.retainStderr,
                request.workingDirectory.length > 0 ? request.workingDirectory : null);

            foreach (line; pipe.stdout.byLineCopy)
            {
                result.outputLines ~= line;
                if (logCallback !is null)
                {
                    logCallback(line);
                }
            }

            result.exitCode = wait(pipe.pid);
            result.success = (result.exitCode == 0);
            if (!result.success)
            {
                result.errorMessage = format("PowerShell execution exited with code %d", result.exitCode);
            }
        }
        catch (Exception e)
        {
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = e.msg;
            if (logCallback !is null)
            {
                logCallback(format("Execution error: %s", e.msg));
            }
        }

        return result;
    }

    ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null)
    {
        return execute(request, logCallback);
    }

    bool canExecuteStep(in BuildStep step) const
    {
        return step.type == "powershell" || step.type == "pwsh" || step.type == "ps1";
    }

    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
    {
        StepExecutionResult res;
        string commandToRun = step.script.length > 0 ? step.script : step.command;
        if (commandToRun.length == 0 && "script" in step.parameters) commandToRun = step.parameters["script"];
        if (commandToRun.length == 0 && "command" in step.parameters) commandToRun = step.parameters["command"];

        if (commandToRun.length == 0)
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = "No script or command specified for powershell build step";
            return res;
        }

        string stepWorkingDir = step.workingDirectory.length > 0
            ? (isAbsolute(step.workingDirectory) ? step.workingDirectory : buildPath(context.workingDirectory, step.workingDirectory))
            : context.workingDirectory;

        string[string] stepEnv;
        foreach (k, v; context.environment)
        {
            stepEnv[k] = v;
        }
        foreach (k, v; step.environment)
        {
            stepEnv[k] = v;
        }

        string executable = getExecutable(step.type, step.parameters);

        try
        {
            if (context.logCallback !is null)
            {
                context.logCallback(format("[powershell] Running: %s", commandToRun));
            }

            string[] args = buildProcessArgs(executable, commandToRun);
            auto pipe = pipeProcess(args,
                Redirect.stdout | Redirect.stderrToStdout,
                stepEnv.length > 0 ? stepEnv : null,
                Config.retainStderr,
                stepWorkingDir.length > 0 ? stepWorkingDir : null);

            foreach (line; pipe.stdout.byLineCopy)
            {
                res.outputLines ~= line;
                if (context.logCallback !is null)
                {
                    context.logCallback(line);
                }
            }

            res.exitCode = wait(pipe.pid);
            res.success = (res.exitCode == 0);
            if (!res.success)
            {
                res.errorMessage = format("PowerShell step execution exited with code %d", res.exitCode);
            }
        }
        catch (Exception e)
        {
            res.exitCode = -1;
            res.success = false;
            res.errorMessage = e.msg;
            if (context.logCallback !is null)
            {
                context.logCallback(format("Execution error: %s", e.msg));
            }
        }

        return res;
    }
}

unittest
{
    auto plugin = new PowerShellPlugin();
    assert(plugin.name == "powershell-plugin");
    assert(plugin.runnerType == "powershell");
    assert(plugin.systemName == "powershell-step-system");
    assert(plugin.stepType == "powershell");

    BuildStep psStep;
    psStep.type = "powershell";
    psStep.script = "Write-Output 'powershell step test'";
    assert(plugin.canExecuteStep(psStep));

    BuildStep pwshStep;
    pwshStep.type = "pwsh";
    pwshStep.script = "Write-Output 'pwsh step test'";
    assert(plugin.canExecuteStep(pwshStep));

    BuildStep ps1Step;
    ps1Step.type = "ps1";
    ps1Step.script = "Write-Output 'ps1 step test'";
    assert(plugin.canExecuteStep(ps1Step));

    BuildStep procStep;
    procStep.type = "process";
    assert(!plugin.canExecuteStep(procStep));

    TaskNode taskNode;
    taskNode.id = "powershell-node";
    taskNode.script = "Write-Output hello";
    assert(!plugin.canExecute(taskNode));

    taskNode.setCustomComponent("shell", Json("powershell"));
    assert(plugin.canExecute(taskNode));

    StepExecutionContext sCtx;
    version(Windows)
    {
        auto sRes = plugin.executeStep(psStep, sCtx);
        assert(sRes.success);
        assert(sRes.exitCode == 0);
        assert(sRes.outputLines.length > 0);
    }

    // Empty script failure handling test
    BuildStep emptyStep;
    emptyStep.type = "powershell";
    auto emptyRes = plugin.executeStep(emptyStep, sCtx);
    assert(!emptyRes.success);
    assert(emptyRes.exitCode != 0);
}
