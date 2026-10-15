module confector.plugin_api.model;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

/**
 * Task execution status states.
 */
enum TaskStatus : string
{
    pending = "pending",
    queued = "queued",
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
 * Kinds of declared task input. See AGENTS.md, "The input model".
 */
enum InputKind : string
{
    /// A source repository at a ref; resolved to the provider's pinned value (git: commit SHA).
    repository = "repository",
    /// A literal value; its pinned value is the value itself.
    value = "value",
    /// The outputs of an upstream task; its pinned value is that task's fingerprint.
    /// Graph edges are derived from these inputs.
    taskOutput = "task_output"
}

/**
 * Kind-specific part of an input declaration. Only the fields belonging to the
 * input's kind are set:
 *
 * - `repository`: `repository` (repository id) and `ref` (ref selector string,
 *   interpreted by the provider's resolver).
 * - `value`: `value`.
 * - `task_output`: `task` (upstream task id) and `artifact` (id of one of that task's
 *   declared output artifacts, staged into the workspace before the task runs).
 *   An empty `artifact` depends on the upstream task without staging any of its outputs.
 */
struct InputSpec
{
    @optional string repository;
    @optional @asName("ref") string refSelector;
    @optional string value;
    @optional string task;
    @optional string artifact;
}

/**
 * A declared task input: a kind plus a kind-specific spec. Declared on
 * `TaskNode.inputs`, a map keyed by the input's name; steps refer to inputs by
 * that name.
 */
struct InputDecl
{
    InputKind kind;
    @optional InputSpec spec;
}

/// Declares a repository input: repository `repositoryId` at the ref selected by `refSelector`.
InputDecl repositoryInput(string repositoryId, string refSelector) pure nothrow @safe
{
    InputDecl decl;
    decl.kind = InputKind.repository;
    decl.spec.repository = repositoryId;
    decl.spec.refSelector = refSelector;
    return decl;
}

/// Declares a value input.
InputDecl valueInput(string value) pure nothrow @safe
{
    InputDecl decl;
    decl.kind = InputKind.value;
    decl.spec.value = value;
    return decl;
}

/// Declares a task output input: artifact `artifact` of upstream task `task`
/// (or no artifact, when `artifact` is empty).
InputDecl taskOutputInput(string task, string artifact = null) pure nothrow @safe
{
    InputDecl decl;
    decl.kind = InputKind.taskOutput;
    decl.spec.task = task;
    decl.spec.artifact = artifact;
    return decl;
}

/**
 * A declared input resolved to a pinned value, as frozen in a build chain.
 */
struct ResolvedInput
{
    /// The input's name, as declared on the task.
    string name;
    InputKind kind;
    /// Canonical pinned value; hashed into the fingerprint. Opaque to the core:
    /// each provider defines its own (git: the commit SHA). For a value input it is
    /// the value; for a task output input, the upstream task's fingerprint.
    Json pinned;
    /// Display-only details (branch, URL, commit subject, ...). Never hashed.
    @optional string[string] info;
}

/**
 * Output artifact declaration produced by a task execution.
 */
struct OutputArtifactDecl
{
    @optional @asName("id") string id;
    @optional @asName("path") string path;
    @optional string name;
    @optional string type = "file";

    this(string path) pure nothrow @safe
    {
        this.id = path;
        this.path = path;
        this.name = path;
    }

    this(string id, string path) pure nothrow @safe
    {
        this.id = id;
        this.path = path;
        this.name = id;
    }

    @property string effectiveId() const pure nothrow @safe
    {
        if (id.length > 0) return id;
        if (name.length > 0) return name;
        return path;
    }

    @property string effectivePath() const pure nothrow @safe
    {
        if (path.length > 0) return path;
        if (name.length > 0) return name;
        return id;
    }
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
    /// Declared inputs keyed by input name. Upstream dependencies are task_output inputs.
    @optional InputDecl[string] inputs;
    @optional TaskOutputs outputs;
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

    ArtifactOutputComponent getArtifactOutputComponent() const pure nothrow @safe
    {
        return ArtifactOutputComponent(outputs.artifacts.dup);
    }
}

/**
 * Returns the ids of the upstream tasks named by the task's task_output inputs,
 * sorted and without duplicates.
 */
string[] upstreamTaskIds(in TaskNode task) pure nothrow @safe
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.array : array;

    string[] ids;
    foreach (decl; task.inputs.byValue)
    {
        if (decl.kind == InputKind.taskOutput) ids ~= decl.spec.task;
    }
    ids.sort();
    return ids.uniq.array;
}

/**
 * Returns the repository ids named by the task's repository inputs, sorted and
 * without duplicates.
 */
string[] repositoryIds(in TaskNode task) pure nothrow @safe
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.array : array;

    string[] ids;
    foreach (decl; task.inputs.byValue)
    {
        if (decl.kind == InputKind.repository) ids ~= decl.spec.repository;
    }
    ids.sort();
    return ids.uniq.array;
}

/**
 * Represents outstanding demand for compute capacity from the work queue.
 */
struct QueueDemand
{
    @optional @asName("executor_type") string executorType;
    @optional @asName("requirements") string[string] requirements;
    @optional @asName("pending_work_order_count") size_t pendingWorkOrderCount;

    this(string executorType, size_t pendingWorkOrderCount = 0, string[string] requirements = null) pure nothrow @safe
    {
        this.executorType = executorType;
        this.pendingWorkOrderCount = pendingWorkOrderCount;
        this.requirements = requirements;
    }
}

/**
 * Metadata recorded for stored artifacts.
 */
struct ArtifactMetadata
{
    @optional @asName("artifact_id") string artifactId;
    @optional @asName("task_fingerprint") string taskFingerprint;
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
 * Abstract storage interface for content-addressed artifact streams.
 * Implementations are provided by ArtifactStoragePlugin instances.
 */
interface ArtifactStorage
{
    /**
     * Unique backend identifier (e.g., "local", "s3", "artifactory").
     */
    @property string backendType() const;

    /**
     * Human-readable display name for the storage backend.
     */
    @property string displayName() const;

    /**
     * Short description of the storage backend.
     */
    @property string description() const;

    /**
     * Returns the default configuration as a JSON value.
     */
    JSONValue defaultConfig() const;

    /**
     * Validates a configuration JSON value and returns an array of error messages.
     * Returns an empty array if the configuration is valid.
     */
    string[] validateConfig(in JSONValue config) const;

    /**
     * Renders an HTML form for configuring the artifact storage backend.
     */
    string renderConfigFormHtml(in JSONValue currentConfig) const;

    /**
     * Stores an artifact by streaming bytes from writer into storage, addressed by task fingerprint and artifact ID.
     *
     * Params:
     *   taskFingerprint = Cryptographic fingerprint of the producing task
     *   artifactId = Logical artifact identifier within the task
     *   writer = Delegate that invokes the provided sink with chunks of artifact data
     */
    void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer);

    /**
     * Retrieves an artifact from storage and streams chunks of bytes into sink.
     *
     * Params:
     *   taskFingerprint = Cryptographic fingerprint of the producing task
     *   artifactId = Logical artifact identifier within the task
     *   sink = Delegate that receives chunks of artifact data
     */
    void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink);

    /**
     * Checks if an artifact exists in storage by task fingerprint and artifact ID.
     */
    bool artifactExists(string taskFingerprint, string artifactId);

    /**
     * Deletes an artifact from storage by task fingerprint and artifact ID.
     */
    void deleteArtifact(string taskFingerprint, string artifactId);

    /**
     * Requests a presigned upload URL for an artifact.
     *
     * If the storage backend supports presigned URLs (e.g., S3-compatible), returns the URL.
     * Returns null to indicate the caller should fall back to server-proxied upload.
     *
     * Params:
     *   taskFingerprint = Cryptographic fingerprint of the producing task
     *   artifactId = Logical artifact identifier within the task
     *
     * Returns:
     *   Presigned upload URL, or null if presigned URLs are not supported.
     */
    string presignUpload(string taskFingerprint, string artifactId);

    /**
     * Requests a presigned download URL for an artifact.
     *
     * If the storage backend supports presigned URLs (e.g., S3-compatible), returns the URL.
     * Returns null to indicate the caller should fall back to server-proxied download.
     *
     * Params:
     *   taskFingerprint = Cryptographic fingerprint of the producing task
     *   artifactId = Logical artifact identifier within the task
     *
     * Returns:
     *   Presigned download URL, or null if presigned URLs are not supported.
     */
    string presignDownload(string taskFingerprint, string artifactId);
}

import vibe.data.json;

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
    @optional @asName("receipt_handle") string receiptHandle;
}

/**
 * Result of a task graph or build execution.
 */
struct GraphExecutionResult
{
    string buildId;
    bool success;
    TaskExecutionResult[string] taskResults;
    string[] executedOrder;
}

/**
 * One task as frozen in a build chain when the chain was created (design records: beads
 * confector-z7z.1, confector-z7z.14 and confector-z7z.15): its declared inputs, which fix the
 * graph's edges, and its resolved external inputs. Build configuration (steps, environment,
 * outputs) is not frozen; it is read from the project when the task is dispatched.
 * Fingerprints are not stored either; they are computed from the chain's tasks.
 */
struct ChainTask
{
    @asName("id") string id;
    /// Declared inputs, keyed by input name, as they were when the chain was created.
    @optional @asName("inputs") InputDecl[string] inputs;
    /// Resolved repository and value inputs, sorted by name. Task output inputs are not
    /// stored: they pin to upstream fingerprints, which are computed from the chain.
    @optional @asName("resolved_inputs") ResolvedInput[] resolvedInputs;
}

/**
 * Persisted record of a build execution.
 *
 * Until the BuildRequest/BuildChain split (bead confector-z7z.23.1), a build record is both a
 * request and the chain it runs on: `chainTasks` is the chain snapshot and `chainId` names the
 * build that created it. A later request to build another task of the same chain is a new
 * record carrying the same `chainId` and `chainTasks`, never a re-resolution.
 */
struct BuildRecord
{
    @optional @asName("build_id") string buildId;
    /// The build that created this build's chain; equal to `buildId` for that build.
    @optional @asName("chain_id") string chainId;
    /// The chain snapshot: every task of the project DAG with its declared and resolved inputs.
    @optional @asName("chain_tasks") ChainTask[] chainTasks;
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
    @optional @asName("refresh_policy") string refreshPolicy = "webhook";  // "webhook", "polling", "both"
    @optional @asName("created_at") string createdAt;
}

/**
 * Generic snapshot of a repository's latest revision state.
 * Completely agnostic of VCS backend (Git commit, Perforce changelist, Plastic changeset).
 */
struct VcsRepositoryState
{
    @asName("repository_url") string repositoryUrl;
    @asName("provider_type") string providerType;   // "git", "perforce", "plastic", etc.
    @asName("target_ref") string targetRef;         // branch name, stream path, or depot path
    @asName("revision") string revision;           // commit SHA, changelist number, changeset GUID
    @optional @asName("author") string author;
    @optional @asName("message") string message;
    @optional @asName("updated_at") string updatedAt;
    @optional @asName("metadata") string[string] metadata;
}

/**
 * Persisted record of a detected repository change event.
 */
struct VcsChangeRecord
{
    @asName("id") string id;
    @asName("repository_url") string repositoryUrl;
    @asName("provider_type") string providerType;
    @asName("target_ref") string targetRef;
    @asName("from_revision") string fromRevision;
    @asName("to_revision") string toRevision;
    @asName("detected_at") string detectedAt;
    @asName("trigger_source") string triggerSource; // "webhook", "polling", "manual"
}

/**
 * Persisted record of a project, repository, and task registry.
 */
struct ProjectRecord
{
    @optional @asName("id") string id;
    @optional @asName("name") string name;
    @optional @asName("description") string description;
    @optional @asName("tasks") TaskNode[] tasks;
    @optional @asName("created_at") string createdAt;
    @optional @asName("updated_at") string updatedAt;
}

/**
 * Returns true if any task of the project declares a repository input naming the
 * repository by its id (the repository record's name).
 */
bool projectUsesRepository(const ref ProjectRecord project, const ref RepositoryRecord repo) pure nothrow @safe
{
    import std.algorithm.searching : canFind;

    if (repo.name.length == 0) return false;
    foreach (ref t; project.tasks)
    {
        if (repositoryIds(t).canFind(repo.name)) return true;
    }
    return false;
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
    @optional @asName("destination") string destination;
    @optional @asName("sha256") string sha256;
}


/**
 * Self-contained execution payload for worker tasks.
 */
struct TaskExecutionPayload
{
    @optional @asName("commit_sha") string commitSha;
    @optional @asName("allowed_repositories") string[] allowedRepositories;
    @optional @asName("repository_map") string[string] repositoryMap;
    @optional string[string] environment;
    /// Single authoritative list of upstream artifacts to unpack before execution.
    @optional @asName("input_artifacts") InputArtifactRef[] inputArtifacts;
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
    /// The task definition to execute.
    @optional @asName("task_node") TaskNode taskNode;
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("executor_type") string executorType;               // e.g., "local", "queue", "aws-ecs"
    @optional @asName("requirements") string[string] requirements;       // e.g., ["arch": "x86_64", "gpu": "true"]
    @optional @asName("payload") TaskExecutionPayload payload;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional @asName("created_at") string createdAt;
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

/**
 * Interface for build and task state persistence (caching, status tracking, metadata).
 */
interface BuildStateRepository
{
    /**
     * Returns a short identifier for the backend type (e.g., "mongo", "memory").
     */
    @property string backendType() const;

    /**
     * Records or updates the granular execution record of a task.
     */
    void recordTaskExecution(TaskExecutionRecord record);

    /**
     * Retrieves the granular execution record of a task.
     */
    bool getTaskExecution(string buildId, string taskId, out TaskExecutionRecord record);

    /**
     * Lists recent task executions across all builds with optional filtering.
     */
    TaskExecutionRecord[] listRecentTaskExecutions(size_t limit = 50, string statusFilter = null, string projectIdFilter = null);

    /**
     * Lists execution records for a specific task (optionally scoped to a project).
     */
    TaskExecutionRecord[] listTaskExecutionsForTask(string projectId, string taskId, size_t limit = 20);

    /**
     * Appends a log line to a task's isolated output stream.
     */
    void appendTaskLog(string buildId, string taskId, string line);

    /**
     * Retrieves all log lines for a specific task execution.
     */
    string[] getTaskLogs(string buildId, string taskId);

    /**
     * Retrieves all task execution records for a build.
     */
    TaskExecutionRecord[] getTaskExecutionsForBuild(string buildId);

    /**
     * Retrieves all recorded task statuses for a build.
     */
    TaskStatus[string] getTaskStatusesForBuild(string buildId);

    /**
     * Records or updates the status of a task execution.
     */
    void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null);

    /**
     * Retrieves the recorded status of a task.
     */
    bool getTaskStatus(string buildId, string taskId, out TaskStatus status);

    /**
     * Records a successful execution fingerprint for memoization.
     */
    void saveCachedFingerprint(string taskId, string fingerprint, ArtifactMetadata[] producedArtifacts);

    /**
     * Checks if a cached fingerprint is recorded and returns previously produced artifact metadata.
     */
    bool getCachedFingerprint(string taskId, string fingerprint, out ArtifactMetadata[] producedArtifacts);

    /**
     * Saves or updates a build execution record.
     */
    void recordBuild(BuildRecord build);

    /**
     * Retrieves a build execution record.
     */
    bool getBuild(string buildId, out BuildRecord build);

    /**
     * Lists recent build execution records.
     */
    BuildRecord[] listBuilds(size_t limit = 50);

    /**
     * Appends a log line to a build's execution output stream.
     */
    void appendBuildLog(string buildId, string line);

    /**
     * Retrieves all log lines for a build execution.
     */
    string[] getBuildLogs(string buildId);

    /**
     * Saves a trigger rule configuration.
     */
    void saveTriggerRule(TriggerRuleRecord rule);

    /**
     * Lists configured trigger rules.
     */
    TriggerRuleRecord[] listTriggerRules();

    /**
     * Deletes a configured trigger rule by ID.
     */
    bool deleteTriggerRule(string ruleId);

    /**
     * Saves or updates a project record.
     */
    void saveProject(in ProjectRecord project);

    /**
     * Retrieves a project record by ID.
     */
    bool getProject(string projectId, out ProjectRecord project);

    /**
     * Lists all registered projects.
     */
    ProjectRecord[] listProjects();

    /**
     * Deletes a project record by ID.
     */
    bool deleteProject(string projectId);

    /**
     * Saves or updates a repository record.
     */
    void saveRepository(in RepositoryRecord repo);

    /**
     * Retrieves a repository record by name.
     */
    bool getRepository(string name, out RepositoryRecord repo);

    /**
     * Lists all registered repositories.
     */
    RepositoryRecord[] listRepositories();

    /**
     * Deletes a repository record by name.
     */
    bool deleteRepository(string name);

    /**
     * Saves or updates an executor record.
     */
    void saveExecutor(in WorkerRecord executor);

    /**
     * Retrieves an executor record by ID.
     */
    bool getExecutor(string id, out WorkerRecord executor);

    /**
     * Lists all configured executors.
     */
    WorkerRecord[] listExecutors();

    /**
     * Deletes an executor record by ID.
     */
    bool deleteExecutor(string id);

    /**
     * Saves or updates the latest revision state for a repository.
     */
    void saveRepositoryState(in VcsRepositoryState state);

    /**
     * Retrieves the latest revision state for a repository and target ref.
     */
    bool getRepositoryState(string repositoryUrl, string targetRef, out VcsRepositoryState state);

    /**
     * Records a detected repository change event.
     */
    void recordRepositoryChange(in VcsChangeRecord change);

    /**
     * Lists recent change records for a repository.
     */
    VcsChangeRecord[] listRepositoryChanges(string repositoryUrl, size_t limit = 20);
}

/// Re-export WorkerRecord from executor module so it's available via model
public import confector.plugin_api.executor : WorkerRecord;

unittest
{
    TaskNode node;
    node.id = "test-node";
    node.inputs["src"] = repositoryInput("repo1", "main");
    node.inputs["lib"] = repositoryInput("repo1", "release");
    node.inputs["engine"] = taskOutputInput("build-engine", "engine.zip");
    node.inputs["order"] = taskOutputInput("setup");
    node.inputs["flavor"] = valueInput("external");
    assert(repositoryIds(node) == ["repo1"]);
    assert(upstreamTaskIds(node) == ["build-engine", "setup"]);

    node.setCustomComponent("test", JSONValue("val"));
    assert(node.hasCustomComponent("test"));
    assert(node.getCustomComponent("test").str == "val");
}

unittest
{
    // Inputs round-trip through JSON as a map keyed by name, with snake_case kinds.
    TaskNode node;
    node.id = "package";
    node.inputs["src"] = repositoryInput("game", "main");
    node.inputs["engine"] = taskOutputInput("build-engine", "engine.zip");
    node.inputs["flavor"] = valueInput("external");

    auto json = serializeToJson(node);
    assert(json["inputs"]["src"]["kind"].get!string == "repository");
    assert(json["inputs"]["src"]["spec"]["ref"].get!string == "main");
    assert(json["inputs"]["engine"]["kind"].get!string == "task_output");

    auto back = deserializeJson!TaskNode(json);
    assert(back.inputs == node.inputs);
}
