module confector.plugins.process_runner;

import std.format;
import std.process;
import std.stdio;
import vibe.core.log;

import confector.core.plugin;
import confector.core.executor;

/**
 * Standard local process execution runner plugin.
 * Implements the TaskRunner interface for OS process execution.
 */
class ProcessTaskRunnerPlugin : TaskRunner
{
    @property string name() const { return "process-task-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Standard process execution runner plugin"; }
    @property string runnerType() const { return "process"; }

    void initialize() {}
    void shutdown() {}

    bool canExecute(in ExecutionRequest request) const
    {
        return request.command.length > 0;
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
}

unittest
{
    auto runner = new ProcessTaskRunnerPlugin();
    assert(runner.name == "process-task-runner");
    assert(runner.runnerType == "process");

    ExecutionRequest req;
    req.command = "echo test_runner_output";
    assert(runner.canExecute(req));

    string[] logged;
    auto result = runner.execute(req, (line) @safe {
        // Log callback test
    });
    assert(result.success);
    assert(result.exitCode == 0);
}
