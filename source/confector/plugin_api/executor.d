module confector.plugin_api.executor;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

/**
 * Delegate callback type for streaming logs from tasks and executors.
 */
alias LogDelegate = void delegate(string message);

/**
 * Request payload for task execution.
 */
struct ExecutionRequest
{
    @optional string taskId;
    @optional string buildId;
    @optional string script;
    @optional string command;
    @optional @asName("working_directory") string workingDirectory;
    @optional string[string] environment;
    @optional @asName("environment_variables") string[string] environmentVariables;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @ignore LogDelegate logCallback;
    @optional @asName("step_types") string[] stepTypes;

    @property string effectiveScript() const
    {
        if (script.length > 0) return script;
        return command;
    }

    @property string[string] effectiveEnvironment() const
    {
        if (environmentVariables.length > 0) return cast(string[string])environmentVariables;
        return cast(string[string])environment;
    }
}

/**
 * Result payload returned from task execution.
 */
struct ExecutionResult
{
    @optional bool success = true;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("output_lines") string[] outputLines;
    @optional @asName("duration_ms") ulong durationMs = 0;
}

/**
 * Task runner interface for execution environments (e.g. bash, powershell).
 */
interface TaskRunner
{
    @property string runnerType() const;
    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null);
}

/**
 * Abstract task executor interface capable of running execution requests.
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
 * Persisted record of a configured task executor.
 */
struct ExecutorRecord
{
    @optional string id;
    @optional string name;
    @optional string description;
    @optional string providerType;
    @optional bool enabled = false;
    @optional @asName("configuration_json") string configurationJson;
    @optional string createdAt;
    @optional string updatedAt;

    JSONValue configuration() const @safe
    {
        if (configurationJson.length == 0) return JSONValue(string[string].init);
        try { return parseJSON(configurationJson); } catch (Exception) { return JSONValue(string[string].init); }
    }

    void configuration(JSONValue val) @safe
    {
        configurationJson = val.toString();
    }
}

/**
 * Provider interface for dynamically creating and configuring task executors.
 */
interface ExecutorProvider
{
    @property string providerType() const;
    @property string displayName() const;
    @property string description() const;
    @property string[] supportedStepTypes() const;

    JSONValue defaultConfig() const;
    string[] validateConfig(in JSONValue config) const;
    string renderConfigFormHtml(in JSONValue currentConfig) const;
    TaskExecutor createExecutor(in ExecutorRecord record);
}

unittest
{
    ExecutorRecord rec;
    rec.id = "e-1";
    rec.name = "Runner";
    rec.providerType = "local";
    assert(!rec.enabled);
    rec.configuration = JSONValue(["key": JSONValue("val")]);
    assert(rec.configuration["key"].str == "val");
}
