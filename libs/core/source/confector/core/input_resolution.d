module confector.core.input_resolution;

/**
 * Pure whole-DAG input resolution (AGENTS.md, "The input model"). Turns every declared
 * external input (repository and value) of every task in a graph into a ResolvedInput, and
 * computes every task's fingerprint from a graph, the refs its inputs are bound to, the pins it is
 * evaluated against and the current rerun generations.
 *
 * - `requiredPins` lists the (repository, ref) each repository input in the graph needs, and
 * - `resolveGraphInputs` pins every task's repository and value inputs from given pins.
 * - `graphResolution` computes every task's fingerprint from the graph, its bindings, its pins and
 *   the current rerun generations; `completeGraphResolution` is the same for callers that hold
 *   every generation.
 *
 * Repository inputs are bound to refs per request (`InputBinding`, keyed by `InputKey`), and a
 * request's pins hold one revision per (repository, ref) (`RepositoryPin`, keyed by `RepositoryAt`;
 * confector.core.chain_pins), so every input bound to a ref sees the request's one revision of it.
 * The repository of an input is the one its declaration names. Only the revision reaches a
 * fingerprint, never the ref (AGENTS.md, invariant 1), so two inputs at one revision through
 * different refs hash alike. Which ref an input is bound to is the trigger's or request's choice,
 * or the input's default; nothing here chooses a ref.
 *
 * Rerun generations are read by the shell in
 * confector.core.rerun_generations.
 */

import confector.core.dag : TaskGraph;
import confector.core.fingerprinter : computeBaseFingerprint, computeFingerprint, pinInputs;
import confector.api.model;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * A declared input could not be resolved: it is not bound to a ref, no pin covers its ref, its pin
 * is not a usable value, or its declaration is malformed.
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
 * Tasks' resolved inputs, base fingerprints and fingerprints (`graphResolution`). Complete only
 * when `graphResolution` reported no unread generations (see `completeGraphResolution`): then
 * every task of the graph has an entry in each map. Otherwise a task whose generation is unread
 * has inputs and a base but no fingerprint, and tasks downstream of it have no entries.
 */
struct GraphResolution
{
    /// Resolved inputs keyed by task id, each task's sorted by input name; empty when the task
    /// declares no inputs.
    ResolvedInput[][string] inputs;
    /// Base fingerprint (the fingerprint without the rerun generation) keyed by task id. Rerun
    /// generations are keyed by it.
    string[string] bases;
    /// Fingerprint keyed by task id.
    string[string] fingerprints;
    /// The rerun generation of each task's base, keyed by task id: an entry exactly when the task
    /// has a fingerprint.
    ulong[string] generations;
}

/**
 * The current rerun generation of each base fingerprint,
 * keyed by base. A base that was never rerun is at generation 0 and must still be present: a
 * missing base means its generation has not been read, never that it is 0. The shell reads
 * generations from the store (confector.core.rerun_generations); the pure core only receives
 * them.
 */
alias RerunGenerations = ulong[string];

/**
 * Returns the (repository, ref) each repository input declared anywhere in `graph` needs, keyed by
 * input: the repository its declaration names, at the ref `bindings` binds it to. Bindings for
 * inputs the graph does not declare are ignored.
 *
 * Throws: InputResolutionException if a repository input is malformed (see
 * `requireRepositorySpec`) or `bindings` does not bind it.
 */
RepositoryAt[InputKey] requiredPins(const TaskGraph graph, in RepositoryRef[InputKey] bindings) @trusted
{
    RepositoryAt[InputKey] result;
    foreach (taskId; graph.allTaskIds())
    {
        foreach (name, decl; graph.getTask(taskId).inputs)
        {
            if (decl.kind != InputKind.repository) continue;
            requireRepositorySpec(taskId, name, decl);
            const key = InputKey(taskId, name);
            auto bound = key in bindings;
            if (bound is null)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s') is not bound to a ref", taskId, name, decl.spec.repository), taskId, name);
            }
            result[key] = RepositoryAt(decl.spec.repository, *bound);
        }
    }
    return result;
}

/**
 * Resolves the external inputs of every task in `graph`, keyed by task id, each task's sorted
 * by input name:
 *
 * - a value input pins to its value;
 * - a repository input pins to the revision of `pins[RepositoryAt(repository, ref)]`, where
 *   the repository is the one the input declares and the ref the one `bindings` binds it to; the
 *   ref is not part of the resolved input. Pins no input needs are ignored.
 *
 * Task output inputs are not resolved here: they pin to upstream fingerprints, which depend on
 * rerun generations, so they are pinned only by `graphResolution`.
 * Every task of the graph has an entry. Pure: performs no I/O.
 *
 * Throws: InputResolutionException if a repository input is not bound, has no pin or an empty
 * one, an entry of `pins` is not stored under its own key, or a repository input is malformed.
 */
ResolvedInput[][string] resolveGraphInputs(const TaskGraph graph, in RepositoryRef[InputKey] bindings,
    in RepositoryPin[RepositoryAt] pins) @trusted
{
    requireKeyed(pins);
    const needed = requiredPins(graph, bindings);

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

            const at = needed[InputKey(taskId, name)];
            auto pin = at in pins;
            if (pin is null)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s' at %s '%s') is not pinned",
                    taskId, name, at.repositoryId, cast(string) at.ref_.kind, at.ref_.name), taskId, name);
            }
            if (pin.pin.pinned.type == Json.Type.undefined || pin.pin.pinned.type == Json.Type.null_)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s' at %s '%s') has an empty pinned value",
                    taskId, name, at.repositoryId, cast(string) at.ref_.kind, at.ref_.name), taskId, name);
            }

            external ~= ResolvedInput(name, InputKind.repository, pin.pin.pinned.clone, cast(string[string]) pin.pin.info.dup);
        }
        result[taskId] = external;
    }
    return result;
}

/**
 * Throws InputResolutionException unless repository input `name` of task `taskId` names a
 * repository, its visibility filter and default ref spec are well formed, and the default is
 * `same [else ...]` or a fixed ref: never `event`, since an input's default cannot make events
 * fire a trigger (only a trigger's own spec does). An input needs no default: the trigger or
 * request chooses its ref, and a request that cannot is refused when the definition loads,
 * never defaulted to "HEAD", "main" or the repository's default branch.
 */
void requireRepositorySpec(string taskId, string name, in InputDecl decl) pure @safe
{
    if (decl.spec.repository.length == 0)
    {
        throw new InputResolutionException(format(
            "Task '%s' repository input '%s' names no repository", taskId, name), taskId, name);
    }
    try requireWellFormed(decl.spec.branches, decl.spec.defaultRef);
    catch (InvalidRefSpecException e)
    {
        throw new InputResolutionException(format("Task '%s' input '%s' (repository '%s'): %s", taskId, name,
            decl.spec.repository, e.msg), taskId, name);
    }
    if (decl.spec.defaultRef.kind == RefSpecKind.event)
    {
        throw new InputResolutionException(format(
            "Task '%s' input '%s' (repository '%s') has the default ref spec '%s'; an input's default cannot fire a trigger, so it is same [else <ref>|else skip] or a fixed ref",
            taskId, name, decl.spec.repository, decl.spec.defaultRef.toString()), taskId, name);
    }
}

/**
 * Computes every task's resolved inputs, base fingerprint and fingerprint from `graph`, the refs
 * `bindings` binds its repository inputs to, `pins` (keyed by repository and ref, as
 * `resolveGraphInputs` takes them) and the current rerun `generations`, in topological order:
 * value inputs pin to their values,
 * repository inputs to their pins' revisions, and task output inputs to upstream fingerprints. A
 * task's resolved inputs are what its work order carries. Generations are shared, live state, so
 * bumping a task's generation changes its fingerprint and every downstream one wherever the
 * task's base is used.
 *
 * A pure function of the project, the graph, the pinned revisions and the generations: the refs
 * pins were made from are never hashed (AGENTS.md, invariant 1).
 *
 * Bases depend on upstream fingerprints, so generations become known a level at a time. A task
 * whose base has no generation in `generations` is put in `unread` (task id to base): it has
 * inputs and a base but no fingerprint, and tasks downstream of it have no entries at all. A
 * missing generation is never taken to be 0. The result is complete when `unread` is empty; the
 * shell reads the generations of `unread` and calls again
 * (confector.core.rerun_generations.readGraphResolution). Pure.
 *
 * Throws: InputResolutionException as `resolveGraphInputs` does.
 */
GraphResolution graphResolution(
    string projectId,
    const TaskGraph graph,
    in RepositoryRef[InputKey] bindings,
    in RepositoryPin[RepositoryAt] pins,
    in RerunGenerations generations,
    out string[string] unread
) @trusted
{
    auto external = resolveGraphInputs(graph, bindings, pins);

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

        ResolvedInput[string] repositoryPins;
        foreach (ref input; external[taskId])
        {
            if (input.kind == InputKind.repository) repositoryPins[input.name] = input;
        }
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
        result.generations[taskId] = *generation;
    }
    return result;
}

/**
 * `graphResolution` for callers that need every task's fingerprint: `generations` must hold the
 * generation of every base of `graph`.
 *
 * Throws: InputResolutionException if a task's generation is missing from `generations`,
 * naming the task and its base; whatever `graphResolution` throws.
 */
GraphResolution completeGraphResolution(
    string projectId,
    const TaskGraph graph,
    in RepositoryRef[InputKey] bindings,
    in RepositoryPin[RepositoryAt] pins,
    in RerunGenerations generations
) @trusted
{
    string[string] unread;
    auto result = graphResolution(projectId, graph, bindings, pins, generations, unread);
    if (unread.length > 0)
    {
        const taskId = unread.keys.sort()[0];
        throw new InputResolutionException(format(
            "The rerun generation of task '%s' (base fingerprint %s) has not been read", taskId, unread[taskId]), taskId);
    }
    return result;
}

/// Throws unless every entry of `pins` is stored under its own key.
private void requireKeyed(in RepositoryPin[RepositoryAt] pins) @trusted
{
    foreach (key, pin; pins)
    {
        if (key != repositoryAt(pin))
        {
            throw new InputResolutionException(format(
                "A pin of repository '%s' at %s '%s' is stored under repository '%s' at %s '%s'",
                pin.repositoryId, cast(string) pin.ref_.kind, pin.ref_.name,
                key.repositoryId, cast(string) key.ref_.kind, key.ref_.name));
        }
    }
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    private enum RepositoryRef mainBranch = RepositoryRef(RefKind.branch, "main");

    private RepositoryAt at(string repository, RepositoryRef ref_)
    {
        return RepositoryAt(repository, ref_);
    }

    /// The pin of repository `repository` at `ref_`, revision `sha`, keyed as input resolution takes pins.
    private RepositoryPin[RepositoryAt] pinsAt(string repository, RepositoryRef ref_, string sha)
    {
        return [at(repository, ref_): RepositoryPin(repository, ref_, InputPin(Json(sha)))];
    }

    /// `into` with `more` added.
    private RepositoryPin[RepositoryAt] plus(RepositoryPin[RepositoryAt] into, in RepositoryPin[RepositoryAt] more)
    {
        auto result = into.dup;
        foreach (key, pin; more) result[key] = cast(RepositoryPin) pin;
        return result;
    }

    /// Every repository input of `graph` bound to `ref_`.
    private RepositoryRef[InputKey] bindAll(const TaskGraph graph, RepositoryRef ref_ = mainBranch)
    {
        RepositoryRef[InputKey] bindings;
        foreach (taskId; graph.allTaskIds())
        {
            foreach (name, decl; graph.getTask(taskId).inputs)
            {
                if (decl.kind == InputKind.repository) bindings[InputKey(taskId, name)] = ref_;
            }
        }
        return bindings;
    }

    private const(ResolvedInput) inputNamed(in GraphResolution r, string taskId, string name)
    {
        foreach (ref input; r.inputs[taskId])
        {
            if (input.name == name) return input;
        }
        assert(false, format("task '%s' has no resolved input '%s'", taskId, name));
    }

    /// `graphResolution` with every base `generations` lacks read at generation 0, the way the
    /// shell reads them a level at a time.
    private GraphResolution atGenerations(string projectId, const TaskGraph graph, in RepositoryRef[InputKey] bindings,
        in RepositoryPin[RepositoryAt] pins, RerunGenerations generations = null)
    {
        for (;;)
        {
            string[string] unread;
            auto result = graphResolution(projectId, graph, bindings, pins, generations, unread);
            if (unread.length == 0) return result;
            foreach (base; unread.byValue) generations[base] = 0;
        }
    }

    /// Evaluates `graph` in project "p" with every repository input bound to branch main and
    /// pinned by `pins`, with no task ever rerun.
    private GraphResolution evaluate(const TaskGraph graph, in RepositoryPin[RepositoryAt] pins)
    {
        return atGenerations("p", graph, bindAll(graph), pins);
    }

    /// The fingerprint of a task never rerun.
    private string firstFingerprint(string projectId, string taskId, in ResolvedInput[] inputs)
    {
        return computeFingerprint(computeBaseFingerprint(projectId, taskId, inputs), 0);
    }

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }
}

unittest
{
    // The whole DAG is resolved, including tasks that are not targets of anything, and
    // task_output inputs pin to upstream fingerprints in topological order.
    TaskNode compile; compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game");
    compile.inputs["flavor"] = valueInput("internal");
    TaskNode test; test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile", "binaries");
    test.inputs["src"] = repositoryInput("game");
    TaskNode package_; package_.id = "package";
    package_.inputs["bin"] = taskOutputInput("compile", "binaries");
    package_.inputs["report"] = taskOutputInput("test");
    TaskNode lint; lint.id = "lint"; // no inputs at all

    auto graph = new TaskGraph([package_, lint, test, compile]);
    RepositoryPin[RepositoryAt] none;
    assert(requiredPins(graph, bindAll(graph)) == [InputKey("compile", "src"): at("game", mainBranch), InputKey("test", "src"): at("game", mainBranch)]);

    // One pin of (game, main) covers every input bound to it
    auto pins = pinsAt("game", mainBranch, "aaa111");
    auto r = evaluate(graph, pins);

    assert(r.inputs.length == 4 && r.fingerprints.length == 4, "Every task must be resolved and fingerprinted");
    assert(r.inputs["lint"].length == 0);
    assert(r.fingerprints["lint"] == firstFingerprint("p", "lint", []));
    assert(r.bases["lint"] == computeBaseFingerprint("p", "lint", []));

    assert(inputNamed(r, "compile", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "test", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "compile", "flavor").pinned == Json("internal"));
    assert(inputNamed(r, "test", "bin").pinned == Json(r.fingerprints["compile"]));
    assert(inputNamed(r, "package", "report").pinned == Json(r.fingerprints["test"]));
    assert(r.fingerprints["compile"] == firstFingerprint("p", "compile", r.inputs["compile"]));
    assert(r.fingerprints["package"] == firstFingerprint("p", "package", r.inputs["package"]));

    // Each task's inputs are sorted by name
    assert(r.inputs["compile"][0].name == "flavor" && r.inputs["compile"][1].name == "src");

    // Build configuration is not an input: changing steps, the filter or the default ref spec
    // leaves every fingerprint unchanged
    TaskNode compileSteps = compile;
    compileSteps.steps = [BuildStep("Build", "bash", Json(["script": Json("dub build --build=release")]))];
    compileSteps.inputs["src"] = repositoryInput("game", RefSpec.fromString("same else main"), BranchFilter.fromString("+:release/*"));
    assert(evaluate(new TaskGraph([package_, lint, test, compileSteps]), pins).fingerprints == r.fingerprints);

    // A new revision changes the repository's tasks and everything downstream, but not lint
    auto r2 = evaluate(graph, pinsAt("game", mainBranch, "bbb222"));
    foreach (id; ["compile", "test", "package"]) assert(r2.fingerprints[id] != r.fingerprints[id]);
    assert(r2.fingerprints["lint"] == r.fingerprints["lint"]);
}

unittest
{
    // Invariant 1: only the revision is hashed, never the ref. Two pins at one revision through
    // different refs give the same fingerprints; another revision changes them
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    auto graph = new TaskGraph([compile, test]);

    GraphResolution through(RepositoryRef ref_, string sha)
    {
        return atGenerations("p", graph, bindAll(graph, ref_), pinsAt("game", ref_, sha));
    }
    auto onMain = through(mainBranch, "aaa111");
    auto onFeature = through(RepositoryRef(RefKind.branch, "feature/x"), "aaa111");
    auto onTag = through(RepositoryRef(RefKind.tag, "v1.0"), "aaa111");
    auto onPull = through(RepositoryRef(RefKind.changeRequest, "pull/12"), "aaa111");
    auto direct = through(RepositoryRef(RefKind.revision, "aaa111"), "aaa111");
    foreach (other; [onFeature, onTag, onPull, direct])
    {
        assert(other.fingerprints == onMain.fingerprints && other.bases == onMain.bases, "The ref is never hashed");
        assert(other.inputs == onMain.inputs);
    }
    auto moved = through(mainBranch, "bbb222");
    assert(moved.fingerprints["compile"] != onMain.fingerprints["compile"] && moved.fingerprints["test"] != onMain.fingerprints["test"]);

    // Display info is carried into the resolved input but never hashed
    auto withInfo = pinsAt("game", mainBranch, "aaa111");
    withInfo[at("game", mainBranch)].pin.info = ["subject": "Fix the build"];
    auto informed = evaluate(graph, withInfo);
    assert(inputNamed(informed, "compile", "src").info.length == 1 && inputNamed(informed, "compile", "src").info["subject"] == "Fix the build");
    assert(informed.fingerprints == onMain.fingerprints);
}

unittest
{
    // One repository at two refs in one closure: each input takes the pin of the ref it is bound
    // to, and inputs bound to one ref share its revision whatever each task names its input
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game");
    TaskNode b; b.id = "b"; b.inputs["code"] = repositoryInput("game");
    b.inputs["engine"] = repositoryInput("engine");
    TaskNode c; c.id = "c"; c.inputs["src"] = repositoryInput("game");
    c.inputs["stable"] = repositoryInput("game");
    auto graph = new TaskGraph([a, b, c]);
    const release = RepositoryRef(RefKind.branch, "release");
    const stable = RepositoryRef(RefKind.branch, "stable");

    RepositoryRef[InputKey] bindings = [
        InputKey("a", "src"): mainBranch, InputKey("b", "code"): mainBranch, InputKey("b", "engine"): stable,
        InputKey("c", "src"): mainBranch, InputKey("c", "stable"): release,
    ];
    auto pins = plus(plus(pinsAt("game", mainBranch, "aaa111"), pinsAt("game", release, "ccc333")),
        pinsAt("engine", stable, "eee555"));
    assert(pins.length == 3, "One repository at two refs is two pins");
    auto r = atGenerations("p", graph, bindings, pins);
    assert(inputNamed(r, "a", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "b", "code").pinned == Json("aaa111"));
    assert(inputNamed(r, "b", "engine").pinned == Json("eee555"));
    assert(inputNamed(r, "c", "src").pinned == Json("aaa111"));
    assert(inputNamed(r, "c", "stable").pinned == Json("ccc333"));

    // Pins and bindings for inputs the graph does not declare are ignored
    auto extra = plus(pins, pinsAt("tools", mainBranch, "ttt999"));
    auto extraBindings = bindings.dup;
    extraBindings[InputKey("gone", "src")] = mainBranch;
    extraBindings[InputKey("a", "unused")] = release;
    assert(atGenerations("p", graph, extraBindings, extra).fingerprints == r.fingerprints);

    // A request that binds the input elsewhere builds from that ref's pin on the same chain
    auto rebound = bindings.dup;
    rebound[InputKey("a", "src")] = release;
    assert(atGenerations("p", graph, rebound, pins).inputs["a"][0].pinned == Json("ccc333"));
}

unittest
{
    // Pinned values are opaque, so a provider may pin to an object
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("depot");
    auto graph = new TaskGraph([a]);
    Json changelist = Json.emptyObject;
    changelist["server"] = "perforce:1666";
    changelist["change"] = 4242;
    const depot = RepositoryRef(RefKind.branch, "//game/main");
    RepositoryPin[RepositoryAt] pins = [at("depot", depot): RepositoryPin("depot", depot, InputPin(changelist))];
    assert(inputNamed(atGenerations("p", graph, bindAll(graph, depot), pins), "a", "src").pinned == changelist);
}

unittest
{
    // An unpinned or unbound repository input fails loudly, naming the task and input
    TaskNode a; a.id = "a"; a.inputs["v"] = valueInput("x");
    TaskNode b; b.id = "b"; b.inputs["src"] = repositoryInput("game");
    b.inputs["a"] = taskOutputInput("a");
    TaskNode c; c.id = "c"; c.inputs["src"] = repositoryInput("game");
    auto graph = new TaskGraph([a, b, c]);
    RepositoryPin[RepositoryAt] none;

    try
    {
        evaluate(graph, none);
        assert(false, "expected InputResolutionException");
    }
    catch (InputResolutionException ex)
    {
        assert((ex.taskId == "b" || ex.taskId == "c") && ex.inputName == "src");
        assert(ex.msg.canFind("'game'") && ex.msg.canFind("'main'"));
    }

    // A pin of the same repository at another ref does not cover an input bound to main
    auto onlyRelease = pinsAt("game", RepositoryRef(RefKind.branch, "release"), "aaa111");
    assert(throwsA!InputResolutionException({ evaluate(graph, onlyRelease); }));

    // An input the request does not bind is refused, even when pinned
    auto pins = pinsAt("game", mainBranch, "aaa111");
    auto bound = bindAll(graph);
    bound.remove(InputKey("c", "src"));
    bool unbound = false;
    try atGenerations("p", graph, bound, pins);
    catch (InputResolutionException ex) unbound = ex.taskId == "c" && ex.inputName == "src" && ex.msg.canFind("not bound");
    assert(unbound);

    // An undefined or null pin is not a value
    foreach (empty; [Json.undefined, Json(null)])
    {
        auto badPins = pinsAt("game", mainBranch, "aaa111");
        badPins[at("game", mainBranch)].pin.pinned = empty;
        bool threw = false;
        try evaluate(graph, badPins);
        catch (InputResolutionException ex) threw = (ex.taskId == "b" || ex.taskId == "c") && ex.inputName == "src";
        assert(threw, "An empty pinned value must throw");
    }
}

unittest
{
    // A pin of another repository does not serve the input: the input is unpinned, and a pin
    // stored under another key than its own is a caller's mistake
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game");
    auto graph = new TaskGraph([a]);
    auto fork = pinsAt("game-fork", mainBranch, "aaa111");
    bool threw = false;
    try evaluate(graph, fork);
    catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "src" && ex.msg.canFind("'game'");
    assert(threw);

    RepositoryPin[RepositoryAt] misfiled = [at("game", mainBranch): RepositoryPin("game-fork", mainBranch, InputPin(Json("aaa111")))];
    assert(throwsA!InputResolutionException({ evaluate(graph, misfiled); }));
}

unittest
{
    // A repository input must name a repository; it needs no default ref spec, but a malformed
    // filter or default is refused, naming the task and input
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("");
    auto graph = new TaskGraph([a]);
    auto pins = pinsAt("", mainBranch, "aaa111");
    bool threw = false;
    try evaluate(graph, pins);
    catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "src";
    assert(threw, "An input without a repository must not resolve, even when pinned");

    requireRepositorySpec("a", "src", repositoryInput("game"));
    requireRepositorySpec("a", "src", repositoryInput("game", RefSpec.fromString("same else main"), BranchFilter.fromString("+:*")));
    requireRepositorySpec("a", "src", repositoryInput("game", RefSpec.fromString("same else skip")));
    requireRepositorySpec("a", "src", repositoryInput("game", RefSpec.fromString("main")));
    foreach (malformed; [repositoryInput("game", RefSpec.fromString("event +:* else main")), repositoryInput("game", RefSpec.fromString("event +:*")),
        repositoryInput("game", RefSpec(RefSpecKind.fixed)), repositoryInput("game", RefSpec(RefSpecKind.same, BranchFilter.init, "x")),
        repositoryInput("game", RefSpec.init, BranchFilter([BranchRule(false, "x")])),
        repositoryInput("game", RefSpec.init, BranchFilter([BranchRule(true, "two words")]))])
    {
        threw = false;
        try requireRepositorySpec("a", "src", malformed);
        catch (InputResolutionException ex) threw = ex.taskId == "a" && ex.inputName == "src" && ex.msg.canFind("'game'");
        assert(threw);
    }
}

unittest
{
    // graphResolution pins repository and value inputs as resolveGraphInputs does, and task
    // outputs to upstream fingerprints; the project is part of every fingerprint
    TaskNode compile; compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game");
    compile.inputs["flavor"] = valueInput("internal");
    compile.steps = [BuildStep("Build", "bash", Json(["script": Json("dub build")]))];
    TaskNode test; test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile", "binaries");
    TaskNode lint; lint.id = "lint";
    auto graph = new TaskGraph([test, lint, compile]);
    auto bindings = bindAll(graph);

    auto pins = pinsAt("game", mainBranch, "aaa111");
    pins[at("game", mainBranch)].pin.info = ["ref": "refs/heads/main"];
    auto external = resolveGraphInputs(graph, bindings, pins);
    assert(external.length == 3 && external["test"].length == 0, "Task outputs are not resolved before evaluation");

    auto resolution = atGenerations("p", graph, bindings, pins);
    assert(resolution.fingerprints.length == 3 && resolution.bases.length == 3);
    assert(resolution.inputs["compile"] == external["compile"]);
    assert(resolution.inputs["compile"][0] == ResolvedInput("flavor", InputKind.value, Json("internal")));
    assert(resolution.inputs["compile"][1].pinned == Json("aaa111") && resolution.inputs["compile"][1].info["ref"] == "refs/heads/main");
    assert(resolution.inputs["lint"].length == 0);
    // A task's resolved inputs, task outputs included, are what the task's work order carries
    assert(resolution.inputs["test"] == [ResolvedInput("bin", InputKind.taskOutput, Json(resolution.fingerprints["compile"]))]);
    assert(atGenerations("q", graph, bindings, pins).fingerprints["lint"] != resolution.fingerprints["lint"], "The project is part of every fingerprint");

    // The same graph over the same pins gives the same fingerprints, however its tasks are listed
    assert(atGenerations("p", new TaskGraph([compile, lint, test]), bindings, pins).fingerprints == resolution.fingerprints);
}

unittest
{
    // Every repository input of the graph must be pinned: graphResolution fails loudly, naming the
    // task and input, rather than fingerprinting a task without its revision
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game");
    a.inputs["v"] = valueInput("x");
    TaskNode b; b.id = "b"; b.inputs["a"] = taskOutputInput("a");
    TaskNode tools; tools.id = "tools"; tools.inputs["src"] = repositoryInput("tools");
    auto graph = new TaskGraph([a, b, tools]);
    auto bindings = bindAll(graph);
    RerunGenerations generations;

    auto partial = pinsAt("game", mainBranch, "aaa111");
    bool threw = false;
    string[string] unread;
    try graphResolution("p", graph, bindings, partial, generations, unread);
    catch (InputResolutionException ex) threw = ex.taskId == "tools" && ex.inputName == "src" && ex.msg.canFind("'tools'");
    assert(threw, "An unpinned repository input must throw");

    // An empty pin does not cover it either
    auto empty = plus(partial, pinsAt("tools", mainBranch, "ttt111"));
    empty[at("tools", mainBranch)].pin.pinned = Json(null);
    threw = false;
    try atGenerations("p", graph, bindings, empty);
    catch (InputResolutionException ex) threw = ex.taskId == "tools" && ex.inputName == "src";
    assert(threw);

    // Fully pinned, a new revision changes the repository's tasks and everything downstream only
    auto atA = plus(pinsAt("game", mainBranch, "aaa111"), pinsAt("tools", mainBranch, "ttt111"));
    auto atB = plus(pinsAt("game", mainBranch, "bbb222"), pinsAt("tools", mainBranch, "ttt111"));
    auto first = atGenerations("p", graph, bindings, atA);
    auto second = atGenerations("p", graph, bindings, atB);
    assert(second.fingerprints["a"] != first.fingerprints["a"] && second.fingerprints["b"] != first.fingerprints["b"]);
    assert(second.fingerprints["tools"] == first.fingerprints["tools"]);
}

unittest
{
    // Rerun generations: bases become known a level at a time, and a generation that has not
    // been read leaves its task and everything downstream without a fingerprint, never at
    // generation 0
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game");
    TaskNode release; release.id = "release"; release.inputs["tested"] = taskOutputInput("test");
    release.inputs["linted"] = taskOutputInput("lint");
    auto graph = new TaskGraph([compile, test, lint, release]);
    auto bindings = bindAll(graph);
    auto pins = pinsAt("game", mainBranch, "aaa111");

    RerunGenerations generations;
    string[string] unread;
    auto none = graphResolution("p", graph, bindings, pins, generations, unread);
    assert(unread.length == 2 && "compile" in unread && "lint" in unread, "Only the tasks without upstream tasks have computable bases");
    assert(none.fingerprints.length == 0 && none.bases.length == 2 && "test" !in none.inputs && "release" !in none.inputs);
    foreach (base; unread.byValue) generations[base] = 0;

    auto partial = graphResolution("p", graph, bindings, pins, generations, unread);
    assert(unread.length == 1 && "test" in unread);
    assert(partial.fingerprints.length == 2 && "release" !in partial.bases, "A task waits for every upstream generation");
    foreach (base; unread.byValue) generations[base] = 0;

    graphResolution("p", graph, bindings, pins, generations, unread);
    assert(unread.length == 1 && "release" in unread);
    foreach (base; unread.byValue) generations[base] = 0;

    auto r = graphResolution("p", graph, bindings, pins, generations, unread);
    assert(unread.length == 0);
    assert(completeGraphResolution("p", graph, bindings, pins, generations) == r);

    // A caller that needs a full result is refused one while any generation is unread
    RerunGenerations missingRelease = generations.dup;
    missingRelease.remove(r.bases["release"]);
    bool threw = false;
    try completeGraphResolution("p", graph, bindings, pins, missingRelease);
    catch (InputResolutionException ex) threw = ex.taskId == "release" && ex.msg.canFind(r.bases["release"]);
    assert(threw, "A missing generation must throw, never count as 0");
    assert(r.fingerprints == atGenerations("p", graph, bindings, pins).fingerprints);
    foreach (id; ["compile", "test", "lint", "release"])
    {
        assert(r.fingerprints[id] == computeFingerprint(r.bases[id], 0));
        assert(r.fingerprints[id] == firstFingerprint("p", id, r.inputs[id]));
    }

    // Topological order: each task's task output inputs pin to its upstream fingerprints
    assert(inputNamed(r, "test", "bin").pinned == Json(r.fingerprints["compile"]));
    assert(inputNamed(r, "release", "tested").pinned == Json(r.fingerprints["test"]));
    assert(inputNamed(r, "release", "linted").pinned == Json(r.fingerprints["lint"]));
}

unittest
{
    // Bumping a task's generation changes its fingerprint and every downstream fingerprint,
    // wherever the task's base is used, and nothing else
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
    TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game");
    TaskNode docs; docs.id = "docs"; docs.inputs["src"] = repositoryInput("game");
    TaskNode publish; publish.id = "publish"; publish.inputs["bin"] = taskOutputInput("compile");
    publish.inputs["docs"] = taskOutputInput("docs");
    const feature = RepositoryRef(RefKind.branch, "feature/x");
    auto atA = pinsAt("game", mainBranch, "aaa111");
    auto atB = pinsAt("game", mainBranch, "bbb222");
    // Another branch at revision aaa111 shares every base with branch main at aaa111
    auto featureAtA = pinsAt("game", feature, "aaa111");

    // Two graphs over the same revisions (two definitions, or two branches at one revision) share
    // compile's base even with different task sets; other revisions do not
    auto graphOne = new TaskGraph([compile, test, report, lint]);
    auto graphTwo = new TaskGraph([compile, docs, publish]);
    auto graphOther = new TaskGraph([compile, test]);

    auto one = atGenerations("p", graphOne, bindAll(graphOne), atA);
    auto two = atGenerations("p", graphTwo, bindAll(graphTwo, feature), featureAtA);
    auto other = atGenerations("p", graphOther, bindAll(graphOther), atB);
    assert(one.bases["compile"] == two.bases["compile"] && one.fingerprints["compile"] == two.fingerprints["compile"]);
    assert(other.bases["compile"] != one.bases["compile"]);

    RerunGenerations rerun = [one.bases["compile"]: 1];
    auto oneAfter = atGenerations("p", graphOne, bindAll(graphOne), atA, rerun.dup);
    auto twoAfter = atGenerations("p", graphTwo, bindAll(graphTwo, feature), featureAtA, rerun.dup);
    auto otherAfter = atGenerations("p", graphOther, bindAll(graphOther), atB, rerun.dup);

    // The rerun task keeps its base and gets a new fingerprint; downstream tasks get new bases
    assert(oneAfter.bases["compile"] == one.bases["compile"]);
    foreach (id; ["compile", "test", "report"]) assert(oneAfter.fingerprints[id] != one.fingerprints[id], id);
    foreach (id; ["test", "report"]) assert(oneAfter.bases[id] != one.bases[id], id);
    assert(oneAfter.fingerprints["lint"] == one.fingerprints["lint"], "Tasks not downstream are unaffected");

    foreach (id; ["compile", "publish"]) assert(twoAfter.fingerprints[id] != two.fingerprints[id], id);
    assert(twoAfter.fingerprints["docs"] == two.fingerprints["docs"]);
    assert(twoAfter.fingerprints["compile"] == oneAfter.fingerprints["compile"], "Graphs sharing a base stay in step");

    assert(otherAfter.fingerprints == other.fingerprints, "Pins that do not share the base are unaffected");

    // Each further generation is new again, and a downstream task can be rerun on its own
    RerunGenerations twice = [one.bases["compile"]: 2];
    assert(atGenerations("p", graphOne, bindAll(graphOne), atA, twice).fingerprints["compile"] != oneAfter.fingerprints["compile"]);
    RerunGenerations testOnly = [one.bases["test"]: 1];
    auto testRerun = atGenerations("p", graphOne, bindAll(graphOne), atA, testOnly);
    assert(testRerun.fingerprints["compile"] == one.fingerprints["compile"]);
    assert(testRerun.fingerprints["test"] != one.fingerprints["test"] && testRerun.fingerprints["report"] != one.fingerprints["report"]);

    // Generations for bases the graph does not have are ignored
    RerunGenerations unrelated = [other.bases["compile"]: 5];
    assert(atGenerations("p", graphOne, bindAll(graphOne), atA, unrelated).fingerprints == one.fingerprints);
}

unittest
{
    // Fingerprints of existing fixtures are unchanged by the (repository, ref) pin model: a task's
    // fingerprint is computed exactly as before from its project, id and pinned inputs. The
    // golden values were computed independently of this code from the fingerprint encoding
    // (length-prefixed fields: project, task, then each input's name and canonical pinned value;
    // then base and generation).
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
    compile.inputs["flavor"] = valueInput("internal");
    auto r = evaluate(new TaskGraph([compile]), pinsAt("game", mainBranch, "aaa111"));
    assert(r.fingerprints["compile"] == firstFingerprint("p", "compile",
        [ResolvedInput("flavor", InputKind.value, Json("internal")), ResolvedInput("src", InputKind.repository, Json("aaa111"))]));
    assert(r.bases["compile"] == "68b033733fe1db7d9d632012f71a89b89269d8900822228daa5550205e3d6874");
    assert(r.fingerprints["compile"] == "5bae3031d22368d1487a300a508b19ac5ae543a90039b05bac1269ffc836ba75");
}
