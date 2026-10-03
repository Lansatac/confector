module confector.core.model;

public import confector.plugin_api.model;

import std.typecons : Nullable;
import vibe.data.json;
import vibe.data.serialization : asName = name, optional;

/**
 * Persisted record of an individual task execution within a build.
 */
struct TaskExecutionRecord
{
    @optional @asName("task_id") string taskId;
    @optional @asName("build_id") string buildId;
    @optional @asName("status") string status = "pending"; // pending, running, succeeded, failed, cached, skipped, cancelled
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("started_at") string startedAt;
    @optional @asName("finished_at") string finishedAt;
    @optional @asName("duration_ms") ulong durationMs = 0;
    @optional @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @optional @asName("upstream_artifact_hashes") string[string] upstreamArtifactHashes;
}

/**
 * Result of a single task execution.
 */
struct TaskExecutionResult
{
    @optional @asName("task_id") string taskId;
    @optional @asName("build_id") string buildId;
    @optional @asName("status") TaskStatus status = TaskStatus.pending;
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("logs") string[] logs;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @optional @asName("duration_ms") ulong durationMs = 0;
}

/**
 * Persisted record of a build execution.
 */
struct BuildRecord
{
    @optional @asName("build_id") string buildId;
    @optional @asName("project_id") string projectId;
    @optional @asName("project_name") string projectName = "default";
    @optional @asName("status") string status = "pending"; // pending, running, succeeded, failed, cached, cancelled
    @optional @asName("trigger_source") string triggerSource = "manual";
    @optional @asName("target_task_id") string targetTaskId;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("started_at") string startedAt;
    @optional @asName("finished_at") string finishedAt;
    @optional @asName("duration_ms") ulong durationMs = 0;
    @optional @asName("executed_tasks") string[] executedTasks;
    @optional @asName("task_records") TaskExecutionRecord[string] taskRecords;
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
    import std.json : JSONValue;

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

    // Test ECS component helpers
    assert(node.getRepositoryInputComponent().repositories == ["confector-repo", "common-utils"]);
    assert(node.getUpstreamArtifactInputComponent().upstreamArtifacts.length == 1);
    assert(node.getProcessExecutionComponent().script == "dub build");
    assert(node.getArtifactOutputComponent().artifacts.length == 1);

    node.setCustomComponent("s3_source", JSONValue(["bucket": JSONValue("my-bucket"), "key": JSONValue("data.tar.gz")]));
    assert(node.hasCustomComponent("s3_source"));
    assert(node.getCustomComponent("s3_source")["bucket"].str == "my-bucket");
    assert(!node.hasCustomComponent("non_existent"));

    // Test BuildStep on TaskNode
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
    assert(stepNode.steps.length == 2);

    // Test deserializing existing project from Mongo
    import vibe.data.json : parseJsonString;
    string oldMongoJson = `{"_id":{"$oid":"6abdaa639a9dd776c18490f7"},"id":"confector","created_at":"20261001T003339.8549745","default_pipeline_id":"","description":"","name":"Confector","repository_url":"","tasks":[{"id":"confector-test","name":"Test Confector","depends_on":[],"inputs":{"repositories":["confector"],"upstream_artifacts":[],"parameters":{}},"outputs":{"artifacts":[]},"script":"","steps":[{"name":"Clone Repository","type":"clone_repository","parameters":{"repository":"https://github.com/Lansatac/confector.git"},"script":"","command":"","working_directory":"","environment":{},"properties":null},{"name":"Execute Script","type":"bash","parameters":{"executable":"bash"},"script":"dub test","command":"","working_directory":"","environment":{},"properties":null}],"triggers":[],"timeout_seconds":900,"environment":{},"components":{}}],"updated_at":"20261001T003339.8549745"}`;
    Json oldJson = parseJsonString(oldMongoJson);
    ProjectRecord oldProject = deserializeJson!ProjectRecord(oldJson);
    assert(oldProject.id == "confector");
    assert(oldProject.tasks.length == 1);
    assert(oldProject.tasks[0].id == "confector-test");
    assert(oldProject.tasks[0].steps.length == 2);
}
