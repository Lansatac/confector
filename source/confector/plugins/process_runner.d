module confector.plugins.process_runner;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import vibe.core.log;

import confector.core.model;
import confector.core.plugin;
import confector.core.system : TaskExecutionSystem, BuildStepSystem, BuildStepProvider, StepExecutionContext, StepExecutionResult;
import confector.core.executor;
import vibe.data.json : Json;

/**
 * Standard local process execution runner plugin.
 * Implements TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces for OS process execution.
 */
class ProcessTaskRunnerPlugin : Plugin, TaskRunner, TaskExecutionSystem, BuildStepSystem, BuildStepProvider
{
    @property string name() const { return "process-task-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Standard process execution runner and build step plugin"; }
    @property string runnerType() const { return "process"; }
    @property string systemName() const { return "process-task-runner"; }
    @property string stepType() const { return "process"; }
    @property string displayName() const { return "Process / Script Runner"; }

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
        import std.array : appender;
        import vibe.textfilter.html : htmlEscape;

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

        html.put("<div class=\"step-subform step-subform-process\">\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label>Command / Script to Execute</label>\n");
        html.put("    <textarea name=\"step_script\" class=\"form-control code-font step-field-script\" rows=\"3\" placeholder=\"e.g. echo 'Building...' && dub build\" required>");
        html.put(htmlEscape(script));
        html.put("</textarea>\n");
        html.put("    <small class=\"form-help-text\">Shell command or script executed using the default system shell.</small>\n");
        html.put("  </div>\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label>Working Directory (Optional)</label>\n");
        html.put("    <input type=\"text\" name=\"step_workingDirectory\" class=\"form-control step-field-working-dir\" placeholder=\"Subdirectory or relative path inside workspace\" value=\"");
        html.put(htmlEscape(workingDir));
        html.put("\" />\n");
        html.put("  </div>\n");
        html.put("</div>\n");

        return html.data;
    }

    bool canExecute(in ExecutionRequest request) const
    {
        return request.command.length > 0;
    }

    bool canExecute(in TaskNode task) const
    {
        return task.script.length > 0 || task.hasCustomComponent("process_execution");
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
            || step.type == "script"
            || step.type == "command"
            || step.type == "shell"
            || step.type == "exec"
            || (step.type.length == 0 && (step.script.length > 0 || step.command.length > 0));
    }

    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
    {
        StepExecutionResult res;
        string commandToRun = step.script.length > 0 ? step.script : step.command;
        if (commandToRun.length == 0 && "command" in step.parameters) commandToRun = step.parameters["command"];
        if (commandToRun.length == 0 && "script" in step.parameters) commandToRun = step.parameters["script"];

        if (commandToRun.length == 0)
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = "No script or command specified for process build step";
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

unittest
{
    auto runner = new ProcessTaskRunnerPlugin();
    assert(runner.name == "process-task-runner");
    assert(runner.runnerType == "process");
    assert(runner.systemName == "process-task-runner");
    assert(runner.stepType == "process");

    ExecutionRequest req;
    req.command = "echo test_runner_output";
    assert(runner.canExecute(req));

    TaskNode node;
    node.id = "run-test";
    node.script = "echo test_runner_output";
    assert(runner.canExecute(node));

    string[] logged;
    auto result = runner.executeTask(node, req, (line) @safe {
        // Log callback test
    });
    assert(result.success);
    assert(result.exitCode == 0);

    BuildStep bStep;
    bStep.type = "process";
    bStep.script = "echo build_step_output";
    assert(runner.canExecuteStep(bStep));

    StepExecutionContext sCtx;
    auto sRes = runner.executeStep(bStep, sCtx);
    assert(sRes.success);
    assert(sRes.exitCode == 0);

    // BuildStepProvider testing
    assert(runner.displayName == "Process / Script Runner");
    assert(runner.defaultParameters()["script"].get!string == "");
    auto html = runner.renderStepFormHtml(Json.emptyObject);
    assert(html.length > 0);
    assert(runner.validateParameters(Json.emptyObject).length > 0);

    Json validParams = Json.emptyObject;
    validParams["script"] = "echo 'ok'";
    assert(runner.validateParameters(validParams).length == 0);
}
