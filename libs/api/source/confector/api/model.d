module confector.api.model;

import vibe.data.serialization : asName = name, optional;

import std.format : format;
import std.typecons : Nullable;

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

// The ref grammar (AGENTS.md, "Branches"). Branch filters
// and ref specs are plain data with a compact text form, which is also how they are stored
// (vibe.d serializes a type with `toString` and `fromString` as a string). Tokens are separated by
// whitespace, so neither a pattern nor a ref name can contain whitespace.

/**
 * A branch filter or ref spec whose text is not well formed.
 */
class InvalidRefSpecException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * One rule of a branch filter: include (`+:`) or exclude (`-:`) the refs whose name matches
 * `pattern`. In a pattern `*` matches any run of characters, `/` included; every other character
 * matches only itself, case-sensitively.
 */
struct BranchRule
{
    bool include;
    string pattern;
}

/**
 * Which refs of a repository may be used (a visibility filter): include/exclude rules written
 * `+:<pattern>` and `-:<pattern>`, for example `+:* -:experimental/*`. A ref is visible when it
 * matches at least one include rule and no exclude rule (`refVisible`); the order of the rules
 * does not matter. The empty filter (no rules, the text "") hides nothing. A filter with rules
 * must have an include rule: one of only exclude rules would hide every ref, so it is refused.
 *
 * Text form: the rules separated by spaces, as written.
 */
struct BranchFilter
{
    BranchRule[] rules;

    /// Whether the filter has no rules, and so hides nothing.
    bool isEmpty() const pure nothrow @safe
    {
        return rules.length == 0;
    }

    /// The filter's text form: its rules separated by single spaces; "" for the empty filter.
    string toString() const pure @safe
    {
        import std.array : join;

        string[] parts;
        foreach (rule; rules) parts ~= (rule.include ? "+:" : "-:") ~ rule.pattern;
        return parts.join(" ");
    }

    /**
     * Parses a filter's text form. Blank text is the empty filter.
     *
     * Throws: InvalidRefSpecException if a token is not `+:<pattern>` or `-:<pattern>` with a
     * pattern, or the filter has rules but no include rule.
     */
    static BranchFilter fromString(string text) pure @safe
    {
        import std.array : split;

        BranchFilter filter;
        foreach (token; text.split())
        {
            filter.rules ~= parseBranchRule(token, format("Branch filter '%s'", text));
        }
        requireInclude(filter, format("Branch filter '%s'", text));
        return filter;
    }
}

/**
 * Whether ref `refName` passes `filter`: the empty filter passes every ref; otherwise the ref
 * must match an include rule and no exclude rule. Pure.
 */
bool refVisible(in BranchFilter filter, string refName) pure nothrow @safe
{
    if (filter.isEmpty) return true;
    bool included = false;
    foreach (rule; filter.rules)
    {
        if (!globMatches(rule.pattern, refName)) continue;
        if (!rule.include) return false;
        included = true;
    }
    return included;
}

/// Whether `name` matches `pattern`, in which `*` matches any run of characters and every other
/// character matches itself.
private bool globMatches(string pattern, string name) pure nothrow @safe
{
    // Iterative wildcard matching with backtracking to the last star: linear in practice.
    size_t p = 0, n = 0;
    ptrdiff_t star = -1;
    size_t afterStar = 0;
    while (n < name.length)
    {
        if (p < pattern.length && pattern[p] == '*')
        {
            star = p++;
            afterStar = n;
        }
        else if (p < pattern.length && pattern[p] == name[n])
        {
            ++p;
            ++n;
        }
        else if (star >= 0)
        {
            p = star + 1;
            n = ++afterStar;
        }
        else
        {
            return false;
        }
    }
    while (p < pattern.length && pattern[p] == '*') ++p;
    return p == pattern.length;
}

private BranchRule parseBranchRule(string token, lazy string what) pure @safe
{
    import std.algorithm.searching : startsWith;

    if (!token.startsWith("+:") && !token.startsWith("-:"))
    {
        throw new InvalidRefSpecException(format("%s: '%s' is not a rule; write +:<pattern> to include refs or -:<pattern> to exclude them",
            what, token));
    }
    if (token.length == 2)
    {
        throw new InvalidRefSpecException(format("%s: rule '%s' has no pattern", what, token));
    }
    return BranchRule(token[0] == '+', token[2 .. $]);
}

private void requireInclude(in BranchFilter filter, lazy string what) pure @safe
{
    if (filter.isEmpty) return;
    foreach (rule; filter.rules)
    {
        if (rule.include) return;
    }
    throw new InvalidRefSpecException(format("%s has only exclude rules, which would hide every ref; add an include rule such as +:*",
        what));
}

/**
 * The kinds of ref spec.
 */
enum RefSpecKind : string
{
    /// No spec: the text "". An input without a default ref spec has this.
    none = "none",
    /// `event <rules> [else <ref>|else skip]`: events on refs passing the rules fire the trigger,
    /// and the other repositories are paired by the event ref's name.
    event = "event",
    /// `same [else <ref>|else skip]`: the ref with the event's name in this repository.
    same = "same",
    /// `<ref>`: a fixed branch, tag or revision, resolved live.
    fixed = "fixed"
}

/**
 * What an `event` or `same` ref spec uses when the name it looks for does not exist or is hidden.
 */
enum RefFallback : string
{
    /// No `else`: the request is skipped, as with `else skip`, but nothing was said.
    none = "none",
    /// `else <ref>`: use `RefSpec.fallbackRef`.
    ref_ = "ref",
    /// `else skip`: make no request.
    skip = "skip"
}

/**
 * Which ref of a repository a build uses (AGENTS.md,
 * "Branches"): given by a trigger or a request, or as an input's default. Its text form is the
 * grammar
 *
 *     event <rules> [else <ref> | else skip]
 *     same [else <ref> | else skip]
 *     <ref>
 *
 * where `<rules>` are one or more branch filter rules (`+:release/*`, at least one an include
 * rule) and `<ref>` is a single token naming a branch, tag or revision as the provider accepts it.
 * The words `event`, `same`, `else` and `skip` are reserved, and a `<ref>` never contains `*`: a
 * pattern is spelled `event +:<pattern>`, never as a bare `<ref>` or an `else <ref>`. A ref named
 * like a reserved word cannot be written in a ref spec. The empty text is
 * `RefSpecKind.none`. Only the fields of the spec's kind are set; `fromString` and `toString`
 * convert between the two forms, and every well-formed spec reads back equal.
 */
struct RefSpec
{
    RefSpecKind kind;
    /// event: the refs whose events fire the trigger.
    BranchFilter rules;
    /// fixed: the ref.
    string refName;
    /// event and same: what applies when the name does not exist or is hidden.
    RefFallback fallback;
    /// fallback `ref_`: the ref used then.
    string fallbackRef;

    /// The spec's text form, with single spaces; "" for `RefSpecKind.none`.
    string toString() const pure @safe
    {
        string fallbackText()
        {
            final switch (fallback)
            {
                case RefFallback.none: return "";
                case RefFallback.ref_: return " else " ~ fallbackRef;
                case RefFallback.skip: return " else skip";
            }
        }

        final switch (kind)
        {
            case RefSpecKind.none: return "";
            case RefSpecKind.event: return "event " ~ rules.toString() ~ fallbackText();
            case RefSpecKind.same: return "same" ~ fallbackText();
            case RefSpecKind.fixed: return refName;
        }
    }

    /**
     * Parses a spec's text form. Blank text is `RefSpecKind.none`.
     *
     * Throws: InvalidRefSpecException naming the text and the problem: an `event` spec without
     * rules or without an include rule, an `else` without exactly one ref or `skip` after it, a
     * fixed ref of more than one token or with an `else`, or a ref that is a reserved word or
     * looks like a rule.
     */
    static RefSpec fromString(string text) pure @safe
    {
        import std.array : split;
        import std.algorithm.searching : countUntil;

        const what = format("Ref spec '%s'", text);
        auto tokens = text.split();
        RefSpec spec;
        if (tokens.length == 0) return spec;

        void parseFallback(string[] rest)
        {
            if (rest.length == 0) return;
            if (rest.length != 2 || rest[0] != "else")
            {
                throw new InvalidRefSpecException(format("%s: expected 'else <ref>' or 'else skip' after the spec, not '%-(%s %)'",
                    what, rest));
            }
            if (rest[1] == "skip")
            {
                spec.fallback = RefFallback.skip;
                return;
            }
            requireRefToken(rest[1], what);
            spec.fallback = RefFallback.ref_;
            spec.fallbackRef = rest[1];
        }

        switch (tokens[0])
        {
            case "event":
                spec.kind = RefSpecKind.event;
                auto end = tokens.countUntil("else");
                auto ruleTokens = end < 0 ? tokens[1 .. $] : tokens[1 .. end];
                if (ruleTokens.length == 0)
                {
                    throw new InvalidRefSpecException(format("%s: an event spec needs at least one rule, such as +:*", what));
                }
                foreach (token; ruleTokens) spec.rules.rules ~= parseBranchRule(token, what);
                requireInclude(spec.rules, what);
                parseFallback(end < 0 ? null : tokens[end .. $]);
                break;
            case "same":
                spec.kind = RefSpecKind.same;
                parseFallback(tokens[1 .. $]);
                break;
            case "else":
            case "skip":
                throw new InvalidRefSpecException(format("%s: '%s' cannot start a spec; write event, same or a ref", what, tokens[0]));
            default:
                if (tokens.length != 1)
                {
                    throw new InvalidRefSpecException(format("%s: a fixed ref is a single token and takes no else", what));
                }
                requireRefToken(tokens[0], what);
                spec.kind = RefSpecKind.fixed;
                spec.refName = tokens[0];
                break;
        }
        return spec;
    }
}

/// Throws InvalidRefSpecException if `token` cannot be a ref in a ref spec: a reserved word, text
/// that looks like a branch filter rule, or a pattern (anything containing `*`).
private void requireRefToken(string token, lazy string what) pure @safe
{
    import std.algorithm.searching : canFind, startsWith;

    if (["event", "same", "else", "skip"].canFind(token))
    {
        throw new InvalidRefSpecException(format("%s: '%s' is a reserved word, not a ref", what, token));
    }
    if (token.startsWith("+:") || token.startsWith("-:"))
    {
        throw new InvalidRefSpecException(format("%s: '%s' is a rule, not a ref", what, token));
    }
    if (token.canFind('*'))
    {
        throw new InvalidRefSpecException(format("%s: '%s' is a pattern, not a ref; a pattern needs event: write event +:%s",
            what, token, token));
    }
}

/**
 * Throws InvalidRefSpecException unless `filter` and `spec` are well formed: what their text forms
 * would accept. For values built in code rather than parsed.
 */
void requireWellFormed(in BranchFilter filter, in RefSpec spec) pure @safe
{
    const filterText = filter.toString();
    if (BranchFilter.fromString(filterText) != filter)
    {
        throw new InvalidRefSpecException(format("Branch filter '%s' is not well formed", filterText));
    }
    const specText = spec.toString();
    if (RefSpec.fromString(specText) != spec)
    {
        throw new InvalidRefSpecException(format("Ref spec '%s' is not well formed", specText));
    }
}

/**
 * Kind-specific part of an input declaration. Only the fields belonging to the
 * input's kind are set:
 *
 * - `repository`: `repository` (repository id), and optionally `branches` (a visibility filter:
 *   which refs of the repository the task may be built from) and `default` (the ref spec used
 *   when the trigger or request gives none for the input). The input never chooses the ref
 *   itself: the trigger or request does (AGENTS.md,
 *   "Branches"). Both are stored in their text forms; "" is the empty filter and no default.
 * - `value`: `value`.
 * - `task_output`: `task` (upstream task id) and `artifact` (id of one of that task's
 *   declared output artifacts, staged into the workspace before the task runs).
 *   An empty `artifact` depends on the upstream task without staging any of its outputs.
 */
struct InputSpec
{
    @optional string repository;
    @optional BranchFilter branches;
    @optional @asName("default") RefSpec defaultRef;
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

/// Declares a repository input of repository `repositoryId`, with default ref spec `defaultRef`
/// (none unless given) and visibility filter `branches` (empty, hiding nothing, unless given).
InputDecl repositoryInput(string repositoryId, RefSpec defaultRef = RefSpec.init, BranchFilter branches = BranchFilter.init)
    pure nothrow @safe
{
    InputDecl decl;
    decl.kind = InputKind.repository;
    decl.spec.repository = repositoryId;
    decl.spec.defaultRef = defaultRef;
    decl.spec.branches = branches;
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
 * from its own execution record. The result deliberately
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
    /// The attempt the worker was given with the work order (`ActiveExecution.attempt` when it
    /// started the execution). Required: a completion from a superseded attempt is rejected.
    @asName("attempt") ulong attempt;
    @optional @asName("exit_code") int exitCode = 0;
    @optional @asName("error_message") string errorMessage;
    @optional @asName("produced_artifacts") ArtifactMetadata[] producedArtifacts;
    @optional @asName("duration_ms") ulong durationMs = 0;
}

// The build model (AGENTS.md, "What a build is"). A request joins or creates a chain. Request
// state is derived from authoritative inputs (the request's pins and definition, the rerun
// generations, and the fingerprint ledgers and executions for its fingerprints). It is cached on
// the BuildRequest itself, which holds whether the request is open, its cached task states and its
// outcome. Each type is stored as its own document. Timestamps are ISO 8601 UTC
// strings (`SysTime.toISOExtString` of a UTC time). They do not sort as text, because
// toISOExtString leaves out zero fractional seconds: parse them to compare.

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
    /// API. One request is made per matched rule.
    @optional @asName("rule_id") string ruleId;
    /// Event details as the trigger source reported them (ref, revision, sender, ...), for
    /// display and audit only: what the trigger pins is in `BuildRequest.pins`.
    @optional string[string] payload;
}

/**
 * Names one declared input of one task. A request binds each repository input to a ref
 * (`InputBinding`), per input, so one closure can use a repository at two refs.
 */
struct InputKey
{
    @asName("task_id") string taskId;
    /// The input's name on the task (its key in `TaskNode.inputs`).
    string input;
}

/**
 * A concrete ref of a repository: its kind and its name as the provider reports it, for example
 * a branch `main`, a tag `v1.2`, a change request `pull/12`, or a revision named directly.
 */
struct RepositoryRef
{
    RefKind kind;
    string name;
}

/**
 * A ref of a repository: the key a pin is stored under. A chain pins each (repository, ref)
 * once, whichever tasks and inputs are bound to it.
 */
struct RepositoryAt
{
    string repositoryId;
    RepositoryRef ref_;
}

/**
 * A repository ref pinned to a revision: an entry of a chain's pins (`BuildChain.pins`) or of a
 * request's pins (`BuildRequest.pins`). Two pins of one (repository, ref) agree
 * only when their revisions (the pinned value, as canonical JSON) agree; display info is never
 * compared. Only the revision is ever hashed into a fingerprint, never the ref (AGENTS.md,
 * invariant 1).
 */
struct RepositoryPin
{
    @asName("repository_id") string repositoryId;
    @asName("ref") RepositoryRef ref_;
    /// The ref's revision when it was pinned (git: the commit SHA), with display info.
    InputPin pin;
}

/// The key `pin` is stored under.
RepositoryAt repositoryAt(in RepositoryPin pin) pure nothrow @safe
{
    return RepositoryAt(pin.repositoryId, pin.ref_);
}

/**
 * The ref a request bound one repository input to: from the trigger's or request's ref spec for
 * the input, else the input's default (AGENTS.md, "Branches"). The input's repository is the one
 * its declaration names. Per request: another request on the chain may bind the same input
 * elsewhere.
 */
struct InputBinding
{
    @asName("task_id") string taskId;
    /// The input's name on the task (its key in `TaskNode.inputs`).
    string input;
    @asName("ref") RepositoryRef ref_;
}

/// The input `binding` binds.
InputKey inputKey(in InputBinding binding) pure nothrow @safe
{
    return InputKey(binding.taskId, binding.input);
}

/**
 * Kinds of headline ref (`HeadlineRef`): a ref kind, or the one history of a project with no
 * repositories.
 */
enum HeadlineKind : string
{
    branch = "branch",
    tag = "tag",
    changeRequest = "change_request",
    revision = "revision",
    /// The headline of every chain of a project with no repositories, which has one history.
    /// Never the default value of the type, so a headline left unset is refused, not taken for
    /// this.
    default_ = "default"
}

/**
 * The ref that groups chains into a history: the event's
 * ref, or for a manual request the ref chosen for the primary (else the first) repository. It is
 * for display and history only: a request joins a chain by pin agreement, never by headline, and
 * two chains with one headline are possible and harmless. A project with no repositories has the
 * headline `default` (`defaultHeadline`), with no name and no repository.
 *
 * Otherwise `name` is the ref's name; `repositoryId` is set only for a change request (a pull
 * request number means nothing without its repository), never for a branch, tag or revision, whose
 * history is the name's across repositories.
 */
struct HeadlineRef
{
    HeadlineKind kind;
    @optional string name;
    @optional @asName("repository_id") string repositoryId;
}

/// The headline `default` of a project with no repositories.
HeadlineRef defaultHeadline() pure nothrow @safe
{
    return HeadlineRef(HeadlineKind.default_);
}

/// The headline for ref `ref_` of repository `repositoryId`, which it keeps only for a change
/// request.
HeadlineRef headlineOf(string repositoryId, in RepositoryRef ref_) pure nothrow @safe
{
    final switch (ref_.kind)
    {
        case RefKind.branch: return HeadlineRef(HeadlineKind.branch, ref_.name);
        case RefKind.tag: return HeadlineRef(HeadlineKind.tag, ref_.name);
        case RefKind.revision: return HeadlineRef(HeadlineKind.revision, ref_.name);
        case RefKind.changeRequest: return HeadlineRef(HeadlineKind.changeRequest, ref_.name, repositoryId);
    }
}

/**
 * Where a project definition is kept (AGENTS.md, "Pipeline definitions").
 */
enum DefinitionLocation : string
{
    /// Edited in the UI and stored by Confector (the project record's tasks).
    confector = "confector",
    /// A file in a repository: a separate configuration repository or the code repository.
    repository = "repository"
}

/**
 * Which definition a request read: where it came from and,
 * for a definition file, the revision it was read at. For display and audit; what the request runs with is the stored
 * definition that `BuildRequest.definitionId` names.
 */
struct DefinitionSource
{
    DefinitionLocation location;
    /// repository only: the repository, the ref the definition was read from (the configuration
    /// branch, resolved when the request was made) and the file's path in the repository. Empty
    /// for a definition kept by Confector.
    @optional @asName("repository_id") string repositoryId;
    @optional @asName("ref_name") string refName;
    @optional string path;
    /// repository only: the revision read, the provider's pinned value of the ref (git: the
    /// commit SHA); required and not empty. Absent for a definition kept by Confector, which has
    /// no revision of its own: the definition id identifies its content exactly. Null when
    /// absent (not undefined, so that sources compare equal after a round trip).
    @optional Json revision = Json(null);
}

/**
 * A project definition (AGENTS.md, "Pipeline definitions"): the one document describing a
 * project's tasks, with their inputs, steps and outputs. Each request reads it once and runs
 * every task with it. Stored immutably under a hash of its content
 * (`confector.core.definition_store`), so requests refer to it by id instead of copying it.
 */
struct ProjectDefinition
{
    @optional TaskNode[] tasks;
}

/**
 * What a build request asks of one task it covers: the task's fingerprint
 * when the request was made, and the `stopSeq` of that fingerprint's ledger then, read after
 * settling it (`LedgerStore.settle`) so a stop that had already happened is counted. A later
 * failure or cancellation at that fingerprint (the ledger's `stopSeq` grows past it) settles the
 * request's demand; an earlier one never does, so a retry made after a failure always runs. Sequence
 * numbers, never timestamps, decide it (AGENTS.md, "Coordinating builds").
 */
struct TaskDemand
{
    @asName("task_id") string taskId;
    string fingerprint;
    /// The task's base fingerprint and its rerun generation then. A fingerprint only moves when
    /// the task or an upstream task is rerun (pins and the request's definition never change), so
    /// the evaluator checks a moved fingerprint against these instead of trusting it.
    string base;
    @optional ulong generation;
    /// How many executions had stopped (failed or been cancelled) at `fingerprint` when the
    /// request was made; 0 when none had or its ledger did not exist.
    @optional @asName("stop_seq") ulong stopSeq;
}

/**
 * Who asked for what, and how the request stands. What was asked is immutable: written once, after
 * the input resolver has found or created the chain the request runs on and added to it every pin
 * the request supplies. The state (`outcome`, `tasks`, `error`) is changed only by reconciling, by
 * compare-and-set (confector.core.request_state).
 */
struct BuildRequest
{
    string id;
    @asName("project_id") string projectId;
    /// The chain the request joined or created.
    @asName("chain_id") string chainId;
    /// The task ids to build, each a task of the request's definition. The request also runs
    /// their upstream tasks, never downstream ones. A rerun names exactly the task to rerun.
    string[] targets;
    BuildIntent intent;
    BuildTrigger trigger;
    /// The pin of every (repository, ref) the request's bindings use, at most one per (repository,
    /// ref), sorted by repository, ref kind and ref name. Complete and immutable once recorded: the
    /// request is evaluated against these pins alone, never against its chain's. Each is also pinned
    /// on the chain before the request is recorded, with the same revision.
    @optional RepositoryPin[] pins;
    /// The ref each repository input of the request's targets and their upstream tasks is bound
    /// to, at most one per input, sorted by (task, input). Each bound (repository, ref) is pinned
    /// on the chain before the request is recorded.
    @optional InputBinding[] bindings;
    /// The id of the stored definition the request runs with (a hash of the `ProjectDefinition`'s
    /// content). Every task the request runs uses it, structure and build configuration alike.
    @asName("definition_id") string definitionId;
    /// Where that definition was read from, and for a definition file at which revision.
    @asName("definition_source") DefinitionSource definitionSource;
    /// One entry per task the request covers (its targets and their upstream tasks in its
    /// definition), sorted by task id: the fingerprint and ledger `stopSeq` the task had when the
    /// request was made (see `TaskDemand`). Request state is derived from these.
    TaskDemand[] demands;
    /// The identity that made the request: a user, an API token, or the trigger source.
    @asName("requested_by") string requestedBy;
    @asName("requested_at") string requestedAt;

    /// Whether the request is still open or how it settled. Settled is final. Recording a request
    /// writes it open.
    RequestOutcome outcome;
    /// The last evaluation's task states, in topological order; empty until the first evaluation
    /// commits.
    @optional RequestTaskState[] tasks;
    /// failed because a needed execution could not be recorded: why. Empty otherwise.
    @optional string error;
}

/**
 * Kinds of event in a chain's history.
 */
enum ChainEventKind : string
{
    /// A task the chain uses was rerun (its base fingerprint's generation was bumped); the chain's
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
    /// The task the event concerns. rerun: the task whose result is superseded.
    @asName("task_id") string taskId;
    /// rerun: the base fingerprint whose generation was bumped, and the generation it was
    /// bumped to.
    @optional string base;
    @optional ulong generation;
}

/**
 * A build chain: what the UI calls a build: the pinned repository refs of one build of one project, and nothing else. It holds no
 * tasks, edges or build configuration; those come from each request's definition. Its identity
 * (id, project, number, headline, creation time) never changes; pins are only added and, once set,
 * never change; labels change and events are only appended. Requests refer to it by id, and join
 * it by pin agreement.
 */
struct BuildChain
{
    string id;
    @asName("project_id") string projectId;
    /// Canonical per-project number ("build #123"), allocated when the chain is created.
    ulong number;
    /// The ref that groups the chain into a history (see `HeadlineRef`). Required. Not part of
    /// how requests find the chain: they join by pin agreement.
    HeadlineRef headline;
    /// The pin of every repository ref the chain's requests have needed: its revision, at most
    /// one per (repository, ref), sorted by repository, ref kind and ref name. An index of the
    /// requests' pins, read to find the pins of a new request and to check one: evaluation never
    /// reads it.
    @optional RepositoryPin[] pins;
    /// The ref each repository input was first bound to: every input of the definition when the
    /// chain was created, plus inputs first bound by later requests. At most one per input, sorted
    /// by (task, input). Grow-only: the first binding is kept, so binding an input to another ref
    /// later adds a pin but leaves this unchanged. A request that names no ref for an input binds
    /// it to the chain's binding.
    @optional InputBinding[] bindings;
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
    /// Recorded; no worker has claimed it yet, or its last worker gave it up or lost its lease and
    /// it waits for another attempt.
    queued = "queued",
    /// A worker holds it under a lease.
    running = "running",
    succeeded = "succeeded",
    /// The task failed, or infrastructure failures used up its attempts. Never retried
    /// automatically and never a cache hit.
    failed = "failed",
    /// Stopped on request. Never a cache hit.
    cancelled = "cancelled"
}

/**
 * One finished run of one task at one fingerprint ("task run" in the UI). Written once, when the
 * execution ends, and never changed after: it is terminal (succeeded, failed or cancelled). Shared
 * across chains: a cache hit is a chain using an execution another chain produced. While an
 * execution is queued or running it is the fingerprint ledger's `ActiveExecution`; the ledger names
 * the finished record as its last success or last stop.
 */
struct TaskExecution
{
    /// The id the ledger gave the execution when it was claimed (`executionIdFor`).
    string id;
    @asName("project_id") string projectId;
    @asName("task_id") string taskId;
    /// Computed by the control plane from a request's definition and its pins, never reported by
    /// a worker.
    string fingerprint;
    /// How the execution ended: succeeded, failed or cancelled.
    ExecutionStatus status;
    /// The attempt that ended it: how many times a worker had claimed the execution by then.
    ulong attempts;
    /// How many leases expired on the execution (a lost worker) before it ended.
    @optional @asName("expired_leases") ulong expiredLeases;
    /// The stored definition the execution ran with (`BuildRequest.definitionId`); `taskId` names
    /// the task in it.
    @asName("definition_id") string definitionId;
    /// The task's resolved inputs, sorted by name, as the execution ran with them.
    @optional ResolvedInput[] inputs;
    /// Where each repository input was fetched from, keyed by input name.
    @optional @asName("repository_addresses") string[string] repositoryAddresses;
    /// Artifacts the execution produced.
    @optional ArtifactMetadata[] artifacts;
    /// When retention deleted the execution's artifacts (ISO 8601 UTC); empty while they exist. A
    /// succeeded execution with this set is a cache miss, not a cache hit (AGENTS.md, "The caching
    /// contract"). Only a succeeded execution has artifacts to expire.
    @optional @asName("artifacts_expired_at") string artifactsExpiredAt;
    /// The id of the worker that held it last; empty if no worker ever did.
    @optional string worker;
    /// When the execution was claimed (queued), when its last attempt started and when it ended
    /// (ISO 8601 UTC).
    @asName("created_at") string createdAt;
    @optional @asName("started_at") string startedAt;
    @asName("finished_at") string finishedAt;
    /// The exit code of the task's steps; meaningful only when `status` is succeeded or failed
    /// and the task ran to completion. An infrastructure failure or cancellation has no exit
    /// code: read `status` and `errorMessage`.
    @optional @asName("exit_code") int exitCode;
    @optional @asName("error_message") string errorMessage;
}

/**
 * The execution a fingerprint's ledger holds queued or running: at most one per fingerprint. It
 * is created by the ledger's claim, changed only by compare-and-set on the ledger (a worker
 * starting it, its heartbeat, a release, an expired lease), and removed when it ends, when its
 * outcome is written as a `TaskExecution` and folded into the ledger.
 */
struct ActiveExecution
{
    /// Deterministic: `executionIdFor(fingerprint, executionSeq)` of the claim that created it.
    string id;
    @asName("project_id") string projectId;
    @asName("task_id") string taskId;
    /// queued (waiting for a worker) or running (held by `worker` under a lease).
    ExecutionStatus status;
    /// How many times a worker has started the execution; the current start's number is its
    /// attempt. A worker's heartbeat, release and completion carry the attempt, and one from
    /// another attempt is rejected. It fences workers only: a release raises it too, so it is not
    /// the retry limit (see `expiredLeases`).
    ulong attempt;
    /// The worker holding it and when its lease expires unless a heartbeat extends it (ISO 8601
    /// UTC); both empty unless running.
    @optional string worker;
    @optional @asName("lease_expires_at") string leaseExpiresAt;
    /// How many leases expired on the execution (a lost worker). Infrastructure failures retry
    /// within the same execution until this reaches an admin-configured limit; a release does not
    /// count. A user's retry is a new execution.
    @optional @asName("expired_leases") ulong expiredLeases;
    /// The stored definition (`BuildRequest.definitionId`) of the request that claimed it, and the
    /// task in it. The execution runs with that definition's task as it was then.
    @asName("definition_id") string definitionId;
    /// The task's resolved inputs, sorted by name, as the claiming request pins them (every chain
    /// at one fingerprint pins the same values). Fixed at the claim; the work order is built from
    /// them.
    @optional ResolvedInput[] inputs;
    /// Where to fetch each repository input from, keyed by input name: how to fetch, not what, so
    /// never hashed. Read from the repository records at the claim and fixed then.
    @optional @asName("repository_addresses") string[string] repositoryAddresses;
    @asName("created_at") string createdAt;
    /// When the current attempt started; empty while queued.
    @optional @asName("started_at") string startedAt;
}

/**
 * The fingerprint ledger (AGENTS.md, "Coordinating builds"): one document per fingerprint, with
 * the fingerprint as its id, read by id and changed only by compare-and-set
 * (confector.core.fingerprint_ledger). It is the linearization point for one fingerprint: the
 * active execution (at most one), and the latest success and stop.
 */
struct FingerprintLedger
{
    /// The fingerprint, which is also the document's id.
    string fingerprint;
    /// The execution queued or running at this fingerprint; null when none is. Set by a claim,
    /// cleared only by the fold of that execution's terminal outcome.
    @optional Nullable!ActiveExecution active;
    /// The latest execution that succeeded; empty when none has. Whether it is still usable (its
    /// artifacts may have expired) is on the execution record.
    @optional @asName("last_success_execution_id") string lastSuccessExecutionId;
    /// The latest execution that failed or was cancelled (a lost execution ends failed); empty
    /// when none has.
    @optional @asName("last_stopped_execution_id") string lastStoppedExecutionId;
    /// How many executions at this fingerprint have failed or been cancelled. Only grows; a
    /// request settles a demand by comparing it with the value seen when the demand was recorded,
    /// never by comparing times.
    @optional @asName("stop_seq") ulong stopSeq;
    /// How many executions have ever been claimed at this fingerprint. The nth has the
    /// deterministic id `executionIdFor(fingerprint, n)`.
    @optional @asName("execution_seq") ulong executionSeq;
}

/**
 * A request task's state, as the request evaluator derives it (confector.core.request_evaluator)
 * and the request caches it. Only tasks the request covers (its targets and their upstream
 * tasks) have one. Not an execution status: it is derived from the request and the fingerprint's
 * ledger.
 */
enum RequestTaskStatus : string
{
    /// No valid success of its own (it never ran, or its success's artifacts expired), not
    /// active, not settled, and no task that must run depends on it: every dependent is already
    /// satisfied. It need not run.
    notNeeded = "not_needed",
    /// It must run and an upstream task has not succeeded yet.
    waitingUpstream = "waiting_upstream",
    /// It must run, every upstream task succeeded, and no execution is active: it needs an
    /// execution (the evaluation lists it as needed).
    needed = "needed",
    /// Its fingerprint's active execution is claimed and not yet held by a worker (or not yet
    /// recorded, if its dispatcher crashed: the dispatcher repairs that).
    queued = "queued",
    /// Its fingerprint's active execution is held by a worker.
    running = "running",
    /// Its fingerprint's latest success is usable, whichever request produced it.
    succeeded = "succeeded",
    /// An execution at its fingerprint failed after the request's demand was recorded.
    failed = "failed",
    /// An execution at its fingerprint was cancelled after the request's demand was recorded.
    cancelled = "cancelled",
    /// It must run, but an upstream task failed or was cancelled.
    blocked = "blocked"
}

/**
 * One request task's derived state (confector.core.request_evaluator.evaluateRequest), cached on
 * the BuildRequest.
 */
struct RequestTaskState
{
    @asName("task_id") string taskId;
    /// The fingerprint the task was evaluated at: from the request's definition, the request's
    /// pins and the current rerun generations.
    string fingerprint;
    RequestTaskStatus status;
    /// Whether the request targets the task (rather than only needing it upstream of a target).
    @optional bool target;
    /// The execution the state comes from: the success used, the active execution, the stop that
    /// settled it, or the expired success of a task not needed. Empty otherwise.
    @optional @asName("execution_id") string executionId;
    /// blocked: the upstream tasks that failed or were cancelled and block it, sorted.
    @optional @asName("blocked_by") string[] blockedBy;
}

/**
 * How a request stands. A request is open until every target is settled.
 */
enum RequestOutcome : string
{
    /// Some target has not settled.
    open = "open",
    /// Every target succeeded.
    succeeded = "succeeded",
    /// Every target settled and some target failed or was cancelled, or a needed execution could
    /// not be recorded (`BuildRequest.error`).
    failed = "failed",
    /// Every target settled, none failed, and some is blocked by an upstream task that failed
    /// or was cancelled.
    blocked = "blocked"
}

/**
 * Kinds of ref: of a tracked branch, of a pin's ref
 * (`RepositoryRef`) and of a headline.
 */
enum RefKind : string
{
    branch = "branch",
    tag = "tag",
    /// A pull request, merge request, code review or shelf, as its provider exposes it.
    changeRequest = "change_request",
    /// A revision named directly (git: a full commit SHA), as a fixed ref spec may name one. The
    /// ref of a pin or a headline only: never a tracked branch's kind.
    revision = "revision"
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
 * A ref of a repository that Confector tracks, independent of the
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
 * Global roles.
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
 * An API token. Only a hash of the token's secret is stored, never the
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
 * A fully resolved, ready-to-execute work order, as a worker receives it. The control plane
 * builds it from the execution's record when a worker claims the execution
 * (confector.core.work_orders).
 */
struct WorkOrder
{
    /// The execution to run (`TaskExecution.id`). The worker's completion names it; a work order
    /// without one cannot be completed.
    @optional @asName("execution_id") string executionId;
    /// The task definition to execute: its steps, environment and declared outputs.
    @optional @asName("task_node") TaskNode taskNode;
    /// The task's fingerprint, computed by the control plane from the request's pins. The runner
    /// stores outputs under it and never computes its own; a work order without one fails.
    @optional @asName("fingerprint") string fingerprint;
    @optional @asName("payload") TaskExecutionPayload payload;
    @optional @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @optional @asName("created_at") string createdAt;
    /// The credential the worker presents to the server for this execution, in the
    /// X-Confector-Worker-Token header (confector.core.worker_token). Issued when the work order is
    /// received; absent from the stored execution. A work order without one cannot be run.
    @optional @asName("worker_token") string workerToken;
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
    node.inputs["src"] = repositoryInput("repo1");
    node.inputs["lib"] = repositoryInput("repo1", RefSpec.fromString("release"));
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
    // Inputs round-trip through JSON as a map keyed by name, with snake_case kinds; a repository
    // input's filter and default ref spec are stored in their text forms
    TaskNode node;
    node.id = "package";
    node.inputs["src"] = repositoryInput("game", RefSpec.fromString("same  else main"), BranchFilter.fromString("+:* -:experimental/*"));
    node.inputs["tools"] = repositoryInput("tools");
    node.inputs["engine"] = taskOutputInput("build-engine", "engine.zip");
    node.inputs["flavor"] = valueInput("external");

    auto json = serializeToJson(node);
    assert(json["inputs"]["src"]["kind"].get!string == "repository");
    assert(json["inputs"]["src"]["spec"]["default"].get!string == "same else main");
    assert(json["inputs"]["src"]["spec"]["branches"].get!string == "+:* -:experimental/*");
    assert(json["inputs"]["tools"]["spec"]["default"].get!string == "", "No default is the empty text");
    assert(json["inputs"]["tools"]["spec"]["branches"].get!string == "");
    assert(json["inputs"]["engine"]["kind"].get!string == "task_output");

    auto back = deserializeJson!TaskNode(json);
    assert(back.inputs == node.inputs);
    assert(roundTrip(node).inputs == node.inputs);

    // Hand-written inputs: the filter and default may be left out; a malformed one fails loudly
    auto written = deserializeJson!InputDecl(`{"kind": "repository", "spec": {"repository": "game"}}`);
    assert(written == repositoryInput("game"));
    assert(written.spec.defaultRef.kind == RefSpecKind.none && written.spec.branches.isEmpty);
    foreach (malformed; [`{"kind": "repository", "spec": {"repository": "game", "default": "same else"}}`,
                         `{"kind": "repository", "spec": {"repository": "game", "branches": "experimental/*"}}`,
                         `{"kind": "repository", "spec": {"repository": "game", "branches": "-:experimental/*"}}`])
    {
        bool threw = false;
        try deserializeJson!InputDecl(malformed);
        catch (Exception) threw = true;
        assert(threw, malformed);
    }
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
    // A build request round-trips, pins and definition included, with snake_case names and
    // string enums
    BuildRequest request;
    request.id = "r1";
    request.projectId = "game";
    request.chainId = "c1";
    request.targets = ["internal", "tests"];
    request.intent = BuildIntent.build;
    request.trigger = BuildTrigger(TriggerType.gitPush, "rule-1", ["ref": "refs/heads/main", "revision": "aaa111"]);
    request.pins = [RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111"), ["subject": "Fix the build"]))];
    request.bindings = [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "main"))];
    request.definitionId = "d1";
    request.definitionSource = DefinitionSource(DefinitionLocation.repository, "ci-config", "main", "game.yaml", Json("ccc333"));
    request.demands = [TaskDemand("compile", "fp-compile", "b-compile", 1, 2), TaskDemand("internal", "fp-internal", "b-internal"),
        TaskDemand("tests", "fp-tests", "b-tests")];
    request.requestedBy = "webhook:github";
    request.requestedAt = "2026-10-15T14:02:00Z";

    auto json = serializeToJson(request);
    assert(json["intent"].get!string == "build");
    assert(json["trigger"]["type"].get!string == "git_push");
    assert(json["trigger"]["rule_id"].get!string == "rule-1");
    assert(json["pins"][0]["repository_id"].get!string == "game");
    assert(json["pins"][0]["ref"]["kind"].get!string == "branch" && json["pins"][0]["ref"]["name"].get!string == "main");
    assert(json["pins"][0]["pin"]["pinned"].get!string == "aaa111");
    assert(json["bindings"][0]["task_id"].get!string == "compile" && json["bindings"][0]["input"].get!string == "src");
    assert(json["bindings"][0]["ref"]["kind"].get!string == "branch" && json["bindings"][0]["ref"]["name"].get!string == "main");
    assert(json["definition_id"].get!string == "d1");
    assert(json["definition_source"]["location"].get!string == "repository");
    assert(json["definition_source"]["repository_id"].get!string == "ci-config");
    assert(json["definition_source"]["ref_name"].get!string == "main");
    assert(json["definition_source"]["path"].get!string == "game.yaml");
    assert(json["definition_source"]["revision"].get!string == "ccc333");
    assert(json["demands"][0]["task_id"].get!string == "compile" && json["demands"][0]["fingerprint"].get!string == "fp-compile");
    assert(json["demands"][0]["stop_seq"].get!long == 2 && json["demands"][1]["stop_seq"].get!long == 0);
    assert(json["demands"][0]["base"].get!string == "b-compile" && json["demands"][0]["generation"].get!long == 1);
    assert(json["requested_by"].get!string == "webhook:github");
    assert(roundTrip(request) == request);

    // A rerun request made by hand from a definition edited in the UI: no rule, no payload, no pins
    BuildRequest rerun;
    rerun.id = "r2";
    rerun.projectId = "game";
    rerun.chainId = "c1";
    rerun.targets = ["release"];
    rerun.intent = BuildIntent.rerun;
    rerun.trigger.type = TriggerType.manual;
    rerun.definitionId = "d2";
    rerun.definitionSource = DefinitionSource(DefinitionLocation.confector);
    rerun.demands = [TaskDemand("release", "fp-release", "b-release")];
    rerun.requestedBy = "jason";
    rerun.requestedAt = "2026-10-15T15:00:00Z";
    assert(serializeToJson(rerun)["intent"].get!string == "rerun");
    assert(serializeToJson(rerun)["definition_source"]["location"].get!string == "confector");
    assert(serializeToJson(rerun)["definition_source"]["revision"].type == Json.Type.null_, "A Confector definition has no revision");
    assert(roundTrip(rerun) == rerun);
}

unittest
{
    // A project definition round-trips its tasks
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
    compile.steps = [BuildStep("Build", "bash", Json(["script": Json("make")]))];
    auto definition = ProjectDefinition([compile]);
    assert(serializeToJson(definition)["tasks"][0]["id"].get!string == "compile");
    assert(roundTrip(definition) == definition);
    assert(deserializeJson!ProjectDefinition(`{}`).tasks.length == 0);
}

unittest
{
    // A build chain round-trips its number, headline, pins, labels and history
    BuildChain chain;
    chain.id = "c1";
    chain.projectId = "game";
    chain.number = 123;
    chain.headline = headlineOf("game", RepositoryRef(RefKind.changeRequest, "pull/12"));
    chain.pins = [
        RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("bbb222"))),
        RepositoryPin("game", RepositoryRef(RefKind.changeRequest, "pull/12"), InputPin(Json("aaa111"), ["subject": "Fix the build"])),
    ];
    chain.createdAt = "2026-10-15T14:02:01Z";
    chain.labels = ["release candidate"];
    chain.events = [ChainEvent(ChainEventKind.rerun, "r2", "release", "base-fingerprint", 1)];

    auto json = serializeToJson(chain);
    assert(json["number"].get!long == 123);
    assert(json["headline"]["repository_id"].get!string == "game");
    assert(json["headline"]["kind"].get!string == "change_request");
    assert(json["headline"]["name"].get!string == "pull/12");
    assert(json["pins"][0]["repository_id"].get!string == "game" && json["pins"][0]["ref"]["name"].get!string == "main");
    assert(json["pins"][1]["pin"]["info"]["subject"].get!string == "Fix the build");
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
        "definition_id": "d1", "definition_source": {"location": "confector"},
        "demands": [{"task_id": "internal", "fingerprint": "fp1", "base": "b1"}],
        "requested_by": "jason", "requested_at": "2026-10-15T14:02:00Z", "outcome": "open"
    }`);
    assert(request.demands == [TaskDemand("internal", "fp1", "b1", 0, 0)], "A demand without a generation or stop_seq saw none");
    assert(request.outcome == RequestOutcome.open && request.tasks.length == 0 && request.error.length == 0);
    assert(request.intent == BuildIntent.retry && request.trigger.type == TriggerType.manual);
    assert(request.trigger.ruleId.length == 0 && request.trigger.payload.length == 0);
    assert(request.pins.length == 0 && request.bindings.length == 0 && request.targets == ["internal"]);
    assert(request.definitionSource.location == DefinitionLocation.confector
        && request.definitionSource.revision.type == Json.Type.null_);
    assert(request.definitionSource.repositoryId.length == 0 && request.definitionSource.path.length == 0);

    // A pin without display info
    auto pinned = deserializeJson!BuildRequest(`{
        "id": "r2", "project_id": "game", "chain_id": "c2", "targets": ["internal"],
        "intent": "build", "trigger": {"type": "git_push", "rule_id": "rule-1", "payload": {"ref": "main"}},
        "pins": [{"repository_id": "game", "ref": {"kind": "branch", "name": "main"}, "pin": {"pinned": "aaa111"}}],
        "bindings": [{"task_id": "compile", "input": "src", "ref": {"kind": "branch", "name": "main"}}],
        "definition_id": "d1", "definition_source": {"location": "confector"},
        "demands": [{"task_id": "internal", "fingerprint": "fp1", "base": "b1", "stop_seq": 1}],
        "requested_by": "webhook:github", "requested_at": "2026-10-15T14:02:00Z", "outcome": "open"
    }`);
    assert(pinned.pins.length == 1 && repositoryAt(pinned.pins[0]) == RepositoryAt("game", RepositoryRef(RefKind.branch, "main")));
    assert(pinned.bindings.length == 1 && inputKey(pinned.bindings[0]) == InputKey("compile", "src"));
    assert(pinned.bindings[0].ref_ == RepositoryRef(RefKind.branch, "main"));
    assert(pinned.pins[0].pin.pinned == Json("aaa111") && pinned.pins[0].pin.info.length == 0);
    assert(pinned.trigger.payload == ["ref": "main"]);

    // A request that does not say which definition it runs with is malformed
    bool undefinedThrew = false;
    try deserializeJson!BuildRequest(`{
        "id": "r1", "project_id": "game", "chain_id": "c1", "targets": ["internal"],
        "intent": "retry", "trigger": {"type": "manual"},
        "requested_by": "jason", "requested_at": "2026-10-15T14:02:00Z", "outcome": "open"
    }`);
    catch (Exception) undefinedThrew = true;
    assert(undefinedThrew, "A request without a definition must not deserialize");
    bool undemandedThrew = false;
    try deserializeJson!BuildRequest(`{
        "id": "r1", "project_id": "game", "chain_id": "c1", "targets": ["internal"],
        "intent": "retry", "trigger": {"type": "manual"},
        "definition_id": "d1", "definition_source": {"location": "confector"},
        "requested_by": "jason", "requested_at": "2026-10-15T14:02:00Z", "outcome": "open"
    }`);
    catch (Exception) undemandedThrew = true;
    assert(undemandedThrew, "A request without its demands must not deserialize");

    auto chain = deserializeJson!BuildChain(`{
        "id": "c1", "project_id": "game", "number": 7, "created_at": "2026-10-15T14:02:01Z",
        "headline": {"kind": "branch", "name": "main"}
    }`);
    assert(chain.number == 7 && chain.headline == HeadlineRef(HeadlineKind.branch, "main"));
    assert(chain.pins.length == 0 && chain.labels.length == 0 && chain.events.length == 0);

    // The headline of a project with no repositories
    auto unpinned = deserializeJson!BuildChain(`{
        "id": "c2", "project_id": "docs", "number": 1, "created_at": "2026-10-15T14:02:01Z", "headline": {"kind": "default"}
    }`);
    assert(unpinned.headline == defaultHeadline() && unpinned.headline.name.length == 0);

    // A chain without a headline is malformed
    bool headlessThrew = false;
    try deserializeJson!BuildChain(`{"id": "c1", "project_id": "game", "number": 7, "created_at": "2026-10-15T14:02:01Z"}`);
    catch (Exception) headlessThrew = true;
    assert(headlessThrew, "A chain without a headline must not deserialize");

    // A rerun event without the optional fields of other kinds still reads
    auto withEvent = deserializeJson!BuildChain(`{
        "id": "c1", "project_id": "game", "number": 7,
        "headline": {"kind": "tag", "name": "v1"},
        "created_at": "2026-10-15T14:02:01Z", "labels": ["rc"],
        "events": [{"kind": "rerun", "request_id": "r2", "task_id": "compile", "base": "b", "generation": 2}]
    }`);
    assert(withEvent.labels == ["rc"]);
    assert(withEvent.events == [ChainEvent(ChainEventKind.rerun, "r2", "compile", "b", 2)]);

    auto execution = deserializeJson!TaskExecution(`{
        "id": "e1", "project_id": "game", "task_id": "compile", "fingerprint": "fp1",
        "status": "failed", "attempts": 1, "definition_id": "def1",
        "created_at": "2026-10-15T14:02:02Z", "finished_at": "2026-10-15T14:09:00Z"
    }`);
    assert(execution.status == ExecutionStatus.failed && execution.attempts == 1 && execution.definitionId == "def1");
    assert(execution.artifacts.length == 0 && execution.worker.length == 0 && execution.inputs.length == 0);
    assert(execution.startedAt.length == 0 && execution.finishedAt == "2026-10-15T14:09:00Z");
    assert(execution.exitCode == 0 && execution.errorMessage.length == 0);

    // A required field left out fails loudly rather than defaulting
    bool threw = false;
    try deserializeJson!TaskExecution(`{"id": "e1", "project_id": "game", "task_id": "compile", "status": "failed"}`);
    catch (Exception) threw = true;
    assert(threw, "A missing fingerprint must not deserialize");
}

unittest
{
    // A task execution round-trips its inputs, artifacts and timestamps
    TaskExecution execution;
    execution.id = "e1";
    execution.projectId = "game";
    execution.taskId = "compile";
    execution.fingerprint = "fp1";
    execution.status = ExecutionStatus.succeeded;
    execution.attempts = 2;
    execution.definitionId = "def1";
    execution.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
    execution.repositoryAddresses = ["src": "https://example.test/game.git"];
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
    assert(json["definition_id"].get!string == "def1");
    assert(json["inputs"][0]["pinned"].get!string == "aaa111");
    assert(roundTrip(execution) == execution);

    // Retention keeps the record and marks when the artifacts went
    TaskExecution expired = execution;
    expired.artifactsExpiredAt = "2026-10-16T09:00:00Z";
    assert(serializeToJson(expired)["artifacts_expired_at"].get!string == "2026-10-16T09:00:00Z");
    assert(roundTrip(expired) == expired);

    // A failed execution keeps its exit code and error
    TaskExecution failed = execution;
    failed.status = ExecutionStatus.failed;
    failed.artifacts = null;
    failed.exitCode = 2;
    failed.errorMessage = "make: *** [all] Error 2";
    assert(roundTrip(failed) == failed);
}

unittest
{
    // A ledger round-trips its active execution, queued or running, and reads without one
    FingerprintLedger idle;
    idle.fingerprint = "fp1";
    idle.lastSuccessExecutionId = "e1";
    idle.executionSeq = 1;
    assert(idle.active.isNull);
    assert(roundTrip(idle) == idle);
    assert(deserializeJson!FingerprintLedger(`{"fingerprint": "fp1"}`).active.isNull);

    ActiveExecution active;
    active.id = "e2";
    active.projectId = "game";
    active.taskId = "compile";
    active.status = ExecutionStatus.queued;
    active.definitionId = "def1";
    active.inputs = [ResolvedInput("src", InputKind.repository, Json("aaa111"), ["ref": "main"])];
    active.repositoryAddresses = ["src": "https://example.test/game.git"];
    active.createdAt = "2026-10-15T14:02:02Z";
    FingerprintLedger queued = idle;
    queued.executionSeq = 2;
    queued.active = active;
    auto json = serializeToJson(queued);
    assert(json["active"]["status"].get!string == "queued" && json["active"]["definition_id"].get!string == "def1");
    assert(roundTrip(queued) == queued);

    ActiveExecution running = active;
    running.status = ExecutionStatus.running;
    running.attempt = 2;
    running.expiredLeases = 1;
    running.worker = "worker-1";
    running.leaseExpiresAt = "2026-10-15T14:04:02Z";
    running.startedAt = "2026-10-15T14:03:02Z";
    queued.active = running;
    assert(roundTrip(queued) == queued);
}

unittest
{
    // A request's state round-trips its outcome, cached task states and error with the request
    BuildRequest request;
    request.id = "r1";
    request.projectId = "game";
    request.outcome = RequestOutcome.failed;
    request.tasks = [
        RequestTaskState("compile", "fp1", RequestTaskStatus.succeeded, false, "e1"),
        RequestTaskState("test", "fp2", RequestTaskStatus.blocked, true, null, ["compile"]),
    ];
    request.error = "no address";
    auto json = serializeToJson(request);
    assert(json["outcome"].get!string == "failed" && json["error"].get!string == "no address");
    assert(json["tasks"][0]["status"].get!string == "succeeded" && json["tasks"][0]["execution_id"].get!string == "e1");
    assert(json["tasks"][1]["blocked_by"][0].get!string == "compile" && json["tasks"][1]["target"].get!bool);
    assert(roundTrip(request) == request);

    // A task state left out of a document is not a target and blocks nothing
    auto fresh = deserializeJson!RequestTaskState(`{"task_id": "t", "fingerprint": "f", "status": "waiting_upstream"}`);
    assert(fresh.status == RequestTaskStatus.waitingUpstream && !fresh.target && fresh.blockedBy.length == 0);
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

unittest
{
    import std.algorithm.searching : canFind;

    // Branch filters: include/exclude rules in their text form; a ref is visible when an include
    // rule matches and no exclude rule does, whatever the order
    auto filter = BranchFilter.fromString("  +:*   -:experimental/* ");
    assert(filter.rules == [BranchRule(true, "*"), BranchRule(false, "experimental/*")]);
    assert(filter.toString() == "+:* -:experimental/*");
    assert(BranchFilter.fromString(filter.toString()) == filter);
    assert(refVisible(filter, "main") && refVisible(filter, "feature/a/b") && refVisible(filter, "experimental"));
    assert(!refVisible(filter, "experimental/x") && !refVisible(filter, "experimental/x/y"), "* matches across slashes");
    auto reversed = BranchFilter.fromString("-:experimental/* +:*");
    assert(!refVisible(reversed, "experimental/x") && refVisible(reversed, "main"), "Order does not matter");

    auto releases = BranchFilter.fromString("+:release/* +:main -:release/*-rc");
    assert(refVisible(releases, "main") && refVisible(releases, "release/1.2"));
    assert(!refVisible(releases, "release/1.2-rc") && !refVisible(releases, "mainline") && !refVisible(releases, "dev"));
    assert(refVisible(BranchFilter.fromString("+:v*.*"), "v1.2") && !refVisible(BranchFilter.fromString("+:v*.*"), "v12"));
    assert(refVisible(BranchFilter.fromString("+:a*b*c"), "aXbYbZc") && !refVisible(BranchFilter.fromString("+:a*b*c"), "aXcYb"));
    assert(!refVisible(BranchFilter.fromString("+:Main"), "main"), "Matching is case-sensitive");

    // The empty filter hides nothing
    assert(BranchFilter.fromString("").isEmpty && BranchFilter.fromString(" ").isEmpty && BranchFilter.init.toString() == "");
    assert(refVisible(BranchFilter.init, "anything/at/all"));

    // Malformed filters fail loudly, naming the filter
    foreach (malformed; ["main", "+:", "-:", "*", "+main", "-:experimental/*", "-:a -:b"])
    {
        bool threw = false;
        try BranchFilter.fromString(malformed);
        catch (InvalidRefSpecException e) threw = e.msg.canFind(malformed);
        assert(threw, malformed);
    }
}

unittest
{
    import std.algorithm.searching : canFind;

    // Ref specs: the three forms, each with the fallbacks it allows, read back equal
    auto event = RefSpec.fromString("event +:* -:experimental/* else main");
    assert(event.kind == RefSpecKind.event && event.rules == BranchFilter.fromString("+:* -:experimental/*"));
    assert(event.fallback == RefFallback.ref_ && event.fallbackRef == "main" && event.refName.length == 0);

    auto skipping = RefSpec.fromString("event +:release/* else skip");
    assert(skipping.fallback == RefFallback.skip && skipping.fallbackRef.length == 0);
    assert(RefSpec.fromString("event +:*").fallback == RefFallback.none);

    auto same = RefSpec.fromString("same else develop");
    assert(same.kind == RefSpecKind.same && same.fallback == RefFallback.ref_ && same.fallbackRef == "develop");
    assert(RefSpec.fromString("same").fallback == RefFallback.none);
    assert(RefSpec.fromString("same else skip").fallback == RefFallback.skip);

    auto fixed = RefSpec.fromString(" refs/tags/v1.2 ");
    assert(fixed.kind == RefSpecKind.fixed && fixed.refName == "refs/tags/v1.2" && fixed.fallback == RefFallback.none);
    assert(RefSpec.fromString("0123456789abcdef0123456789abcdef01234567").refName.length == 40, "A revision is a fixed ref");

    auto none = RefSpec.fromString("   ");
    assert(none.kind == RefSpecKind.none && none == RefSpec.init && none.toString() == "");

    foreach (text; ["event +:* -:experimental/* else main", "event +:release/* else skip", "event +:*", "same",
        "same else develop", "same else skip", "main", "event +:feat/* else main", ""])
    {
        auto spec = RefSpec.fromString(text);
        assert(spec.toString() == text, text);
        assert(RefSpec.fromString(spec.toString()) == spec, text);
        requireWellFormed(BranchFilter.init, spec);
    }
    assert(RefSpec.fromString("same   else\tmain").toString() == "same else main", "Whitespace is normalized");

    // A pattern is never a ref: it needs event, and the message says how to write it
    foreach (pattern; ["*", "release/*", "same else release/*", "event +:* else feat/*"])
    {
        bool hinted = false;
        try RefSpec.fromString(pattern);
        catch (InvalidRefSpecException e) hinted = e.msg.canFind("a pattern needs event: write event +:");
        assert(hinted, pattern);
    }

    // Malformed specs fail loudly, naming the spec
    foreach (malformed; [
        "event", "event else main", "event -:experimental/*", "event main", "event +:* else", "event +:* else a b",
        "event +:* otherwise main", "same else", "same main", "same else skip now", "same else event",
        "same else +:x", "else main", "skip", "main else develop", "main develop", "+:main", "-:main",
        "same else same", "*", "release/*", "same else release/*", "event +:* else feat/*",
    ])
    {
        bool threw = false;
        try RefSpec.fromString(malformed);
        catch (InvalidRefSpecException e) threw = e.msg.canFind("'" ~ malformed ~ "'");
        assert(threw, malformed);
    }

    // A spec or filter built in code must be one its text form accepts
    bool threw = false;
    try requireWellFormed(BranchFilter.init, RefSpec(RefSpecKind.fixed, BranchFilter.init, "two words"));
    catch (InvalidRefSpecException) threw = true;
    assert(threw);
    threw = false;
    try requireWellFormed(BranchFilter([BranchRule(false, "x")]), RefSpec.init);
    catch (InvalidRefSpecException) threw = true;
    assert(threw);
    threw = false;
    try requireWellFormed(BranchFilter.init, RefSpec(RefSpecKind.same, BranchFilter.init, "stray"));
    catch (InvalidRefSpecException) threw = true;
    assert(threw, "A field of another kind is not well formed");
}

unittest
{
    // Headlines: a change request keeps its repository, other refs do not; `default` is a
    // distinguished value and never the value of an unset headline
    assert(headlineOf("game", RepositoryRef(RefKind.branch, "main")) == HeadlineRef(HeadlineKind.branch, "main"));
    assert(headlineOf("game", RepositoryRef(RefKind.tag, "v1")) == HeadlineRef(HeadlineKind.tag, "v1"));
    assert(headlineOf("game", RepositoryRef(RefKind.revision, "abc")) == HeadlineRef(HeadlineKind.revision, "abc"));
    assert(headlineOf("game", RepositoryRef(RefKind.changeRequest, "pull/12")) == HeadlineRef(HeadlineKind.changeRequest, "pull/12", "game"));
    assert(defaultHeadline().kind == HeadlineKind.default_ && HeadlineRef.init.kind != HeadlineKind.default_);
    assert(serializeToJson(defaultHeadline())["kind"].get!string == "default");
    assert(roundTrip(defaultHeadline()) == defaultHeadline());
}
