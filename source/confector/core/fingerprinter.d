module confector.core.fingerprinter;

import confector.core.model;
import confector.core.system : FingerprintContributionContext, FingerprintContributionSystem;
import confector.core.plugin : PluginRegistry;
import std.algorithm : sort;
import std.array : appender;
import std.digest.sha : SHA256, toHexString, LetterCase, digest;
import std.file : exists, isFile, read;
import std.format : format;
import vibe.data.json : serializeToJsonString;

/**
 * Computes the SHA256 hex string of a byte slice or string.
 */
string sha256Hex(in void[] data) pure nothrow @safe
{
    ubyte[32] hash = digest!SHA256(data);
    return toHexString!(LetterCase.lower)(hash).idup;
}

/**
 * Computes the SHA256 hash of a file on disk.
 */
string computeFileSha256(string filePath) @trusted
{
    if (!exists(filePath) || !isFile(filePath))
    {
        throw new FingerprintException(format("File not found or is not a regular file: %s", filePath));
    }

    try
    {
        auto content = read(filePath);
        return sha256Hex(content);
    }
    catch (Exception e)
    {
        throw new FingerprintException(format("Failed to read file for hashing '%s': %s", filePath, e.msg));
    }
}

/**
 * Computes deterministic SHA256 digest of upstream artifact hashes.
 */
string computeArtifactHashesDigest(in string[string] artifactHashes) pure nothrow @trusted
{
    if (artifactHashes.length == 0) return sha256Hex("");

    string[] keys;
    foreach (k; artifactHashes.byKey)
    {
        keys ~= k;
    }
    keys.sort();

    auto app = appender!string();
    foreach (k; keys)
    {
        app.put(k);
        app.put(":");
        app.put(artifactHashes[k]);
        app.put("\n");
    }
    return sha256Hex(app.data);
}

/**
 * Computes deterministic SHA256 digest of resolved environment variables.
 */
string computeEnvDigest(in string[string] resolvedEnv) pure nothrow @trusted
{
    if (resolvedEnv.length == 0) return sha256Hex("");

    string[] keys;
    foreach (k; resolvedEnv.byKey)
    {
        keys ~= k;
    }
    keys.sort();

    auto app = appender!string();
    foreach (k; keys)
    {
        app.put(k);
        app.put("=");
        app.put(resolvedEnv[k]);
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
        try
        {
            app.put(serializeToJsonString(task.components[k]));
        }
        catch (Exception e)
        {
            app.put(task.components[k].toString());
        }
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
    app.put(task.workingDirectory);
    app.put("|");
    app.put(computeEnvDigest(task.environment));
    return sha256Hex(app.data);
}

/**
 * Computes the full Node Fingerprint according to the specification:
 * NodeFingerprint = SHA256(
 *     TaskScriptContent
 *   + SortAndHash(UpstreamArtifactHashes)
 *   + TaskConfigurationHash
 *   + CustomComponentsHash
 * )
 */
string computeNodeFingerprint(
    in TaskNode task,
    in string[string] upstreamArtifactHashes
) @trusted
{
    auto app = appender!string();
    app.put("SCRIPT:");
    app.put(task.script);
    app.put("\nARTIFACTS:");
    app.put(computeArtifactHashesDigest(upstreamArtifactHashes));
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
     * Resolves task configuration and upstream artifact hashes to compute the node fingerprint.
     */
    static string computeNodeFingerprint(
        in TaskNode task,
        string workspaceDir,
        in string[string] upstreamArtifactHashes = null
    ) @trusted
    {
        string[string] relevantArtifacts;
        if (upstreamArtifactHashes !is null)
        {
            if (task.inputs.upstreamArtifacts.length > 0)
            {
                foreach (refArt; task.inputs.upstreamArtifacts)
                {
                    string key1 = format("%s:%s", refArt.taskId, refArt.name);
                    string key2 = refArt.name;
                    auto p1 = key1 in upstreamArtifactHashes;
                    auto p2 = key2 in upstreamArtifactHashes;
                    if (p1 !is null)
                    {
                        relevantArtifacts[key1] = *p1;
                    }
                    else if (p2 !is null)
                    {
                        relevantArtifacts[key1] = *p2;
                    }
                }
            }
            else
            {
                relevantArtifacts = cast(string[string])upstreamArtifactHashes;
            }
        }

        string baseFp = .computeNodeFingerprint(task, relevantArtifacts);

        // Incorporate registered FingerprintContributionSystem outputs if present
        auto contributors = PluginRegistry.instance.getFingerprintContributors();
        if (contributors.length > 0)
        {
            FingerprintContributionContext ctx;
            ctx.workspaceDir = workspaceDir;
            ctx.upstreamArtifactHashes = relevantArtifacts;

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
    task.script = "dub build --build=release";
    task.workingDirectory = "/workspace";
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

    // 2. Invalidation when script changes
    TaskNode taskModScript = task;
    taskModScript.script = "dub build --build=debug";
    string fpModScript = computeNodeFingerprint(taskModScript, artifacts1);
    assert(fpModScript != fp1, "Fingerprint must change when script changes");

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
    import vibe.data.json : Json;
    TaskNode taskCustom = task;
    taskCustom.setCustomComponent("s3_source", Json(["bucket": Json("artifacts-bucket"), "key": Json("item.zip")]));
    string fpCustom = computeNodeFingerprint(taskCustom, artifacts1);
    assert(fpCustom != fp1, "Fingerprint must change when custom component is added");

    // 6. System contribution
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
