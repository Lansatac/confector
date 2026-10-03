module confector.plugin_api.model;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

/**
 * Task execution status states.
 */
enum TaskStatus : string
{
    pending = "pending",
    running = "running",
    succeeded = "succeeded",
    failed = "failed",
    cached = "cached",
    skipped = "skipped",
    cancelled = "cancelled"
}

/**
 * Supported trigger types.
 */
enum TriggerType : string
{
    manual = "manual",
    gitPush = "git_push",
    gitTag = "git_tag",
    webhook = "webhook",
    cron = "cron"
}

/**
 * Specification for a trigger rule defined on a task node.
 */
struct TriggerRule
{
    @optional TriggerType type;
    @optional string[] branches;
    @optional string[] tags;
    @optional string endpoint;
    @optional @asName("cron_schedule") string cronSchedule;
    @optional string[string] parameters;
    @optional @asName("force_execution") bool forceExecution = false;

    this(TriggerType type, string[] branches = null, string[] tags = null, string endpoint = null, string cronSchedule = null, bool forceExecution = false) pure nothrow @safe
    {
        this.type = type;
        this.branches = branches;
        this.tags = tags;
        this.endpoint = endpoint;
        this.cronSchedule = cronSchedule;
        this.forceExecution = forceExecution;
    }
}

/**
 * Event payload representing an incoming trigger dispatch.
 */
struct TriggerEvent
{
    @optional TriggerType type;
    @optional string branch;
    @optional string tag;
    @optional string endpoint;
    @optional string[string] parameters;
    @optional bool force = false;
    @optional @asName("target_task_id") string targetTaskId;
}

/**
 * Upstream artifact reference consumed as input by a dependent task.
 */
struct UpstreamArtifactRef
{
    @asName("task_id") string taskId;
    @optional string name;
    @optional string path;
    @optional string destination;

    this(string taskId, string name = null) pure nothrow @safe
    {
        this.taskId = taskId;
        this.name = name;
        this.path = name;
    }
}

/**
 * Specific repository configuration for VCS inputs.
 */
struct RepositoryInput
{
    @optional string url;
    @optional string branch;
    @optional @asName("target_dir") string targetDir;
}

/**
 * Inputs required for a task execution.
 */
struct TaskInputs
{
    @optional string[] repositories;
    @optional @asName("repository_configs") RepositoryInput[] repositoryConfigs;
    @optional @asName("upstream_artifacts") UpstreamArtifactRef[] upstreamArtifacts;
    @optional string[string] parameters;
}

/**
 * Output artifact declaration produced by a task execution.
 */
struct OutputArtifactDecl
{
    string path;
    @optional string name;
    @optional string type = "file";

    this(string path, string type = "file") pure nothrow @safe
    {
        this.path = path;
        this.name = path;
        this.type = type;
    }
}

/**
 * Repository input component data.
 */
struct RepositoryInputComponent
{
    @optional string[] repositories;
    @optional string address;
    @optional @asName("target_directory") string targetDirectory;
    @optional string branch;
    @optional string tag;
}

/**
 * Upstream artifact input component data.
 */
struct UpstreamArtifactInputComponent
{
    @optional @asName("upstream_artifacts") UpstreamArtifactRef[] upstreamArtifacts;
}

/**
 * Represents an individual plugin-defined build step within a TaskNode.
 */
struct BuildStep
{
    @optional string name;
    string type;
    @optional string[string] parameters;
    @optional string script;
    @optional string command;
    @optional @asName("working_directory") string workingDirectory;
    @optional string[string] environment;
    @optional @asName("properties") string propertiesJson;

    this(string name, string type, string[string] parameters = null, string script = null, string command = null, string workingDirectory = null, string propertiesJson = null) pure nothrow @safe
    {
        this.name = name;
        this.type = type;
        this.parameters = parameters;
        this.script = script;
        this.command = command;
        this.workingDirectory = workingDirectory;
        this.propertiesJson = propertiesJson;
    }

    JSONValue properties() const @safe
    {
        if (propertiesJson.length == 0) return JSONValue(null);
        try { return parseJSON(propertiesJson); } catch (Exception) { return JSONValue(propertiesJson); }
    }

    void properties(JSONValue val) @safe
    {
        propertiesJson = val.toString();
    }
}

/**
 * Parameter input component data.
 */
struct ParameterInputComponent
{
    @optional string[string] parameters;
}

/**
 * Process execution component data.
 */
struct ProcessExecutionComponent
{
    @optional string script;
    @optional string command;
    @optional string[] arguments;
    @optional string[string] environment;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
}

/**
 * Artifact output component data.
 */
struct ArtifactOutputComponent
{
    @optional OutputArtifactDecl[] artifacts;
}

/**
 * Trigger rule component data.
 */
struct TriggerRuleComponent
{
    @optional TriggerRule[] rules;
}

/**
 * Outputs produced by a task execution.
 */
struct TaskOutputs
{
    @optional OutputArtifactDecl[] artifacts;
}

/**
 * Represents a discrete task node in the Directed Acyclic Graph (DAG)
 * modeled as an entity with composable components.
 */
struct TaskNode
{
    string id;
    @optional string name;
    @optional @asName("depends_on") string[] dependsOn;
    @optional TaskInputs inputs;
    @optional TaskOutputs outputs;
    @optional string script;
    @optional @asName("steps") BuildStep[] steps;
    @optional TriggerRule[] triggers;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional string[string] environment;
    @optional string[string] components;

    bool hasCustomComponent(string componentName) const @safe
    {
        if (components is null) return false;
        return (componentName in components) !is null;
    }

    JSONValue getCustomComponent(string componentName) const @safe
    {
        if (components is null) return JSONValue(null);
        if (auto p = componentName in components)
        {
            try
            {
                return parseJSON(*p);
            }
            catch (Exception)
            {
                return JSONValue(*p);
            }
        }
        return JSONValue(null);
    }

    void setCustomComponent(string componentName, JSONValue data) @safe
    {
        components[componentName] = data.toString();
    }

    RepositoryInputComponent getRepositoryInputComponent() const pure nothrow @safe
    {
        return RepositoryInputComponent(inputs.repositories.dup);
    }

    UpstreamArtifactInputComponent getUpstreamArtifactInputComponent() const pure nothrow @safe
    {
        return UpstreamArtifactInputComponent(inputs.upstreamArtifacts.dup);
    }

    ProcessExecutionComponent getProcessExecutionComponent() const pure nothrow @safe
    {
        ProcessExecutionComponent comp;
        comp.script = script;
        comp.timeoutSeconds = timeoutSeconds;
        foreach (k, v; environment)
        {
            comp.environment[k] = v;
        }
        return comp;
    }

    ArtifactOutputComponent getArtifactOutputComponent() const pure nothrow @safe
    {
        return ArtifactOutputComponent(outputs.artifacts.dup);
    }
}

/**
 * Metadata recorded for stored artifacts.
 */
struct ArtifactMetadata
{
    @optional @asName("artifact_id") string artifactId;
    @optional @asName("build_id") string buildId;
    @optional @asName("task_id") string taskId;
    @optional @asName("file_path") string filePath;
    @optional string sha256;
    @optional @asName("size_bytes") ulong sizeBytes;
    @optional @asName("storage_backend") string storageBackend;
    @optional @asName("storage_uri") string storageUri;
    @optional @asName("created_at") string createdAt;
}

/**
 * Abstract storage interface for artifacts.
 */
interface ArtifactStorage
{
    ArtifactMetadata storeArtifact(string buildId, string taskId, string localFilePath, string artifactType = "file");
    void retrieveArtifact(string buildId, string taskId, string artifactPath, string targetLocalPath);
    bool artifactExists(string buildId, string taskId, string artifactPath);
    bool getArtifactMetadata(string buildId, string taskId, string artifactPath, out ArtifactMetadata metadata);
}

unittest
{
    TaskNode node;
    node.id = "test-node";
    node.inputs.repositories = ["repo1"];
    assert(node.getRepositoryInputComponent().repositories == ["repo1"]);

    node.setCustomComponent("test", JSONValue("val"));
    assert(node.hasCustomComponent("test"));
    assert(node.getCustomComponent("test").str == "val");
}
