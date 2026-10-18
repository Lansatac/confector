module confector.plugin_api.executor;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

import confector.plugin_api.model : QueueDemand;

/**
 * Delegate callback type for streaming logs from tasks and executors.
 */
alias LogDelegate = void delegate(string message);

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
