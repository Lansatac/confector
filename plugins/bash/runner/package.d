module plugins.bash.runner;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.system : TaskExecutionSystem, BuildStepSystem, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : TaskRunner, ExecutionRequest, ExecutionResult, LogDelegate;

/**
 * Bash script execution plugin.
 * Implements StepExecutionPlugin, TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces for Bash scripts.
 */
class BashRunnerPlugin : StepExecutionPlugin, TaskRunner, TaskExecutionSystem, BuildStepSystem
{
    private PluginContext m_context;

    @property string name() const { return "bash-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Bash script execution and runner plugin"; }
    @property PluginCategory category() const { return PluginCategory.runner; }
    @property string runnerType() const { return "bash"; }
    @property string systemName() const { return "bash-step-system"; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("BashRunnerPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("BashRunnerPlugin shut down");
        }
    }

    bool canExecute(in ExecutionRequest request) const
    {
        return request.command.length > 0;
    }

    bool canExecute(in TaskNode task) const
    {
        if (task.hasCustomComponent("bash")) return true;
        if (task.script.length > 0)
        {
            if (task.hasCustomComponent("shell"))
            {
                auto shellComp = task.getCustomComponent("shell");
                if (shellComp.type == JSONType.string && (shellComp.str == "bash" || shellComp.str == "sh"))
                {
                    return true;
                }
            }
            if (task.hasCustomComponent("runner"))
            {
                auto runnerComp = task.getCustomComponent("runner");
                if (runnerComp.type == JSONType.string && runnerComp.str == "bash")
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
            string[] args = ["bash", "-c", request.command];
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
                result.errorMessage = format("Bash execution exited with code %d", result.exitCode);
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
        return step.type == "bash" || step.type == "sh";
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
            res.errorMessage = "No script or command specified for bash build step";
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

        string bashExecutable = "bash";
        if ("executable" in step.parameters && step.parameters["executable"].length > 0)
        {
            bashExecutable = step.parameters["executable"];
        }

        try
        {
            if (context.logCallback !is null)
            {
                context.logCallback(format("[bash] Running: %s", commandToRun));
            }

            string[] args = [bashExecutable, "-c", commandToRun];
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
                res.errorMessage = format("Bash step execution exited with code %d", res.exitCode);
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

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new BashRunnerPlugin();
}

unittest
{
    auto plugin = new BashRunnerPlugin();
    plugin.initialize(new NullPluginContext("bash-runner"));
    assert(plugin.name == "bash-runner");
    assert(plugin.category == PluginCategory.runner);
    assert(plugin.runnerType == "bash");
    assert(plugin.systemName == "bash-step-system");

    BuildStep bStep;
    bStep.type = "bash";
    bStep.script = "echo 'bash step test'";
    assert(plugin.canExecuteStep(bStep));

    BuildStep shStep;
    shStep.type = "sh";
    shStep.script = "echo 'sh step test'";
    assert(plugin.canExecuteStep(shStep));

    BuildStep procStep;
    procStep.type = "process";
    assert(!plugin.canExecuteStep(procStep));

    TaskNode taskNode;
    taskNode.id = "bash-node";
    taskNode.script = "echo hello";
    assert(!plugin.canExecute(taskNode));

    taskNode.setCustomComponent("shell", JSONValue("bash"));
    assert(plugin.canExecute(taskNode));
}
