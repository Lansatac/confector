module confector.core.model;

import std.typecons : Nullable;
import vibe.data.json;
import vibe.data.serialization : asName = name, optional;

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
    @optional string cronSchedule;
    @optional string[string] parameters;
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
    @optional string targetTaskId;
}

/**
 * Upstream artifact reference consumed as input by a dependent task.
 */
struct UpstreamArtifactRef
{
    @asName("task_id") string taskId;
    @optional string name;
}

/**
 * Inputs required for a task execution.
 */
struct TaskInputs
{
    @optional string[] files;
    @optional string[] env;
    @optional @asName("upstream_artifacts") UpstreamArtifactRef[] upstreamArtifacts;
    @optional string[string] parameters;
}

/**
 * Output artifact declaration produced by a task execution.
 */
struct OutputArtifactDecl
{
    string path;
    @optional string type = "file";
}

/**
 * Outputs produced by a task execution.
 */
struct TaskOutputs
{
    @optional OutputArtifactDecl[] artifacts;
}

/**
 * Represents a discrete task node in the Directed Acyclic Graph (DAG).
 */
struct TaskNode
{
    string id;
    @optional string name;
    @optional @asName("depends_on") string[] dependsOn;
    @optional TaskInputs inputs;
    @optional TaskOutputs outputs;
    @optional string script;
    @optional TriggerRule[] triggers;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional @asName("working_directory") string workingDirectory;
    @optional string[string] environment;
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
 * Persisted record of a build execution.
 */
struct BuildRecord
{
    @optional @asName("build_id") string buildId;
    @optional @asName("project_id") string projectId;
    @optional @asName("project_name") string projectName = "default";
    @optional @asName("status") string status = "pending"; // pending, running, succeeded, failed, cached
    @optional @asName("trigger_source") string triggerSource = "manual";
    @optional @asName("target_task_id") string targetTaskId;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("started_at") string startedAt;
    @optional @asName("finished_at") string finishedAt;
    @optional @asName("duration_ms") ulong durationMs = 0;
    @optional @asName("executed_tasks") string[] executedTasks;
    @optional @asName("error_message") string errorMessage;
}

/**
 * Persisted configuration for a node-level trigger rule.
 */
struct TriggerRuleRecord
{
    @optional @asName("id") string id;
    @optional @asName("name") string name;
    @optional @asName("project_id") string projectId = "default";
    @optional @asName("target_task_id") string targetTaskId;
    @optional @asName("trigger_type") string triggerType; // manual, git_push, git_tag, webhook, cron
    @optional @asName("criteria") string criteria; // e.g. branch pattern, cron expression, webhook token
    @optional @asName("force_execution") bool forceExecution = false;
    @optional @asName("enabled") bool enabled = true;
    @optional @asName("created_at") string createdAt;
}

/**
 * Persisted record of a project workspace, repository, and task registry.
 */
struct ProjectRecord
{
    @optional @asName("id") string id;
    @optional @asName("name") string name;
    @optional @asName("description") string description;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("repository_url") string repositoryUrl;
    @optional @asName("tasks") TaskNode[] tasks;
    @optional @asName("created_at") string createdAt;
    @optional @asName("updated_at") string updatedAt;
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

    // Test ProjectRecord serialization with Tasks
    ProjectRecord project;
    project.id = "proj-1";
    project.name = "Confector Project";
    project.description = "Self build project";
    project.workspaceDir = ".";
    project.repositoryUrl = "https://github.com/example/confector";
    project.tasks = [node];
    project.createdAt = "2026-09-30T12:00:00Z";
    project.updatedAt = "2026-09-30T12:00:00Z";

    Json projJson = serializeToJson(project);
    assert(projJson["workspace_dir"].get!string == ".");
    assert(projJson["tasks"].length == 1);
    assert(projJson["tasks"][0]["id"].get!string == "build");

    ProjectRecord projDeserialized = deserializeJson!ProjectRecord(projJson);
    assert(projDeserialized.id == "proj-1");
    assert(projDeserialized.workspaceDir == ".");
    assert(projDeserialized.tasks.length == 1);
    assert(projDeserialized.tasks[0].id == "build");
    assert(projDeserialized.tasks[0].dependsOn == ["lint"]);
    assert(projDeserialized.tasks[0].inputs.upstreamArtifacts.length == 1);
    assert(projDeserialized.tasks[0].inputs.upstreamArtifacts[0].taskId == "lint");

    // Test BuildRecord serialization
    BuildRecord bRecord;
    bRecord.buildId = "b-123";
    bRecord.projectId = "proj-1";
    bRecord.projectName = "Confector Project";
    bRecord.targetTaskId = "build";
    bRecord.status = "succeeded";
    Json bJson = serializeToJson(bRecord);
    BuildRecord bDeserialized = deserializeJson!BuildRecord(bJson);
    assert(bDeserialized.buildId == "b-123");
    assert(bDeserialized.projectId == "proj-1");
    assert(bDeserialized.targetTaskId == "build");

    // Test TaskNode array format
    string arrayJsonStr = `[{"id":"task-1","script":"echo hello"}]`;
    Json arrayParsed = parseJsonString(arrayJsonStr);
    TaskNode[] taskArray = deserializeJson!(TaskNode[])(arrayParsed);
    assert(taskArray.length == 1);
    assert(taskArray[0].id == "task-1");
}
