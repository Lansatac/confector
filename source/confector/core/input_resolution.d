module confector.core.input_resolution;

/**
 * Pure whole-DAG input resolution (design record: bead confector-z7z.13; AGENTS.md, "The input
 * model"). Turns every declared external input (repository and value) of every task in a graph
 * into a ResolvedInput, so a chain created from the result pins the same revisions for every
 * task, including tasks nobody has asked to build yet.
 *
 * Resolution runs in two steps around the shell's I/O:
 *
 * 1. `unpinnedRepositoryInputs` lists the distinct repository inputs in the graph that no
 *    pre-supplied pin covers. The shell resolves each of them once, through the
 *    RepositoryResolver for its repository's provider.
 * 2. `resolveGraphInputs` combines the pre-supplied pins with the resolver results.
 *
 * Repository inputs are identified by their declaration (repository id and ref selector), not
 * by the task or input name that declares them, so every task declaring the same repository at
 * the same ref sees one pinned value. Pins are keyed the same way; build keys with
 * `repositoryInput(repositoryId, refSelector)`.
 *
 * A build chain stores the result as `freezeChain` returns it; `chainResolution` computes
 * fingerprints from a chain and the current rerun generations (bead confector-z7z.15), so
 * building any task of an existing chain never resolves again. The shell that calls a resolver
 * is confector.core.chain_resolver; the one that reads rerun generations is
 * confector.core.rerun_generations.
 */

import confector.core.dag : TaskGraph;
import confector.core.fingerprinter : computeBaseFingerprint, computeFingerprint, pinInputs;
import confector.core.model;
import confector.plugin_api.input_resolver : InputPin;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * A declared input could not be resolved: no pin covers it, or its pin is not a usable value.
 */
class InputResolutionException : Exception
{
    /// The task declaring the input, when the failure concerns one task's input.
    string taskId;
    /// The input's name on that task.
    string inputName;

    this(string msg, string taskId = null, string inputName = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.taskId = taskId;
        this.inputName = inputName;
    }
}

/**
 * Every task's resolved inputs, base fingerprint and fingerprint, for the whole graph.
 */
struct GraphResolution
{
    /// Resolved inputs keyed by task id, each task's sorted by input name. Every task in the
    /// graph has an entry, empty when it declares no inputs.
    ResolvedInput[][string] inputs;
    /// Base fingerprint (the fingerprint without the rerun generation) keyed by task id, for
    /// every task in the graph. Rerun generations are keyed by it.
    string[string] bases;
    /// Fingerprint keyed by task id, for every task in the graph.
    string[string] fingerprints;
}

/**
 * The current rerun generation of each base fingerprint (design record: bead confector-z7z.15),
 * keyed by base. A base that was never rerun is at generation 0 and must still be present: a
 * missing base means its generation has not been read, never that it is 0. The shell reads
 * generations from the store (confector.core.rerun_generations); the pure core only receives
 * them.
 */
alias RerunGenerations = ulong[string];

/**
 * Returns the key that identifies a repository input: its declaration reduced to the kind,
 * repository id and ref selector, so fields that do not belong to the repository kind cannot
 * make two declarations of the same repository at the same ref distinct.
 *
 * Throws: InputResolutionException if `decl` is not a repository input.
 */
InputDecl repositoryInputKey(in InputDecl decl) pure @safe
{
    if (decl.kind != InputKind.repository)
    {
        throw new InputResolutionException(format("Input of kind '%s' is not a repository input", cast(string) decl.kind));
    }
    return repositoryInput(decl.spec.repository, decl.spec.refSelector);
}

/**
 * Returns the distinct repository inputs declared anywhere in `graph` that `knownPins` does not
 * already pin, sorted by repository id and then ref selector. The shell resolves each exactly
 * once and passes the results to `resolveGraphInputs`; pre-supplied pins are never resolved
 * live.
 *
 * Throws: InputResolutionException if a key of `knownPins` is not a repository input, or a
 * repository input names no repository or has an empty ref selector (see
 * `requireRepositorySpec`).
 */
InputDecl[] unpinnedRepositoryInputs(const TaskGraph graph, in InputPin[InputDecl] knownPins) @trusted
{
    const known = normalizePins(knownPins, "pre-supplied");

    bool[InputDecl] pending;
    foreach (taskId; graph.allTaskIds())
    {
        foreach (name, decl; graph.getTask(taskId).inputs)
        {
            if (decl.kind != InputKind.repository) continue;
            requireRepositorySpec(taskId, name, decl);
            const key = repositoryInputKey(decl);
            if (key !in known) pending[key] = true;
        }
    }

    InputDecl[] result = pending.keys;
    result.sort!((a, b) => a.spec.repository != b.spec.repository
        ? a.spec.repository < b.spec.repository
        : a.spec.refSelector < b.spec.refSelector);
    return result;
}

/**
 * Resolves the external inputs of every task in `graph`, keyed by task id, each task's sorted
 * by input name:
 *
 * - a value input pins to its value;
 * - a repository input pins to `knownPins[key]` if present, otherwise to
 *   `resolvedPins[key]`, where `key` is `repositoryInputKey` of its declaration. A
 *   pre-supplied pin always takes precedence; a resolver result for the same key is ignored.
 *   Pins for repository inputs the graph does not declare are ignored.
 *
 * Task output inputs are not resolved here: they pin to upstream fingerprints, which depend on
 * rerun generations, so they are pinned only when a chain is evaluated (`chainResolution`).
 * Every task of the graph has an entry. Pure: performs no I/O.
 *
 * Throws: InputResolutionException if a repository input has no pin in either map, if a pin
 * used is undefined or null, if a key of either map is not a repository input, or if a
 * repository input names no repository or has an empty ref selector.
 */
ResolvedInput[][string] resolveGraphInputs(
    const TaskGraph graph,
    in InputPin[InputDecl] knownPins,
    in InputPin[InputDecl] resolvedPins
) @trusted
{
    const known = normalizePins(knownPins, "pre-supplied");
    const resolved = normalizePins(resolvedPins, "resolver");

    ResolvedInput[][string] result;
    foreach (taskId; graph.allTaskIds())
    {
        const task = graph.getTask(taskId);

        ResolvedInput[] external;
        foreach (name; task.inputs.keys.sort().release)
        {
            const decl = task.inputs[name];
            if (decl.kind == InputKind.value)
            {
                external ~= ResolvedInput(name, InputKind.value, Json(decl.spec.value));
                continue;
            }
            if (decl.kind != InputKind.repository) continue;
            requireRepositorySpec(taskId, name, decl);
            const key = repositoryInputKey(decl);

            string source = "pre-supplied";
            auto pin = key in known;
            if (pin is null)
            {
                source = "resolver";
                pin = key in resolved;
            }
            if (pin is null)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s' at ref '%s') was neither pinned up front nor resolved",
                    taskId, name, decl.spec.repository, decl.spec.refSelector), taskId, name);
            }
            if (pin.pinned.type == Json.Type.undefined || pin.pinned.type == Json.Type.null_)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s' at ref '%s') has an empty %s pinned value",
                    taskId, name, decl.spec.repository, decl.spec.refSelector, source), taskId, name);
            }

            external ~= ResolvedInput(name, InputKind.repository, pin.pinned.clone, cast(string[string]) pin.info.dup);
        }
        result[taskId] = external;
    }
    return result;
}

/**
 * Throws InputResolutionException unless repository input `name` of task `taskId` names a
 * repository and a ref selector. There is no default ref: an empty selector is a definition
 * error, never "HEAD", "main" or the repository's default branch, because a guessed ref would
 * silently pin a revision nobody chose.
 */
void requireRepositorySpec(string taskId, string name, in InputDecl decl) pure @safe
{
    if (decl.spec.repository.length == 0)
    {
        throw new InputResolutionException(format(
            "Task '%s' repository input '%s' names no repository", taskId, name), taskId, name);
    }
    if (decl.spec.refSelector.length == 0)
    {
        throw new InputResolutionException(format(
            "Task '%s' input '%s' (repository '%s') has no ref selector; there is no default ref, so the task must name one",
            taskId, name, decl.spec.repository), taskId, name);
    }
}

/**
 * Freezes `graph` and its resolved external inputs (`resolveGraphInputs`) into a build chain's
 * tasks (design records: beads confector-z7z.1 and confector-z7z.15): every task of the graph,
 * sorted by id, with its declared inputs and its resolved repository and value inputs. Task
 * output inputs and fingerprints are never frozen; `chainResolution` computes them from the
 * chain and the current rerun generations.
 *
 * Throws: InputResolutionException if `externalInputs` lacks a task of `graph` or holds a
 * task output input.
 */
ChainTask[] freezeChain(const TaskGraph graph, in ResolvedInput[][string] externalInputs) @trusted
{
    ChainTask[] chain;
    foreach (taskId; graph.allTaskIds())
    {
        auto resolved = taskId in externalInputs;
        if (resolved is null)
        {
            throw new InputResolutionException(format("Task '%s' has not been resolved", taskId), taskId);
        }

        ChainTask frozen;
        frozen.id = taskId;
        foreach (name, decl; graph.getTask(taskId).inputs) frozen.inputs[name] = decl;
        foreach (ref input; *resolved)
        {
            if (input.kind == InputKind.taskOutput)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' is a task output, which a chain never freezes", taskId, input.name),
                    taskId, input.name);
            }
            frozen.resolvedInputs ~= ResolvedInput(input.name, input.kind, input.pinned.clone, cast(string[string]) input.info.dup);
        }
        chain ~= frozen;
    }
    return chain;
}

/**
 * Returns the graph structure `chain` froze: its tasks with their declared inputs and no
 * build configuration. Edges come from the frozen task_output inputs, so a later change to
 * the project's tasks cannot change a chain's structure.
 *
 * Throws: DAGValidationException if the chain's tasks do not form a valid graph.
 */
TaskGraph chainGraph(in ChainTask[] chain)
{
    TaskNode[] nodes;
    foreach (ref frozen; chain)
    {
        TaskNode node;
        node.id = frozen.id;
        foreach (name, decl; frozen.inputs) node.inputs[name] = decl;
        nodes ~= node;
    }
    return new TaskGraph(nodes);
}

/**
 * Computes every task's resolved inputs, base fingerprint and fingerprint from `chain` and the
 * current rerun `generations` (design record: bead confector-z7z.15): the frozen repository
 * pins, value inputs and graph structure, with task_output inputs pinned to upstream
 * fingerprints. Never reads the project or resolves anything, so every request on a chain sees
 * the same inputs; a task's resolved inputs are what its work order carries. Generations are
 * shared, live state, not part of the chain, so bumping a task's generation changes its
 * fingerprint and every downstream one in every chain that shares the task's base.
 *
 * `generations` must hold every base of the chain. Bases depend on upstream fingerprints, so
 * they become known a level at a time: the shell reads `unreadRerunBases` until none are left
 * (confector.core.rerun_generations.readChainResolution).
 *
 * Throws: InputResolutionException if a frozen resolved input does not match the task's
 * declared inputs, or a task's base is missing from `generations`; Exception if a frozen
 * repository input has no resolved pin.
 */
GraphResolution chainResolution(string projectId, in ChainTask[] chain, in RerunGenerations generations) @trusted
{
    string[string] unread;
    auto result = evaluateChain(projectId, chain, generations, unread);
    if (unread.length > 0)
    {
        const taskId = unread.keys.sort()[0];
        throw new InputResolutionException(format(
            "The rerun generation of task '%s' (base fingerprint %s) has not been read", taskId, unread[taskId]), taskId);
    }
    return result;
}

/**
 * Returns the bases of `chain` that `generations` lacks but that can be computed from it,
 * sorted and without duplicates; empty once `generations` covers the whole chain. Reading these
 * and calling again settles at least one more level of the graph each round. Pure.
 *
 * Throws: as `chainResolution`, except for missing generations.
 */
string[] unreadRerunBases(string projectId, in ChainTask[] chain, in RerunGenerations generations) @trusted
{
    string[string] unread;
    evaluateChain(projectId, chain, generations, unread);

    bool[string] distinct;
    foreach (base; unread.byValue) distinct[base] = true;
    return distinct.keys.sort().release;
}

/// Pins and fingerprints, in topological order, every task of `chain` whose own and upstream
/// generations are all in `generations`. A task whose base has no generation is added to
/// `unread` (task id -> base) and has inputs and a base but no fingerprint; tasks downstream of
/// it are skipped.
private GraphResolution evaluateChain(
    string projectId,
    in ChainTask[] chain,
    in RerunGenerations generations,
    ref string[string] unread
) @trusted
{
    auto graph = chainGraph(chain);

    ResolvedInput[string][string] repositoryPinsByTask;
    foreach (ref frozen; chain)
    {
        ResolvedInput[string] repositoryPins;
        foreach (ref input; frozen.resolvedInputs)
        {
            auto decl = input.name in frozen.inputs;
            if (decl is null || decl.kind != input.kind || input.kind == InputKind.taskOutput)
            {
                throw new InputResolutionException(format(
                    "Chain task '%s' has resolved input '%s' that does not match its declared inputs", frozen.id, input.name),
                    frozen.id, input.name);
            }
            if (input.kind == InputKind.value && input.pinned != Json(decl.spec.value))
            {
                throw new InputResolutionException(format(
                    "Chain task '%s' value input '%s' does not match its declared value", frozen.id, input.name),
                    frozen.id, input.name);
            }
            if (input.kind == InputKind.repository)
            {
                repositoryPins[input.name] = ResolvedInput(input.name, input.kind, input.pinned.clone, cast(string[string]) input.info.dup);
            }
        }
        repositoryPinsByTask[frozen.id] = repositoryPins;
    }

    GraphResolution result;
    foreach (taskId; graph.topologicalSort())
    {
        const task = graph.getTask(taskId);
        // Topological order puts every upstream task first; one without a fingerprint is
        // waiting for its generation to be read, and so is this task.
        bool upstreamPending = false;
        foreach (decl; task.inputs.byValue)
        {
            if (decl.kind == InputKind.taskOutput && decl.spec.task !in result.fingerprints) upstreamPending = true;
        }
        if (upstreamPending) continue;

        const(ResolvedInput[string]) repositoryPins = repositoryPinsByTask.get(taskId, null);
        auto inputs = pinInputs(task, result.fingerprints, repositoryPins);
        const base = computeBaseFingerprint(projectId, taskId, inputs);
        result.inputs[taskId] = inputs;
        result.bases[taskId] = base;

        auto generation = base in generations;
        if (generation is null)
        {
            unread[taskId] = base;
            continue;
        }
        result.fingerprints[taskId] = computeFingerprint(base, *generation);
    }
    return result;
}

/// Re-keys `pins` by repositoryInputKey. Throws if a key is not a repository input, or if two
/// keys that normalize alike carry different pins.
private InputPin[InputDecl] normalizePins(in InputPin[InputDecl] pins, string source) @trusted
{
    import confector.core.fingerprinter : canonicalPinned;

    InputPin[InputDecl] result;
    foreach (decl, pin; pins)
    {
        if (decl.kind != InputKind.repository)
        {
            throw new InputResolutionException(format(
                "A %s pin is keyed by an input of kind '%s'; only repository inputs are pinned this way",
                source, cast(string) decl.kind));
        }
        const key = repositoryInputKey(decl);
        if (auto existing = key in result)
        {
            if (existing.pinned.type == Json.Type.undefined || pin.pinned.type == Json.Type.undefined
                || canonicalPinned(existing.pinned) != canonicalPinned(pin.pinned))
            {
                throw new InputResolutionException(format(
                    "Conflicting %s pins for repository '%s' at ref '%s'", source, key.spec.repository, key.spec.refSelector));
            }
            continue;
        }
        result[key] = InputPin(pin.pinned.clone, cast(string[string]) pin.info.dup);
    }
    return result;
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    private InputPin pinOf(string sha, string[string] info = null)
    {
        return InputPin(Json(sha), info);
    }

    private const(ResolvedInput) inputNamed(in GraphResolution r, string taskId, string name)
    {
        foreach (ref input; r.inputs[taskId])
        {
            if (input.name == name) return input;
        }
        assert(false, format("task '%s' has no resolved input '%s'", taskId, name));
    }

    /// `chainResolution` with every base `generations` lacks read at generation 0, the way the
    /// shell reads them a level at a time.
    private GraphResolution atGenerations(string projectId, in ChainTask[] chain, RerunGenerations generations = null)
    {
        for (auto unread = unreadRerunBases(projectId, chain, generations); unread.length > 0;
            unread = unreadRerunBases(projectId, chain, generations))
        {
            foreach (base; unread) generations[base] = 0;
        }
        return chainResolution(projectId, chain, generations);
    }

    /// Resolves, freezes and evaluates `graph` in project "p", with no task ever rerun.
    private GraphResolution evaluate(const TaskGraph graph, in InputPin[InputDecl] known, in InputPin[InputDecl] resolved)
    {
        return atGenerations("p", freezeChain(graph, resolveGraphInputs(graph, known, resolved)));
    }

    /// The fingerprint of a task never rerun.
    private string firstFingerprint(string projectId, string taskId, in ResolvedInput[] inputs)
    {
        return computeFingerprint(computeBaseFingerprint(projectId, taskId, inputs), 0);
    }
}

unittest
{
    // The whole DAG is resolved, including tasks that are not targets of anything, and
    // task_output inputs pin to upstream fingerprints in topological order.
    TaskNode compile; compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", "main");
    compile.inputs["flavor"] = valueInput("internal");
    TaskNode test; test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile", "binaries");
    test.inputs["src"] = repositoryInput("game", "main");
    TaskNode package_; package_.id = "package";
    package_.inputs["bin"] = taskOutputInput("compile", "binaries");
    package_.inputs["report"] = taskOutputInput("test");
    TaskNode lint; lint.id = "lint"; // no inputs at all

    auto graph = new TaskGraph([package_, lint, test, compile]);
    InputPin[InputDecl] none;
    auto pending = unpinnedRepositoryInputs(graph, none);
    assert(pending == [repositoryInput("game", "main")]);

    InputPin[InputDecl] resolved = [repositoryInput("game", "main"): pinOf("aaa111")];
    auto r = evaluate(graph, none, resolved);

    assert(r.inputs.length == 4 && r.fingerprints.length == 4, "Every task must be resolved and fingerprinted");
    assert(r.inputs["lint"].length == 0);
    assert(r.fingerprints["lint"] == firstFingerprint("p", "lint", []));
    assert(r.bases["lint"] == computeBaseFingerprint("p", "lint", []));

    assert(inputNamed(r, "compile", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "compile", "flavor").pinned == Json("internal"));
    assert(inputNamed(r, "test", "bin").pinned == Json(r.fingerprints["compile"]));
    assert(inputNamed(r, "package", "report").pinned == Json(r.fingerprints["test"]));
    assert(r.fingerprints["compile"] == firstFingerprint("p", "compile", r.inputs["compile"]));
    assert(r.fingerprints["package"] == firstFingerprint("p", "package", r.inputs["package"]));

    // Each task's inputs are sorted by name
    assert(r.inputs["compile"][0].name == "flavor" && r.inputs["compile"][1].name == "src");

    // Build configuration is not an input: changing steps leaves every fingerprint unchanged
    TaskNode compileSteps = compile;
    compileSteps.steps = [BuildStep("Build", "bash", null, "dub build --build=release")];
    assert(evaluate(new TaskGraph([package_, lint, test, compileSteps]), none, resolved).fingerprints
        == r.fingerprints);

    // A new revision changes the repository's tasks and everything downstream, but not lint
    InputPin[InputDecl] newer = [repositoryInput("game", "main"): pinOf("bbb222")];
    auto r2 = evaluate(graph, none, newer);
    foreach (id; ["compile", "test", "package"]) assert(r2.fingerprints[id] != r.fingerprints[id]);
    assert(r2.fingerprints["lint"] == r.fingerprints["lint"]);
}

unittest
{
    // A shared repository input resolves once, and all tasks agree on its pinned value,
    // whatever name each task gives the input. A different ref is a distinct input.
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game", "main");
    TaskNode b; b.id = "b"; b.inputs["code"] = repositoryInput("game", "main");
    b.inputs["engine"] = repositoryInput("engine", "stable");
    TaskNode c; c.id = "c"; c.inputs["src"] = repositoryInput("game", "release");
    c.inputs["engine"] = repositoryInput("engine", "stable");
    auto graph = new TaskGraph([a, b, c]);

    InputPin[InputDecl] none;
    auto pending = unpinnedRepositoryInputs(graph, none);
    assert(pending == [
        repositoryInput("engine", "stable"),
        repositoryInput("game", "main"),
        repositoryInput("game", "release"),
    ], "Each distinct repository input must be listed once, in a deterministic order");

    InputPin[InputDecl] resolved = [
        repositoryInput("engine", "stable"): pinOf("eee555"),
        repositoryInput("game", "main"): pinOf("aaa111"),
        repositoryInput("game", "release"): pinOf("ccc333"),
    ];
    auto r = evaluate(graph, none, resolved);
    assert(inputNamed(r, "a", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "b", "code").pinned == Json("aaa111"));
    assert(inputNamed(r, "b", "engine").pinned == Json("eee555"));
    assert(inputNamed(r, "c", "engine").pinned == Json("eee555"));
    assert(inputNamed(r, "c", "src").pinned == Json("ccc333"));
}

unittest
{
    // Pre-supplied pins take precedence over live resolution, and are not listed for resolving
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game", "main");
    a.inputs["engine"] = repositoryInput("engine", "stable");
    auto graph = new TaskGraph([a]);

    InputPin[InputDecl] known = [repositoryInput("game", "main"): pinOf("from-trigger")];
    assert(unpinnedRepositoryInputs(graph, known) == [repositoryInput("engine", "stable")]);

    InputPin[InputDecl] resolved = [
        repositoryInput("game", "main"): pinOf("from-resolver"),
        repositoryInput("engine", "stable"): pinOf("eee555"),
    ];
    auto r = evaluate(graph, known, resolved);
    assert(inputNamed(r, "a", "src").pinned == Json("from-trigger"));
    assert(inputNamed(r, "a", "engine").pinned == Json("eee555"));

    // Everything pinned up front needs no resolution at all
    known[repositoryInput("engine", "stable")] = pinOf("eee000");
    assert(unpinnedRepositoryInputs(graph, known).length == 0);
    InputPin[InputDecl] none;
    auto r2 = evaluate(graph, known, none);
    assert(inputNamed(r2, "a", "engine").pinned == Json("eee000"));

    // Pins for repositories the graph does not use are ignored
    known[repositoryInput("tools", "main")] = pinOf("ttt999");
    assert(evaluate(graph, known, none).fingerprints == r2.fingerprints);
}

unittest
{
    // Display info is carried into the resolved input but never hashed; pinned values are
    // opaque, so a provider may pin to an object
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("depot", "//game/main");
    auto graph = new TaskGraph([a]);
    InputPin[InputDecl] none;

    Json changelist = Json.emptyObject;
    changelist["server"] = "perforce:1666";
    changelist["change"] = 4242;
    InputPin[InputDecl] plain = [repositoryInput("depot", "//game/main"): InputPin(changelist)];
    InputPin[InputDecl] withInfo = [repositoryInput("depot", "//game/main"):
        InputPin(changelist, ["description": "Fix the build"])];

    auto r1 = evaluate(graph, none, plain);
    auto r2 = evaluate(graph, none, withInfo);
    assert(inputNamed(r2, "a", "src").info.length == 1 && inputNamed(r2, "a", "src").info["description"] == "Fix the build");
    assert(inputNamed(r2, "a", "src").pinned == changelist);
    assert(r1.fingerprints == r2.fingerprints);
}

unittest
{
    // An unresolvable repository input fails loudly, naming the task and input
    TaskNode a; a.id = "a"; a.inputs["v"] = valueInput("x");
    TaskNode b; b.id = "b"; b.inputs["src"] = repositoryInput("game", "main");
    b.inputs["a"] = taskOutputInput("a");
    auto graph = new TaskGraph([a, b]);
    InputPin[InputDecl] none;

    try
    {
        evaluate(graph, none, none);
        assert(false, "expected InputResolutionException");
    }
    catch (InputResolutionException ex)
    {
        assert(ex.taskId == "b" && ex.inputName == "src");
        assert(ex.msg.canFind("'game'") && ex.msg.canFind("'main'"));
    }

    // A pin for the same repository at another ref does not cover it
    InputPin[InputDecl] otherRef = [repositoryInput("game", "release"): pinOf("ccc333")];
    bool threw = false;
    try evaluate(graph, otherRef, none);
    catch (InputResolutionException) threw = true;
    assert(threw);

    // An undefined or null pin is not a value
    foreach (bad; [Json.undefined, Json(null)])
    {
        InputPin[InputDecl] badPins = [repositoryInput("game", "main"): InputPin(bad)];
        threw = false;
        try evaluate(graph, none, badPins);
        catch (InputResolutionException ex) threw = ex.taskId == "b" && ex.inputName == "src";
        assert(threw, "An empty pinned value must throw");
    }
}

unittest
{
    // Pins must be keyed by repository inputs; anything else is a caller error
    TaskNode a; a.id = "a"; a.inputs["v"] = valueInput("x");
    auto graph = new TaskGraph([a]);
    InputPin[InputDecl] none;
    InputPin[InputDecl] valuePin = [valueInput("x"): pinOf("y")];

    bool threw = false;
    try evaluate(graph, valuePin, none);
    catch (InputResolutionException) threw = true;
    assert(threw, "A pre-supplied pin keyed by a value input must throw");

    threw = false;
    try unpinnedRepositoryInputs(graph, valuePin);
    catch (InputResolutionException) threw = true;
    assert(threw);

    // Keys that differ only in fields outside the repository kind are the same input
    InputDecl noisy = repositoryInput("game", "main");
    noisy.spec.value = "stray";
    TaskNode b; b.id = "b"; b.inputs["src"] = noisy;
    auto g2 = new TaskGraph([b]);
    InputPin[InputDecl] known = [repositoryInput("game", "main"): pinOf("aaa111")];
    assert(unpinnedRepositoryInputs(g2, known).length == 0);
    assert(inputNamed(evaluate(g2, known, none), "b", "src").pinned == Json("aaa111"));
}

unittest
{
    // A repository input must name a repository and a ref selector; there is no default ref,
    // and a pre-supplied pin does not excuse an empty selector
    foreach (bad; [repositoryInput("game", ""), repositoryInput("", "main")])
    {
        TaskNode a; a.id = "a"; a.inputs["src"] = bad;
        auto graph = new TaskGraph([a]);
        InputPin[InputDecl] none;
        InputPin[InputDecl] pinned = [bad: pinOf("aaa111")];

        bool threw = false;
        try unpinnedRepositoryInputs(graph, none);
        catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "src";
        assert(threw, "An incomplete repository input must not be listed for resolving");

        threw = false;
        try evaluate(graph, pinned, none);
        catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "src";
        assert(threw, "An incomplete repository input must not resolve, even when pinned");
    }
}

unittest
{
    // A frozen chain holds every task with its declared inputs and its resolved repository and
    // value inputs (never task outputs); evaluating it pins task outputs to upstream fingerprints
    TaskNode compile; compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", "main");
    compile.inputs["flavor"] = valueInput("internal");
    compile.steps = [BuildStep("Build", "bash", null, "dub build")];
    TaskNode test; test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile", "binaries");
    TaskNode lint; lint.id = "lint";
    auto graph = new TaskGraph([test, lint, compile]);

    InputPin[InputDecl] none;
    InputPin[InputDecl] resolved = [repositoryInput("game", "main"): pinOf("aaa111", ["ref": "refs/heads/main"])];
    auto external = resolveGraphInputs(graph, none, resolved);
    assert(external.length == 3 && external["test"].length == 0, "Task outputs are not resolved before evaluation");
    auto chain = freezeChain(graph, external);

    assert(chain.length == 3 && chain[0].id == "compile" && chain[1].id == "lint" && chain[2].id == "test");
    assert(chain[0].inputs == compile.inputs);
    assert(chain[0].resolvedInputs.length == 2);
    assert(chain[0].resolvedInputs[0] == ResolvedInput("flavor", InputKind.value, Json("internal")));
    assert(chain[0].resolvedInputs[1].pinned == Json("aaa111") && chain[0].resolvedInputs[1].info["ref"] == "refs/heads/main");
    assert(chain[1].inputs.length == 0 && chain[1].resolvedInputs.length == 0);
    assert(chain[2].inputs.length == 1 && chain[2].resolvedInputs.length == 0, "Task outputs are not frozen");

    auto resolution = atGenerations("p", chain);
    assert(resolution.fingerprints.length == 3 && resolution.bases.length == 3);
    assert(resolution.inputs["compile"] == chain[0].resolvedInputs);
    // A task's resolved inputs, task outputs included, are what the task's work order carries
    assert(resolution.inputs["test"] == [ResolvedInput("bin", InputKind.taskOutput, Json(resolution.fingerprints["compile"]))]);
    assert(atGenerations("q", chain).fingerprints["lint"] != resolution.fingerprints["lint"], "The project is part of every fingerprint");

    // Resolved inputs holding a task output cannot be frozen
    ResolvedInput[][string] withTaskOutput;
    foreach (id, inputs; external) withTaskOutput[id] = cast(ResolvedInput[]) inputs.dup;
    withTaskOutput["test"] = [ResolvedInput("bin", InputKind.taskOutput, Json("fp"))];
    bool threw = false;
    try freezeChain(graph, withTaskOutput);
    catch (InputResolutionException ex) threw = ex.taskId == "test" && ex.inputName == "bin";
    assert(threw);

    // The chain does not alias the project's tasks: editing them later changes nothing
    compile.inputs["src"] = repositoryInput("game", "release");
    compile.inputs["extra"] = valueInput("x");
    assert(chain[0].inputs.length == 2 && chain[0].inputs["src"] == repositoryInput("game", "main"));
    assert(atGenerations("p", chain).fingerprints == resolution.fingerprints);

    // Survives a serialization round trip, as when stored in and loaded from the state store
    import vibe.data.json : deserializeJson, serializeToJson;
    BuildRecord record;
    record.buildId = "b1";
    record.chainId = "b1";
    record.chainTasks = chain;
    auto loaded = deserializeJson!BuildRecord(serializeToJson(record).toString());
    assert(loaded.chainId == "b1" && loaded.chainTasks.length == 3);
    assert(loaded.chainTasks[0].inputs["src"] == repositoryInput("game", "main"));
    assert(atGenerations("p", loaded.chainTasks).fingerprints == resolution.fingerprints);
}

unittest
{
    // chainResolution reads only the chain: a new revision or a missing pin is visible only
    // through the frozen values, and a chain inconsistent with its declarations fails loudly
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game", "main");
    a.inputs["v"] = valueInput("x");
    TaskNode b; b.id = "b"; b.inputs["a"] = taskOutputInput("a");
    auto graph = new TaskGraph([a, b]);
    InputPin[InputDecl] none;
    auto chain = freezeChain(graph, resolveGraphInputs(graph, none, [repositoryInput("game", "main"): pinOf("aaa111")]));
    const base = atGenerations("p", chain).fingerprints;

    auto newer = freezeChain(graph, resolveGraphInputs(graph, none, [repositoryInput("game", "main"): pinOf("bbb222")]));
    assert(atGenerations("p", newer).fingerprints["a"] != base["a"] && atGenerations("p", newer).fingerprints["b"] != base["b"]);

    ChainTask[] dropped = [ChainTask(chain[0].id, chain[0].inputs, [chain[0].resolvedInputs[1]]), chain[1]];
    bool threw = false;
    try atGenerations("p", dropped);
    catch (Exception ex) threw = ex.msg.canFind("'src'");
    assert(threw, "A frozen repository input without a pin must throw");

    ChainTask[] wrongValue = [ChainTask(chain[0].id, chain[0].inputs,
        [chain[0].resolvedInputs[0], ResolvedInput("v", InputKind.value, Json("y"))]), chain[1]];
    threw = false;
    try atGenerations("p", wrongValue);
    catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "v";
    assert(threw);

    ChainTask[] undeclared = [ChainTask(chain[0].id, chain[0].inputs,
        chain[0].resolvedInputs ~ ResolvedInput("ghost", InputKind.value, Json("z"))), chain[1]];
    threw = false;
    try atGenerations("p", undeclared);
    catch (InputResolutionException ex) threw = ex.inputName == "ghost";
    assert(threw);
}

unittest
{
    // Rerun generations: bases become known a level at a time, and a generation that has not
    // been read is an error, never generation 0
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game", "main");
    TaskNode release; release.id = "release"; release.inputs["tested"] = taskOutputInput("test");
    release.inputs["linted"] = taskOutputInput("lint");
    auto graph = new TaskGraph([compile, test, lint, release]);
    InputPin[InputDecl] none;
    auto chain = freezeChain(graph, resolveGraphInputs(graph, none, [repositoryInput("game", "main"): pinOf("aaa111")]));

    RerunGenerations generations;
    auto first = unreadRerunBases("p", chain, generations);
    assert(first.length == 2, "Only the tasks without upstream tasks have computable bases");
    foreach (base; first) generations[base] = 0;
    auto second = unreadRerunBases("p", chain, generations);
    assert(second.length == 1);
    foreach (base; second) generations[base] = 0;
    auto third = unreadRerunBases("p", chain, generations);
    assert(third.length == 1);
    foreach (base; third) generations[base] = 0;
    assert(unreadRerunBases("p", chain, generations).length == 0);
    auto r = chainResolution("p", chain, generations);
    assert(r.fingerprints == atGenerations("p", chain).fingerprints);
    foreach (id; ["compile", "test", "lint", "release"])
    {
        assert(r.fingerprints[id] == computeFingerprint(r.bases[id], 0));
        assert(r.fingerprints[id] == firstFingerprint("p", id, r.inputs[id]));
    }

    RerunGenerations partial;
    foreach (base; first) partial[base] = 0;
    bool threw = false;
    try chainResolution("p", chain, partial);
    catch (InputResolutionException ex) threw = ex.taskId == "test" && ex.msg.canFind(r.bases["test"]);
    assert(threw, "A base whose generation was not read must throw");
}

unittest
{
    // Bumping a task's generation changes its fingerprint and every downstream fingerprint, in
    // every chain sharing the task's base, and nothing else
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
    TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game", "main");
    TaskNode docs; docs.id = "docs"; docs.inputs["src"] = repositoryInput("game", "main");
    TaskNode publish; publish.id = "publish"; publish.inputs["bin"] = taskOutputInput("compile");
    publish.inputs["docs"] = taskOutputInput("docs");
    InputPin[InputDecl] none;
    InputPin[InputDecl] atA = [repositoryInput("game", "main"): pinOf("aaa111")];
    InputPin[InputDecl] atB = [repositoryInput("game", "main"): pinOf("bbb222")];

    // Two chains pinning the same revision (for example on different branches) share
    // compile's base even with different task sets; a chain at another revision does not
    auto graphOne = new TaskGraph([compile, test, report, lint]);
    auto graphTwo = new TaskGraph([compile, docs, publish]);
    auto graphOther = new TaskGraph([compile, test]);
    auto chainOne = freezeChain(graphOne, resolveGraphInputs(graphOne, none, atA));
    auto chainTwo = freezeChain(graphTwo, resolveGraphInputs(graphTwo, none, atA));
    auto chainOther = freezeChain(graphOther, resolveGraphInputs(graphOther, none, atB));

    auto one = atGenerations("p", chainOne);
    auto two = atGenerations("p", chainTwo);
    auto other = atGenerations("p", chainOther);
    assert(one.bases["compile"] == two.bases["compile"] && one.fingerprints["compile"] == two.fingerprints["compile"]);
    assert(other.bases["compile"] != one.bases["compile"]);

    RerunGenerations rerun = [one.bases["compile"]: 1];
    auto oneAfter = atGenerations("p", chainOne, rerun.dup);
    auto twoAfter = atGenerations("p", chainTwo, rerun.dup);
    auto otherAfter = atGenerations("p", chainOther, rerun.dup);

    // The rerun task keeps its base and gets a new fingerprint; downstream tasks get new bases
    assert(oneAfter.bases["compile"] == one.bases["compile"]);
    foreach (id; ["compile", "test", "report"]) assert(oneAfter.fingerprints[id] != one.fingerprints[id], id);
    foreach (id; ["test", "report"]) assert(oneAfter.bases[id] != one.bases[id], id);
    assert(oneAfter.fingerprints["lint"] == one.fingerprints["lint"], "Tasks not downstream are unaffected");

    foreach (id; ["compile", "publish"]) assert(twoAfter.fingerprints[id] != two.fingerprints[id], id);
    assert(twoAfter.fingerprints["docs"] == two.fingerprints["docs"]);
    assert(twoAfter.fingerprints["compile"] == oneAfter.fingerprints["compile"], "Chains sharing a base stay in step");

    assert(otherAfter.fingerprints == other.fingerprints, "A chain that does not share the base is unaffected");

    // Each further generation is new again, and a downstream task can be rerun on its own
    RerunGenerations twice = [one.bases["compile"]: 2];
    assert(atGenerations("p", chainOne, twice).fingerprints["compile"] != oneAfter.fingerprints["compile"]);
    RerunGenerations testOnly = [one.bases["test"]: 1];
    auto testRerun = atGenerations("p", chainOne, testOnly);
    assert(testRerun.fingerprints["compile"] == one.fingerprints["compile"]);
    assert(testRerun.fingerprints["test"] != one.fingerprints["test"] && testRerun.fingerprints["report"] != one.fingerprints["report"]);

    // Generations for bases the chain does not have are ignored
    RerunGenerations unrelated = [other.bases["compile"]: 5];
    assert(atGenerations("p", chainOne, unrelated).fingerprints == one.fingerprints);
}
