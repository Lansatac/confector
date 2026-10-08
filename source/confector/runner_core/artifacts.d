module confector.runner_core.artifacts;

import confector.core.model;
import confector.core.storage;
import confector.core.zip_packager;

import std.file : exists, mkdirRecurse, isDir;
import std.path : buildPath, dirName;
import std.format : format;
import std.array : Appender;
import std.datetime.systime : Clock;
import std.digest.sha : SHA256;
import std.digest : toHexString, LetterCase;
import confector.runner_core.logging : logInfo, logError, logWarn, logDebug;

/**
 * Utility for staging upstream artifacts and packaging output artifacts.
 */
final class ArtifactStager
{
    /**
     * Computes the SHA-256 hex digest of raw byte data.
     */
    static string computeSha256(const(ubyte)[] data) pure nothrow @safe
    {
        SHA256 sha;
        sha.start();
        sha.put(data);
        auto digest = sha.finish();
        return toHexString!(LetterCase.lower)(digest).idup;
    }

    /**
     * Retrieves an upstream artifact archive from storage and extracts it into destinationDir.
     * Optionally validates cryptographic checksum against expectedSha256.
     */
    static bool stageUpstreamArtifact(
        ArtifactStorage storage,
        string taskFingerprint,
        string artifactId,
        string destinationDir,
        string expectedSha256 = null
    )
    {
        if (storage is null) return false;
        if (!storage.artifactExists(taskFingerprint, artifactId)) return false;

        if (!exists(destinationDir))
        {
            mkdirRecurse(destinationDir);
        }

        try
        {
            Appender!(ubyte[]) buffer;
            storage.retrieveArtifactStream(taskFingerprint, artifactId, (const(ubyte)[] chunk) {
                buffer.put(chunk);
            });

            ubyte[] data = buffer.data;
            if (data.length == 0) return false;

            // Cryptographic checksum verification
            if (expectedSha256.length > 0)
            {
                string actualSha = computeSha256(data);
                if (actualSha != expectedSha256)
                {
                    logError("[ArtifactStager] Checksum mismatch for artifact '%s' (fp: %s): expected %s, got %s",
                        artifactId, taskFingerprint, expectedSha256, actualSha);
                    return false;
                }
            }

            ZipPackager.unpack(data, destinationDir);
            return true;
        }
        catch (Exception e)
        {
            logError("[ArtifactStager] Failed to unpack artifact '%s' (fp: %s) into '%s': %s",
                artifactId, taskFingerprint, destinationDir, e.msg);
            return false;
        }
    }

    /**
     * Packages declared output files from workspace and stores them in ArtifactStorage under taskFingerprint.
     * Computes and records sha256 and sizeBytes in returned ArtifactMetadata.
     */
    static ArtifactMetadata packOutputArtifact(
        ArtifactStorage storage,
        string taskFingerprint,
        string buildId,
        string taskId,
        string workspaceDir,
        in OutputArtifactDecl decl,
        string storageBaseDir = ""
    )
    {
        string artId = decl.effectiveId;
        string artPath = decl.effectivePath;

        SHA256 sha;
        sha.start();
        ulong totalBytes = 0;

        if (storage !is null && taskFingerprint.length > 0 && taskFingerprint != "unknown")
        {
            storage.storeArtifactStream(taskFingerprint, artId, (void delegate(const(ubyte)[]) sink) {
                ZipPackager.pack(workspaceDir, artPath, (const(ubyte)[] chunk) {
                    if (chunk.length > 0)
                    {
                        sha.put(chunk);
                        totalBytes += chunk.length;
                        sink(chunk);
                    }
                });
            });
        }
        else
        {
            ZipPackager.pack(workspaceDir, artPath, (const(ubyte)[] chunk) {
                if (chunk.length > 0)
                {
                    sha.put(chunk);
                    totalBytes += chunk.length;
                }
            });
        }

        auto digest = sha.finish();
        string sha256Hex = toHexString!(LetterCase.lower)(digest).idup;

        ArtifactMetadata meta;
        meta.artifactId = artId;
        meta.taskFingerprint = taskFingerprint;
        meta.buildId = buildId;
        meta.taskId = taskId;
        meta.filePath = artPath;
        meta.sha256 = sha256Hex;
        meta.sizeBytes = totalBytes;
        meta.storageBackend = "local";
        if (storageBaseDir.length > 0)
        {
            meta.storageUri = format("%s/%s/%s.zip", storageBaseDir, taskFingerprint, artId);
        }
        else
        {
            meta.storageUri = format("%s/%s.zip", taskFingerprint, artId);
        }
        meta.createdAt = Clock.currTime.toISOString();
        return meta;
    }
}

unittest
{
    import std.file : exists, rmdirRecurse, mkdirRecurse, write, readText;
    import confector.core.storage : InMemoryArtifactStorage;

    string testDir = "test_artifact_stager_suite";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    string wsDir = buildPath(testDir, "ws");
    string destDir = buildPath(testDir, "dest");
    mkdirRecurse(wsDir);
    mkdirRecurse(destDir);

    write(buildPath(wsDir, "out.txt"), "hello world artifact");

    auto storage = new InMemoryArtifactStorage();
    auto decl = OutputArtifactDecl("my_art", "out.txt");
    auto meta = ArtifactStager.packOutputArtifact(storage, "fp123", "build1", "task1", wsDir, decl);

    assert(meta.sha256.length == 64);
    assert(meta.sizeBytes > 0);
    assert(storage.artifactExists("fp123", "my_art"));

    // Stage with matching SHA256
    bool staged = ArtifactStager.stageUpstreamArtifact(storage, "fp123", "my_art", destDir, meta.sha256);
    assert(staged);
    assert(readText(buildPath(destDir, "out.txt")) == "hello world artifact");

    // Stage with mismatched SHA256 should fail
    string badDest = buildPath(testDir, "dest_bad");
    bool stagedBad = ArtifactStager.stageUpstreamArtifact(storage, "fp123", "my_art", badDest, "0000000000000000000000000000000000000000000000000000000000000000");
    assert(!stagedBad);
}
