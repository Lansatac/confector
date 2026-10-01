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
    @optional string[] repositories;
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
 * Repository input component data.
 */
struct RepositoryInputComponent
{
    @optional string[] repositories;
    @optional string address;
    @optional string targetDirectory;
    @optional string branch;
    @optional string tag;
}

/**
 * Upstream artifact input component data.
 */
struct UpstreamArtifactInputComponent
{
    @optional UpstreamArtifactRef[] upstreamArtifacts;
}

/**
 * Represents an individual plugin-defined build step within a TaskNode.
 */
struct BuildStep
{
    @optional string name;
    string type; // e.g. "clone_repository", "git_clone", "script", "command"
    @optional string[string] parameters;
    @optional string script;
    @optional string command;
    @optional @asName("working_directory") string workingDirectory;
    @optional string[string] environment;
    @optional Json properties;
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
    @optional size_t timeoutSeconds = 900;
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
    @optional Json[string] components;

    bool hasCustomComponent(string componentName) const @safe
    {
        if (components is null) return false;
        return (componentName in components) !is null;
    }

    Json getCustomComponent(string componentName) const @safe
    {
        if (components is null) return Json.undefined;
        auto p = componentName in components;
        return p !is null ? *p : Json.undefined;
    }

    void setCustomComponent(string componentName, Json data) @safe
    {
        components[componentName] = data;
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
 * Persisted record of a repository.
 */
struct RepositoryRecord
{
    @optional @asName("name") string name;
    @optional @asName("address") string address;
    @optional @asName("created_at") string createdAt;
}

/**
 * Persisted record of a project, repository, and task registry.
 */
struct ProjectRecord
{
    @optional @asName("id") string id;
    @optional @asName("name") string name;
    @optional @asName("description") string description;
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
    node.inputs.repositories = ["confector-repo", "common-utils"];
    node.inputs.upstreamArtifacts = [UpstreamArtifactRef("lint", "reports/lint.json")];
    node.outputs.artifacts = [OutputArtifactDecl("bin/confector", "binary")];
    node.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];

    // Test ProjectRecord serialization with Tasks
    ProjectRecord project;
    project.id = "proj-1";
    project.name = "Confector Project";
    project.description = "Self build project";
    project.repositoryUrl = "https://github.com/example/confector";
    project.tasks = [node];
    project.createdAt = "2026-09-30T12:00:00Z";
    project.updatedAt = "2026-09-30T12:00:00Z";

    Json projJson = serializeToJson(project);
    assert(projJson["tasks"].length == 1);
    assert(projJson["tasks"][0]["id"].get!string == "build");

    ProjectRecord projDeserialized = deserializeJson!ProjectRecord(projJson);
    assert(projDeserialized.id == "proj-1");
    assert(projDeserialized.tasks.length == 1);
    assert(projDeserialized.tasks[0].id == "build");
    assert(projDeserialized.tasks[0].dependsOn == ["lint"]);
    assert(projDeserialized.tasks[0].inputs.repositories == ["confector-repo", "common-utils"]);
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

    // Test ECS component helpers
    assert(node.getRepositoryInputComponent().repositories == ["confector-repo", "common-utils"]);
    assert(node.getUpstreamArtifactInputComponent().upstreamArtifacts.length == 1);
    assert(node.getProcessExecutionComponent().script == "dub build");
    assert(node.getArtifactOutputComponent().artifacts.length == 1);

    node.setCustomComponent("s3_source", Json(["bucket": Json("my-bucket"), "key": Json("data.tar.gz")]));
    assert(node.hasCustomComponent("s3_source"));
    assert(node.getCustomComponent("s3_source")["bucket"].get!string == "my-bucket");
    assert(!node.hasCustomComponent("non_existent"));

    // Test BuildStep serialization on TaskNode
    TaskNode stepNode;
    stepNode.id = "pipeline-task";
    BuildStep step1;
    step1.name = "Clone Code";
    step1.type = "clone_repository";
    step1.parameters = ["repository": "https://github.com/example/repo.git", "branch": "main"];
    BuildStep step2;
    step2.name = "Build App";
    step2.type = "process";
    step2.script = "dub build";
    stepNode.steps = [step1, step2];

    Json stepNodeJson = serializeToJson(stepNode);
    TaskNode deserializedStepNode = deserializeJson!TaskNode(stepNodeJson);
    assert(deserializedStepNode.steps.length == 2);
    assert(deserializedStepNode.steps[0].type == "clone_repository");
    assert(deserializedStepNode.steps[0].parameters["repository"] == "https://github.com/example/repo.git");
    assert(deserializedStepNode.steps[1].type == "process");
    assert(deserializedStepNode.steps[1].script == "dub build");
}
