module confector.core.fingerprinter;

import confector.core.model;
import confector.core.plugin;
import confector.core.system : FingerprintContributionSystem, FingerprintContributionContext;

import std.digest.sha : SHA256;
import std.algorithm.sorting : sort;
import std.array : appender;
import std.format : format;
import std.file : exists, isFile, read;
import std.json : JSONValue, JSONType, toJSON;

/**
 * Computes deterministic SHA256 hex digest for a string payload.
 */
string sha256Hex(in string input) pure nothrow @safe
{
    SHA256 sha;
    sha.start();
    sha.put(cast(const(ubyte)[]) input);
    auto digest = sha.finish();

    import std.digest : toHexString, LetterCase;
    return toHexString!(LetterCase.lower)(digest).idup;
}

/**
 * Computes deterministic SHA256 hex digest for file content.
 */
string computeFileSha256(in string filePath) @trusted
{
    if (!exists(filePath) || !isFile(filePath))
    {
        throw new FingerprintException(format("Cannot compute hash: file does not exist or is not regular file: %s", filePath));
    }

    auto content = cast(ubyte[]) read(filePath);
    SHA256 sha;
    sha.start();
    sha.put(content);
    auto digest = sha.finish();

    import std.digest : toHexString, LetterCase;
    return toHexString!(LetterCase.lower)(digest).idup;
}

/**
 * Computes deterministic SHA256 digest of upstream task fingerprints.
 * Ensures associative array keys are sorted lexicographically before hashing.
 */
string computeUpstreamFingerprintsDigest(in string[string] upstreamFingerprints) pure nothrow @safe
{
    if (upstreamFingerprints.length == 0) return sha256Hex("");

    string[] keys;
    foreach (k; upstreamFingerprints.byKey)
    {
        keys ~= k;
    }
    keys.sort();

    auto app = appender!string();
    foreach (k; keys)
    {
        app.put(k);
        app.put("=");
        app.put(upstreamFingerprints[k]);
        app.put("\n");
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of environment key-value pairs.
 */
string computeEnvDigest(in string[string] environment) pure nothrow @safe
{
    if (environment.length == 0) return sha256Hex("");

    string[] keys;
    foreach (k; environment.byKey)
    {
        keys ~= k;
    }
    keys.sort();

    auto app = appender!string();
    foreach (k; keys)
    {
        app.put(k);
        app.put("=");
        app.put(environment[k]);
        app.put("\n");
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of attached custom components.
 */
string computeCustomComponentsDigest(in TaskNode task) @trusted
{
    if (task.components is null || task.components.length == 0) return sha256Hex("");

    string[] keys;
    foreach (k; task.components.byKey)
    {
        keys ~= k;
    }
    keys.sort();

    auto app = appender!string();
    foreach (k; keys)
    {
        app.put(k);
        app.put("=");
        app.put(task.components[k]);
        app.put("\n");
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of task build steps.
 */
string computeBuildStepsDigest(in TaskNode task) @trusted
{
    if (task.steps.length == 0) return sha256Hex("");

    auto app = appender!string();
    foreach (size_t i, step; task.steps)
    {
        app.put(format("[%d]TYPE:%s|NAME:%s|SCRIPT:%s|CMD:%s|DIR:%s\n",
            i, step.type, step.name, step.script, step.command, step.workingDirectory));

        if (step.parameters.length > 0)
        {
            string[] paramKeys;
            foreach (k; step.parameters.byKey) paramKeys ~= k;
            paramKeys.sort();
            foreach (k; paramKeys)
            {
                app.put(format("P:%s=%s\n", k, step.parameters[k]));
            }
        }

        if (step.environment.length > 0)
        {
            app.put(computeEnvDigest(step.environment));
        }

        if (step.propertiesJson.length > 0)
        {
            app.put(step.propertiesJson);
        }
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of task inputs (repositories, configs, upstream artifacts, parameters).
 */
string computeTaskInputsDigest(in TaskNode task) pure nothrow @safe
{
    auto app = appender!string();

    if (task.inputs.repositories.length > 0)
    {
        string[] repos = task.inputs.repositories.dup;
        repos.sort();
        foreach (r; repos)
        {
            app.put("REPO:");
            app.put(r);
            app.put("\n");
        }
    }

    if (task.inputs.repositoryConfigs.length > 0)
    {
        foreach (rc; task.inputs.repositoryConfigs)
        {
            app.put("REPOCFG:url=");
            app.put(rc.url);
            app.put("|branch=");
            app.put(rc.branch);
            app.put("|dir=");
            app.put(rc.targetDir);
            app.put("\n");
        }
    }

    if (task.inputs.upstreamArtifacts.length > 0)
    {
        foreach (art; task.inputs.upstreamArtifacts)
        {
            app.put("UPSTREAM_ART:task=");
            app.put(art.taskId);
            app.put("|art=");
            app.put(art.effectiveArtifactId);
            app.put("|dest=");
            app.put(art.destination);
            app.put("\n");
        }
    }

    if (task.inputs.parameters.length > 0)
    {
        string[] pkeys;
        foreach (k; task.inputs.parameters.byKey) pkeys ~= k;
        pkeys.sort();
        foreach (k; pkeys)
        {
            app.put("PARAM:");
            app.put(k);
            app.put("=");
            app.put(task.inputs.parameters[k]);
            app.put("\n");
        }
    }

    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of task declared output artifacts.
 */
string computeTaskOutputsDigest(in TaskNode task) pure nothrow @safe
{
    if (task.outputs.artifacts.length == 0) return sha256Hex("");

    auto app = appender!string();
    foreach (art; task.outputs.artifacts)
    {
        app.put("OUT_ART:id=");
        app.put(art.effectiveId);
        app.put("|path=");
        app.put(art.effectivePath);
        app.put("\n");
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of task configuration metadata.
 */
string computeTaskConfigDigest(in TaskNode task) pure nothrow @safe
{
    auto app = appender!string();
    app.put(task.id);
    app.put("|");
    app.put(computeEnvDigest(task.environment));
    return sha256Hex(app.data);
}

/**
 * Computes the full Node Fingerprint deterministically upfront:
 * NodeFingerprint = SHA256(
 *     BuildStepsHash
 *   + UpstreamFingerprintsHash
 *   + TaskInputsHash
 *   + TaskOutputsHash
 *   + TaskConfigurationHash
 *   + CustomComponentsHash
 * )
 */
string computeNodeFingerprint(
    in TaskNode task,
    in string[string] upstreamFingerprints = null
) @trusted
{
    auto app = appender!string();
    app.put("STEPS:");
    app.put(computeBuildStepsDigest(task));
    app.put("\nUPSTREAM:");
    app.put(computeUpstreamFingerprintsDigest(upstreamFingerprints));
    app.put("\nINPUTS:");
    app.put(computeTaskInputsDigest(task));
    app.put("\nOUTPUTS:");
    app.put(computeTaskOutputsDigest(task));
    app.put("\nCONFIG:");
    app.put(computeTaskConfigDigest(task));
    app.put("\nCOMPONENTS:");
    app.put(computeCustomComponentsDigest(task));

    return sha256Hex(app.data);
}

/**
 * High-level helper struct for fingerprint computation.
 */
struct Fingerprinter
{
    /**
     * Resolves task configuration and upstream task fingerprints to compute the node fingerprint.
     */
    static string computeNodeFingerprint(
        in TaskNode task,
        string workspaceDir = "",
        in string[string] upstreamFingerprints = null
    ) @trusted
    {
        string[string] relevantFingerprints;
        if (upstreamFingerprints !is null)
        {
            if (task.dependsOn.length > 0 || task.inputs.upstreamArtifacts.length > 0)
            {
                foreach (depId; task.dependsOn)
                {
                    if (auto p = depId in upstreamFingerprints)
                    {
                        relevantFingerprints[depId] = *p;
                    }
                }
                foreach (refArt; task.inputs.upstreamArtifacts)
                {
                    if (refArt.taskId.length > 0)
                    {
                        if (auto p = refArt.taskId in upstreamFingerprints)
                        {
                            relevantFingerprints[refArt.taskId] = *p;
                        }
                    }
                    string artKey = format("%s:%s", refArt.taskId, refArt.effectiveArtifactId);
                    if (auto p = artKey in upstreamFingerprints)
                    {
                        relevantFingerprints[artKey] = *p;
                    }
                }
                if (relevantFingerprints.length == 0)
                {
                    relevantFingerprints = cast(string[string]) upstreamFingerprints;
                }
            }
            else
            {
                relevantFingerprints = cast(string[string]) upstreamFingerprints;
            }
        }

        string baseFp = .computeNodeFingerprint(task, relevantFingerprints);

        // Incorporate registered FingerprintContributionSystem outputs if present
        auto contributors = PluginRegistry.instance.getFingerprintContributors();
        if (contributors.length > 0)
        {
            FingerprintContributionContext ctx;
            ctx.workspaceDir = workspaceDir;
            ctx.upstreamArtifactHashes = relevantFingerprints;
            ctx.upstreamFingerprints = relevantFingerprints;

            auto app = appender!string();
            app.put(baseFp);

            foreach (contributor; contributors)
            {
                if (contributor.canContribute(task))
                {
                    app.put("\nSYS:");
                    app.put(contributor.systemName);
                    app.put("=");
                    app.put(contributor.contributeFingerprint(task, ctx));
                }
            }
            return sha256Hex(app.data);
        }

        return baseFp;
    }
}

unittest
{
    TaskNode task;
    task.id = "build";
    task.steps = [BuildStep("Build", "bash", null, "dub build --build=release")];
    task.environment = ["DUB_ARGS": "-q", "RELEASE_TAG": "v1.0.0"];

    string[string] artifacts1 = [
        "lint:reports/lint.json": "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0",
        "test:coverage.xml": "b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01"
    ];

    // Same hashes inserted in reverse order
    string[string] artifacts2 = [
        "test:coverage.xml": "b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01",
        "lint:reports/lint.json": "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0"
    ];

    string fp1 = computeNodeFingerprint(task, artifacts1);
    string fp2 = computeNodeFingerprint(task, artifacts2);

    // 1. Must be deterministic regardless of associative array iteration order
    assert(fp1 == fp2, "Fingerprints must be identical across insertion order");
    assert(fp1.length == 64, "Fingerprint must be 64-char SHA256 hex string");

    // 2. Invalidation when build step script changes
    TaskNode taskModScript = task;
    taskModScript.steps = [BuildStep("Build", "bash", null, "dub build --build=debug")];
    string fpModScript = computeNodeFingerprint(taskModScript, artifacts1);
    assert(fpModScript != fp1, "Fingerprint must change when build step script changes");

    // 3. Invalidation when upstream artifact changes
    string[string] artifactsMod = artifacts1.dup;
    artifactsMod["lint:reports/lint.json"] = "2222222222222222222222222222222222222222222222222222222222222222";
    string fpModArtifacts = computeNodeFingerprint(task, artifactsMod);
    assert(fpModArtifacts != fp1, "Fingerprint must change when upstream artifact changes");

    // 4. Invalidation when task environment configuration changes
    TaskNode taskModEnv = task;
    taskModEnv.environment["DUB_ARGS"] = "-v";
    string fpModEnv = computeNodeFingerprint(taskModEnv, artifacts1);
    assert(fpModEnv != fp1, "Fingerprint must change when task environment configuration changes");

    // 5. Invalidation when custom component is added or modified
    import std.json : JSONValue;
    TaskNode taskCustom = task;
    taskCustom.setCustomComponent("s3_source", JSONValue(["bucket": JSONValue("artifacts-bucket"), "key": JSONValue("item.zip")]));
    string fpCustom = computeNodeFingerprint(taskCustom, artifacts1);
    assert(fpCustom != fp1, "Fingerprint must change when custom component is added");

    // 6. Invalidation when build steps are added or modified
    TaskNode taskSteps = task;
    taskSteps.steps = [
        BuildStep("Clone", "clone_repository", ["repository": "https://github.com/example/repo.git"]),
        BuildStep("Build", "bash", null, "dub build")
    ];
    string fpSteps = computeNodeFingerprint(taskSteps, artifacts1);
    assert(fpSteps != fp1, "Fingerprint must change when build steps are added");

    TaskNode taskStepsMod = taskSteps;
    taskStepsMod.steps = [
        BuildStep("Clone", "clone_repository", ["repository": "https://github.com/example/repo.git"]),
        BuildStep("Build", "bash", null, "dub test")
    ];
    string fpStepsMod = computeNodeFingerprint(taskStepsMod, artifacts1);
    assert(fpStepsMod != fpSteps, "Fingerprint must change when build step script changes");

    // 7. Invalidation when upstream artifact declaration changes (destination or artifact_id)
    TaskNode taskUpstreamArt = task;
    taskUpstreamArt.inputs.upstreamArtifacts = [UpstreamArtifactRef("lint", "reports", "dest/lint")];
    string fpUpstreamArt = computeNodeFingerprint(taskUpstreamArt, artifacts1);
    assert(fpUpstreamArt != fp1, "Fingerprint must change when upstream artifact declaration changes");

    TaskNode taskUpstreamArtMod = taskUpstreamArt;
    taskUpstreamArtMod.inputs.upstreamArtifacts = [UpstreamArtifactRef("lint", "reports", "dest/lint_other")];
    string fpUpstreamArtMod = computeNodeFingerprint(taskUpstreamArtMod, artifacts1);
    assert(fpUpstreamArtMod != fpUpstreamArt, "Fingerprint must change when upstream artifact destination changes");

    // 8. Invalidation when declared output artifacts change
    TaskNode taskOutputs = task;
    taskOutputs.outputs.artifacts = [OutputArtifactDecl("binaries", "out/*")];
    string fpOutputs = computeNodeFingerprint(taskOutputs, artifacts1);
    assert(fpOutputs != fp1, "Fingerprint must change when declared output artifacts are added");

    TaskNode taskOutputsMod = taskOutputs;
    taskOutputsMod.outputs.artifacts = [OutputArtifactDecl("binaries", "dist/*")];
    string fpOutputsMod = computeNodeFingerprint(taskOutputsMod, artifacts1);
    assert(fpOutputsMod != fpOutputs, "Fingerprint must change when declared output artifact pattern changes");

    // 9. Invalidation when input parameters change
    TaskNode taskParams = task;
    taskParams.inputs.parameters = ["target": "x86_64"];
    string fpParams = computeNodeFingerprint(taskParams, artifacts1);
    assert(fpParams != fp1, "Fingerprint must change when input parameters change");

    // 10. System contribution
    class CustomFingerprintSystem : FingerprintContributionSystem
    {
        @property string systemName() const { return "custom-hash-system"; }
        bool canContribute(in TaskNode t) const { return t.id == "build"; }
        string contributeFingerprint(in TaskNode t, in FingerprintContributionContext ctx) const
        {
            return "system_hash_12345";
        }
    }

    auto sys = new CustomFingerprintSystem();
    PluginRegistry.instance.registerFingerprintContributor(sys);
    string fpWithSys = Fingerprinter.computeNodeFingerprint(task, ".", artifacts1);
    PluginRegistry.instance.shutdownAll();
    string fpWithoutSys = Fingerprinter.computeNodeFingerprint(task, ".", artifacts1);
    assert(fpWithSys != fpWithoutSys);
}
