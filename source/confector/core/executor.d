module confector.core.executor;

import confector.core.plugin;

/**
 * Execution request encapsulating execution parameters without tying to a specific runner.
 */
struct ExecutionRequest
{
    string command;
    string[] arguments;
    string workingDirectory;
    string[string] environmentVariables;
    size_t timeoutSeconds = 0;
}

/**
 * Result produced by a task execution.
 */
struct ExecutionResult
{
    int exitCode;
    string[] outputLines;
    bool success;
    string errorMessage;
}

alias LogDelegate = void delegate(string line) @safe;

/**
 * Generic core interface for task runners / executors.
 * Core code interacts exclusively with this interface rather than concrete backends.
 */
interface TaskRunner : Plugin
{
    @property string runnerType() const;
    bool canExecute(in ExecutionRequest request) const;
    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null);
}
