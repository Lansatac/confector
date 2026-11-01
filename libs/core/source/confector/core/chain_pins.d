module confector.core.chain_pins;

/**
 * Pure operations on pins (AGENTS.md, "What a build is"): a chain's pins (`BuildChain.pins`) and a
 * request's pins (`BuildRequest.pins`) are lists of `RepositoryPin`, one per (repository, ref),
 * sorted by repository, ref kind and ref name; input resolution works on maps keyed the same way
 * (`RepositoryPin[RepositoryAt]`). A request binds each repository input to a ref
 * (`BuildRequest.bindings`), per input, and its pins are the pins of exactly the (repository, ref)
 * pairs those bindings use.
 *
 * - `pinMap` turns a list into that map; `pinMap` of a request's pins is what
 *   `confector.core.input_resolution.graphResolution` takes. `sortPins` turns any list of pins
 *   into a well-formed one.
 * - `mergePins` adds pins to a list: pins only grow, and a pin once set never changes.
 * - `refsOf` lists the distinct pairs a request's bindings use and `selectPins` takes the pins of
 *   some of them from a list.
 * - `pinsForRefs` turns the revisions the shell resolved for those pairs into pins, so every input
 *   bound to a ref agrees on its revision, including inputs of tasks added to the definition after
 *   the chain was created.
 * - `bindingMap` and `validateBindings` handle a request's bindings; `validatePins` checks a
 *   stored list.
 *
 * Two pins of one (repository, ref) agree when their revisions (the pinned value, compared as
 * canonical JSON) are equal. Display info is never compared: re-adding a pin with other display
 * info changes nothing, and the first info is kept.
 */

import confector.core.fingerprinter : canonicalPinned;
import confector.core.input_resolution : InputResolutionException, requiredPins;
import confector.api.model;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * A (repository, ref) is already pinned to another revision. Pins never change once set: a request
 * whose revision of that ref differs belongs on another chain.
 */
class PinConflictException : Exception
{
    /// The repository and ref concerned.
    RepositoryAt key;
    /// The pin it has, and the different pin offered.
    RepositoryPin existing;
    RepositoryPin proposed;

    this(string msg, RepositoryAt key, RepositoryPin existing, RepositoryPin proposed, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        this.key = key;
        this.existing = existing;
        this.proposed = proposed;
    }
}

/**
 * Pins or bindings that are not well formed: a pin naming no repository or ref, an empty pinned
 * value, a binding naming no task, input or ref, a list that is not sorted or holds an entry
 * twice, or a list or map that pins a (repository, ref) to two revisions or binds an input to two
 * refs. Always a caller's mistake.
 */
class InvalidPinsException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Whether key `a` sorts before key `b`: by repository id, then ref kind, then ref name, each
 * compared as text. A strict total order on keys; lists of pins are sorted by it.
 */
bool pinKeyLess(in RepositoryAt a, in RepositoryAt b) pure nothrow @safe
{
    if (a.repositoryId != b.repositoryId) return a.repositoryId < b.repositoryId;
    if (a.ref_.kind != b.ref_.kind) return cast(string) a.ref_.kind < cast(string) b.ref_.kind;
    return a.ref_.name < b.ref_.name;
}

/// Whether input `a` sorts before input `b`: by task id, then input name. Lists of bindings are
/// sorted by it.
bool inputKeyLess(in InputKey a, in InputKey b) pure nothrow @safe
{
    if (a.taskId != b.taskId) return a.taskId < b.taskId;
    return a.input < b.input;
}

/// Describes key `key` for messages: "task 'compile' input 'src'".
string describeInput(in InputKey key) pure @safe
{
    return format("task '%s' input '%s'", key.taskId, key.input);
}

/// Describes key `key` for messages: "repository 'game' at branch 'main'".
string describeRepositoryAt(in RepositoryAt key) pure @trusted
{
    return format("repository '%s' at %s '%s'", key.repositoryId, cast(string) key.ref_.kind, key.ref_.name);
}

/// Describes what `pin` pins, for messages: "repository 'game' at branch 'main', revision
/// "aaa111"".
string describePin(in RepositoryPin pin) @trusted
{
    return format("%s, revision %s", describeRepositoryAt(repositoryAt(pin)), canonicalPinned(pin.pin.pinned));
}

/**
 * Whether `value` is empty as a pinned value: undefined, null, an empty string, or an empty
 * object or array. No provider pins to such a value, so it is always a caller's mistake.
 */
bool isEmptyPinned(in Json value) @trusted
{
    switch (value.type)
    {
        case Json.Type.undefined:
        case Json.Type.null_:
            return true;
        case Json.Type.string:
            return value.get!string.length == 0;
        case Json.Type.array:
        case Json.Type.object:
            return value.length == 0;
        default:
            return false;
    }
}

/// Whether two pinned values are equal as canonical JSON.
bool samePinned(in Json a, in Json b) @trusted
{
    return canonicalPinned(a) == canonicalPinned(b);
}

/// Whether two pins agree: same repository, same ref (kind and name) and same revision. Display
/// info is not compared.
bool samePin(in RepositoryPin a, in RepositoryPin b) @trusted
{
    return repositoryAt(a) == repositoryAt(b) && samePinned(a.pin.pinned, b.pin.pinned);
}

/**
 * Throws InvalidPinsException unless `pins` is a well-formed list of pins: every pin names a
 * repository and a ref name and has a pinned value that is not empty (`isEmptyPinned`), and the
 * list is sorted by key (`pinKeyLess`) with no (repository, ref) twice. `owner` names whose pins
 * they are, for the message ("chain 'c1'").
 */
void validatePins(in RepositoryPin[] pins, lazy string owner) @trusted
{
    foreach (i, ref entry; pins)
    {
        requireWellFormed(entry, owner);
        if (i > 0 && !pinKeyLess(repositoryAt(pins[i - 1]), repositoryAt(entry)))
        {
            throw new InvalidPinsException(format("The pins of %s are not sorted by repository and ref, or pin %s twice",
                owner, describeRepositoryAt(repositoryAt(entry))));
        }
    }
}

/**
 * Returns `pins` sorted by key, each pin well formed, with a (repository, ref) pinned twice alike
 * kept once (the first display info is kept), as copies.
 *
 * Throws: InvalidPinsException if a pin is not well formed or `pins` pins one ref to two
 * revisions.
 */
RepositoryPin[] sortPins(in RepositoryPin[] pins) @trusted
{
    return sortedList(pinMap(pins));
}

/**
 * Returns `pins` as a map keyed by (repository, ref), as input resolution takes it
 * (`confector.core.input_resolution.graphResolution`), with copies of the pins.
 *
 * Throws: InvalidPinsException if a pin is not well formed or `pins` pins one ref to two
 * revisions.
 */
RepositoryPin[RepositoryAt] pinMap(in RepositoryPin[] pins) @trusted
{
    RepositoryPin[RepositoryAt] byKey;
    foreach (ref entry; pins) addTo(byKey, entry, "the given pins");
    return byKey;
}

/**
 * Returns `existing` with `added` added, sorted by key. Pins only grow: a (repository, ref) already
 * in `existing` keeps its pin, and adding it again alike (whatever its display info) changes
 * nothing. The result is longer than `existing` exactly when something was added.
 *
 * Throws: PinConflictException if `added` pins a ref of `existing` to another revision (the race
 * case: another request pinned it first; decide again); InvalidPinsException if `added` pins one
 * ref to two revisions or a pin is not well formed (caller mistakes).
 */
RepositoryPin[] mergePins(in RepositoryPin[] existing, in RepositoryPin[] added) @trusted
{
    RepositoryPin[RepositoryAt] additions;
    foreach (ref entry; added) addTo(additions, entry, "the pins being added");

    RepositoryPin[RepositoryAt] byKey = pinMap(existing);
    foreach (key, pin; additions)
    {
        if (auto pinnedAlready = key in byKey)
        {
            if (!samePin(*pinnedAlready, pin))
            {
                throw new PinConflictException(format(
                    "%s is already pinned to revision %s in the chain; it cannot be pinned to revision %s, because pins never change",
                    describeRepositoryAt(key), canonicalPinned(pinnedAlready.pin.pinned), canonicalPinned(pin.pin.pinned)),
                    key, copyOf(*pinnedAlready), copyOf(pin));
            }
            continue;
        }
        byKey[key] = pin;
    }
    return sortedList(byKey);
}

/**
 * Throws InvalidPinsException unless `bindings` is a well-formed list: every binding names a task,
 * an input and a ref name, and the list is sorted by input (`inputKeyLess`) with no input twice.
 * `owner` names whose bindings they are, for the message ("request 'r1'").
 */
void validateBindings(in InputBinding[] bindings, lazy string owner) @trusted
{
    foreach (i, ref binding; bindings)
    {
        requireWellFormed(binding, owner);
        if (i > 0 && !inputKeyLess(inputKey(bindings[i - 1]), inputKey(binding)))
        {
            throw new InvalidPinsException(format("The bindings of %s are not sorted by task and input, or bind %s twice",
                owner, describeInput(inputKey(binding))));
        }
    }
}

/**
 * Returns `bindings` as a map keyed by input, as input resolution takes it. An input bound twice
 * alike is kept once.
 *
 * Throws: InvalidPinsException if a binding is not well formed or an input is bound to two refs.
 */
RepositoryRef[InputKey] bindingMap(in InputBinding[] bindings) @trusted
{
    RepositoryRef[InputKey] byKey;
    foreach (ref binding; bindings)
    {
        requireWellFormed(binding, "the given bindings");
        const key = inputKey(binding);
        if (auto existing = key in byKey)
        {
            if (*existing != binding.ref_)
            {
                throw new InvalidPinsException(format("%s is bound twice, to %s '%s' and to %s '%s'", describeInput(key),
                    cast(string) existing.kind, existing.name, cast(string) binding.ref_.kind, binding.ref_.name));
            }
            continue;
        }
        byKey[key] = binding.ref_;
    }
    return byKey;
}

/**
 * Returns the distinct (repository, ref) pairs that `required` (`requiredPins`) maps repository
 * inputs to, sorted by key: the pairs a request's pins must cover, each once.
 */
RepositoryAt[] refsOf(in RepositoryAt[InputKey] required) @trusted
{
    bool[RepositoryAt] distinct;
    foreach (key, at; required) distinct[at] = true;
    auto result = distinct.keys;
    result.sort!((a, b) => pinKeyLess(a, b));
    return result;
}

/**
 * Returns the pins of `pins` for the (repository, ref) pairs `refs`, sorted by key, as copies.
 *
 * Throws: InputResolutionException if `pins` has no pin for one of `refs`; InvalidPinsException as
 * `pinMap` does.
 */
RepositoryPin[] selectPins(in RepositoryPin[] pins, in RepositoryAt[] refs) @trusted
{
    const byKey = pinMap(pins);
    RepositoryPin[RepositoryAt] selected;
    foreach (at; refs)
    {
        auto pin = at in byKey;
        if (pin is null) throw new InputResolutionException(format("%s is not pinned", describeRepositoryAt(at)));
        selected[at] = copyOf(*pin);
    }
    return sortedList(selected);
}

/**
 * Returns the pins of `refs`, sorted by key: each (repository, ref) pinned to the revision
 * `revisions` holds for it. Pure: `revisions` is what the shell resolved, once per ref it lacked
 * a pin for (`refsOf` lists the refs a request uses).
 *
 * Throws: InvalidPinsException if a ref names no repository or ref name or a revision is empty;
 * InputResolutionException if `revisions` lacks a ref.
 */
RepositoryPin[] pinsForRefs(in RepositoryAt[] refs, in InputPin[RepositoryAt] revisions) @trusted
{
    RepositoryPin[RepositoryAt] byKey;
    foreach (ref at; refs)
    {
        auto revision = at in revisions;
        if (revision is null)
        {
            throw new InputResolutionException(format("%s was not resolved", describeRepositoryAt(at)));
        }
        auto pin = RepositoryPin(at.repositoryId, at.ref_, InputPin(revision.pinned.clone, cast(string[string]) revision.info.dup));
        requireWellFormed(pin, "the resolved pins");
        byKey[at] = pin;
    }
    return sortedList(byKey);
}

/// Throws InvalidPinsException unless `pin` names a repository and a ref name and has a pinned
/// value that is not empty.
private void requireWellFormed(in RepositoryPin pin, lazy string owner) @trusted
{
    if (pin.repositoryId.length == 0 || pin.ref_.name.length == 0)
    {
        throw new InvalidPinsException(format("A pin in %s names no repository or no ref", owner));
    }
    if (isEmptyPinned(pin.pin.pinned))
    {
        throw new InvalidPinsException(format("The pin of %s in %s has an empty pinned value",
            describeRepositoryAt(repositoryAt(pin)), owner));
    }
}

/// Throws InvalidPinsException unless `binding` names a task, an input and a ref name.
private void requireWellFormed(in InputBinding binding, lazy string owner) @safe
{
    if (binding.taskId.length == 0 || binding.input.length == 0 || binding.ref_.name.length == 0)
    {
        throw new InvalidPinsException(format("A binding in %s names no task, input or ref (%s)", owner, describeInput(inputKey(binding))));
    }
}

/// Adds a copy of `pin` to `byKey` under its key, unless an agreeing pin is there; throws
/// InvalidPinsException if a different one is: one list or map pinning a ref two ways is the
/// caller's mistake.
private void addTo(ref RepositoryPin[RepositoryAt] byKey, in RepositoryPin pin, string owner) @trusted
{
    requireWellFormed(pin, owner);
    const key = repositoryAt(pin);
    if (auto existing = key in byKey)
    {
        if (!samePin(*existing, pin))
        {
            throw new InvalidPinsException(format("%s pin %s twice, to revision %s and to revision %s",
                owner, describeRepositoryAt(key), canonicalPinned(existing.pin.pinned), canonicalPinned(pin.pin.pinned)));
        }
        return;
    }
    byKey[key] = copyOf(pin);
}

private RepositoryPin copyOf(in RepositoryPin pin) @trusted
{
    return RepositoryPin(pin.repositoryId, pin.ref_, InputPin(pin.pin.pinned.clone, cast(string[string]) pin.pin.info.dup));
}

private RepositoryPin[] sortedList(in RepositoryPin[RepositoryAt] byKey) @trusted
{
    RepositoryPin[] result;
    result.reserve(byKey.length);
    foreach (pin; byKey.byValue) result ~= copyOf(pin);
    result.sort!((a, b) => pinKeyLess(repositoryAt(a), repositoryAt(b)));
    return result;
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    /// Repository `repository` at branch `branch` pinned to revision `sha`.
    private RepositoryPin pinned(string repository, string branch, string sha, string[string] info = null)
    {
        return RepositoryPin(repository, RepositoryRef(RefKind.branch, branch), InputPin(Json(sha), info));
    }

    private RepositoryAt at(string repository, string branch)
    {
        return RepositoryAt(repository, RepositoryRef(RefKind.branch, branch));
    }

    /// Task `task`'s input `input` bound to branch `branch`.
    private InputBinding bound(string task, string input, string branch)
    {
        return InputBinding(task, input, RepositoryRef(RefKind.branch, branch));
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
    // Lists and maps convert both ways; lists are sorted by (repository, ref) and hold copies
    auto list = sortPins([
        pinned("tools", "main", "ttt111"),
        pinned("game", "release", "ccc333"),
        pinned("game", "main", "aaa111", ["subject": "Fix"]),
        pinned("game", "main", "aaa111", ["subject": "Other"]),
    ]);
    assert(list == [pinned("game", "main", "aaa111", ["subject": "Fix"]), pinned("game", "release", "ccc333"), pinned("tools", "main", "ttt111")]);
    validatePins(list, "the test");

    auto back = pinMap(list);
    assert(back.length == 3 && back[at("tools", "main")].pin.pinned == Json("ttt111"));
    back[at("game", "main")].pin.info["subject"] = "edited";
    assert(list[0].pin.info["subject"] == "Fix", "Copies: changing the map does not change the list");
    assert(pinMap(null).length == 0 && sortPins(null).length == 0);

    // One ref pinned to two revisions in one list is a caller's mistake
    assert(throwsA!InvalidPinsException({ pinMap([pinned("game", "main", "aaa111"), pinned("game", "main", "bbb222")]); }));
    assert(throwsA!InvalidPinsException({ sortPins([pinned("game", "main", "aaa111"), pinned("game", "main", "bbb222")]); }));

    // A tag and a branch of one name are two refs, and so are two pins
    auto tag = RepositoryPin("game", RepositoryRef(RefKind.tag, "main"), InputPin(Json("ttt222")));
    assert(sortPins([pinned("game", "main", "aaa111"), tag]).length == 2);
}

unittest
{
    // Pins only grow: adding agrees or adds, never changes
    auto existing = [pinned("game", "main", "aaa111", ["subject": "Fix"])];

    // An identical pin is a no-op, whatever its display info
    auto same = mergePins(existing, [pinned("game", "main", "aaa111", ["subject": "Other"])]);
    assert(same == existing, "The first display info is kept");

    // A new ref is added in key order, including another ref of a pinned repository
    auto grown = mergePins(existing, [pinned("engine", "stable", "eee111"), pinned("game", "release", "ccc333"), pinned("game", "main", "aaa111")]);
    assert(grown == [pinned("engine", "stable", "eee111"), pinned("game", "main", "aaa111", ["subject": "Fix"]), pinned("game", "release", "ccc333")]);
    validatePins(grown, "the test");

    // Another revision for a pinned ref is refused, naming the ref and both revisions
    try
    {
        mergePins(grown, [pinned("game", "main", "bbb222")]);
        assert(false, "A conflicting pin must throw");
    }
    catch (PinConflictException e)
    {
        assert(e.key == at("game", "main"));
        assert(e.existing.pin.pinned == Json("aaa111") && e.proposed.pin.pinned == Json("bbb222"));
        assert(e.msg.canFind("'game'") && e.msg.canFind("'main'") && e.msg.canFind("aaa111") && e.msg.canFind("bbb222"), e.msg);
    }

    // The same revision through another ref is another pin, not a conflict
    auto otherKind = RepositoryPin("game", RepositoryRef(RefKind.tag, "main"), InputPin(Json("aaa111")));
    assert(mergePins(grown, [otherKind]).length == 4, "A tag and a branch of one name differ");
    assert(mergePins(grown, [pinned("fork", "main", "aaa111")]).length == 4);

    // Two revisions for one ref in the pins being added are the caller's mistake, not a race:
    // InvalidPinsException, whether or not the chain pins the ref
    assert(throwsA!InvalidPinsException({ mergePins(null, [pinned("tools", "main", "t1"), pinned("tools", "main", "t2")]); }));
    assert(throwsA!InvalidPinsException({ mergePins(grown, [pinned("game", "main", "bbb222"), pinned("game", "main", "ccc333")]); }));
    bool racy = false;
    try mergePins(grown, [pinned("game", "main", "bbb222"), pinned("game", "main", "bbb222")]);
    catch (PinConflictException e) racy = e.msg.canFind("in the chain");
    assert(racy, "A pin differing from the chain's is a conflict with the chain");

    // Pinned values are compared as canonical JSON, so key order does not matter
    Json a = Json.emptyObject;
    a["server"] = "p4:1666";
    a["change"] = 42;
    Json b = Json.emptyObject;
    b["change"] = 42;
    b["server"] = "p4:1666";
    auto depot = RepositoryRef(RefKind.branch, "//main");
    auto object = [RepositoryPin("depot", depot, InputPin(a))];
    assert(mergePins(object, [RepositoryPin("depot", depot, InputPin(b))]).length == 1);

    // Empty values and incomplete pins are refused
    foreach (empty; [Json(null), Json.undefined, Json(""), Json.emptyObject, Json.emptyArray])
    {
        auto bad = RepositoryPin("game", RepositoryRef(RefKind.branch, "main"), InputPin(empty));
        assert(throwsA!InvalidPinsException({ mergePins(null, [bad]); }), "An empty pinned value is refused");
        assert(throwsA!InvalidPinsException({ validatePins([bad], "the test"); }));
    }
    assert(!isEmptyPinned(Json(0)) && !isEmptyPinned(Json(false)) && !isEmptyPinned(Json("a")));
    assert(mergePins(null, [RepositoryPin("depot", depot, InputPin(Json(4242)))]).length == 1);
    foreach (incomplete; [pinned("", "main", "a"), pinned("game", "", "a")])
    {
        assert(throwsA!InvalidPinsException({ mergePins(null, [incomplete]); }));
    }
}

unittest
{
    // Keys order component by component, not by the text of a joined key: "a" sorts before
    // "a b" although a space sorts before a quote; refs of a repository sort by kind, then name
    assert(pinKeyLess(at("a", "z"), at("a b", "a")));
    assert(!pinKeyLess(at("a b", "a"), at("a", "z")));
    assert(pinKeyLess(at("game", "main"), at("game", "release")));
    assert(!pinKeyLess(at("game", "main"), at("game", "main")));
    assert(pinKeyLess(at("game", "zzz"), RepositoryAt("game", RepositoryRef(RefKind.tag, "a"))), "branch sorts before tag");
    auto list = sortPins([pinned("a b", "main", "1"), pinned("a", "main", "2")]);
    assert(list[0].repositoryId == "a");
    validatePins(list, "the test");

    assert(inputKeyLess(InputKey("a", "z"), InputKey("a b", "a")));
    assert(inputKeyLess(InputKey("compile", "lib"), InputKey("compile", "src")));
    assert(!inputKeyLess(InputKey("compile", "src"), InputKey("compile", "src")));
}

unittest
{
    // A stored list must be well formed
    validatePins(null, "the test");
    auto unsorted = [pinned("tools", "main", "aaa111"), pinned("game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ validatePins(unsorted, "chain 'c1'"); }));
    auto twice = [pinned("game", "main", "aaa111"), pinned("game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ validatePins(twice, "chain 'c1'"); }));
    try
    {
        validatePins([pinned("game", "main", "")], "chain 'c1'");
        assert(false, "An empty revision is refused");
    }
    catch (InvalidPinsException e)
    {
        assert(e.msg.canFind("chain 'c1'") && e.msg.canFind("'game'"));
    }
    assert(throwsA!InvalidPinsException({ validatePins([pinned("game", "", "aaa111")], "chain 'c1'"); }));
    assert(throwsA!InvalidPinsException({ validatePins([pinned("", "main", "aaa111")], "chain 'c1'"); }));

    // Bindings: sorted by input, each once, each complete
    validateBindings(null, "the test");
    validateBindings([bound("compile", "src", "main"), bound("lint", "src", "main")], "request 'r1'");
    assert(throwsA!InvalidPinsException({ validateBindings([bound("lint", "src", "main"), bound("compile", "src", "main")], "request 'r1'"); }));
    assert(throwsA!InvalidPinsException({ validateBindings([bound("compile", "src", "main"), bound("compile", "src", "main")], "request 'r1'"); }));
    foreach (incomplete; [bound("", "src", "main"), bound("compile", "", "main"), bound("compile", "src", "")])
    {
        assert(throwsA!InvalidPinsException({ validateBindings([incomplete], "request 'r1'"); }));
    }
}

unittest
{
    // A request pins each distinct (repository, ref) once: inputs bound to one ref share its
    // revision, and one repository at two refs gives two pins
    import confector.core.dag : TaskGraph;

    TaskNode compile; compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game");
    compile.inputs["engine"] = repositoryInput("engine");
    TaskNode lint; lint.id = "lint"; lint.inputs["code"] = repositoryInput("game");
    TaskNode package_; package_.id = "package";
    package_.inputs["src"] = repositoryInput("game");
    package_.inputs["stable"] = repositoryInput("game");
    package_.inputs["bin"] = taskOutputInput("compile");
    auto graph = new TaskGraph([compile, lint, package_]);
    InputBinding[] bindings = [
        bound("compile", "engine", "main"),
        bound("compile", "src", "main"),
        bound("lint", "code", "main"),
        bound("package", "src", "main"),
        bound("package", "stable", "release"),
        bound("compile", "src", "main"), // bound twice alike: once
    ];
    auto asRefs = bindingMap(bindings);
    assert(asRefs.length == 5 && asRefs[InputKey("package", "stable")] == RepositoryRef(RefKind.branch, "release"));

    // Only the inputs' (repository, ref) pairs count: three inputs of game at main are one
    assert(refsOf(requiredPins(graph, asRefs)) == [at("engine", "main"), at("game", "main"), at("game", "release")],
        "Each distinct (repository, ref) once, in a deterministic order");

    // The chain keeps its pin of game at main; the request adds the other two refs
    auto onChain = [pinned("game", "main", "aaa111")];

    InputPin[RepositoryAt] revisions = [
        at("engine", "main"): InputPin(Json("eee111")),
        at("game", "release"): InputPin(Json("ccc333"), ["subject": "Release"]),
    ];
    auto added = pinsForRefs([at("engine", "main"), at("game", "release")], revisions);
    assert(added == [pinned("engine", "main", "eee111"), pinned("game", "release", "ccc333", ["subject": "Release"])]);
    auto grown = mergePins(onChain, added);
    validatePins(grown, "the test");
    assert(grown.length == 3);

    // The same name as a tag is another ref, resolved on its own
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game");
    TaskNode b; b.id = "b"; b.inputs["src"] = repositoryInput("game");
    auto tagged = refsOf(requiredPins(new TaskGraph([a, b]), bindingMap([bound("a", "src", "main"),
        InputBinding("b", "src", RepositoryRef(RefKind.tag, "main"))])));
    assert(tagged.length == 2);

    // An unresolved ref, an empty revision, an input left unbound or bound two ways fail loudly
    assert(throwsA!InputResolutionException({ pinsForRefs([at("game", "main")], null); }));
    InputPin[RepositoryAt] empty = [at("game", "main"): InputPin(Json(""))];
    assert(throwsA!InvalidPinsException({ pinsForRefs([at("game", "main")], empty); }));
    assert(throwsA!InvalidPinsException({ pinsForRefs([at("", "main")], [at("", "main"): InputPin(Json("a"))]); }));
    assert(throwsA!InputResolutionException({ requiredPins(graph, bindingMap(bindings[0 .. 3])); }), "package's inputs are unbound");
    assert(throwsA!InvalidPinsException({ bindingMap([bound("a", "src", "main"), bound("a", "src", "release")]); }));
    assert(throwsA!InvalidPinsException({ bindingMap([bound("", "src", "main")]); }));
    assert(throwsA!InvalidPinsException({ bindingMap([bound("a", "src", "")]); }));
    assert(pinsForRefs(null, null).length == 0);

    // The refs a request's bindings use are its pins' refs: each distinct pair once, sorted, and
    // selectPins takes exactly those pins from a list
    auto required = requiredPins(graph, bindingMap(bindings));
    assert(refsOf(required) == [at("engine", "main"), at("game", "main"), at("game", "release")]);
    assert(refsOf(null).length == 0);
    auto requestPins = [pinned("game", "release", "ccc333"), pinned("engine", "main", "eee111"),
        pinned("game", "main", "aaa111"), pinned("tools", "main", "ttt111")];
    auto selected = selectPins(requestPins, refsOf(required));
    assert(selected == [pinned("engine", "main", "eee111"), pinned("game", "main", "aaa111"), pinned("game", "release", "ccc333")]);
    assert(throwsA!InputResolutionException({ selectPins(requestPins[0 .. 1], refsOf(required)); }), "A ref without a pin is refused");
    assert(selectPins(null, null).length == 0);
}

unittest
{
    // A request's pins are what its tasks are fingerprinted against: a task added to the definition
    // after the chain was created, bound to a ref the chain pins, resolves to the chain's revision
    // of it, and no existing fingerprint changes
    import confector.core.dag : TaskGraph;
    import confector.core.input_resolution : GraphResolution, RerunGenerations, graphResolution;

    // Every task never rerun: generations read at 0, a level at a time, as the shell reads them
    GraphResolution atGenerationZero(TaskGraph graph, in InputBinding[] bindings, in RepositoryPin[] pins)
    {
        RerunGenerations generations;
        for (;;)
        {
            string[string] unread;
            auto result = graphResolution("p", graph, bindingMap(bindings), pinMap(pins), generations, unread);
            if (unread.length == 0) return result;
            foreach (base; unread.byValue) generations[base] = 0;
        }
    }

    TaskNode internal;
    internal.id = "compile";
    internal.inputs["src"] = repositoryInput("game");
    internal.inputs["flavor"] = valueInput("internal");
    auto internalBindings = [bound("compile", "src", "main")];
    auto chainPins = [pinned("game", "main", "aaa111")];
    auto first = atGenerationZero(new TaskGraph([internal]), internalBindings, chainPins);
    assert(first.inputs["compile"][1].pinned == Json("aaa111"));
    // Fixed values: the fingerprint hashes the project, the task and the revision, never the ref
    assert(first.bases["compile"] == "68b033733fe1db7d9d632012f71a89b89269d8900822228daa5550205e3d6874");
    assert(first.fingerprints["compile"] == "5bae3031d22368d1487a300a508b19ac5ae543a90039b05bac1269ffc836ba75");

    // The added task uses game at main, which the chain already pins, and console-sdk at v2,
    // which it lacks
    TaskNode external;
    external.id = "external";
    external.inputs["src"] = repositoryInput("game");
    external.inputs["sdk"] = repositoryInput("console-sdk");
    auto externalBindings = [bound("external", "sdk", "v2"), bound("external", "src", "main")];
    auto graph = new TaskGraph([internal, external]);
    auto bindings = internalBindings ~ externalBindings;
    assert(refsOf(requiredPins(graph, bindingMap(bindings))) == [at("console-sdk", "v2"), at("game", "main")],
        "The request uses two refs; game at main is the chain's, so only console-sdk at v2 is resolved");
    auto grown = mergePins(chainPins, pinsForRefs([at("console-sdk", "v2")], [at("console-sdk", "v2"): InputPin(Json("sdk222"))]));
    auto later = atGenerationZero(graph, bindings, grown);
    assert(later.fingerprints["compile"] == first.fingerprints["compile"], "Adding a pin changes no existing fingerprint");
    assert(later.inputs["external"][0].pinned == Json("sdk222") && later.inputs["external"][1].pinned == Json("aaa111"),
        "The added task builds from the chain's existing revision of (game, main)");

    // One repository at two refs: two pins, and each input takes the revision of its own ref
    TaskNode two;
    two.id = "two";
    two.inputs["code"] = repositoryInput("game");
    two.inputs["scripts"] = repositoryInput("game");
    auto twoBindings = [bound("two", "code", "feature/x"), bound("two", "scripts", "main")];
    auto twoGraph = new TaskGraph([two]);
    assert(refsOf(requiredPins(twoGraph, bindingMap(twoBindings))) == [at("game", "feature/x"), at("game", "main")]);
    auto both = mergePins(chainPins, pinsForRefs([at("game", "feature/x")], [at("game", "feature/x"): InputPin(Json("fff333"))]));
    assert(both.length == 2);
    auto resolved = atGenerationZero(twoGraph, twoBindings, both);
    assert(resolved.inputs["two"][0].pinned == Json("fff333") && resolved.inputs["two"][1].pinned == Json("aaa111"));
}
