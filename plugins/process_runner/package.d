module plugins.process_runner;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import vibe.core.log;
import vibe.data.json : Json;

import confector.core.model;
import confector.core.plugin;
import confector.core.system : TaskExecutionSystem, BuildStepSystem, BuildStepProvider, StepExecutionContext, StepExecutionResult;
import confector.core.executor : TaskRunner, ExecutionRequest, ExecutionResult, LogDelegate;

/**
 * Built-in ProcessRunner plugin.
 * Implements TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces using system processes.
 */
class ProcessRunnerPlugin : Plugin, TaskRunner, TaskExecutionSystem, BuildStepSystem, BuildStepProvider
{
    @property string name() const { return "process-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Executes build tasks and steps as local child processes"; }
    @property string runnerType() const { return "process"; }
    @property string systemName() const { return "process-execution-system"; }
    @property string stepType() const { return "process"; }
    @property string displayName() const { return "Process Command"; }

    void initialize() {}
    void shutdown() {}

    Json defaultParameters() const
    {
        Json p = Json.emptyObject;
        p["script"] = "";
        p["workingDirectory"] = "";
        return p;
    }

    string[] validateParameters(in Json parameters) const
    {
        string[] errors;
        if (parameters.type != Json.Type.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }
        auto pScript = "script" in parameters;
        auto pCommand = "command" in parameters;
        if ((pScript is null || pScript.get!string.length == 0) &&
            (pCommand is null || pCommand.get!string.length == 0))
        {
            errors ~= "Command or script cannot be empty";
        }
        return errors;
    }

    string renderStepFormHtml(in Json currentParameters) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;
        string script = "";
        string workingDir = "";

        if (currentParameters.type == Json.Type.object)
        {
            if (auto p = "script" in currentParameters) script = p.get!string;
            else if (auto p = "command" in currentParameters) script = p.get!string;

            if (auto p = "workingDirectory" in currentParameters) workingDir = p.get!string;
            else if (auto p = "working_directory" in currentParameters) workingDir = p.get!string;
        }

        compileHTMLDietFile!("step.dt", script, workingDir)(html);

        return html.data;
    }

    bool canExecute(in ExecutionRequest request) const
    {
        return request.command.length > 0;
    }

    bool canExecute(in TaskNode task) const
    {
        return task.script.length > 0 || task.hasCustomComponent("process_runner");
    }

    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
    {
        ExecutionResult result;
        try
        {
            auto pipe = pipeShell(request.command,
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
                result.errorMessage = format("Process exited with code %d", result.exitCode);
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
        return step.type == "process"
            || step.type == "command"
            || step.type == "script"
            || step.type == "shell";
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
            res.errorMessage = "No command or script specified for build step";
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

        try
        {
            if (context.logCallback !is null)
            {
                context.logCallback(format("[process] Running: %s", commandToRun));
            }

            auto pipe = pipeShell(commandToRun,
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
                res.errorMessage = format("Step execution exited with code %d", res.exitCode);
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

/// Alias for backwards compatibility with legacy imports
alias ProcessTaskRunnerPlugin = ProcessRunnerPlugin;

unittest
{
    auto plugin = new ProcessRunnerPlugin();
    assert(plugin.name == "process-runner");
    assert(plugin.runnerType == "process");
    assert(plugin.systemName == "process-execution-system");
    assert(plugin.stepType == "process");

    BuildStep bStep;
    bStep.type = "process";
    bStep.script = "echo 'hello process step'";
    assert(plugin.canExecuteStep(bStep));

    BuildStep scriptStep;
    scriptStep.type = "script";
    scriptStep.script = "echo 'hello script step'";
    assert(plugin.canExecuteStep(scriptStep));

    BuildStep unknownStep;
    unknownStep.type = "unsupported_xyz";
    assert(!plugin.canExecuteStep(unknownStep));

    StepExecutionContext sCtx;
    auto sRes = plugin.executeStep(bStep, sCtx);
    assert(sRes.success);
    assert(sRes.exitCode == 0);
    assert(sRes.outputLines.length > 0);

    // Empty command failure handling test
    BuildStep emptyStep;
    emptyStep.type = "process";
    auto emptyRes = plugin.executeStep(emptyStep, sCtx);
    assert(!emptyRes.success);
    assert(emptyRes.exitCode != 0);

    // BuildStepProvider testing
    assert(plugin.displayName == "Process Command");
    assert(plugin.defaultParameters()["script"].get!string == "");
    auto html = plugin.renderStepFormHtml(Json.emptyObject);
    assert(html.length > 0);
    assert(plugin.validateParameters(Json.emptyObject).length > 0);

    Json validParams = Json.emptyObject;
    validParams["script"] = "echo 'valid command'";
    assert(plugin.validateParameters(validParams).length == 0);
}
