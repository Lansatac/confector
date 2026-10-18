module confector.api.model;

import vibe.data.serialization : asName = name, optional;

/**
 * What made a build request (`BuildTrigger.type`).
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
 * A declared input resolved to a pinned value, as a work order carries it.
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
 * An artifact a task declares it produces: the files at `path` (relative to the task's working
 * directory; a glob may match several), stored under the artifact id `id`. Both are required.
 * task_output inputs of downstream tasks name the artifact by `id`.
 */
struct OutputArtifactDecl
{
    string id;
    string path;
}

/**
 * One build step of a task: a step `type` (the built-in `checkout`, `bash` or `powershell`, or
 * a step program; AGENTS.md, "Build steps") and its configuration. `config` is the step type's
 * own JSON object (for checkout: `input`, `target_dir`, `depth`, `submodules`), including any
 * step-level environment or working directory the type supports; its schema belongs to the step
 * type. Absent and empty `config` both mean no settings. `name` is a display label only.
 */
struct BuildStep
{
    @optional string name;
    string type;
    @optional Json config;
}

/**
 * Outputs produced by a task execution.
 */
struct TaskOutputs
{
    @optional OutputArtifactDecl[] artifacts;
}

/**
 * A task of a project's definition: its declared inputs, the steps that build it, the
 * artifacts it produces, its timeout and the environment its steps run with. Graph edges are
 * derived from its task_output inputs.
 */
struct TaskNode
{
    string id;
    @optional string name;
    /// Declared inputs keyed by input name. Upstream dependencies are task_output inputs.
    @optional InputDecl[string] inputs;
    @optional TaskOutputs outputs;
    @optional @asName("steps") BuildStep[] steps;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional string[string] environment;
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
 * Metadata recorded for stored artifacts.
 */
struct ArtifactMetadata
{
    @optional @asName("artifact_id") string artifactId;
    @optional @asName("task_fingerprint") string taskFingerprint;
    @optional @asName("execution_id") string executionId;
    @optional @asName("task_id") string taskId;
    @optional @asName("file_path") string filePath;
    @optional string sha256;
    @optional @asName("size_bytes") ulong sizeBytes;
    @optional @asName("storage_backend") string storageBackend;
    @optional @asName("storage_uri") string storageUri;
    @optional @asName("created_at") string createdAt;
}

/**
 * Thrown by an ArtifactStorage asked to read an artifact it does not hold.
 */
class ArtifactNotFoundException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Thrown by an ArtifactStorage given a fingerprint or artifact id it cannot hold (empty, or
 * containing characters the store does not allow).
 */
class InvalidArtifactKeyException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Abstract storage interface for content-addressed artifact streams. Operations given a key the
 * store cannot hold throw InvalidArtifactKeyException (artifactExists answers false instead);
 * reading an artifact the store does not hold throws ArtifactNotFoundException. Any other
 * exception is a storage failure.
 */
interface ArtifactStorage
{
    /**
     * Unique backend identifier (e.g., "local", "s3", "artifactory").
     */
    @property string backendType() const;

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
 * Result of a single task execution: what a worker reports when it completes an execution.
 *
 * A completion names its execution by id (the worker posts it to
 * `/executions/<execution id>/complete`), and the control plane reads the fingerprint and task
 * from its own execution record (design record: bead confector-z7z.2). The result deliberately
 * has no fingerprint: a worker cannot name the cache key its result is stored under.
 */
struct TaskExecutionResult
{
    /// The task that ran, for logs. The control plane takes the task from the execution record
    /// and rejects a completion naming a different one.
    @optional @asName("task_id") string taskId;
    /// How the execution ended: succeeded, failed or cancelled. Required: a completion without
    /// a status is malformed, and one with an active status is rejected.
    @asName("status") ExecutionStatus status;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @optional @asName("duration_ms") ulong durationMs = 0;
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
    /// The id of the trigger rule that matched; empty for a request made by hand or through the
    /// API. One request is made per matched rule. (How trigger rules are declared is beads
    /// confector-z7z.24.4 and confector-z7z.37.1.)
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
 * A build chain: what the UI calls a build (bead confector-z7z.52). Everything but `labels` and
 * `events` is immutable once created; requests refer to it by id. Its branch context and pinned
 * inputs are bead confector-z7z.53.4.
 */
struct BuildChain
{
    string id;
    @asName("project_id") string projectId;
    /// Canonical per-project number ("build #123"), allocated when the chain is created.
    ulong number;
    @asName("created_at") string createdAt;
    /// User-editable labels, separate from the number.
    @optional string[] labels;
    /// The chain's history, oldest first. Appended to, never rewritten.
    @optional ChainEvent[] events;
}

/**
 * Status of a task execution. Only `queued` and `running` are active; an execution never
 * leaves a terminal status. Whether a chain's task is pending, cached or skipped is not an
 * execution status: it is derived from the chain and its executions, never stored.
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
    /// The task's resolved inputs, sorted by name, as the chain that dispatched the execution
    /// pins them (every chain at one fingerprint pins the same values). Fixed at dispatch; the
    /// work order a worker receives is built from them.
    @optional ResolvedInput[] inputs;
    /// Where to fetch each repository input from, keyed by input name: how to fetch, not what,
    /// so never hashed. Read from the repository records at dispatch and fixed then.
    @optional @asName("repository_addresses") string[string] repositoryAddresses;
    /// When a message for the execution was last sent to the dispatch queue; empty while none has
    /// been. A queued execution that was never sent (its dispatcher failed or crashed between
    /// recording and sending it) is sent again by the dispatcher or the sweep (bead
    /// confector-z7z.49.3).
    @optional @asName("sent_at") string sentAt;
    /// Artifacts the execution produced.
    @optional ArtifactMetadata[] artifacts;
    /// When retention deleted the execution's artifacts (ISO 8601 UTC); empty while they exist. A
    /// succeeded execution with this set is a cache miss, not a cache hit (AGENTS.md, "The caching
    /// contract"). Only a succeeded execution has artifacts to expire.
    @optional @asName("artifacts_expired_at") string artifactsExpiredAt;
    /// The id of the worker that holds or last held it; empty until claimed.
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
}

/**
 * A fully resolved, ready-to-execute work order, as a worker receives it. The dispatch queue
 * never carries one: it carries a DispatchMessage naming the execution, and the control plane
 * builds the work order from the execution's record when a worker receives it
 * (confector.core.work_orders).
 */
struct WorkOrder
{
    /// The execution to run (`TaskExecution.id`). The worker's completion names it; a work order
    /// without one cannot be completed.
    @optional @asName("execution_id") string executionId;
    /// The task definition to execute: its steps, environment and declared outputs.
    @optional @asName("task_node") TaskNode taskNode;
    /// The task's fingerprint, computed by the control plane from the build chain. The runner
    /// stores outputs under it and never computes its own; a work order without one fails.
    @optional @asName("fingerprint") string fingerprint;
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
}

unittest
{
    import std.algorithm.searching : canFind;

    // Steps and output declarations round-trip in their one canonical form: a step is a name, a
    // type and a JSON config object; an output is an id and a path, both required
    TaskNode node;
    node.id = "compile";
    node.steps = [
        BuildStep("Checkout", "checkout", Json(["input": Json("src"), "depth": Json(1)])),
        BuildStep("Compile", "bash"),
    ];
    node.outputs.artifacts = [OutputArtifactDecl("game.zip", "out/game.zip")];

    auto json = serializeToJson(node);
    assert(json["steps"][0]["type"].get!string == "checkout");
    assert(json["steps"][0]["config"]["input"].get!string == "src");
    assert(json["steps"][0]["config"]["depth"].get!long == 1);
    assert(json["outputs"]["artifacts"][0]["id"].get!string == "game.zip");
    assert(json["outputs"]["artifacts"][0]["path"].get!string == "out/game.zip");
    // A step without config stores none
    assert(!json.toString().canFind(`"config":null`) && !json.toString().canFind("undefined"), json.toString());

    auto back = deserializeJson!TaskNode(json.toString());
    assert(back.steps.length == 2 && back.steps[0] == node.steps[0]);
    assert(back.steps[1].config.type == Json.Type.undefined);
    assert(back.outputs.artifacts == node.outputs.artifacts);

    // An output without an id or a path is malformed, not defaulted from the other field
    foreach (malformed; [`{"id": "t", "outputs": {"artifacts": [{"path": "out/x"}]}}`,
                         `{"id": "t", "outputs": {"artifacts": [{"id": "x"}]}}`])
    {
        bool threw = false;
        try deserializeJson!TaskNode(malformed);
        catch (Exception) threw = true;
        assert(threw, malformed);
    }
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
    // A build chain round-trips its number, labels and history
    BuildChain chain;
    chain.id = "c1";
    chain.projectId = "game";
    chain.number = 123;
    chain.createdAt = "2026-10-15T14:02:01Z";
    chain.labels = ["release candidate"];
    chain.events = [ChainEvent(ChainEventKind.rerun, "r2", "release", "base-fingerprint", 1)];

    auto json = serializeToJson(chain);
    assert(json["number"].get!long == 123);
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
        "id": "c1", "project_id": "game", "number": 7, "created_at": "2026-10-15T14:02:01Z"
    }`);
    assert(chain.number == 7);
    assert(chain.labels.length == 0 && chain.events.length == 0);

    // A rerun event without the optional fields of other kinds still reads
    auto withEvent = deserializeJson!BuildChain(`{
        "id": "c1", "project_id": "game", "number": 7,
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
    execution.definition.steps = [BuildStep("Checkout", "checkout", Json(["input": Json("src")])),
        BuildStep("Compile", "bash", Json(["script": Json("make")]))];
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
    assert(json["definition"]["steps"][1]["config"]["script"].get!string == "make");
    assert(roundTrip(execution) == execution);

    // Retention keeps the record and marks when the artifacts went
    TaskExecution expired = execution;
    expired.artifactsExpiredAt = "2026-10-16T09:00:00Z";
    assert(serializeToJson(expired)["artifacts_expired_at"].get!string == "2026-10-16T09:00:00Z");
    assert(roundTrip(expired) == expired);

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
