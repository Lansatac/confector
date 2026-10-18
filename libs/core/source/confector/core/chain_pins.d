module confector.core.chain_pins;

/**
 * Pure operations on pinned inputs (design record: bead confector-z7z.52; AGENTS.md, "What a
 * build is"): a chain's pins (`BuildChain.pins`) and the pins supplied with a request
 * (`BuildRequest.pins`) are lists of `PinnedInput`, keyed by `pinKey` and sorted by it; input
 * resolution works on maps keyed the same way (`InputPin[InputDecl]`).
 *
 * - `pinnedInputs` and `pinMap` convert between the two forms; `pinMap` of a chain's pins is what
 *   `confector.core.input_resolution.graphResolution` takes.
 * - `mergePins` adds pins to a list: pins only grow, and a pin once set never changes.
 * - `pinsAgree` and `missingPins` are what the input resolver needs to decide whether a request
 *   joins a chain and which pins it adds to it (bead confector-z7z.53.2).
 * - `validatePins` checks a stored list.
 *
 * Two pins agree when their pinned values are equal as canonical JSON. Display info is never
 * compared: re-adding a pin with other display info changes nothing, and the first info is kept.
 */

import confector.core.fingerprinter : canonicalPinned;
import confector.core.input_resolution : InputResolutionException, pinKey;
import confector.api.model;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.format : format;

/**
 * An input is already pinned to another value. Pins never change once set: a request whose
 * resolved value differs belongs on another chain.
 */
class PinConflictException : Exception
{
    /// The input's pin key.
    InputDecl input;
    /// The value it is pinned to, and the different value offered.
    Json existing;
    Json proposed;

    this(string msg, InputDecl input, Json existing, Json proposed, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        this.input = input;
        this.existing = existing;
        this.proposed = proposed;
    }
}

/**
 * A list of pins that is not well formed: an input that is not reduced to its pin key, an empty
 * pinned value, or a list that is not sorted by pin key or holds an input twice.
 */
class InvalidPinsException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Whether pin key `a` sorts before pin key `b`: by kind, then component by component through the
 * kind-specific key (for a repository, its id and then its ref selector, each compared as text).
 * A strict total order on pin keys; lists of pins are sorted by it.
 *
 * Throws: InputResolutionException if either key is not an external input's.
 */
bool pinKeyLess(in InputDecl a, in InputDecl b) @safe
{
    if (a.kind != b.kind) return cast(string) a.kind < cast(string) b.kind;
    final switch (a.kind)
    {
        case InputKind.repository:
            if (a.spec.repository != b.spec.repository) return a.spec.repository < b.spec.repository;
            return a.spec.refSelector < b.spec.refSelector;
        case InputKind.value:
        case InputKind.taskOutput:
            throw new InputResolutionException(format("Input of kind '%s' has no pin key to order by", cast(string) a.kind));
    }
}

/// Describes pin key `key` for messages: "repository 'game' at ref 'main'".
string describePinKey(in InputDecl key) @safe
{
    if (key.kind == InputKind.repository)
    {
        return format("repository '%s' at ref '%s'", key.spec.repository, key.spec.refSelector);
    }
    return format("input of kind '%s'", cast(string) key.kind);
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

/**
 * Throws InvalidPinsException unless `pins` is a well-formed list of pins: every input reduced to
 * its pin key, no pinned value empty (`isEmptyPinned`), sorted by pin key (`pinKeyLess`) with no
 * input twice. `owner` names whose pins they are, for the message ("chain 'c1'").
 */
void validatePins(in PinnedInput[] pins, lazy string owner) @trusted
{
    foreach (i, ref entry; pins)
    {
        InputDecl key;
        try key = pinKey(entry.input);
        catch (InputResolutionException e)
        {
            throw new InvalidPinsException(format("Pin %s of %s: %s", i, owner, e.msg));
        }
        if (key != entry.input)
        {
            throw new InvalidPinsException(format("Pin %s of %s (%s) is not reduced to its pin key", i, owner, describePinKey(key)));
        }
        requireValue(entry.pin, key, owner);
        if (i > 0 && !pinKeyLess(pins[i - 1].input, key))
        {
            throw new InvalidPinsException(format("The pins of %s are not sorted by pin key, or pin %s twice", owner, describePinKey(key)));
        }
    }
}

/**
 * Returns `pins` as a list sorted by pin key, each input reduced to its pin key, with copies of
 * the pinned values and display info.
 *
 * Throws: InputResolutionException if a key is not an external input; InvalidPinsException if a
 * pinned value is empty, or two keys that reduce to the same pin key carry different values.
 */
PinnedInput[] pinnedInputs(in InputPin[InputDecl] pins) @trusted
{
    InputPin[InputDecl] byKey;
    foreach (decl, pin; pins) addTo(byKey, decl, pin, "the given pins");
    return sortedList(byKey);
}

/**
 * Returns `pins` as a map keyed by pin key, as input resolution takes it
 * (`confector.core.input_resolution.graphResolution`), with copies of the pinned values and
 * display info.
 *
 * Throws: as `pinnedInputs`, for a list that holds an input twice with different values.
 */
InputPin[InputDecl] pinMap(in PinnedInput[] pins) @trusted
{
    InputPin[InputDecl] byKey;
    foreach (ref entry; pins) addTo(byKey, entry.input, entry.pin, "the given pins");
    return byKey;
}

/**
 * Returns `existing` with `added` added, sorted by pin key. Pins only grow: an input already in
 * `existing` keeps its pin, and adding it again with the same value (whatever its display info)
 * changes nothing. The result is longer than `existing` exactly when something was added.
 *
 * Throws: PinConflictException if `added` pins an input of `existing` to another value (the race
 * case: another request pinned it first; decide again); InvalidPinsException if `added` pins one
 * input twice with different values or a pinned value is empty, and InputResolutionException if
 * an added pin has no pin key (caller mistakes).
 */
PinnedInput[] mergePins(in PinnedInput[] existing, in PinnedInput[] added) @trusted
{
    InputPin[InputDecl] additions;
    foreach (ref entry; added) addTo(additions, entry.input, entry.pin, "the pins being added");

    InputPin[InputDecl] byKey = pinMap(existing);
    foreach (key, pin; additions)
    {
        if (auto pinnedAlready = key in byKey)
        {
            if (!samePinned(pinnedAlready.pinned, pin.pinned))
            {
                throw new PinConflictException(format(
                    "%s is already pinned to %s in the chain; it cannot be pinned to %s, because pins never change",
                    describePinKey(key), canonicalPinned(pinnedAlready.pinned), canonicalPinned(pin.pinned)),
                    key, pinnedAlready.pinned.clone, pin.pinned.clone);
            }
            continue;
        }
        byKey[key] = pin;
    }
    return sortedList(byKey);
}

/**
 * Whether `chainPins` agree with every value in `resolved`: no input pinned in both has different
 * values. Inputs pinned in only one of them do not matter; `missingPins` lists the ones the chain
 * lacks. A request joins a chain of its branch context only if they agree (bead
 * confector-z7z.53.2).
 *
 * Throws: as `pinMap` and `pinnedInputs`.
 */
bool pinsAgree(in PinnedInput[] chainPins, in InputPin[InputDecl] resolved) @trusted
{
    const chain = pinMap(chainPins);
    foreach (ref entry; pinnedInputs(resolved))
    {
        auto pinned = entry.input in chain;
        if (pinned !is null && !samePinned(pinned.pinned, entry.pin.pinned)) return false;
    }
    return true;
}

/**
 * Returns the pins of `resolved` whose inputs `chainPins` lacks, sorted by pin key: what a request
 * joining the chain adds to it (`ChainStore.addPins`).
 *
 * Throws: as `pinMap` and `pinnedInputs`.
 */
PinnedInput[] missingPins(in PinnedInput[] chainPins, in InputPin[InputDecl] resolved) @trusted
{
    const chain = pinMap(chainPins);
    PinnedInput[] result;
    foreach (entry; pinnedInputs(resolved))
    {
        if (entry.input !in chain) result ~= entry;
    }
    return result;
}

/// Whether two pinned values are equal as canonical JSON: whether two pins agree.
bool samePinned(in Json a, in Json b) @trusted
{
    return canonicalPinned(a) == canonicalPinned(b);
}

private void requireValue(in InputPin pin, in InputDecl key, lazy string owner) @trusted
{
    if (isEmptyPinned(pin.pinned))
    {
        throw new InvalidPinsException(format("The pin of %s in %s has an empty pinned value", describePinKey(key), owner));
    }
}

/// Adds `pin` for `decl` to `byKey` under its pin key, unless an equal pin is there; throws
/// InvalidPinsException if a different one is: one list or map pinning an input twice with
/// different values is the caller's mistake.
private void addTo(ref InputPin[InputDecl] byKey, in InputDecl decl, in InputPin pin, string owner) @trusted
{
    const key = pinKey(decl);
    requireValue(pin, key, owner);
    if (auto existing = key in byKey)
    {
        if (!samePinned(existing.pinned, pin.pinned))
        {
            throw new InvalidPinsException(format("%s pin %s twice, to %s and to %s",
                owner, describePinKey(key), canonicalPinned(existing.pinned), canonicalPinned(pin.pinned)));
        }
        return;
    }
    byKey[cast(InputDecl) key] = InputPin(pin.pinned.clone, cast(string[string]) pin.info.dup);
}

private PinnedInput[] sortedList(InputPin[InputDecl] byKey) @trusted
{
    PinnedInput[] result;
    result.reserve(byKey.length);
    foreach (key, pin; byKey) result ~= PinnedInput(key, pin);
    result.sort!((a, b) => pinKeyLess(a.input, b.input));
    return result;
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    private PinnedInput pinned(string repository, string refSelector, string sha, string[string] info = null)
    {
        return PinnedInput(repositoryInput(repository, refSelector), InputPin(Json(sha), info));
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
    // Maps and lists convert both ways; lists are sorted by pin key and keys are reduced
    InputDecl noisy = repositoryInput("tools", "main");
    noisy.spec.value = "stray";
    InputPin[InputDecl] map = [
        repositoryInput("game", "main"): InputPin(Json("aaa111"), ["subject": "Fix"]),
        noisy: InputPin(Json("ttt111")),
        repositoryInput("engine", "stable"): InputPin(Json("eee111")),
    ];
    auto list = pinnedInputs(map);
    assert(list == [pinned("engine", "stable", "eee111"), pinned("game", "main", "aaa111", ["subject": "Fix"]),
        pinned("tools", "main", "ttt111")]);
    validatePins(list, "the test");

    auto back = pinMap(list);
    assert(back.length == 3 && back[repositoryInput("tools", "main")].pinned == Json("ttt111"));
    assert(back[repositoryInput("game", "main")].info == ["subject": "Fix"]);

    // Copies: changing the result does not change the source
    back[repositoryInput("game", "main")].info["subject"] = "edited";
    assert(list[1].pin.info["subject"] == "Fix");
    InputPin[InputDecl] empty;
    assert(pinnedInputs(empty).length == 0 && pinMap(null).length == 0);
}

unittest
{
    // Pins only grow: adding agrees or adds, never changes
    auto existing = [pinned("game", "main", "aaa111", ["subject": "Fix"])];

    // An identical value is a no-op, whatever its display info
    auto same = mergePins(existing, [pinned("game", "main", "aaa111", ["subject": "Other"])]);
    assert(same == existing, "The first display info is kept");

    // A new input is added in pin key order
    auto grown = mergePins(existing, [pinned("engine", "stable", "eee111"), pinned("game", "main", "aaa111")]);
    assert(grown == [pinned("engine", "stable", "eee111"), pinned("game", "main", "aaa111", ["subject": "Fix"])]);
    validatePins(grown, "the test");

    // Another value for a pinned input is refused, naming the input and both values
    try
    {
        mergePins(grown, [pinned("game", "main", "bbb222")]);
        assert(false, "A conflicting pin must throw");
    }
    catch (PinConflictException e)
    {
        assert(e.input == repositoryInput("game", "main"));
        assert(e.existing == Json("aaa111") && e.proposed == Json("bbb222"));
        assert(e.msg.canFind("'game'") && e.msg.canFind("aaa111") && e.msg.canFind("bbb222"));
    }

    // Two different values for one input in the pins being added are the caller's mistake, not a
    // race: InvalidPinsException, whether or not the chain pins the input
    assert(throwsA!InvalidPinsException({ mergePins(null, [pinned("tools", "main", "t1"), pinned("tools", "main", "t2")]); }));
    assert(throwsA!InvalidPinsException({ mergePins(grown, [pinned("game", "main", "aaa111"), pinned("game", "main", "bbb222")]); }));
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
    auto object = [PinnedInput(repositoryInput("depot", "//main"), InputPin(a))];
    assert(mergePins(object, [PinnedInput(repositoryInput("depot", "//main"), InputPin(b))]).length == 1);

    // Empty values and inputs that are not external are refused
    foreach (empty; [Json(null), Json.undefined, Json(""), Json.emptyObject, Json.emptyArray])
    {
        assert(throwsA!InvalidPinsException({ mergePins(null, [PinnedInput(repositoryInput("game", "main"), InputPin(empty))]); }),
            "An empty pinned value is refused");
        assert(throwsA!InvalidPinsException({ validatePins([PinnedInput(repositoryInput("game", "main"), InputPin(empty))], "the test"); }));
    }
    assert(!isEmptyPinned(Json(0)) && !isEmptyPinned(Json(false)) && !isEmptyPinned(Json("a")));
    assert(mergePins(null, [PinnedInput(repositoryInput("depot", "//main"), InputPin(Json(4242)))]).length == 1);
    assert(throwsA!InputResolutionException({ mergePins(null, [PinnedInput(valueInput("x"), InputPin(Json("x")))]); }));
}

unittest
{
    // Agreement and missing pins, as the input resolver decides a join
    auto chain = [pinned("engine", "stable", "eee111"), pinned("game", "main", "aaa111")];

    InputPin[InputDecl] subset = [repositoryInput("game", "main"): InputPin(Json("aaa111"), ["subject": "Other info"])];
    assert(pinsAgree(chain, subset) && missingPins(chain, subset).length == 0);

    InputPin[InputDecl] wider = [
        repositoryInput("game", "main"): InputPin(Json("aaa111")),
        repositoryInput("tools", "main"): InputPin(Json("ttt111")),
        repositoryInput("art", "main"): InputPin(Json("rrr111")),
    ];
    assert(pinsAgree(chain, wider), "Inputs the chain lacks do not disagree");
    assert(missingPins(chain, wider) == [pinned("art", "main", "rrr111"), pinned("tools", "main", "ttt111")]);

    InputPin[InputDecl] moved = [
        repositoryInput("game", "main"): InputPin(Json("bbb222")),
        repositoryInput("tools", "main"): InputPin(Json("ttt111")),
    ];
    assert(!pinsAgree(chain, moved), "A newer revision of a pinned input belongs on another chain");

    // The same repository at another ref is another input
    InputPin[InputDecl] otherRef = [repositoryInput("game", "release"): InputPin(Json("ccc333"))];
    assert(pinsAgree(chain, otherRef) && missingPins(chain, otherRef) == [pinned("game", "release", "ccc333")]);

    InputPin[InputDecl] none;
    assert(pinsAgree(null, wider) && pinsAgree(chain, none) && missingPins(chain, none).length == 0);
    assert(missingPins(null, subset) == [pinned("game", "main", "aaa111", ["subject": "Other info"])]);
}

unittest
{
    // Pin keys order component by component, not by the text of a joined key: "a" sorts before
    // "a b" although a space sorts before a quote
    assert(pinKeyLess(repositoryInput("a", "z"), repositoryInput("a b", "a")));
    assert(!pinKeyLess(repositoryInput("a b", "a"), repositoryInput("a", "z")));
    assert(pinKeyLess(repositoryInput("game", "main"), repositoryInput("game", "release")));
    assert(!pinKeyLess(repositoryInput("game", "main"), repositoryInput("game", "main")));
    InputPin[InputDecl] map = [repositoryInput("a b", "a"): InputPin(Json("1")), repositoryInput("a", "z"): InputPin(Json("2"))];
    auto list = pinnedInputs(map);
    assert(list[0].input == repositoryInput("a", "z"));
    validatePins(list, "the test");
}

unittest
{
    // A stored list must be well formed
    validatePins(null, "the test");
    auto unsorted = [pinned("game", "main", "aaa111"), pinned("engine", "stable", "eee111")];
    assert(throwsA!InvalidPinsException({ validatePins(unsorted, "chain 'c1'"); }));
    auto twice = [pinned("game", "main", "aaa111"), pinned("game", "main", "aaa111")];
    assert(throwsA!InvalidPinsException({ validatePins(twice, "chain 'c1'"); }));
    auto empty = [PinnedInput(repositoryInput("game", "main"), InputPin(Json(null)))];
    assert(throwsA!InvalidPinsException({ validatePins(empty, "chain 'c1'"); }));
    InputDecl noisy = repositoryInput("game", "main");
    noisy.spec.value = "stray";
    assert(throwsA!InvalidPinsException({ validatePins([PinnedInput(noisy, InputPin(Json("a")))], "chain 'c1'"); }));
    try
    {
        validatePins([PinnedInput(valueInput("x"), InputPin(Json("x")))], "chain 'c1'");
        assert(false, "A value input is not pinned on a chain");
    }
    catch (InvalidPinsException e)
    {
        assert(e.msg.canFind("chain 'c1'"));
    }
    assert(throwsA!InvalidPinsException({ validatePins([pinned("game", "", "aaa111")], "chain 'c1'"); }));
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
    internal.inputs["src"] = repositoryInput("game", "main");
    auto chainPins = [pinned("game", "main", "aaa111")];
    auto first = atGenerationZero(new TaskGraph([internal]), chainPins);
    assert(first.inputs["internal"][0].pinned == Json("aaa111"));

    // A task added to the definition later uses a repository the chain never pinned
    TaskNode external;
    external.id = "external";
    external.inputs["src"] = repositoryInput("game", "main");
    external.inputs["sdk"] = repositoryInput("console-sdk", "v2");
    InputPin[InputDecl] resolved = [repositoryInput("console-sdk", "v2"): InputPin(Json("sdk222"))];
    assert(pinsAgree(chainPins, resolved));
    auto grown = mergePins(chainPins, missingPins(chainPins, resolved));
    auto later = atGenerationZero(new TaskGraph([internal, external]), grown);
    assert(later.fingerprints["internal"] == first.fingerprints["internal"], "Adding a pin changes no existing fingerprint");
    assert(later.inputs["external"][0].pinned == Json("sdk222") && later.inputs["external"][1].pinned == Json("aaa111"));
}
