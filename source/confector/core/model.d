module confector.core.model;

public import confector.plugin_api.model;
public import confector.plugin_api.system : StepExecutionResult, StepExecutionContext;

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
    @optional @asName("project_id") string projectId;
    @optional @asName("project_name") string projectName;
    @optional @asName("status") string status = "pending"; // pending, queued, running, succeeded, failed, cached, skipped, cancelled
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("started_at") string startedAt;
    @optional @asName("finished_at") string finishedAt;
    @optional @asName("duration_ms") ulong durationMs = 0;
    @optional @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @optional @asName("upstream_artifact_hashes") string[string] upstreamArtifactHashes;
    @optional @asName("step_results") StepExecutionResult[] stepResults;
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
    @optional @asName("step_results") StepExecutionResult[] stepResults;
    @optional @asName("receipt_handle") string receiptHandle;
}

/**
 * Persisted record of a build execution.
 */
struct BuildRecord
{
    @optional @asName("build_id") string buildId;
    @optional @asName("project_id") string projectId;
    @optional @asName("project_name") string projectName = "default";
    @optional @asName("status") string status = "pending"; // pending, queued, running, succeeded, failed, cached, cancelled
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
 * Authoritative upstream artifact reference for worker staging.
 * Addressed by (taskFingerprint, artifactId) with optional unpack destination.
 */
struct InputArtifactRef
{
    @asName("task_id") string taskId;
    @optional @asName("task_fingerprint") string taskFingerprint;
    @optional @asName("artifact_id") string artifactId;
    @optional @asName("storage_uri") string storageUri;
    @optional @asName("target_path") string targetPath; // deprecated legacy alias
    @optional @asName("destination") string destination;
    @optional @asName("sha256") string sha256;
}

/**
 * Deprecated dual representation retained only for serialization compatibility.
 * New code must use InputArtifactRef via TaskExecutionPayload.inputArtifacts.
 */
struct UpstreamArtifactLocation
{
    @asName("task_id") string taskId;
    @optional @asName("task_fingerprint") string taskFingerprint;
    @optional @asName("artifact_id") string artifactId;
    @optional @asName("artifact_path") string artifactPath;
    @optional @asName("destination") string destination;
    @optional @asName("storage_backend") string storageBackend = "local";
    @optional @asName("storage_uri") string storageUri;
    @optional @asName("sha256") string sha256;
    @optional @asName("target_path") string targetPath;
}

/**
 * Self-contained execution payload for worker tasks.
 */
struct TaskExecutionPayload
{
    @optional @asName("repository_url") string repositoryUrl;
    @optional @asName("commit_sha") string commitSha;
    @optional @asName("allowed_repositories") string[] allowedRepositories;
    @optional @asName("repository_map") string[string] repositoryMap;
    @optional string script;
    @optional string[string] environment;
    /// Single authoritative list of upstream artifacts to unpack before execution.
    @optional @asName("input_artifacts") InputArtifactRef[] inputArtifacts;
    /// Deprecated: no longer populated by coordinator; kept for wire compatibility.
    @optional @asName("upstream_artifact_locations") UpstreamArtifactLocation[] upstreamArtifactLocations;
    /// Map of upstream taskId -> task fingerprint (content-addressed).
    @optional @asName("upstream_artifact_hashes") string[string] upstreamArtifactHashes;
    @optional @asName("expected_outputs") OutputArtifactDecl[] expectedOutputs;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("callback_url") string callbackUrl;
    @optional @asName("node_fingerprint") string nodeFingerprint;
    @optional @asName("force") bool force = false;
}

/**
 * Represents a fully resolved, ready-to-execute work order dispatched to a worker or queue.
 */
struct WorkOrder
{
    @optional @asName("build_id") string buildId;
    @optional @asName("task_id") string taskId;
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("executor_type") string executorType;               // e.g., "local", "queue", "aws-ecs"
    @optional @asName("requirements") string[string] requirements;       // e.g., ["arch": "x86_64", "gpu": "true"]
    @optional @asName("payload") TaskExecutionPayload payload;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional @asName("created_at") string createdAt;
}

/**
 * Message queued for worker consumption wrapping a WorkOrder and tracking queue lease state.
 */
struct TaskQueueMessage
{
    @optional @asName("id") string id;
    @optional @asName("receipt_handle") string receiptHandle;
    @optional @asName("work_order") WorkOrder workOrder;
    @optional @asName("status") string status = "enqueued";              // "enqueued", "claimed", "completed", "failed"
    @optional @asName("locked_by") string lockedBy;
    @optional @asName("lock_expires_at") long lockExpiresAt = 0;
    @optional @asName("retry_count") size_t retryCount = 0;
    @optional @asName("attempt") int attempt = 1;
    @optional @asName("task_node") TaskNode taskNode;
    @optional @asName("max_attempts") size_t maxAttempts = 3;
    @optional @asName("visible_after") long visibleAfterUnix = 0;
    @optional @asName("error_reason") string errorReason;

    // Helper constructor
    this(string id, WorkOrder workOrder, string status = "enqueued", string lockedBy = null, long lockExpiresAt = 0, size_t retryCount = 0) pure nothrow @safe
    {
        this.id = id;
        this.workOrder = workOrder;
        this.status = status;
        this.lockedBy = lockedBy;
        this.lockExpiresAt = lockExpiresAt;
        this.retryCount = retryCount;
        this.attempt = cast(int)retryCount + 1;
    }

    // Convenience properties for backwards compatibility and ease of access
    @ignore @property string messageId() const pure nothrow @safe
    {
        return id;
    }

    @ignore @property void messageId(string val) pure nothrow @safe
    {
        id = val;
    }

    @ignore @property string taskId() const pure nothrow @safe
    {
        return workOrder.taskId;
    }

    @ignore @property void taskId(string val) pure nothrow @safe
    {
        workOrder.taskId = val;
    }

    @ignore @property string buildId() const pure nothrow @safe
    {
        return workOrder.buildId;
    }

    @ignore @property void buildId(string val) pure nothrow @safe
    {
        workOrder.buildId = val;
    }

    @ignore @property string nodeFingerprint() const pure nothrow @safe
    {
        return workOrder.fingerprint;
    }

    @ignore @property void nodeFingerprint(string val) pure nothrow @safe
    {
        workOrder.fingerprint = val;
    }

    @ignore @property string executorType() const pure nothrow @safe
    {
        return workOrder.executorType;
    }

    @ignore @property void executorType(string val) pure nothrow @safe
    {
        workOrder.executorType = val;
    }

    @ignore @property size_t timeoutSeconds() const pure nothrow @safe
    {
        return workOrder.timeoutSeconds;
    }

    @ignore @property void timeoutSeconds(size_t val) pure nothrow @safe
    {
        workOrder.timeoutSeconds = val;
    }

    @ignore @property string createdAt() const pure nothrow @safe
    {
        return workOrder.createdAt;
    }

    @ignore @property void createdAt(string val) pure nothrow @safe
    {
        workOrder.createdAt = val;
    }

    @ignore @property ref TaskExecutionPayload executionPayload() return pure nothrow @safe
    {
        return workOrder.payload;
    }

    @ignore @property const(TaskExecutionPayload) executionPayload() const pure nothrow @safe
    {
        return workOrder.payload;
    }

    @ignore @property void executionPayload(TaskExecutionPayload val) pure nothrow @safe
    {
        workOrder.payload = val;
    }
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
    node.inputs.upstreamArtifacts = [UpstreamArtifactRef("lint", "reports/lint.json", "reports")];
    node.outputs.artifacts = [OutputArtifactDecl("binary", "bin/confector")];
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

    // Test WorkOrder serialization, tag deserialization, and payload wrapping
    WorkOrder wo;
    wo.buildId = "bld_100";
    wo.taskId = "compile";
    wo.fingerprint = "fp_abc123";
    wo.executorType = "local";
    wo.requirements = ["arch": "x86_64", "gpu": "true"];
    wo.timeoutSeconds = 600;
    wo.createdAt = "2026-10-04T12:00:00Z";
    wo.payload.script = "dub build";
    wo.payload.workspaceDir = "/tmp/workspace";
    wo.payload.inputArtifacts = [InputArtifactRef("upstream_task", "fp_upstream", "art_1", "s3://bucket/art_1.tar.gz")];

    Json woJson = serializeToJson(wo);
    assert(woJson["build_id"].get!string == "bld_100");
    assert(woJson["task_id"].get!string == "compile");
    assert(woJson["fingerprint"].get!string == "fp_abc123");
    assert(woJson["executor_type"].get!string == "local");
    assert(woJson["requirements"]["arch"].get!string == "x86_64");
    assert(woJson["requirements"]["gpu"].get!string == "true");
    assert(woJson["payload"]["script"].get!string == "dub build");
    assert(woJson["payload"]["input_artifacts"].length == 1);

    WorkOrder woDeserialized = deserializeJson!WorkOrder(woJson);
    assert(woDeserialized.buildId == "bld_100");
    assert(woDeserialized.taskId == "compile");
    assert(woDeserialized.fingerprint == "fp_abc123");
    assert(woDeserialized.executorType == "local");
    assert(woDeserialized.requirements["arch"] == "x86_64");
    assert(woDeserialized.requirements["gpu"] == "true");
    assert(woDeserialized.timeoutSeconds == 600);
    assert(woDeserialized.payload.script == "dub build");
    assert(woDeserialized.payload.inputArtifacts.length == 1);
    assert(woDeserialized.payload.inputArtifacts[0].taskId == "upstream_task");
    assert(woDeserialized.payload.inputArtifacts[0].taskFingerprint == "fp_upstream");

    // Test TaskQueueMessage wrapping WorkOrder and lease properties
    TaskQueueMessage msg;
    msg.id = "msg_001";
    msg.receiptHandle = "rcpt_999";
    msg.workOrder = wo;
    msg.status = "claimed";
    msg.lockedBy = "worker_node_42";
    msg.lockExpiresAt = 1790000000L;
    msg.retryCount = 2;
    msg.attempt = 3;
    msg.maxAttempts = 5;
    msg.visibleAfterUnix = 1790000030L;
    msg.errorReason = "Temporary worker timeout";

    // Test compatibility accessors
    assert(msg.messageId == "msg_001");
    assert(msg.taskId == "compile");
    assert(msg.buildId == "bld_100");
    assert(msg.nodeFingerprint == "fp_abc123");
    assert(msg.executorType == "local");
    assert(msg.timeoutSeconds == 600);
    assert(msg.executionPayload.script == "dub build");
    assert(msg.retryCount == 2);
    assert(msg.attempt == 3);

    Json msgJson = serializeToJson(msg);
    assert(msgJson["id"].get!string == "msg_001");
    assert(msgJson["status"].get!string == "claimed");
    assert(msgJson["locked_by"].get!string == "worker_node_42");
    assert(msgJson["lock_expires_at"].get!long == 1790000000L);
    assert(msgJson["retry_count"].get!ulong == 2);
    assert(msgJson["work_order"]["build_id"].get!string == "bld_100");

    TaskQueueMessage msgDeserialized = deserializeJson!TaskQueueMessage(msgJson);
    assert(msgDeserialized.id == "msg_001");
    assert(msgDeserialized.receiptHandle == "rcpt_999");
    assert(msgDeserialized.status == "claimed");
    assert(msgDeserialized.lockedBy == "worker_node_42");
    assert(msgDeserialized.lockExpiresAt == 1790000000L);
    assert(msgDeserialized.retryCount == 2);
    assert(msgDeserialized.workOrder.taskId == "compile");
    assert(msgDeserialized.workOrder.requirements["gpu"] == "true");
    assert(msgDeserialized.taskId == "compile");
    assert(msgDeserialized.buildId == "bld_100");
    assert(msgDeserialized.nodeFingerprint == "fp_abc123");
}
