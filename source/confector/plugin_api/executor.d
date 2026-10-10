module confector.plugin_api.executor;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

import confector.plugin_api.model : QueueDemand;

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
 * Status or state of a provisioned worker or compute resource.
 */
enum WorkerStatus : string
{
    idle = "idle",
    provisioning = "provisioning",
    running = "running",
    terminated = "terminated",
    error = "error"
}

/**
 * Abstract compute instance / task executor interface capable of running execution requests.
 */
interface ComputeInstance
{
    @property string id() const;
    @property string providerType() const;
    @property bool isEnabled() const;
    @property string[] supportedStepTypes() const;
    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null);
}

/**
 * Persisted record of a configured worker pool or compute provider instance.
 */
struct WorkerRecord
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
 * Worker / Compute Provider interface responsible for provisioning compute infrastructure,
 * worker fleet lifecycle management, credential injection, and configuration rendering.
 */
interface ComputeProvider
{
    @property string providerType() const;
    @property string displayName() const;
    @property string description() const;
    @property string[] supportedStepTypes() const;

    JSONValue defaultConfig() const;
    string[] validateConfig(in JSONValue config) const;
    string renderConfigFormHtml(in JSONValue currentConfig) const;
    ComputeInstance createExecutor(in WorkerRecord record);
    ComputeProvisioner createProvisioner(in WorkerRecord record);
}

/**
 * Plugin interface for provisioning compute capacity on demand (e.g., local subprocesses,
 * ECS tasks, Kubernetes Jobs, AWS Lambda).
 */
interface ComputeProvisioner
{
    @property string providerType() const;
    bool canProvision(in QueueDemand demand) const;
    void requestCapacity(in QueueDemand demand);
    @property size_t activeInstanceCount() const;
    @property size_t maxCapacity() const;
}

/**
 * Server-side broker coordinating capacity across registered provisioners.
 */
interface CapacityBroker
{
    void registerProvisioner(ComputeProvisioner provisioner);
    void evaluateDemand();
    @property size_t activeInstanceCount() const;
    @property size_t maxCapacity() const;
    @property ComputeProvisioner[] provisioners();
}

/**
 * Interface for queue consumers / worker pools managing task execution lifecycle.
 */
interface WorkerPool
{
    void start();
    void stop();
    @property size_t activeTaskCount() const;
    @property size_t maxConcurrentTasks() const;
}

unittest
{
    WorkerRecord rec;
    rec.id = "e-1";
    rec.name = "Runner";
    rec.providerType = "local";
    assert(!rec.enabled);
    rec.configuration = JSONValue(["key": JSONValue("val")]);
    assert(rec.configuration["key"].str == "val");
}
