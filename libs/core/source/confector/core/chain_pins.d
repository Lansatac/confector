module confector.core.chain_pins;

/**
 * Pure operations on pinned inputs (design records: beads confector-z7z.52 and confector-z7z.56;
 * AGENTS.md, "What a build is"): a chain's pins (`BuildChain.pins`) and the pins supplied with a
 * request (`BuildRequest.pins`) are lists of `PinnedInput`, one per task input, sorted by
 * (task, input); input resolution works on maps keyed the same way (`PinnedInput[InputKey]`).
 *
 * - `pinMap` turns a list into that map; `pinMap` of a chain's pins is what
 *   `confector.core.input_resolution.graphResolution` takes. `sortPins` turns any list of pins
 *   into a well-formed one.
 * - `mergePins` adds pins to a list: pins only grow, and a pin once set never changes.
 * - `pinsAgree` and `missingPins` are what the input resolver needs to decide whether a request
 *   joins a chain and which pins it adds to it (bead confector-z7z.53.2).
 * - `refsToResolve` and `pinsForBindings` turn the refs a request chose for its inputs into pins,
 *   resolving each distinct (repository, ref) once, so inputs sharing a ref agree on its revision.
 * - `validatePins` checks a stored list.
 *
 * Two pins of one input agree when their repository, ref (kind and name) and revision (the
 * pinned value, compared as canonical JSON) are all equal. Display info is never compared:
 * re-adding a pin with other display info changes nothing, and the first info is kept.
 */

import confector.core.fingerprinter : canonicalPinned;
import confector.core.input_resolution : InputResolutionException;
import confector.api.model;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * An input is already pinned differently: another repository, ref or revision. Pins never change
 * once set: a request whose pin differs belongs on another chain.
 */
class PinConflictException : Exception
{
    /// The task input concerned.
    InputKey key;
    /// The pin it has, and the different pin offered.
    PinnedInput existing;
    PinnedInput proposed;

    this(string msg, InputKey key, PinnedInput existing, PinnedInput proposed, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        this.key = key;
        this.existing = existing;
        this.proposed = proposed;
    }
}

/**
 * Pins that are not well formed: a pin naming no task, input, repository or ref, an empty pinned
 * value, a list that is not sorted by (task, input) or holds an input twice, or a list or map that
 * pins one input two ways. Always a caller's mistake.
 */
class InvalidPinsException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Whether key `a` sorts before key `b`: by task id, then by input name, each compared as text. A
 * strict total order on keys; lists of pins are sorted by it.
 */
bool pinKeyLess(in InputKey a, in InputKey b) pure nothrow @safe
{
    if (a.taskId != b.taskId) return a.taskId < b.taskId;
    return a.input < b.input;
}

/// Describes key `key` for messages: "task 'compile' input 'src'".
string describeInput(in InputKey key) pure @safe
{
    return format("task '%s' input '%s'", key.taskId, key.input);
}

/// Describes what `pin` pins its input to, for messages: "repository 'game' at branch 'main',
/// revision "aaa111"".
string describePin(in PinnedInput pin) @trusted
{
    return format("repository '%s' at %s '%s', revision %s", pin.repositoryId, cast(string) pin.ref_.kind, pin.ref_.name,
        canonicalPinned(pin.pin.pinned));
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

/// Whether two pins agree: same repository, same ref (kind and name) and same revision. Their
/// keys and display info are not compared.
bool samePin(in PinnedInput a, in PinnedInput b) @trusted
{
    return a.repositoryId == b.repositoryId && a.ref_ == b.ref_ && samePinned(a.pin.pinned, b.pin.pinned);
}

/**
 * Throws InvalidPinsException unless `pins` is a well-formed list of pins: every pin names a task,
 * an input, a repository and a ref name and has a pinned value that is not empty
 * (`isEmptyPinned`), and the list is sorted by key (`pinKeyLess`) with no input twice. `owner`
 * names whose pins they are, for the message ("chain 'c1'").
 */
void validatePins(in PinnedInput[] pins, lazy string owner) @trusted
{
    foreach (i, ref entry; pins)
    {
        requireWellFormed(entry, owner);
        if (i > 0 && !pinKeyLess(inputKey(pins[i - 1]), inputKey(entry)))
        {
            throw new InvalidPinsException(format("The pins of %s are not sorted by task and input, or pin %s twice",
                owner, describeInput(inputKey(entry))));
        }
    }
}

/**
 * Returns `pins` sorted by key, each pin well formed, with an input pinned twice alike kept once
 * (the first display info is kept), as copies.
 *
 * Throws: InvalidPinsException if a pin is not well formed or `pins` pins one input two ways.
 */
PinnedInput[] sortPins(in PinnedInput[] pins) @trusted
{
    return sortedList(pinMap(pins));
}

/**
 * Returns `pins` as a map keyed by (task, input), as input resolution takes it
 * (`confector.core.input_resolution.graphResolution`), with copies of the pins.
 *
 * Throws: InvalidPinsException if a pin is not well formed or `pins` pins one input two ways.
 */
PinnedInput[InputKey] pinMap(in PinnedInput[] pins) @trusted
{
    PinnedInput[InputKey] byKey;
    foreach (ref entry; pins) addTo(byKey, entry, "the given pins");
    return byKey;
}

/**
 * Returns `existing` with `added` added, sorted by key. Pins only grow: an input already in
 * `existing` keeps its pin, and adding it again alike (whatever its display info) changes
 * nothing. The result is longer than `existing` exactly when something was added.
 *
 * Throws: PinConflictException if `added` pins an input of `existing` differently (the race case:
 * another request pinned it first; decide again); InvalidPinsException if `added` pins one input
 * two ways or a pin is not well formed (caller mistakes).
 */
PinnedInput[] mergePins(in PinnedInput[] existing, in PinnedInput[] added) @trusted
{
    PinnedInput[InputKey] additions;
    foreach (ref entry; added) addTo(additions, entry, "the pins being added");

    PinnedInput[InputKey] byKey = pinMap(existing);
    foreach (key, pin; additions)
    {
        if (auto pinnedAlready = key in byKey)
        {
            if (!samePin(*pinnedAlready, pin))
            {
                throw new PinConflictException(format(
                    "%s is already pinned to %s in the chain; it cannot be pinned to %s, because pins never change",
                    describeInput(key), describePin(*pinnedAlready), describePin(pin)),
                    key, copyOf(*pinnedAlready), copyOf(pin));
            }
            continue;
        }
        byKey[key] = pin;
    }
    return sortedList(byKey);
}

/**
 * Whether `chainPins` agree with every pin in `resolved`: no input pinned in both is pinned
 * differently (repository, ref or revision). Inputs pinned in only one of them do not matter;
 * `missingPins` lists the ones the chain lacks. A request joins a chain only if they agree (bead
 * confector-z7z.53.2).
 *
 * Throws: as `pinMap`, for either list.
 */
bool pinsAgree(in PinnedInput[] chainPins, in PinnedInput[] resolved) @trusted
{
    const chain = pinMap(chainPins);
    foreach (key, pin; pinMap(resolved))
    {
        auto pinned = key in chain;
        if (pinned !is null && !samePin(*pinned, pin)) return false;
    }
    return true;
}

/**
 * Returns the pins of `resolved` whose inputs `chainPins` lacks, sorted by key: what a request
 * joining the chain adds to it (`ChainStore.addPins`).
 *
 * Throws: as `pinMap`, for either list.
 */
PinnedInput[] missingPins(in PinnedInput[] chainPins, in PinnedInput[] resolved) @trusted
{
    const chain = pinMap(chainPins);
    PinnedInput[InputKey] missing;
    foreach (key, pin; pinMap(resolved))
    {
        if (key !in chain) missing[key] = pin;
    }
    return sortedList(missing);
}

/**
 * A repository input of one task bound to a ref by a request, not yet resolved: the ref comes
 * from the trigger's or request's spec for the input, else from the input's default (bead
 * confector-z7z.53.2 decides it).
 */
struct InputBinding
{
    string taskId;
    string input;
    string repositoryId;
    RepositoryRef ref_;
}

/// A ref of a repository: what a request resolves to a revision, once however many of its inputs
/// are bound to it.
struct RepositoryAt
{
    string repositoryId;
    RepositoryRef ref_;
}

/**
 * Returns the distinct (repository, ref) pairs of `bindings`, sorted by repository, ref kind and
 * ref name: what the shell resolves, each exactly once, before calling `pinsForBindings`.
 *
 * Throws: InvalidPinsException if a binding names no task, input, repository or ref, or two
 * bindings of one input differ.
 */
RepositoryAt[] refsToResolve(in InputBinding[] bindings) @trusted
{
    bool[RepositoryAt] distinct;
    foreach (binding; checkedBindings(bindings).byValue) distinct[RepositoryAt(binding.repositoryId, binding.ref_)] = true;
    auto result = distinct.keys;
    result.sort!((a, b) => a.repositoryId != b.repositoryId ? a.repositoryId < b.repositoryId
        : a.ref_.kind != b.ref_.kind ? cast(string) a.ref_.kind < cast(string) b.ref_.kind
        : a.ref_.name < b.ref_.name);
    return result;
}

/**
 * Returns the pins of `bindings`, sorted by key: each input pinned to its repository and ref at
 * the revision `revisions` holds for that (repository, ref). Every input bound to one ref of one
 * repository gets the same revision, because the revision is looked up per (repository, ref),
 * never per input. Pure: `revisions` is what the shell resolved, once per entry of
 * `refsToResolve`.
 *
 * Throws: InvalidPinsException as `refsToResolve` does, or if a revision is empty;
 * InputResolutionException if `revisions` lacks a (repository, ref) a binding needs.
 */
PinnedInput[] pinsForBindings(in InputBinding[] bindings, in InputPin[RepositoryAt] revisions) @trusted
{
    PinnedInput[InputKey] byKey;
    foreach (key, binding; checkedBindings(bindings))
    {
        auto revision = RepositoryAt(binding.repositoryId, binding.ref_) in revisions;
        if (revision is null)
        {
            throw new InputResolutionException(format("%s is bound to repository '%s' at %s '%s', which was not resolved",
                describeInput(key), binding.repositoryId, cast(string) binding.ref_.kind, binding.ref_.name), key.taskId, key.input);
        }
        auto pin = PinnedInput(key.taskId, key.input, binding.repositoryId, binding.ref_,
            InputPin(revision.pinned.clone, cast(string[string]) revision.info.dup));
        requireWellFormed(pin, "the resolved pins");
        byKey[key] = pin;
    }
    return sortedList(byKey);
}

/// `bindings` keyed by input, each checked; throws InvalidPinsException for an incomplete binding
/// or an input bound two ways.
private InputBinding[InputKey] checkedBindings(in InputBinding[] bindings) @safe
{
    InputBinding[InputKey] byKey;
    foreach (binding; bindings)
    {
        const key = InputKey(binding.taskId, binding.input);
        if (key.taskId.length == 0 || key.input.length == 0 || binding.repositoryId.length == 0 || binding.ref_.name.length == 0)
        {
            throw new InvalidPinsException(format("The binding of %s names no task, input, repository or ref", describeInput(key)));
        }
        if (auto existing = key in byKey)
        {
            if (*existing != binding)
            {
                throw new InvalidPinsException(format("%s is bound twice, to repository '%s' at %s '%s' and to repository '%s' at %s '%s'",
                    describeInput(key), existing.repositoryId, cast(string) existing.ref_.kind, existing.ref_.name,
                    binding.repositoryId, cast(string) binding.ref_.kind, binding.ref_.name));
            }
            continue;
        }
        byKey[key] = binding;
    }
    return byKey;
}

/// Throws InvalidPinsException unless `pin` names a task, an input, a repository and a ref name
/// and has a pinned value that is not empty.
private void requireWellFormed(in PinnedInput pin, lazy string owner) @trusted
{
    if (pin.taskId.length == 0 || pin.input.length == 0)
    {
        throw new InvalidPinsException(format("A pin in %s names no task or no input (%s)", owner, describeInput(inputKey(pin))));
    }
    if (pin.repositoryId.length == 0 || pin.ref_.name.length == 0)
    {
        throw new InvalidPinsException(format("The pin of %s in %s names no repository or no ref", describeInput(inputKey(pin)), owner));
    }
    if (isEmptyPinned(pin.pin.pinned))
    {
        throw new InvalidPinsException(format("The pin of %s in %s has an empty pinned value", describeInput(inputKey(pin)), owner));
    }
}

/// Adds a copy of `pin` to `byKey` under its key, unless an agreeing pin is there; throws
/// InvalidPinsException if a different one is: one list or map pinning an input two ways is the
/// caller's mistake.
private void addTo(ref PinnedInput[InputKey] byKey, in PinnedInput pin, string owner) @trusted
{
    requireWellFormed(pin, owner);
    const key = inputKey(pin);
    if (auto existing = key in byKey)
    {
        if (!samePin(*existing, pin))
        {
            throw new InvalidPinsException(format("%s pin %s twice, to %s and to %s",
                owner, describeInput(key), describePin(*existing), describePin(pin)));
        }
        return;
    }
    byKey[key] = copyOf(pin);
}

private PinnedInput copyOf(in PinnedInput pin) @trusted
{
    return PinnedInput(pin.taskId, pin.input, pin.repositoryId, pin.ref_,
        InputPin(pin.pin.pinned.clone, cast(string[string]) pin.pin.info.dup));
}

private PinnedInput[] sortedList(in PinnedInput[InputKey] byKey) @trusted
{
    PinnedInput[] result;
    result.reserve(byKey.length);
    foreach (pin; byKey.byValue) result ~= copyOf(pin);
    result.sort!((a, b) => pinKeyLess(inputKey(a), inputKey(b)));
    return result;
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    /// Task `task`'s input `input` pinned to repository `repository` at branch `branch`, revision `sha`.
    private PinnedInput pinned(string task, string input, string repository, string branch, string sha, string[string] info = null)
    {
        return PinnedInput(task, input, repository, RepositoryRef(RefKind.branch, branch), InputPin(Json(sha), info));
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
    // Lists and maps convert both ways; lists are sorted by (task, input) and hold copies
    auto list = sortPins([
        pinned("package", "src", "game", "main", "aaa111", ["subject": "Fix"]),
        pinned("compile", "tools", "tools", "main", "ttt111"),
        pinned("compile", "src", "game", "main", "aaa111"),
        pinned("compile", "src", "game", "main", "aaa111", ["subject": "Other"]),
    ]);
    assert(list == [pinned("compile", "src", "game", "main", "aaa111"), pinned("compile", "tools", "tools", "main", "ttt111"),
        pinned("package", "src", "game", "main", "aaa111", ["subject": "Fix"])]);
    validatePins(list, "the test");

    auto back = pinMap(list);
    assert(back.length == 3 && back[InputKey("compile", "tools")].pin.pinned == Json("ttt111"));
    back[InputKey("package", "src")].pin.info["subject"] = "edited";
    assert(list[2].pin.info["subject"] == "Fix", "Copies: changing the map does not change the list");
    assert(pinMap(null).length == 0 && sortPins(null).length == 0);

    // One input pinned two ways in one list is a caller's mistake: another revision, ref or
    // repository
    foreach (other; [pinned("compile", "src", "game", "main", "bbb222"), pinned("compile", "src", "game", "release", "aaa111"),
        pinned("compile", "src", "fork", "main", "aaa111"),
        PinnedInput("compile", "src", "game", RepositoryRef(RefKind.tag, "main"), InputPin(Json("aaa111")))])
    {
        assert(throwsA!InvalidPinsException({ pinMap([pinned("compile", "src", "game", "main", "aaa111"), other]); }));
        assert(throwsA!InvalidPinsException({ sortPins([pinned("compile", "src", "game", "main", "aaa111"), other]); }));
    }
}

unittest
{
    // Pins only grow: adding agrees or adds, never changes
    auto existing = [pinned("compile", "src", "game", "main", "aaa111", ["subject": "Fix"])];

    // An identical pin is a no-op, whatever its display info
    auto same = mergePins(existing, [pinned("compile", "src", "game", "main", "aaa111", ["subject": "Other"])]);
    assert(same == existing, "The first display info is kept");

    // A new input is added in key order
    auto grown = mergePins(existing, [pinned("compile", "engine", "engine", "stable", "eee111"),
        pinned("compile", "src", "game", "main", "aaa111")]);
    assert(grown == [pinned("compile", "engine", "engine", "stable", "eee111"), pinned("compile", "src", "game", "main", "aaa111", ["subject": "Fix"])]);
    validatePins(grown, "the test");

    // Another revision for a pinned input is refused, naming the input and both pins
    try
    {
        mergePins(grown, [pinned("compile", "src", "game", "main", "bbb222")]);
        assert(false, "A conflicting pin must throw");
    }
    catch (PinConflictException e)
    {
        assert(e.key == InputKey("compile", "src"));
        assert(e.existing.pin.pinned == Json("aaa111") && e.proposed.pin.pinned == Json("bbb222"));
        assert(e.msg.canFind("'compile'") && e.msg.canFind("'src'") && e.msg.canFind("aaa111") && e.msg.canFind("bbb222"), e.msg);
    }

    // The same revision reached through another ref is another pin too: agreement compares refs
    auto otherRef = pinned("compile", "src", "game", "release", "aaa111");
    assert(throwsA!PinConflictException({ mergePins(grown, [otherRef]); }));
    auto otherKind = PinnedInput("compile", "src", "game", RepositoryRef(RefKind.tag, "main"), InputPin(Json("aaa111")));
    assert(throwsA!PinConflictException({ mergePins(grown, [otherKind]); }), "A tag and a branch of one name differ");
    assert(throwsA!PinConflictException({ mergePins(grown, [pinned("compile", "src", "fork", "main", "aaa111")]); }));

    // Two pins for one input in the pins being added are the caller's mistake, not a race:
    // InvalidPinsException, whether or not the chain pins the input
    assert(throwsA!InvalidPinsException({ mergePins(null, [pinned("t", "tools", "tools", "main", "t1"), pinned("t", "tools", "tools", "main", "t2")]); }));
    assert(throwsA!InvalidPinsException({ mergePins(grown, [pinned("compile", "src", "game", "main", "aaa111"), otherRef]); }));
    bool racy = false;
    try mergePins(grown, [pinned("compile", "src", "game", "main", "bbb222"), pinned("compile", "src", "game", "main", "bbb222")]);
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
    auto object = [PinnedInput("t", "src", "depot", depot, InputPin(a))];
    assert(mergePins(object, [PinnedInput("t", "src", "depot", depot, InputPin(b))]).length == 1);

    // Empty values and incomplete pins are refused
    foreach (empty; [Json(null), Json.undefined, Json(""), Json.emptyObject, Json.emptyArray])
    {
        auto bad = PinnedInput("t", "src", "game", RepositoryRef(RefKind.branch, "main"), InputPin(empty));
        assert(throwsA!InvalidPinsException({ mergePins(null, [bad]); }), "An empty pinned value is refused");
        assert(throwsA!InvalidPinsException({ validatePins([bad], "the test"); }));
    }
    assert(!isEmptyPinned(Json(0)) && !isEmptyPinned(Json(false)) && !isEmptyPinned(Json("a")));
    assert(mergePins(null, [PinnedInput("t", "src", "depot", depot, InputPin(Json(4242)))]).length == 1);
    foreach (incomplete; [pinned("", "src", "game", "main", "a"), pinned("t", "", "game", "main", "a"),
        pinned("t", "src", "", "main", "a"), pinned("t", "src", "game", "", "a")])
    {
        assert(throwsA!InvalidPinsException({ mergePins(null, [incomplete]); }));
    }
}

unittest
{
    // Agreement and missing pins, as the input resolver decides a join
    auto chain = [pinned("compile", "engine", "engine", "stable", "eee111"), pinned("compile", "src", "game", "main", "aaa111")];

    auto subset = [pinned("compile", "src", "game", "main", "aaa111", ["subject": "Other info"])];
    assert(pinsAgree(chain, subset) && missingPins(chain, subset).length == 0);

    auto wider = [
        pinned("compile", "src", "game", "main", "aaa111"),
        pinned("lint", "src", "game", "main", "aaa111"),
        pinned("art", "src", "art", "main", "rrr111"),
    ];
    assert(pinsAgree(chain, wider), "Inputs the chain lacks do not disagree");
    assert(missingPins(chain, wider) == [pinned("art", "src", "art", "main", "rrr111"), pinned("lint", "src", "game", "main", "aaa111")]);

    auto moved = [pinned("compile", "src", "game", "main", "bbb222")];
    assert(!pinsAgree(chain, moved), "A newer revision of a pinned input belongs on another chain");
    auto otherRef = [pinned("compile", "src", "game", "release", "aaa111")];
    assert(!pinsAgree(chain, otherRef), "The same revision through another ref is another build");

    // One repository at two refs, in two inputs of one closure: both are pinned, and agree
    auto twoRefs = [pinned("compile", "src", "game", "main", "aaa111"), pinned("compile", "stable", "game", "release", "ccc333")];
    assert(pinsAgree(chain, twoRefs) && missingPins(chain, twoRefs) == [pinned("compile", "stable", "game", "release", "ccc333")]);
    auto both = mergePins(chain, missingPins(chain, twoRefs));
    assert(both.length == 3 && both[2] == pinned("compile", "stable", "game", "release", "ccc333"));
    validatePins(both, "the test");

    assert(pinsAgree(null, wider) && pinsAgree(chain, null) && missingPins(chain, null).length == 0);
    assert(missingPins(null, subset) == [pinned("compile", "src", "game", "main", "aaa111", ["subject": "Other info"])]);
}

unittest
{
    // Keys order component by component, not by the text of a joined key: "a" sorts before
    // "a b" although a space sorts before a quote
    assert(pinKeyLess(InputKey("a", "z"), InputKey("a b", "a")));
    assert(!pinKeyLess(InputKey("a b", "a"), InputKey("a", "z")));
    assert(pinKeyLess(InputKey("compile", "lib"), InputKey("compile", "src")));
    assert(!pinKeyLess(InputKey("compile", "src"), InputKey("compile", "src")));
    auto list = sortPins([pinned("a b", "a", "r", "main", "1"), pinned("a", "z", "r", "main", "2")]);
    assert(inputKey(list[0]) == InputKey("a", "z"));
    validatePins(list, "the test");
}

unittest
{
    // A stored list must be well formed
    validatePins(null, "the test");
    auto unsorted = [pinned("lint", "src", "game", "main", "aaa111"), pinned("compile", "src", "game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ validatePins(unsorted, "chain 'c1'"); }));
    auto twice = [pinned("compile", "src", "game", "main", "aaa111"), pinned("compile", "src", "game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ validatePins(twice, "chain 'c1'"); }));
    try
    {
        validatePins([pinned("compile", "src", "game", "main", "")], "chain 'c1'");
        assert(false, "An empty revision is refused");
    }
    catch (InvalidPinsException e)
    {
        assert(e.msg.canFind("chain 'c1'") && e.msg.canFind("'compile'"));
    }
    assert(throwsA!InvalidPinsException({ validatePins([pinned("compile", "src", "game", "", "aaa111")], "chain 'c1'"); }));
    assert(throwsA!InvalidPinsException({ validatePins([pinned("compile", "src", "", "main", "aaa111")], "chain 'c1'"); }));
}

unittest
{
    // A request resolves each distinct (repository, ref) once: inputs bound to one ref share its
    // revision, and one repository at two refs gives two pins
    auto main = RepositoryRef(RefKind.branch, "main");
    auto release = RepositoryRef(RefKind.branch, "release");
    InputBinding[] bindings = [
        InputBinding("compile", "src", "game", main),
        InputBinding("lint", "code", "game", main),
        InputBinding("package", "src", "game", main),
        InputBinding("package", "stable", "game", release),
        InputBinding("compile", "engine", "engine", main),
        InputBinding("compile", "src", "game", main), // bound twice alike: once
    ];
    auto toResolve = refsToResolve(bindings);
    assert(toResolve == [RepositoryAt("engine", main), RepositoryAt("game", main), RepositoryAt("game", release)],
        "Each distinct (repository, ref) once, in a deterministic order");

    InputPin[RepositoryAt] revisions = [
        RepositoryAt("engine", main): InputPin(Json("eee111")),
        RepositoryAt("game", main): InputPin(Json("aaa111"), ["subject": "Fix"]),
        RepositoryAt("game", release): InputPin(Json("ccc333")),
    ];
    auto pins = pinsForBindings(bindings, revisions);
    validatePins(pins, "the test");
    assert(pins == [
        PinnedInput("compile", "engine", "engine", main, InputPin(Json("eee111"))),
        PinnedInput("compile", "src", "game", main, InputPin(Json("aaa111"), ["subject": "Fix"])),
        PinnedInput("lint", "code", "game", main, InputPin(Json("aaa111"), ["subject": "Fix"])),
        PinnedInput("package", "src", "game", main, InputPin(Json("aaa111"), ["subject": "Fix"])),
        PinnedInput("package", "stable", "game", release, InputPin(Json("ccc333"))),
    ]);

    // The same name as a tag is another ref, resolved on its own
    auto tagged = refsToResolve([InputBinding("a", "src", "game", main), InputBinding("b", "src", "game", RepositoryRef(RefKind.tag, "main"))]);
    assert(tagged.length == 2);

    // A ref that was not resolved, an empty revision, an incomplete binding or an input bound two
    // ways fail loudly
    InputPin[RepositoryAt] partial = [RepositoryAt("game", main): InputPin(Json("aaa111"))];
    try
    {
        pinsForBindings(bindings, partial);
        assert(false, "An unresolved ref must throw");
    }
    catch (InputResolutionException e)
    {
        assert(e.msg.canFind("'engine'") || e.msg.canFind("'release'"), e.msg);
    }
    InputPin[RepositoryAt] empty = [RepositoryAt("game", main): InputPin(Json(""))];
    assert(throwsA!InvalidPinsException({ pinsForBindings([InputBinding("a", "src", "game", main)], empty); }));
    assert(throwsA!InvalidPinsException({ refsToResolve([InputBinding("a", "src", "", main)]); }));
    assert(throwsA!InvalidPinsException({ refsToResolve([InputBinding("a", "src", "game", RepositoryRef(RefKind.branch, ""))]); }));
    assert(throwsA!InvalidPinsException({ refsToResolve([InputBinding("a", "src", "game", main), InputBinding("a", "src", "game", release)]); }));
    assert(refsToResolve(null).length == 0 && pinsForBindings(null, null).length == 0);
}

unittest
{
    // A chain's pins are what its tasks are fingerprinted against: pinMap gives graphResolution
    // its pins, and a pin added later serves a task the chain's first request never needed
    import confector.core.dag : TaskGraph;
    import confector.core.input_resolution : GraphResolution, RerunGenerations, graphResolution;

    // Every task never rerun: generations read at 0, a level at a time, as the shell reads them
    GraphResolution atGenerationZero(TaskGraph graph, in PinnedInput[] pins)
    {
        RerunGenerations generations;
        for (;;)
        {
            string[string] unread;
            auto result = graphResolution("p", graph, pinMap(pins), generations, unread);
            if (unread.length == 0) return result;
            foreach (base; unread.byValue) generations[base] = 0;
        }
    }

    TaskNode internal;
    internal.id = "internal";
    internal.inputs["src"] = repositoryInput("game");
    auto chainPins = [pinned("internal", "src", "game", "main", "aaa111")];
    auto first = atGenerationZero(new TaskGraph([internal]), chainPins);
    assert(first.inputs["internal"][0].pinned == Json("aaa111"));

    // A task added to the definition later uses inputs the chain never pinned
    TaskNode external;
    external.id = "external";
    external.inputs["src"] = repositoryInput("game");
    external.inputs["sdk"] = repositoryInput("console-sdk");
    auto resolved = [pinned("external", "src", "game", "main", "aaa111"), pinned("external", "sdk", "console-sdk", "v2", "sdk222")];
    assert(pinsAgree(chainPins, resolved));
    auto grown = mergePins(chainPins, missingPins(chainPins, resolved));
    auto later = atGenerationZero(new TaskGraph([internal, external]), grown);
    assert(later.fingerprints["internal"] == first.fingerprints["internal"], "Adding a pin changes no existing fingerprint");
    assert(later.inputs["external"][0].pinned == Json("sdk222") && later.inputs["external"][1].pinned == Json("aaa111"));
}
