module confector.core.input_resolution;

/**
 * Pure whole-DAG input resolution (design record: bead confector-z7z.13; AGENTS.md, "The input
 * model"). Turns every declared input of every task in a graph into a ResolvedInput and
 * fingerprints every task, so a chain created from the result pins the same revisions for
 * every task, including tasks nobody has asked to build yet.
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
 */

import confector.core.dag : TaskGraph;
import confector.core.fingerprinter : computeNodeFingerprint, pinInputs;
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
 * Every task's resolved inputs and fingerprint, for the whole graph.
 */
struct GraphResolution
{
    /// Resolved inputs keyed by task id, each task's sorted by input name. Every task in the
    /// graph has an entry, empty when it declares no inputs.
    ResolvedInput[][string] inputs;
    /// Fingerprint keyed by task id, for every task in the graph.
    string[string] fingerprints;
}

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
 * Throws: InputResolutionException if a key of `knownPins` is not a repository input.
 */
InputDecl[] unpinnedRepositoryInputs(const TaskGraph graph, in InputPin[InputDecl] knownPins) @trusted
{
    const known = normalizePins(knownPins, "pre-supplied");

    bool[InputDecl] pending;
    foreach (taskId; graph.allTaskIds())
    {
        foreach (decl; graph.getTask(taskId).inputs.byValue)
        {
            if (decl.kind != InputKind.repository) continue;
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
 * Resolves every declared input of every task in `graph` and fingerprints every task, in
 * topological order:
 *
 * - a value input pins to its value;
 * - a repository input pins to `knownPins[key]` if present, otherwise to
 *   `resolvedPins[key]`, where `key` is `repositoryInputKey` of its declaration. A
 *   pre-supplied pin always takes precedence; a resolver result for the same key is ignored.
 *   Pins for repository inputs the graph does not declare are ignored;
 * - a task_output input pins to the upstream task's fingerprint.
 *
 * Fingerprints come from `computeNodeFingerprint` with `projectId`. Pure: performs no I/O.
 *
 * Throws: InputResolutionException if a repository input has no pin in either map, if a pin
 * used is undefined or null, or if a key of either map is not a repository input.
 */
GraphResolution resolveGraphInputs(
    string projectId,
    const TaskGraph graph,
    in InputPin[InputDecl] knownPins,
    in InputPin[InputDecl] resolvedPins
) @trusted
{
    const known = normalizePins(knownPins, "pre-supplied");
    const resolved = normalizePins(resolvedPins, "resolver");

    GraphResolution result;
    foreach (taskId; graph.topologicalSort())
    {
        const task = graph.getTask(taskId);

        ResolvedInput[string] repositoryPins;
        foreach (name, decl; task.inputs)
        {
            if (decl.kind != InputKind.repository) continue;
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

            repositoryPins[name] = ResolvedInput(name, InputKind.repository, pin.pinned.clone, cast(string[string]) pin.info.dup);
        }

        // Topological order guarantees every upstream fingerprint is already present.
        auto inputs = pinInputs(task, result.fingerprints, repositoryPins);
        result.inputs[taskId] = inputs;
        result.fingerprints[taskId] = computeNodeFingerprint(projectId, taskId, inputs);
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
    auto r = resolveGraphInputs("p", graph, none, resolved);

    assert(r.inputs.length == 4 && r.fingerprints.length == 4, "Every task must be resolved and fingerprinted");
    assert(r.inputs["lint"].length == 0);
    assert(r.fingerprints["lint"] == computeNodeFingerprint("p", "lint", []));

    assert(inputNamed(r, "compile", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "compile", "flavor").pinned == Json("internal"));
    assert(inputNamed(r, "test", "bin").pinned == Json(r.fingerprints["compile"]));
    assert(inputNamed(r, "package", "report").pinned == Json(r.fingerprints["test"]));
    assert(r.fingerprints["compile"] == computeNodeFingerprint("p", "compile", r.inputs["compile"]));
    assert(r.fingerprints["package"] == computeNodeFingerprint("p", "package", r.inputs["package"]));

    // Each task's inputs are sorted by name
    assert(r.inputs["compile"][0].name == "flavor" && r.inputs["compile"][1].name == "src");

    // Agrees with TaskGraph's fingerprints given the same repository pins
    ResolvedInput[string][string] byTask = [
        "compile": ["src": ResolvedInput("src", InputKind.repository, Json("aaa111"))],
        "test": ["src": ResolvedInput("src", InputKind.repository, Json("aaa111"))],
    ];
    graph.computeFingerprints("p", byTask);
    assert(graph.allFingerprints() == r.fingerprints);

    // A new revision changes the repository's tasks and everything downstream, but not lint
    InputPin[InputDecl] newer = [repositoryInput("game", "main"): pinOf("bbb222")];
    auto r2 = resolveGraphInputs("p", graph, none, newer);
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
    auto r = resolveGraphInputs("p", graph, none, resolved);
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
    auto r = resolveGraphInputs("p", graph, known, resolved);
    assert(inputNamed(r, "a", "src").pinned == Json("from-trigger"));
    assert(inputNamed(r, "a", "engine").pinned == Json("eee555"));

    // Everything pinned up front needs no resolution at all
    known[repositoryInput("engine", "stable")] = pinOf("eee000");
    assert(unpinnedRepositoryInputs(graph, known).length == 0);
    InputPin[InputDecl] none;
    auto r2 = resolveGraphInputs("p", graph, known, none);
    assert(inputNamed(r2, "a", "engine").pinned == Json("eee000"));

    // Pins for repositories the graph does not use are ignored
    known[repositoryInput("tools", "main")] = pinOf("ttt999");
    assert(resolveGraphInputs("p", graph, known, none).fingerprints == r2.fingerprints);
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

    auto r1 = resolveGraphInputs("p", graph, none, plain);
    auto r2 = resolveGraphInputs("p", graph, none, withInfo);
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
        resolveGraphInputs("p", graph, none, none);
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
    try resolveGraphInputs("p", graph, otherRef, none);
    catch (InputResolutionException) threw = true;
    assert(threw);

    // An undefined or null pin is not a value
    foreach (bad; [Json.undefined, Json(null)])
    {
        InputPin[InputDecl] badPins = [repositoryInput("game", "main"): InputPin(bad)];
        threw = false;
        try resolveGraphInputs("p", graph, none, badPins);
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
    try resolveGraphInputs("p", graph, valuePin, none);
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
    assert(inputNamed(resolveGraphInputs("p", g2, known, none), "b", "src").pinned == Json("aaa111"));
}
