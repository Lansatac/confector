module confector.core.definition_hash;

import confector.core.fingerprinter : canonicalPinned, sha256Hex;
import confector.core.model;

import vibe.data.json : Json;

/**
 * Computes the hash of a task's build configuration (design records: beads confector-z7z.1 and
 * confector-z7z.20.4): its steps (type, parameters, script, command, working directory,
 * environment, properties), the task environment and its output declarations. Display names,
 * the timeout, triggers, components and inputs do not contribute: names and triggers are
 * cosmetic or say when to run, and inputs are already part of the fingerprint.
 *
 * Each execution result records this hash beside its fingerprint so the UI can show that a
 * result predates a configuration change. It is never part of the fingerprint. The hash is
 * over canonical JSON, so it does not depend on the order of any map; the order of steps and
 * of output declarations does matter.
 */
string computeDefinitionHash(in TaskNode task) @trusted
{
    Json steps = Json.emptyArray;
    foreach (step; task.steps)
    {
        Json item = Json.emptyObject;
        item["type"] = step.type;
        item["parameters"] = stringMap(step.parameters);
        item["script"] = step.script;
        item["command"] = step.command;
        item["working_directory"] = step.workingDirectory;
        item["environment"] = stringMap(step.environment);
        item["properties"] = step.propertiesJson;
        steps ~= item;
    }

    Json outputs = Json.emptyArray;
    foreach (artifact; task.outputs.artifacts)
    {
        Json item = Json.emptyObject;
        item["id"] = artifact.effectiveId;
        item["path"] = artifact.effectivePath;
        item["type"] = artifact.type;
        outputs ~= item;
    }

    Json definition = Json.emptyObject;
    definition["steps"] = steps;
    definition["environment"] = stringMap(task.environment);
    definition["outputs"] = outputs;
    return sha256Hex(canonicalPinned(definition));
}

/**
 * Records on `record` the definition `task` that an execution ran with, and its hash. The
 * record gets its own copy of the steps, environment and outputs, so editing `task` afterwards
 * cannot change what was recorded.
 */
void recordDefinition(ref TaskExecutionRecord record, in TaskNode task) @trusted
{
    TaskNode copy = cast(TaskNode) task;
    copy.steps = copy.steps.dup;
    foreach (ref step; copy.steps)
    {
        step.parameters = step.parameters.dup;
        step.environment = step.environment.dup;
    }
    copy.environment = copy.environment.dup;
    copy.outputs.artifacts = copy.outputs.artifacts.dup;
    copy.inputs = copy.inputs.dup;
    copy.components = copy.components.dup;
    copy.triggers = copy.triggers.dup;
    record.definition = copy;
    record.definitionHash = computeDefinitionHash(task);
}

private Json stringMap(in string[string] map) @trusted
{
    Json result = Json.emptyObject;
    foreach (key, value; map) result[key] = value;
    return result;
}

unittest
{
    TaskNode task;
    task.id = "build";
    task.name = "Build";
    task.steps = [
        BuildStep("Compile", "bash", ["shell": "bash"], "dub build", null, "src", null),
        BuildStep("Package", "powershell", null, null, "Compress-Archive out out.zip"),
    ];
    task.environment = ["A": "1", "B": "2", "C": "3"];
    task.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    const hash = computeDefinitionHash(task);
    assert(hash.length == 64, "The hash must be a 64-char SHA256 hex string");
    assert(computeDefinitionHash(task) == hash);

    // Cosmetic fields do not change the hash: display names, timeout, triggers, inputs
    TaskNode cosmetic = task;
    cosmetic.name = "Renamed";
    cosmetic.steps = task.steps.dup;
    cosmetic.steps[0].name = "Compile the game";
    cosmetic.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];
    cosmetic.outputs.artifacts[0].name = "Binaries";
    cosmetic.timeoutSeconds = 60;
    cosmetic.triggers = [TriggerRule()];
    cosmetic.inputs["flavor"] = valueInput("internal");
    assert(computeDefinitionHash(cosmetic) == hash);

    // Map order does not matter
    TaskNode reordered = task;
    reordered.environment = null;
    foreach (key; ["C", "B", "A"]) reordered.environment[key] = task.environment[key];
    assert(computeDefinitionHash(reordered) == hash);

    // Configuration changes do
    TaskNode changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].parameters = ["shell": "sh"];
    assert(computeDefinitionHash(changed) != hash, "A step parameter");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].script = "dub build --build=release";
    assert(computeDefinitionHash(changed) != hash, "A step script");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].type = "powershell";
    assert(computeDefinitionHash(changed) != hash, "A step type");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].environment = ["X": "1"];
    assert(computeDefinitionHash(changed) != hash, "A step environment");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].workingDirectory = "other";
    assert(computeDefinitionHash(changed) != hash, "A step working directory");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[0].propertiesJson = `{"a":1}`;
    assert(computeDefinitionHash(changed) != hash, "Step properties");

    changed = task;
    changed.steps = task.steps.dup;
    changed.steps[1].command = "Compress-Archive out other.zip";
    assert(computeDefinitionHash(changed) != hash, "A step command");

    changed = task;
    changed.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];
    changed.outputs.artifacts[0].type = "directory";
    assert(computeDefinitionHash(changed) != hash, "An output type");

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
    a.steps = [BuildStep("s", "bash", null, "x", null)];
    TaskNode b;
    b.steps = [BuildStep("s", "bash", null, null, "x")];
    assert(computeDefinitionHash(a) != computeDefinitionHash(b));
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
    task.steps = [BuildStep("Compile", "bash", ["shell": "bash"], "dub build")];
    task.environment = ["A": "1"];
    task.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];

    TaskExecutionRecord record;
    recordDefinition(record, task);
    assert(record.definitionHash == computeDefinitionHash(task));
    assert(record.definition.steps[0].script == "dub build");

    // The record does not alias the task's arrays or maps
    task.steps[0].script = "edited";
    task.steps[0].parameters["shell"] = "edited";
    task.environment["A"] = "edited";
    task.outputs.artifacts[0].path = "edited";
    assert(record.definition.steps[0].script == "dub build" && record.definition.steps[0].parameters["shell"] == "bash");
    assert(record.definition.environment["A"] == "1" && record.definition.outputs.artifacts[0].path == "out/*");
    assert(computeDefinitionHash(record.definition) == record.definitionHash);
    task.steps[0].script = "dub build";
    task.steps[0].parameters["shell"] = "bash";
    task.environment["A"] = "1";
    task.outputs.artifacts[0].path = "out/*";

    auto restored = deserializeJson!TaskExecutionRecord(serializeToJson(record));
    assert(restored.definitionHash == record.definitionHash);
    assert(computeDefinitionHash(restored.definition) == record.definitionHash);
    assert(restored.definition.name == "Build" && restored.definition.inputs["flavor"].spec.value == "internal");
}
