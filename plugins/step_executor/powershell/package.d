module plugins.step_executor.powershell;

import std.format;
import std.process;
import std.stdio;
import std.path : buildPath, isAbsolute;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.system : BuildStepSystem, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : LogDelegate;

/**
 * PowerShell script execution plugin.
 * Implements StepExecutionPlugin and BuildStepSystem interfaces for PowerShell scripts.
 */
class PowerShellRunnerPlugin : StepExecutionPlugin, BuildStepSystem
{
    private PluginContext m_context;

    @property string name() const { return "powershell-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "PowerShell script execution and runner plugin"; }
    @property PluginCategory category() const { return PluginCategory.step_executor; }

    ConfigDefinition[] configDefinitions() const { return null; }
    @property string systemName() const { return "powershell-step-system"; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("PowerShellRunnerPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("PowerShellRunnerPlugin shut down");
        }
    }

    private string[] getPowerShellCommandArgs(string executable, string command) const
    {
        return [executable, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command];
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

        string psExecutable = "powershell";
        version(Posix)
        {
            psExecutable = "pwsh";
        }
        if ("executable" in step.parameters && step.parameters["executable"].length > 0)
        {
            psExecutable = step.parameters["executable"];
        }

        try
        {
            if (context.logCallback !is null)
            {
                context.logCallback(format("[powershell] Running: %s", commandToRun));
            }

            string[] args = getPowerShellCommandArgs(psExecutable, commandToRun);
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
    return new PowerShellRunnerPlugin();
}

unittest
{
    auto plugin = new PowerShellRunnerPlugin();
    plugin.initialize(new NullPluginContext("powershell-runner"));
    assert(plugin.name == "powershell-runner");
    assert(plugin.category == PluginCategory.step_executor);
    assert(plugin.systemName == "powershell-step-system");

    BuildStep psStep;
    psStep.type = "powershell";
    psStep.script = "Write-Output 'ps step test'";
    assert(plugin.canExecuteStep(psStep));

    BuildStep pwshStep;
    pwshStep.type = "pwsh";
    pwshStep.script = "Write-Output 'pwsh step test'";
    assert(plugin.canExecuteStep(pwshStep));

    BuildStep bashStep;
    bashStep.type = "bash";
    assert(!plugin.canExecuteStep(bashStep));
}
