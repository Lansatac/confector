module confector.plugin_api.model;

import std.json : JSONValue, JSONType, parseJSON;
import vibe.data.serialization : asName = name, optional, ignore;

/**
 * Task execution status states, in the build model that BuildChain and TaskExecution replace.
 * ExecutionStatus supersedes it: there, cached and skipped are derived chain task states, not
 * stored statuses.
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
 * The error for a task_output input requesting artifact `artifact` that upstream task
 * `upstreamTask`'s result at `upstreamFingerprint` does not contain. Build configuration is not
 * fingerprinted, so a cached result can predate a change to the task's output declarations;
 * re-running the upstream task is the remedy.
 */
string missingUpstreamArtifactMessage(string upstreamTask, string upstreamFingerprint, string artifact) pure @safe
{
    import std.format : format;

    return format("Upstream task '%s' (fingerprint '%s') has no artifact '%s'; its result predates the artifact's declaration or did not produce it. Re-run task '%s' to produce it",
        upstreamTask, upstreamFingerprint, artifact, upstreamTask);
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
 * A pinned value for a declared input, as a RepositoryResolver returns it or as it is supplied
 * up front (from a trigger payload, an existing chain, or a user's pin).
 */
struct InputPin
{
    /// Canonical pinned value; hashed into fingerprints. Opaque to the core: each provider
    /// defines its own (git: the commit SHA alone, never the URL, branch or checkout path).
    /// Must not be undefined or null.
    Json pinned;
    /// Display-only details (branch, commit subject, author, ...). Never hashed.
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
    /// The task definition the execution ran with, and its hash (`computeDefinitionHash`), so a
    /// result that predates a configuration change can be recognized. Not part of the fingerprint.
    @optional @asName("definition") TaskNode definition;
    @optional @asName("definition_hash") string definitionHash;
}

/**
 * What a cache hit reuses: the artifacts a successful execution produced and the task
 * definition (with its hash) that execution ran with, so a result resolved from the cache
 * still shows the configuration it was built with.
 */
struct CachedResult
{
    @optional ArtifactMetadata[] artifacts;
    @optional @asName("definition") TaskNode definition;
    @optional @asName("definition_hash") string definitionHash;
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
 * Persisted record of a build execution, in the build model that BuildRequest, BuildChain,
 * TaskExecution and FingerprintClaim replace. It is removed with the BuildCoordinator (bead
 * confector-z7z.23.10).
 *
 * A build record is both a request and the chain it runs on: `chainTasks` is the chain
 * snapshot and `chainId` names the build that created it. A later request to build another
 * task of the same chain is a new record carrying the same `chainId` and `chainTasks`, never a
 * re-resolution.
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

// The build model (design records: beads confector-z7z.14, confector-z7z.15 and confector-z7z.2;
// AGENTS.md, "What a build is"). A request joins or creates a chain; chain state is derived from
// the chain, its requests, the rerun generations and the executions for its fingerprints, and is
// never stored. Each type is stored as its own document. Timestamps are ISO 8601 UTC strings
// (`SysTime.toISOExtString` of a UTC time). They do not sort as text, because toISOExtString
// leaves out zero fractional seconds: parse them to compare.

/**
 * What a build request asks for. See AGENTS.md, "What a build is" and "Re-running a task".
 */
enum BuildIntent : string
{
    /// Build the targets and their upstream tasks, reusing every result the cache allows.
    build = "build",
    /// Run failed or cancelled targets again in the same chain, at the same fingerprints.
    retry = "retry",
    /// Stop using the target's succeeded result: bump its rerun generation, so it and every task
    /// downstream of it get new fingerprints, in every chain sharing its base fingerprint.
    rerun = "rerun"
}

/**
 * What made a build request.
 */
struct BuildTrigger
{
    TriggerType type;
    /// The trigger rule that matched (`TriggerRuleRecord.id`); empty for a request made by hand
    /// or through the API. One request is made per matched rule.
    @optional @asName("rule_id") string ruleId;
    /// Event details as the trigger source reported them (ref, revision, sender, ...), for
    /// display and audit only: what the trigger pins is in `BuildRequest.pins`.
    @optional string[string] payload;
}

/**
 * A pinned value supplied with a build request, from the trigger payload or a user, for the
 * repository input `input`. Resolution takes it as given instead of resolving the input live.
 */
struct RequestPin
{
    /// The repository input it pins, reduced to its kind, repository id and ref selector
    /// (`repositoryInputKey`), so it pins that repository at that ref for every task.
    InputDecl input;
    InputPin pin;
}

/**
 * Who asked for what (bead confector-z7z.14). Immutable: written once, after the input
 * resolver has found or created the chain the request runs on.
 */
struct BuildRequest
{
    string id;
    @asName("project_id") string projectId;
    /// The chain the request joined or created.
    @asName("chain_id") string chainId;
    /// The task ids to build. The request also runs their upstream tasks, never downstream ones.
    /// A rerun names exactly the task to rerun.
    string[] targets;
    BuildIntent intent;
    BuildTrigger trigger;
    /// Pins for repository inputs, at most one per repository input, applied when the request
    /// created its chain. A request that joined an existing chain resolved nothing.
    @optional RequestPin[] pins;
    /// The identity that made the request: a user, an API token, or the trigger source.
    @asName("requested_by") string requestedBy;
    @asName("requested_at") string requestedAt;
}

/**
 * Kinds of event in a chain's history.
 */
enum ChainEventKind : string
{
    /// A task sharing a base fingerprint with one of the chain's tasks was rerun; the chain's
    /// earlier result for it is superseded. Reruns are recorded on every affected chain.
    rerun = "rerun"
}

/**
 * One entry in a chain's history: something that changed what the chain uses after it was
 * created. Who caused it and when are not repeated here: they are the `requestedBy` and
 * `requestedAt` of the BuildRequest that `requestId` names.
 */
struct ChainEvent
{
    ChainEventKind kind;
    /// The request that caused the event. For a rerun it may belong to another chain.
    @asName("request_id") string requestId;
    /// The chain's task the event concerns. rerun: the task whose result is superseded.
    @asName("task_id") string taskId;
    /// rerun: the base fingerprint whose generation was bumped, and the generation it was
    /// bumped to.
    @optional string base;
    @optional ulong generation;
}

/**
 * A snapshot of a project's whole DAG (beads confector-z7z.14 and confector-z7z.15); what the
 * UI calls a build. Everything but `labels` and `events` is immutable once created. The chain
 * stores every task's declared and resolved external inputs once; requests refer to it by id.
 * Fingerprints are not stored: they are computed from `tasks` and the current rerun
 * generations (`chainResolution`).
 */
struct BuildChain
{
    string id;
    @asName("project_id") string projectId;
    /// Canonical per-project number ("build #123"), allocated when the chain is created.
    ulong number;
    /// The join key: a request whose resolution has this hash joins the chain instead of
    /// creating one. Stored so the join can find the chain by index query.
    @asName("snapshot_hash") string snapshotHash;
    /// Every task of the project's DAG when the chain was created, sorted by id
    /// (`freezeChain`).
    ChainTask[] tasks;
    @asName("created_at") string createdAt;
    /// User-editable labels, separate from the number.
    @optional string[] labels;
    /// The chain's history, oldest first. Appended to, never rewritten.
    @optional ChainEvent[] events;
}

/**
 * Status of a task execution. Only `queued` and `running` are active; an execution never
 * leaves a terminal status.
 *
 * Supersedes TaskStatus in the new build model. TaskStatus's other states are not execution
 * states: whether a chain's task is pending, cached or skipped is derived from the chain and
 * its executions, never stored.
 */
enum ExecutionStatus : string
{
    /// Recorded and dispatched; no worker has claimed it yet, or its last worker was lost and
    /// it waits for another attempt.
    queued = "queued",
    /// A worker holds it.
    running = "running",
    succeeded = "succeeded",
    /// The task failed, or infrastructure failures used up its attempts. Never retried
    /// automatically and never a cache hit.
    failed = "failed",
    /// Stopped on request. Never a cache hit.
    cancelled = "cancelled"
}

/**
 * One run of one task at one fingerprint ("task run" in the UI; bead confector-z7z.14).
 * Append-only and shared across chains: records are never overwritten by another execution,
 * and a cache hit is a chain using an execution another chain produced. A terminal execution
 * does not change again.
 */
struct TaskExecution
{
    string id;
    @asName("project_id") string projectId;
    @asName("task_id") string taskId;
    /// Computed by the control plane from the chain, never reported by a worker.
    string fingerprint;
    ExecutionStatus status;
    /// How many times a worker has claimed the execution. Infrastructure failures (a lost
    /// worker, an expired lease, a queue redelivery) retry within the same execution up to an
    /// admin-configured limit; a user's retry is a new execution.
    ulong attempts;
    /// The full task definition the execution ran with, read from the project when it was
    /// dispatched, and its hash (`computeDefinitionHash`). Not part of the fingerprint.
    TaskNode definition;
    @asName("definition_hash") string definitionHash;
    /// Artifacts the execution produced.
    @optional ArtifactMetadata[] artifacts;
    /// The worker that holds or last held it (`WorkerRecord.id`); empty until claimed.
    @optional string worker;
    @asName("created_at") string createdAt;
    /// When the current attempt started, and when the execution reached a terminal status.
    @optional @asName("started_at") string startedAt;
    @optional @asName("finished_at") string finishedAt;
    /// The exit code of the task's steps; meaningful only when `status` is succeeded or failed
    /// and the task ran to completion. An infrastructure failure or cancellation has no exit
    /// code: read `status` and `errorMessage`.
    @optional @asName("exit_code") int exitCode;
    @optional @asName("error_message") string errorMessage;
}

/**
 * The claim on a fingerprint (bead confector-z7z.2): at most one active (queued or running)
 * execution per fingerprint, enforced by compare-and-set on the document's version, with the
 * fingerprint as the document id. A dispatcher claims a fingerprint by setting
 * `executionId`; a loser re-reads and does nothing. A claim is released by clearing
 * `executionId`, never by removing the document, so its version only grows and a writer
 * holding an older version always loses.
 */
struct FingerprintClaim
{
    /// The claimed fingerprint; mirrors the document id.
    string fingerprint;
    /// The fingerprint's active execution; empty when it has none.
    @optional @asName("execution_id") string executionId;
}

/**
 * Kinds of ref a tracked branch can be (bead confector-z7z.19).
 */
enum RefKind : string
{
    branch = "branch",
    tag = "tag",
    /// A pull request, merge request, code review or shelf, as its provider exposes it.
    changeRequest = "change_request"
}

/**
 * Whether a tracked branch still exists in its repository. A deleted branch is hidden and no
 * longer triggers, but its record and history are kept.
 */
enum BranchStatus : string
{
    active = "active",
    deleted = "deleted"
}

/**
 * A ref of a repository that Confector tracks (bead confector-z7z.19), independent of the
 * version control system: git branches, Plastic branches and Perforce streams all map onto it.
 * Kept current by webhooks and polling. Identified by repository, kind and ref name, which never
 * change.
 */
struct TrackedBranch
{
    /// The repository's id (`RepositoryRecord.name`).
    @asName("repository_id") string repositoryId;
    RefKind kind;
    /// The ref's name as the provider reports it, e.g. `main` or `pull/123`.
    @asName("ref_name") string refName;
    /// The provider's pinned value for the ref's current head (git: the commit SHA), with
    /// display details.
    InputPin head;
    BranchStatus status;
    /// When the ref was last seen by a webhook or poll (ISO 8601 UTC).
    @asName("last_seen_at") string lastSeenAt;
}

/**
 * Global roles (bead confector-z7z.10). Per-project permissions come later.
 */
enum Role : string
{
    /// No role, granting nothing. First, so an identity or token whose role was never set fails
    /// closed; never stored on a token.
    none = "none",
    admin = "admin",
    member = "member",
    viewer = "viewer"
}

/**
 * An API token (bead confector-z7z.10). Only a hash of the token's secret is stored, never the
 * secret itself; the hash identifies the token, so authenticating a request is a read by id.
 */
struct ApiToken
{
    /// SHA-256 of the secret, in lowercase hex.
    @asName("secret_hash") string secretHash;
    /// A label chosen by its owner.
    string name;
    /// The identity that owns the token; requests made with it act as this identity.
    string owner;
    Role role;
    @asName("created_at") string createdAt;
    /// Set when the token is revoked; a revoked token authenticates nothing.
    @optional @asName("revoked_at") string revokedAt;
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
 * Self-contained execution payload for worker tasks.
 *
 * Inputs reach the runner only as the work order's task declares them (`WorkOrder.taskNode.inputs`)
 * and as `inputs` pins them; nothing else names a repository or revision.
 */
struct TaskExecutionPayload
{
    /// The task's resolved inputs, one per declared input, sorted by name, as the build chain
    /// pins them: a repository input's provider pinned value (git: the commit SHA), a value
    /// input's value, and a task_output input's upstream task fingerprint, which addresses the
    /// upstream artifacts its declaration names.
    @optional @asName("inputs") ResolvedInput[] inputs;
    /// Address to fetch each repository input from, keyed by input name: exactly the task's
    /// repository inputs. How to fetch, not what; never hashed. Used only by the built-in
    /// checkout step.
    @optional @asName("repository_addresses") string[string] repositoryAddresses;
    @optional string[string] environment;
    @optional @asName("expected_outputs") OutputArtifactDecl[] expectedOutputs;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("callback_url") string callbackUrl;
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
    /// The task's fingerprint, computed by the control plane from the build chain. The runner
    /// stores outputs under it and never computes its own; a work order without one fails.
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

version (unittest)
{
    /// Serializes `value` to JSON text and back, as the state store stores documents.
    private T roundTrip(T)(T value)
    {
        return deserializeJson!T(serializeToJson(value).toString());
    }
}

unittest
{
    // A build request round-trips, pins included, with snake_case names and string intents
    BuildRequest request;
    request.id = "r1";
    request.projectId = "game";
    request.chainId = "c1";
    request.targets = ["internal", "tests"];
    request.intent = BuildIntent.build;
    request.trigger = BuildTrigger(TriggerType.gitPush, "rule-1", ["ref": "refs/heads/main", "revision": "aaa111"]);
    request.pins = [RequestPin(repositoryInput("game", "main"), InputPin(Json("aaa111"), ["subject": "Fix the build"]))];
    request.requestedBy = "webhook:github";
    request.requestedAt = "2026-10-15T14:02:00Z";

    auto json = serializeToJson(request);
    assert(json["intent"].get!string == "build");
    assert(json["trigger"]["type"].get!string == "git_push");
    assert(json["trigger"]["rule_id"].get!string == "rule-1");
    assert(json["pins"][0]["input"]["spec"]["ref"].get!string == "main");
    assert(json["requested_by"].get!string == "webhook:github");
    assert(roundTrip(request) == request);

    // A rerun request made by hand: no rule, no payload, no pins
    BuildRequest rerun;
    rerun.id = "r2";
    rerun.projectId = "game";
    rerun.chainId = "c1";
    rerun.targets = ["release"];
    rerun.intent = BuildIntent.rerun;
    rerun.trigger.type = TriggerType.manual;
    rerun.requestedBy = "jason";
    rerun.requestedAt = "2026-10-15T15:00:00Z";
    assert(serializeToJson(rerun)["intent"].get!string == "rerun");
    assert(roundTrip(rerun) == rerun);
}

unittest
{
    // A build chain round-trips its frozen tasks, number, join key, labels and history
    BuildChain chain;
    chain.id = "c1";
    chain.projectId = "game";
    chain.number = 123;
    chain.snapshotHash = "0123abcd";
    ChainTask compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", "main");
    compile.resolvedInputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["branch": "main"])];
    ChainTask release;
    release.id = "release";
    release.inputs["bin"] = taskOutputInput("compile", "game.zip");
    release.inputs["flavor"] = valueInput("external");
    release.resolvedInputs = [ResolvedInput("flavor", InputKind.value, Json("external"))];
    chain.tasks = [compile, release];
    chain.createdAt = "2026-10-15T14:02:01Z";
    chain.labels = ["release candidate"];
    chain.events = [ChainEvent(ChainEventKind.rerun, "r2", "release", "base-fingerprint", 1)];

    auto json = serializeToJson(chain);
    assert(json["number"].get!long == 123);
    assert(json["snapshot_hash"].get!string == "0123abcd");
    assert(json["tasks"][0]["resolved_inputs"][0]["pinned"].get!string == "aaa111");
    assert(json["events"][0]["kind"].get!string == "rerun");
    assert(json["events"][0]["request_id"].get!string == "r2");
    assert(json["events"][0]["task_id"].get!string == "release");
    assert(json["events"][0]["generation"].get!long == 1);
    assert(roundTrip(chain) == chain);

    // A new chain has no labels or history yet: both serialize as empty arrays and read back
    // empty
    BuildChain fresh = chain;
    fresh.labels = null;
    fresh.events = null;
    auto freshJson = serializeToJson(fresh);
    assert(freshJson["labels"].type == Json.Type.array && freshJson["labels"].length == 0);
    assert(freshJson["events"].type == Json.Type.array && freshJson["events"].length == 0);
    auto freshBack = roundTrip(fresh);
    assert(freshBack.labels.length == 0 && freshBack.events.length == 0);
    assert(freshBack.tasks == chain.tasks);
}

unittest
{
    // Hand-written documents deserialize, with every optional field left out
    auto request = deserializeJson!BuildRequest(`{
        "id": "r1", "project_id": "game", "chain_id": "c1", "targets": ["internal"],
        "intent": "retry", "trigger": {"type": "manual"},
        "requested_by": "jason", "requested_at": "2026-10-15T14:02:00Z"
    }`);
    assert(request.intent == BuildIntent.retry && request.trigger.type == TriggerType.manual);
    assert(request.trigger.ruleId.length == 0 && request.trigger.payload.length == 0);
    assert(request.pins.length == 0 && request.targets == ["internal"]);

    // A pin without display info
    auto pinned = deserializeJson!BuildRequest(`{
        "id": "r2", "project_id": "game", "chain_id": "c2", "targets": ["internal"],
        "intent": "build", "trigger": {"type": "git_push", "rule_id": "rule-1", "payload": {"ref": "main"}},
        "pins": [{"input": {"kind": "repository", "spec": {"repository": "game", "ref": "main"}},
                  "pin": {"pinned": "aaa111"}}],
        "requested_by": "webhook:github", "requested_at": "2026-10-15T14:02:00Z"
    }`);
    assert(pinned.pins.length == 1 && pinned.pins[0].input == repositoryInput("game", "main"));
    assert(pinned.pins[0].pin.pinned == Json("aaa111") && pinned.pins[0].pin.info.length == 0);
    assert(pinned.trigger.payload == ["ref": "main"]);

    auto chain = deserializeJson!BuildChain(`{
        "id": "c1", "project_id": "game", "number": 7, "snapshot_hash": "abc",
        "tasks": [{"id": "compile", "inputs": {"src": {"kind": "repository", "spec": {"repository": "game", "ref": "main"}}},
                   "resolved_inputs": [{"name": "src", "kind": "repository", "pinned": "aaa111"}]},
                  {"id": "lint"}],
        "created_at": "2026-10-15T14:02:01Z"
    }`);
    assert(chain.number == 7 && chain.tasks.length == 2);
    assert(chain.tasks[0].resolvedInputs[0].pinned == Json("aaa111") && chain.tasks[0].resolvedInputs[0].info.length == 0);
    assert(chain.tasks[1].inputs.length == 0 && chain.tasks[1].resolvedInputs.length == 0);
    assert(chain.labels.length == 0 && chain.events.length == 0);

    // A rerun event without the optional fields of other kinds still reads
    auto withEvent = deserializeJson!BuildChain(`{
        "id": "c1", "project_id": "game", "number": 7, "snapshot_hash": "abc", "tasks": [],
        "created_at": "2026-10-15T14:02:01Z", "labels": ["rc"],
        "events": [{"kind": "rerun", "request_id": "r2", "task_id": "compile", "base": "b", "generation": 2}]
    }`);
    assert(withEvent.labels == ["rc"]);
    assert(withEvent.events == [ChainEvent(ChainEventKind.rerun, "r2", "compile", "b", 2)]);

    auto execution = deserializeJson!TaskExecution(`{
        "id": "e1", "project_id": "game", "task_id": "compile", "fingerprint": "fp1",
        "status": "queued", "attempts": 0, "definition": {"id": "compile"},
        "definition_hash": "def1", "created_at": "2026-10-15T14:02:02Z"
    }`);
    assert(execution.status == ExecutionStatus.queued && execution.attempts == 0);
    assert(execution.definition.id == "compile" && execution.definition.steps.length == 0);
    assert(execution.artifacts.length == 0 && execution.worker.length == 0);
    assert(execution.startedAt.length == 0 && execution.finishedAt.length == 0);
    assert(execution.exitCode == 0 && execution.errorMessage.length == 0);

    // A required field left out fails loudly rather than defaulting
    bool threw = false;
    try deserializeJson!TaskExecution(`{"id": "e1", "project_id": "game", "task_id": "compile", "status": "queued"}`);
    catch (Exception) threw = true;
    assert(threw, "A missing fingerprint must not deserialize");
}

unittest
{
    // A task execution round-trips its definition, artifacts and timestamps
    TaskExecution execution;
    execution.id = "e1";
    execution.projectId = "game";
    execution.taskId = "compile";
    execution.fingerprint = "fp1";
    execution.status = ExecutionStatus.succeeded;
    execution.attempts = 2;
    execution.definition.id = "compile";
    execution.definition.inputs["src"] = repositoryInput("game", "main");
    execution.definition.steps = [BuildStep("Checkout", "checkout", ["input": "src"]), BuildStep("Compile", "bash", null, "make")];
    execution.definition.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];
    execution.definitionHash = "def1";
    ArtifactMetadata artifact;
    artifact.artifactId = "game.zip";
    artifact.taskFingerprint = "fp1";
    artifact.sha256 = "abc";
    artifact.sizeBytes = 1024;
    artifact.storageBackend = "local";
    execution.artifacts = [artifact];
    execution.worker = "worker-1";
    execution.createdAt = "2026-10-15T14:02:02Z";
    execution.startedAt = "2026-10-15T14:03:00Z";
    execution.finishedAt = "2026-10-15T14:09:00Z";

    auto json = serializeToJson(execution);
    assert(json["status"].get!string == "succeeded");
    assert(json["attempts"].get!long == 2);
    assert(json["definition_hash"].get!string == "def1");
    assert(json["definition"]["steps"][1]["script"].get!string == "make");
    assert(roundTrip(execution) == execution);

    // A failed execution keeps its exit code and error; a queued one has no worker or times yet
    TaskExecution failed = execution;
    failed.status = ExecutionStatus.failed;
    failed.artifacts = null;
    failed.exitCode = 2;
    failed.errorMessage = "make: *** [all] Error 2";
    assert(roundTrip(failed) == failed);

    TaskExecution queued;
    queued.id = "e2";
    queued.projectId = "game";
    queued.taskId = "compile";
    queued.fingerprint = "fp2";
    queued.status = ExecutionStatus.queued;
    queued.definition.id = "compile";
    queued.definitionHash = "def1";
    queued.createdAt = "2026-10-15T14:02:02Z";
    assert(roundTrip(queued) == queued);
}

unittest
{
    // A fingerprint claim round-trips with and without an active execution
    auto claimed = FingerprintClaim("fp1", "e1");
    assert(serializeToJson(claimed)["execution_id"].get!string == "e1");
    assert(roundTrip(claimed) == claimed);

    auto released = FingerprintClaim("fp1");
    assert(roundTrip(released) == released);
    assert(deserializeJson!FingerprintClaim(`{"fingerprint": "fp1"}`) == released);
}

unittest
{
    // A tracked branch and an API token round-trip with snake_case names and string enums
    TrackedBranch branch;
    branch.repositoryId = "game";
    branch.kind = RefKind.changeRequest;
    branch.refName = "pull/12";
    branch.head = InputPin(Json("aaa111"), ["subject": "Fix the build"]);
    branch.status = BranchStatus.active;
    branch.lastSeenAt = "2026-10-15T14:02:00Z";
    auto branchJson = serializeToJson(branch);
    assert(branchJson["repository_id"].get!string == "game");
    assert(branchJson["kind"].get!string == "change_request");
    assert(branchJson["ref_name"].get!string == "pull/12");
    assert(branchJson["head"]["pinned"].get!string == "aaa111");
    assert(branchJson["last_seen_at"].get!string == "2026-10-15T14:02:00Z");
    assert(roundTrip(branch) == branch);

    ApiToken token;
    token.secretHash = "0123abcd";
    token.name = "ci";
    token.owner = "jason";
    token.role = Role.admin;
    token.createdAt = "2026-10-15T14:02:00Z";
    auto tokenJson = serializeToJson(token);
    assert(tokenJson["secret_hash"].get!string == "0123abcd");
    assert(tokenJson["role"].get!string == "admin");
    assert(roundTrip(token) == token);
    auto unrevoked = deserializeJson!ApiToken(`{"secret_hash": "h", "name": "ci", "owner": "jason", "role": "viewer", "created_at": "2026-10-15T14:02:00Z"}`);
    assert(unrevoked.role == Role.viewer && unrevoked.revokedAt.length == 0);
    assert(ApiToken.init.role == Role.none, "An unset role grants nothing");
}
