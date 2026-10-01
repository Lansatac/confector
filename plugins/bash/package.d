module plugins.bash;

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
 * Bash script execution plugin.
 * Implements TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces for Bash scripts.
 */
class BashPlugin : Plugin, TaskRunner, TaskExecutionSystem, BuildStepSystem, BuildStepProvider
{
    @property string name() const { return "bash-plugin"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Bash script execution build step and runner plugin"; }
    @property string runnerType() const { return "bash"; }
    @property string systemName() const { return "bash-step-system"; }
    @property string stepType() const { return "bash"; }
    @property string displayName() const { return "Bash Script"; }

    void initialize() {}
    void shutdown() {}

    Json defaultParameters() const
    {
        Json p = Json.emptyObject;
        p["script"] = "";
        p["workingDirectory"] = "";
        p["executable"] = "bash";
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
            errors ~= "Bash script or command cannot be empty";
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
        string executable = "bash";

        if (currentParameters.type == Json.Type.object)
        {
            if (auto p = "script" in currentParameters) script = p.get!string;
            else if (auto p = "command" in currentParameters) script = p.get!string;

            if (auto p = "workingDirectory" in currentParameters) workingDir = p.get!string;
            else if (auto p = "working_directory" in currentParameters) workingDir = p.get!string;

            if (auto p = "executable" in currentParameters) executable = p.get!string;
        }

        compileHTMLDietFile!("step.dt", script, workingDir, executable)(html);

        return html.data;
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
                if (shellComp.type == Json.Type.string && (shellComp.get!string == "bash" || shellComp.get!string == "sh"))
                {
                    return true;
                }
            }
            if (task.hasCustomComponent("runner"))
            {
                auto runnerComp = task.getCustomComponent("runner");
                if (runnerComp.type == Json.Type.string && runnerComp.get!string == "bash")
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
    return new BashPlugin();
}

unittest
{
    auto plugin = new BashPlugin();
    assert(plugin.name == "bash-plugin");
    assert(plugin.runnerType == "bash");
    assert(plugin.systemName == "bash-step-system");
    assert(plugin.stepType == "bash");

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

    taskNode.setCustomComponent("shell", Json("bash"));
    assert(plugin.canExecute(taskNode));

    StepExecutionContext sCtx;
    auto sRes = plugin.executeStep(bStep, sCtx);
    assert(sRes.success);
    assert(sRes.exitCode == 0);
    assert(sRes.outputLines.length > 0);

    // Empty script failure handling test
    BuildStep emptyStep;
    emptyStep.type = "bash";
    auto emptyRes = plugin.executeStep(emptyStep, sCtx);
    assert(!emptyRes.success);
    assert(emptyRes.exitCode != 0);

    // BuildStepProvider testing
    assert(plugin.displayName == "Bash Script");
    assert(plugin.defaultParameters()["executable"].get!string == "bash");
    auto html = plugin.renderStepFormHtml(Json.emptyObject);
    assert(html.length > 0);
    assert(plugin.validateParameters(Json.emptyObject).length > 0);

    Json validParams = Json.emptyObject;
    validParams["script"] = "echo 'hello bash'";
    assert(plugin.validateParameters(validParams).length == 0);
}
