module confector.core.model;

import std.typecons : Nullable;
import vibe.data.json;
import vibe.data.serialization : asName = name;

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
    TriggerType type;
    string[] branches;
    string[] tags;
    string endpoint;
    string cronSchedule;
    string[string] parameters;
}

/**
 * Event payload representing an incoming trigger dispatch.
 */
struct TriggerEvent
{
    TriggerType type;
    string branch;
    string tag;
    string endpoint;
    string[string] parameters;
    bool force = false;
    string targetTaskId;
}

/**
 * Upstream artifact reference consumed as input by a dependent task.
 */
struct UpstreamArtifactRef
{
    @asName("task_id") string taskId;
    string name;
}

/**
 * Inputs required for a task execution.
 */
struct TaskInputs
{
    string[] files;
    string[] env;
    @asName("upstream_artifacts") UpstreamArtifactRef[] upstreamArtifacts;
    string[string] parameters;
}

/**
 * Output artifact declaration produced by a task execution.
 */
struct OutputArtifactDecl
{
    string path;
    string type = "file";
}

/**
 * Outputs produced by a task execution.
 */
struct TaskOutputs
{
    OutputArtifactDecl[] artifacts;
}

/**
 * Represents a discrete task node in the Directed Acyclic Graph (DAG).
 */
struct TaskNode
{
    string id;
    string name;
    @asName("depends_on") string[] dependsOn;
    TaskInputs inputs;
    TaskOutputs outputs;
    string script;
    TriggerRule[] triggers;
    @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @asName("working_directory") string workingDirectory;
    string[string] environment;
}

/**
 * Root pipeline definition representing the complete DAG specification.
 */
struct PipelineDefinition
{
    @asName("version") string schemaVersion = "1.0";
    TaskNode[] tasks;
}

/**
 * Metadata recorded for stored artifacts.
 */
struct ArtifactMetadata
{
    @asName("artifact_id") string artifactId;
    @asName("build_id") string buildId;
    @asName("task_id") string taskId;
    @asName("file_path") string filePath;
    string sha256;
    @asName("size_bytes") ulong sizeBytes;
    @asName("storage_backend") string storageBackend;
    @asName("storage_uri") string storageUri;
    @asName("created_at") string createdAt;
}

/**
 * Persisted record of a pipeline or build execution.
 */
struct BuildRecord
{
    @asName("build_id") string buildId;
    @asName("pipeline_name") string pipelineName = "default";
    @asName("status") string status = "pending"; // pending, running, succeeded, failed, cached
    @asName("trigger_source") string triggerSource = "manual";
    @asName("target_task_id") string targetTaskId;
    @asName("workspace_dir") string workspaceDir;
    @asName("started_at") string startedAt;
    @asName("finished_at") string finishedAt;
    @asName("duration_ms") ulong durationMs = 0;
    @asName("executed_tasks") string[] executedTasks;
    @asName("error_message") string errorMessage;
}

/**
 * Persisted configuration for a node-level trigger rule.
 */
struct TriggerRuleRecord
{
    @asName("id") string id;
    @asName("name") string name;
    @asName("pipeline_id") string pipelineId = "default";
    @asName("target_task_id") string targetTaskId;
    @asName("trigger_type") string triggerType; // manual, git_push, git_tag, webhook, cron
    @asName("criteria") string criteria; // e.g. branch pattern, cron expression, webhook token
    @asName("force_execution") bool forceExecution = false;
    @asName("enabled") bool enabled = true;
    @asName("created_at") string createdAt;
}

/**
 * Execution plan resolved from DAG and cache status.
 */
struct ExecutionPlan
{
    string[] orderedTaskIds;
    string[] cachedTaskIds;
    string[] toExecuteTaskIds;
}

/**
 * Exception thrown when DAG structure is invalid (e.g. cycles, missing dependencies).
 */
class DAGValidationException : Exception
{
    string[] cycle;
    string[] missingDependencies;

    this(string msg, string[] cycle = null, string[] missingDependencies = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.cycle = cycle;
        this.missingDependencies = missingDependencies;
    }
}

/**
 * Exception thrown during fingerprint calculation.
 */
class FingerprintException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

unittest
{
    import vibe.data.json : serializeToJson, deserializeJson;

    TaskNode node;
    node.id = "build";
    node.name = "Compile Application";
    node.dependsOn = ["lint"];
    node.script = "dub build";
    node.inputs.files = ["source/**/*.d", "dub.json"];
    node.inputs.env = ["DUB_ARGS"];
    node.inputs.upstreamArtifacts = [UpstreamArtifactRef("lint", "reports/lint.json")];
    node.outputs.artifacts = [OutputArtifactDecl("bin/confector", "binary")];
    node.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];

    PipelineDefinition pipeline;
    pipeline.schemaVersion = "1.0";
    pipeline.tasks = [node];

    Json serialized = serializeToJson(pipeline);
    assert(serialized["tasks"].length == 1);
    assert(serialized["tasks"][0]["id"].get!string == "build");

    PipelineDefinition deserialized = deserializeJson!PipelineDefinition(serialized);
    assert(deserialized.tasks.length == 1);
    assert(deserialized.tasks[0].id == "build");
    assert(deserialized.tasks[0].dependsOn == ["lint"]);
    assert(deserialized.tasks[0].inputs.upstreamArtifacts.length == 1);
    assert(deserialized.tasks[0].inputs.upstreamArtifacts[0].taskId == "lint");
}
