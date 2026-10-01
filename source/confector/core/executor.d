module confector.core.executor;

import confector.core.plugin;
import vibe.data.json : Json;

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
 * Persisted record of a configured executor instance.
 * All new executors default to disabled (`enabled = false`) for safety.
 */
struct ExecutorRecord
{
    string id;
    string name;
    string providerType;
    string description;
    bool enabled = false;
    Json configuration;
    string createdAt;
    string updatedAt;
}

/**
 * Runtime executor instance instantiated from an ExecutorRecord.
 */
interface TaskExecutor
{
    @property string id() const;
    @property string providerType() const;
    @property bool isEnabled() const;
    @property string[] supportedStepTypes() const;
    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null);
}

/**
 * Plugin interface for providing executor types and dynamic sub-template configuration UI.
 */
interface ExecutorProvider
{
    @property string providerType() const;
    @property string displayName() const;
    @property string description() const;
    @property string[] supportedStepTypes() const;

    Json defaultConfig() const;
    string[] validateConfig(in Json config) const;
    string renderConfigFormHtml(in Json currentConfig) const;
    TaskExecutor createExecutor(in ExecutorRecord record) const;
}

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

unittest
{
    ExecutorRecord record;
    record.id = "exec_1";
    record.name = "Local Runner 1";
    record.providerType = "local";
    assert(!record.enabled, "Executors must be disabled by default");

    import vibe.data.json : serializeToJson, deserializeJson;
    record.configuration = Json.emptyObject;
    record.configuration["maxConcurrency"] = 4;
    auto json = serializeToJson(record);
    auto deserialized = deserializeJson!ExecutorRecord(json);
    assert(deserialized.id == "exec_1");
    assert(deserialized.name == "Local Runner 1");
    assert(!deserialized.enabled);
    assert(deserialized.configuration["maxConcurrency"].get!int == 4);
}
