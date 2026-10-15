module confector.core.fingerprinter;

import confector.core.model;

import vibe.data.json : Json;

import std.algorithm.sorting : sort;
import std.array : appender;
import std.digest : toHexString, LetterCase;
import std.digest.sha : SHA256;
import std.format : format;

/**
 * Computes deterministic SHA256 hex digest for a string payload.
 */
string sha256Hex(in string input) pure nothrow @safe
{
    SHA256 sha;
    sha.start();
    sha.put(cast(const(ubyte)[]) input);
    auto digest = sha.finish();

    return toHexString!(LetterCase.lower)(digest).idup;
}

/**
 * Serializes a pinned value to a canonical string: object keys are sorted at every level
 * and no insignificant whitespace is emitted, so equal values always hash equally.
 */
string canonicalPinned(in Json value) @trusted
{
    if (value.type == Json.Type.undefined)
    {
        throw new Exception("Cannot fingerprint an undefined pinned value");
    }
    auto app = appender!string();
    putCanonical(app, value);
    return app.data;
}

private void putCanonical(Out)(ref Out app, in Json value) @trusted
{
    final switch (value.type)
    {
        case Json.Type.undefined:
            throw new Exception("Cannot fingerprint an undefined pinned value");
        case Json.Type.null_:
            app.put("null");
            break;
        case Json.Type.bool_:
        case Json.Type.int_:
        case Json.Type.bigInt:
        case Json.Type.float_:
        case Json.Type.string:
            app.put(value.toString());
            break;
        case Json.Type.array:
            app.put('[');
            bool firstItem = true;
            foreach (size_t i; 0 .. value.length)
            {
                if (!firstItem) app.put(',');
                firstItem = false;
                putCanonical(app, value[i]);
            }
            app.put(']');
            break;
        case Json.Type.object:
            string[] keys;
            foreach (string key, const(Json) item; value.byKeyValue) keys ~= key;
            keys.sort();
            app.put('{');
            bool firstKey = true;
            foreach (key; keys)
            {
                if (!firstKey) app.put(',');
                firstKey = false;
                app.put(Json(key).toString());
                app.put(':');
                putCanonical(app, value[key]);
            }
            app.put('}');
            break;
    }
}

/**
 * Computes a node's fingerprint: SHA256 over the node's identity (project id and task id)
 * and its resolved inputs, sorted by input name, each as `name=pinned`. Nothing else contributes; in particular, build
 * configuration (steps, environment, outputs) does not.
 *
 * A task_output input's pinned value is the upstream task's fingerprint, so hashing is
 * transitive. Fields are length-prefixed so distinct inputs can never serialize alike.
 * This function is pure: it does not consult the plugin registry or any other state.
 *
 * Throws: Exception if the project id is empty, two inputs share a name, or a pinned
 * value is undefined.
 */
string computeNodeFingerprint(in string projectId, in string nodeId, in ResolvedInput[] inputs) @trusted
{
    if (projectId.length == 0)
    {
        throw new Exception(format("Cannot fingerprint task '%s' without a project id", nodeId));
    }

    string[string] bindings;
    foreach (input; inputs)
    {
        if (input.name in bindings)
        {
            throw new Exception(format("Task '%s' has more than one resolved input named '%s'", nodeId, input.name));
        }
        bindings[input.name] = canonicalPinned(input.pinned);
    }

    string[] names = bindings.keys;
    names.sort();

    auto app = appender!string();
    putField(app, projectId);
    putField(app, nodeId);
    foreach (name; names)
    {
        putField(app, name);
        putField(app, bindings[name]);
    }
    return sha256Hex(app.data);
}

private void putField(Out)(ref Out app, in string field) @safe
{
    app.put(format("%d:", field.length));
    app.put(field);
    app.put('\n');
}

/**
 * Pins the inputs that need no provider: a value input pins to its value and a task_output
 * input pins to the upstream task's fingerprint (taken from `upstreamFingerprints`, keyed
 * by task id). Repository inputs take their pinned value from `resolvedRepositories`
 * (keyed by input name); until a resolver supplies one, a repository input pins to an
 * explicit `{"unresolved": {"repository": <id>, "ref": <selector>}}` marker built from its
 * declaration, so changing the repository or ref still changes the fingerprint.
 *
 * Throws: Exception if a task_output input names an upstream task with no fingerprint.
 */
ResolvedInput[] pinInputs(
    in TaskNode task,
    in string[string] upstreamFingerprints,
    in ResolvedInput[string] resolvedRepositories = null
) @trusted
{
    ResolvedInput[] result;
    foreach (name; task.inputs.keys.sort().release)
    {
        const decl = task.inputs[name];
        ResolvedInput input;
        input.name = name;
        input.kind = decl.kind;
        final switch (decl.kind)
        {
            case InputKind.value:
                input.pinned = Json(decl.spec.value);
                break;
            case InputKind.taskOutput:
                auto fp = decl.spec.task in upstreamFingerprints;
                if (fp is null)
                {
                    throw new Exception(format("Task '%s' input '%s' has no fingerprint for upstream task '%s'",
                        task.id, name, decl.spec.task));
                }
                input.pinned = Json(*fp);
                break;
            case InputKind.repository:
                if (auto resolved = name in resolvedRepositories) input.pinned = resolved.pinned;
                else
                {
                    auto spec = Json.emptyObject;
                    spec["repository"] = decl.spec.repository;
                    spec["ref"] = decl.spec.refSelector;
                    input.pinned = Json.emptyObject;
                    input.pinned["unresolved"] = spec;
                }
                break;
        }
        result ~= input;
    }
    return result;
}

unittest
{
    ResolvedInput pin(string name, InputKind kind, Json pinned)
    {
        ResolvedInput input;
        input.name = name;
        input.kind = kind;
        input.pinned = pinned;
        return input;
    }

    auto src = pin("src", InputKind.repository, Json("aaa111"));
    auto lib = pin("lib", InputKind.repository, Json("bbb222"));
    auto flavor = pin("flavor", InputKind.value, Json("internal"));

    const base = computeNodeFingerprint("p", "build", [src, lib, flavor]);
    assert(base.length == 64, "Fingerprint must be a 64-char SHA256 hex string");

    // Deterministic, and independent of the order inputs are listed in
    assert(computeNodeFingerprint("p", "build", [src, lib, flavor]) == base);
    assert(computeNodeFingerprint("p", "build", [flavor, lib, src]) == base);

    // Changing any pinned value changes the fingerprint
    assert(computeNodeFingerprint("p", "build", [pin("src", InputKind.repository, Json("aaa112")), lib, flavor]) != base);
    assert(computeNodeFingerprint("p", "build", [src, pin("lib", InputKind.repository, Json("bbb223")), flavor]) != base);
    assert(computeNodeFingerprint("p", "build", [src, lib, pin("flavor", InputKind.value, Json("external"))]) != base);

    // Changing an input name changes the fingerprint
    assert(computeNodeFingerprint("p", "build", [pin("source", InputKind.repository, Json("aaa111")), lib, flavor]) != base);

    // Adding or removing an input changes the fingerprint
    assert(computeNodeFingerprint("p", "build", [src, lib]) != base);

    // Two nodes with identical inputs differ
    assert(computeNodeFingerprint("p", "build-internal", [src, lib, flavor])
        != computeNodeFingerprint("p", "build-external", [src, lib, flavor]));

    // Field boundaries cannot be forged: moving text between name and pinned value changes the hash
    assert(computeNodeFingerprint("p", "n", [pin("a", InputKind.value, Json("b=c"))])
        != computeNodeFingerprint("p", "n", [pin("a=b", InputKind.value, Json("c"))]));

    // Object-valued pinned values hash the same regardless of key order
    Json objA = Json.emptyObject;
    objA["sha"] = "abc";
    objA["tree"] = "def";
    Json objB = Json.emptyObject;
    objB["tree"] = "def";
    objB["sha"] = "abc";
    assert(computeNodeFingerprint("p", "n", [pin("p", InputKind.repository, objA)])
        == computeNodeFingerprint("p", "n", [pin("p", InputKind.repository, objB)]));
    objB["sha"] = "abd";
    assert(computeNodeFingerprint("p", "n", [pin("p", InputKind.repository, objA)])
        != computeNodeFingerprint("p", "n", [pin("p", InputKind.repository, objB)]));

    // Duplicate input names fail loudly
    bool threw = false;
    try computeNodeFingerprint("p", "build", [src, src]);
    catch (Exception) threw = true;
    assert(threw, "Duplicate input names must throw");
}

unittest
{
    // Build configuration is not part of the fingerprint: pinInputs only reads declared inputs
    TaskNode task;
    task.id = "build";
    task.inputs["flavor"] = valueInput("internal");
    task.steps = [BuildStep("Build", "bash", null, "dub build --build=release")];
    task.environment = ["DUB_ARGS": "-q"];
    task.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    const base = computeNodeFingerprint("p", task.id, pinInputs(task, null));

    TaskNode changed = task;
    changed.steps = [BuildStep("Build", "bash", null, "dub build --build=debug"), BuildStep("Extra", "bash", null, "echo")];
    changed.environment = ["DUB_ARGS": "-v", "EXTRA": "1"];
    changed.outputs.artifacts = [OutputArtifactDecl("binaries", "dist/*")];
    assert(computeNodeFingerprint("p", changed.id, pinInputs(changed, null)) == base,
        "Changing step, environment or output configuration must not change the fingerprint");

    // Changing a declared input does
    TaskNode newFlavor = task;
    newFlavor.inputs["flavor"] = valueInput("external");
    assert(computeNodeFingerprint("p", newFlavor.id, pinInputs(newFlavor, null)) != base);
}

unittest
{
    // A change to an upstream fingerprint propagates to the downstream node, transitively
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["flavor"] = valueInput("internal");
    TaskNode test;
    test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile", "binaries");
    TaskNode report;
    report.id = "report";
    report.inputs["results"] = taskOutputInput("test");

    string[string] fps;
    fps["compile"] = computeNodeFingerprint("p", compile.id, pinInputs(compile, null));
    fps["test"] = computeNodeFingerprint("p", test.id, pinInputs(test, fps));
    fps["report"] = computeNodeFingerprint("p", report.id, pinInputs(report, fps));

    compile.inputs["flavor"] = valueInput("external");
    string[string] fps2;
    fps2["compile"] = computeNodeFingerprint("p", compile.id, pinInputs(compile, null));
    fps2["test"] = computeNodeFingerprint("p", test.id, pinInputs(test, fps2));
    fps2["report"] = computeNodeFingerprint("p", report.id, pinInputs(report, fps2));

    assert(fps2["compile"] != fps["compile"]);
    assert(fps2["test"] != fps["test"], "Upstream change must change the direct dependent");
    assert(fps2["report"] != fps["report"], "Upstream change must propagate transitively");

    // The order the upstream fingerprints were inserted in does not matter
    string[string] reversed;
    foreach (k; ["report", "test", "compile"]) reversed[k] = fps[k];
    assert(computeNodeFingerprint("p", test.id, pinInputs(test, reversed)) == fps["test"]);

    // A task_output input with no upstream fingerprint fails loudly
    bool threw = false;
    try pinInputs(test, null);
    catch (Exception) threw = true;
    assert(threw);
}

unittest
{
    // A repository input contributes its resolved pinned revision, not its declaration
    TaskNode task;
    task.id = "compile";
    task.inputs["src"] = repositoryInput("game", "main");

    ResolvedInput[string] atA = ["src": ResolvedInput("src", InputKind.repository, Json("aaa111"))];
    ResolvedInput[string] atB = ["src": ResolvedInput("src", InputKind.repository, Json("ccc333"))];
    assert(computeNodeFingerprint("p", task.id, pinInputs(task, null, atA))
        != computeNodeFingerprint("p", task.id, pinInputs(task, null, atB)));

    // Display-only info is never hashed
    ResolvedInput[string] atAInfo = ["src": ResolvedInput("src", InputKind.repository, Json("aaa111"), ["branch": "main"])];
    assert(computeNodeFingerprint("p", task.id, pinInputs(task, null, atA))
        == computeNodeFingerprint("p", task.id, pinInputs(task, null, atAInfo)));
}

unittest
{
    // An unresolved repository input still reflects its declaration
    TaskNode task;
    task.id = "compile";
    task.inputs["src"] = repositoryInput("game", "main");
    const base = computeNodeFingerprint("p", task.id, pinInputs(task, null));

    TaskNode otherRepo = task;
    otherRepo.inputs["src"] = repositoryInput("engine", "main");
    assert(computeNodeFingerprint("p", task.id, pinInputs(otherRepo, null)) != base);

    TaskNode otherRef = task;
    otherRef.inputs["src"] = repositoryInput("game", "release");
    assert(computeNodeFingerprint("p", task.id, pinInputs(otherRef, null)) != base);
}

unittest
{
    // Same task id and inputs in different projects never share a fingerprint
    ResolvedInput flavor = ResolvedInput("flavor", InputKind.value, Json("internal"));
    assert(computeNodeFingerprint("alpha", "build", [flavor]) != computeNodeFingerprint("beta", "build", [flavor]));
    // Project and task ids cannot be shifted into each other
    assert(computeNodeFingerprint("ab", "c", [flavor]) != computeNodeFingerprint("a", "bc", [flavor]));

    bool threw = false;
    try computeNodeFingerprint("", "build", [flavor]);
    catch (Exception) threw = true;
    assert(threw, "An empty project id must throw");
}

unittest
{
    // An undefined pinned value is an error, not something to hash
    ResolvedInput bad;
    bad.name = "src";
    bad.kind = InputKind.repository;
    bool threw = false;
    try computeNodeFingerprint("p", "build", [bad]);
    catch (Exception) threw = true;
    assert(threw, "An undefined pin must throw");
}
