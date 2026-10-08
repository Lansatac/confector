module plugins.step_executor.bash;

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
 * Bash script execution plugin.
 * Implements StepExecutionPlugin and BuildStepSystem interfaces for Bash scripts.
 */
class BashRunnerPlugin : StepExecutionPlugin, BuildStepSystem
{
    private PluginContext m_context;

    @property string name() const { return "bash-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Bash script execution and runner plugin"; }
    @property PluginCategory category() const { return PluginCategory.step_executor; }

    ConfigDefinition[] configDefinitions() const { return null; }
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
    assert(plugin.category == PluginCategory.step_executor);
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
}
