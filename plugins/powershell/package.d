module plugins.powershell;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import std.json : JSONValue, JSONType, parseJSON;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.system : TaskExecutionSystem, BuildStepSystem, BuildStepProvider, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : TaskRunner, ExecutionRequest, ExecutionResult, LogDelegate;

/**
 * PowerShell script execution plugin.
 * Implements TaskRunner, TaskExecutionSystem, and BuildStepSystem interfaces for PowerShell scripts.
 */
class PowerShellPlugin : Plugin, TaskRunner, TaskExecutionSystem, BuildStepSystem, BuildStepProvider
{
    private PluginContext m_context;

    @property string name() const { return "powershell-plugin"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "PowerShell script execution build step and runner plugin"; }
    @property string runnerType() const { return "powershell"; }
    @property string systemName() const { return "powershell-step-system"; }
    @property string stepType() const { return "powershell"; }
    @property string displayName() const { return "PowerShell Script"; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("PowerShellPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("PowerShellPlugin shut down");
        }
    }

    JSONValue defaultParameters() const
    {
        string defaultExe;
        version(Windows)
        {
            defaultExe = "powershell";
        }
        else
        {
            defaultExe = "pwsh";
        }
        JSONValue p = JSONValue(["script": JSONValue(""), "workingDirectory": JSONValue(""), "executable": JSONValue(defaultExe)]);
        return p;
    }

    string[] validateParameters(in JSONValue parameters) const
    {
        string[] errors;
        if (parameters.type != JSONType.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }
        auto pScript = "script" in parameters;
        auto pCommand = "command" in parameters;
        if ((pScript is null || pScript.str.length == 0) &&
            (pCommand is null || pCommand.str.length == 0))
        {
            errors ~= "PowerShell script or command cannot be empty";
        }
        return errors;
    }

    string renderStepFormHtml(in JSONValue currentParameters) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;
        string script = "";
        string workingDir = "";
        string executable = "";
        version(Windows)
        {
            executable = "powershell";
        }
        else
        {
            executable = "pwsh";
        }

        if (currentParameters.type == JSONType.object)
        {
            if (auto p = "script" in currentParameters) script = p.str;
            else if (auto p = "command" in currentParameters) script = p.str;

            if (auto p = "workingDirectory" in currentParameters) workingDir = p.str;
            else if (auto p = "working_directory" in currentParameters) workingDir = p.str;

            if (auto p = "executable" in currentParameters) executable = p.str;
        }

        compileHTMLDietFile!("step.dt", script, workingDir, executable)(html);

        return html.data;
    }

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
                if (shellComp.type == JSONType.string &&
                    (shellComp.str == "powershell" || shellComp.str == "pwsh" || shellComp.str == "ps1"))
                {
                    return true;
                }
            }
            if (task.hasCustomComponent("runner"))
            {
                auto runnerComp = task.getCustomComponent("runner");
                if (runnerComp.type == JSONType.string &&
                    (runnerComp.str == "powershell" || runnerComp.str == "pwsh"))
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
            string exec = getExecutable("powershell");
            string[] args = buildProcessArgs(exec, request.command);
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
        return step.type == "powershell"
            || step.type == "pwsh"
            || step.type == "ps1";
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
            res.errorMessage = "No script or command specified for PowerShell build step";
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

        string psExecutable = getExecutable(step.type, step.parameters);

        try
        {
            if (context.logCallback !is null)
            {
                context.logCallback(format("[%s] Running: %s", psExecutable, commandToRun));
            }

            string[] args = buildProcessArgs(psExecutable, commandToRun);
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

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new PowerShellPlugin();
}

unittest
{
    auto plugin = new PowerShellPlugin();
    plugin.initialize(new NullPluginContext("powershell-plugin"));
    assert(plugin.name == "powershell-plugin");
    assert(plugin.runnerType == "powershell");
    assert(plugin.systemName == "powershell-step-system");
    assert(plugin.stepType == "powershell");

    BuildStep bStep;
    bStep.type = "powershell";
    bStep.script = "Write-Output 'powershell step test'";
    assert(plugin.canExecuteStep(bStep));

    BuildStep pwshStep;
    pwshStep.type = "pwsh";
    pwshStep.script = "Write-Output 'pwsh step test'";
    assert(plugin.canExecuteStep(pwshStep));

    BuildStep procStep;
    procStep.type = "process";
    assert(!plugin.canExecuteStep(procStep));

    TaskNode taskNode;
    taskNode.id = "powershell-node";
    taskNode.script = "Write-Output hello";
    assert(!plugin.canExecute(taskNode));

    taskNode.setCustomComponent("shell", JSONValue("powershell"));
    assert(plugin.canExecute(taskNode));

    StepExecutionContext sCtx;
    auto sRes = plugin.executeStep(bStep, sCtx);
    assert(sRes.success);
    assert(sRes.exitCode == 0);
    assert(sRes.outputLines.length > 0);

    // Empty script failure handling test
    BuildStep emptyStep;
    emptyStep.type = "powershell";
    auto emptyRes = plugin.executeStep(emptyStep, sCtx);
    assert(!emptyRes.success);
    assert(emptyRes.exitCode != 0);

    // BuildStepProvider testing
    assert(plugin.displayName == "PowerShell Script");
    assert(plugin.defaultParameters()["executable"].str.length > 0);
    auto html = plugin.renderStepFormHtml(JSONValue(string[string].init));
    assert(html.length > 0);
    assert(plugin.validateParameters(JSONValue(string[string].init)).length > 0);

    JSONValue validParams = JSONValue(["script": JSONValue("Write-Output 'hello powershell'")]);
    assert(plugin.validateParameters(validParams).length == 0);
}
