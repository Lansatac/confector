module confector.core.definition_hash;

import confector.core.fingerprinter : canonicalPinned, sha256Hex;
import confector.plugin_api.model;

import vibe.data.json : Json;

/**
 * Computes the hash of a task's build configuration (design records: beads confector-z7z.1 and
 * confector-z7z.20.4): its steps (type and config), the task environment and its output
 * declarations (id and path). Display names, the timeout and inputs do not contribute: names
 * are cosmetic, and inputs are already part of the fingerprint.
 *
 * Each execution result records this hash beside its fingerprint so the UI can show that a
 * result predates a configuration change. It is never part of the fingerprint. The hash is
 * over canonical JSON, so it does not depend on the order of any map or config key; the order
 * of steps and of output declarations does matter. A step without config hashes like one with
 * an empty config object: both mean no settings.
 */
string computeDefinitionHash(in TaskNode task) @trusted
{
    Json steps = Json.emptyArray;
    foreach (step; task.steps)
    {
        Json item = Json.emptyObject;
        item["type"] = step.type;
        item["config"] = step.config.type == Json.Type.undefined ? Json.emptyObject : step.config.clone;
        steps ~= item;
    }

    Json outputs = Json.emptyArray;
    foreach (artifact; task.outputs.artifacts)
    {
        Json item = Json.emptyObject;
        item["id"] = artifact.id;
        item["path"] = artifact.path;
        outputs ~= item;
    }

    Json definition = Json.emptyObject;
    definition["steps"] = steps;
    definition["environment"] = stringMap(task.environment);
    definition["outputs"] = outputs;
    return sha256Hex(canonicalPinned(definition));
}

/**
 * Records on `record` the definition `task` that the execution ran with, and its hash. The
 * record gets its own copy of the steps (configs included), environment, outputs and inputs, so
 * editing `task` afterwards cannot change what was recorded.
 */
void recordDefinition(ref TaskExecution record, in TaskNode task) @trusted
{
    TaskNode copy = cast(TaskNode) task;
    copy.steps = copy.steps.dup;
    foreach (ref step; copy.steps)
    {
        step.config = step.config.clone;
    }
    copy.environment = copy.environment.dup;
    copy.outputs.artifacts = copy.outputs.artifacts.dup;
    copy.inputs = copy.inputs.dup;
    record.definition = copy;
    record.definitionHash = computeDefinitionHash(task);
}

private Json stringMap(in string[string] map) @trusted
{
    Json result = Json.emptyObject;
    foreach (key, value; map) result[key] = value;
    return result;
}

version (unittest)
{
    /// A step of type `type` whose config is `config`.
    private BuildStep step(string name, string type, Json config)
    {
        return BuildStep(name, type, config);
    }
}

unittest
{
    TaskNode task;
    task.id = "build";
    task.name = "Build";
    task.steps = [
        step("Compile", "bash", Json(["script": Json("dub build"), "working_directory": Json("src")])),
        step("Package", "powershell", Json(["script": Json("Compress-Archive out out.zip")])),
    ];
    task.environment = ["A": "1", "B": "2", "C": "3"];
    task.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    const hash = computeDefinitionHash(task);
    assert(hash.length == 64, "The hash must be a 64-char SHA256 hex string");
    assert(computeDefinitionHash(task) == hash);

    // Cosmetic fields do not change the hash: display names, timeout, inputs
    TaskNode cosmetic = task;
    cosmetic.name = "Renamed";
    cosmetic.steps = task.steps.dup;
    cosmetic.steps[0].name = "Compile the game";
    cosmetic.timeoutSeconds = 60;
    cosmetic.inputs["flavor"] = valueInput("internal");
    assert(computeDefinitionHash(cosmetic) == hash);

    // Map and config key order does not matter
    TaskNode reordered = task;
    reordered.environment = null;
    foreach (key; ["C", "B", "A"]) reordered.environment[key] = task.environment[key];
    reordered.steps = task.steps.dup;
    reordered.steps[0].config = Json.emptyObject;
    reordered.steps[0].config["working_directory"] = "src";
    reordered.steps[0].config["script"] = "dub build";
    assert(computeDefinitionHash(reordered) == hash);

    // No config and an empty config are the same: no settings
    TaskNode bare;
    bare.steps = [BuildStep("Checkout", "checkout")];
    TaskNode empty;
    empty.steps = [step("Checkout", "checkout", Json.emptyObject)];
    assert(computeDefinitionHash(bare) == computeDefinitionHash(empty));

    // Configuration changes do
    TaskNode changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].config = Json(["script": Json("dub build --build=release"), "working_directory": Json("src")]);
    assert(computeDefinitionHash(changed) != hash, "A step's config value");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].config = Json(["script": Json("dub build"), "working_directory": Json("src"), "environment": Json(["X": Json("1")])]);
    assert(computeDefinitionHash(changed) != hash, "An added config key");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].config = Json(["script": Json("dub build"), "working_directory": Json(1)]);
    assert(computeDefinitionHash(changed) != hash, "A config value of another JSON type");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].type = "powershell";
    assert(computeDefinitionHash(changed) != hash, "A step type");

    changed = task;
    changed.outputs.artifacts = [OutputArtifactDecl("bins", "out/*")];
    assert(computeDefinitionHash(changed) != hash, "An output id");

    changed = task;
    changed.steps = [task.steps[1], task.steps[0]];
    assert(computeDefinitionHash(changed) != hash, "Step order");

    changed = task;
    changed.steps = task.steps[0 .. 1];
    assert(computeDefinitionHash(changed) != hash, "A removed step");

    changed = task;
    changed.environment = ["A": "1", "B": "2", "C": "4"];
    assert(computeDefinitionHash(changed) != hash, "A task environment value");

    changed = task;
    changed.outputs.artifacts = [OutputArtifactDecl("binaries", "dist/*")];
    assert(computeDefinitionHash(changed) != hash, "An output path");

    changed = task;
    changed.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*"), OutputArtifactDecl("symbols", "sym/*")];
    assert(computeDefinitionHash(changed) != hash, "An added output");

    // Values cannot be shifted between fields
    TaskNode a;
    a.steps = [step("s", "bash", Json(["script": Json("x")]))];
    TaskNode b;
    b.steps = [step("s", "bash", Json(["command": Json("x")]))];
    assert(computeDefinitionHash(a) != computeDefinitionHash(b));
    TaskNode c;
    c.outputs.artifacts = [OutputArtifactDecl("x", "y")];
    TaskNode d;
    d.outputs.artifacts = [OutputArtifactDecl("y", "x")];
    assert(computeDefinitionHash(c) != computeDefinitionHash(d));
}

unittest
{
    // A record carries the definition and the hash it was recorded with, and both survive
    // serialization
    import vibe.data.json : deserializeJson, serializeToJson;

    TaskNode task;
    task.id = "build";
    task.name = "Build";
    task.inputs["flavor"] = valueInput("internal");
    task.steps = [step("Compile", "bash", Json(["script": Json("dub build"), "shell": Json("bash")]))];
    task.environment = ["A": "1"];
    task.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    TaskExecution record;
    recordDefinition(record, task);
    assert(record.definitionHash == computeDefinitionHash(task));
    assert(record.definition.steps[0].config["script"].get!string == "dub build");

    // The record does not alias the task's arrays, maps or step configs
    task.steps[0].config["script"] = "edited";
    task.steps[0].config["shell"] = "edited";
    task.environment["A"] = "edited";
    task.outputs.artifacts[0].path = "edited";
    assert(record.definition.steps[0].config["script"].get!string == "dub build");
    assert(record.definition.steps[0].config["shell"].get!string == "bash");
    assert(record.definition.environment["A"] == "1" && record.definition.outputs.artifacts[0].path == "out/*");
    assert(computeDefinitionHash(record.definition) == record.definitionHash);
    task.steps[0].config["script"] = "dub build";
    task.steps[0].config["shell"] = "bash";
    task.environment["A"] = "1";
    task.outputs.artifacts[0].path = "out/*";

    // Survives a serialization round trip, as when stored in and loaded from the state store
    auto restored = deserializeJson!TaskExecution(serializeToJson(record).toString());
    assert(restored.definitionHash == record.definitionHash);
    assert(computeDefinitionHash(restored.definition) == record.definitionHash);
    assert(restored.definition.name == "Build" && restored.definition.inputs["flavor"].spec.value == "internal");
}
