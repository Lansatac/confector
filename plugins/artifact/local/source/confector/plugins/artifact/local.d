module confector.plugins.artifact.local;

import std.format;
import std.file : exists, isDir, isFile, mkdirRecurse, remove, rmdir, rename, dirEntries, SpanMode;
import std.path : buildPath;
import std.process : thisProcessID;
import std.random : unpredictableSeed;
import std.stdio : File;

import confector.plugin_api.model : ArtifactNotFoundException, ArtifactStorage, InvalidArtifactKeyException;

/**
 * Artifact storage on the local filesystem. Stores content-addressed artifacts as zip archives
 * under a base directory, one subdirectory per task fingerprint.
 */
class LocalArtifactStorage : ArtifactStorage
{
    private string m_baseStorageDir;

    /**
     * Stores artifacts under `baseDirectory`, creating it if it does not exist. Throws if the
     * directory is empty or cannot be created.
     */
    this(string baseDirectory)
    {
        if (baseDirectory.length == 0)
            throw new Exception("Local artifact storage needs a base directory");
        if (!exists(baseDirectory))
        {
            try
            {
                mkdirRecurse(baseDirectory);
            }
            catch (Exception e)
            {
                throw new Exception(format("Local artifact storage could not create its base directory '%s': %s", baseDirectory, e.msg));
            }
        }
        else if (!isDir(baseDirectory))
        {
            throw new Exception(format("Local artifact storage base directory '%s' is not a directory", baseDirectory));
        }
        m_baseStorageDir = baseDirectory;
    }

    @property string backendType() const pure nothrow @safe
    {
        return "local";
    }

    private static void validateStorageKey(string key, string paramName)
    {
        if (key.length == 0)
        {
            throw new InvalidArtifactKeyException(format("Invalid %s: key cannot be empty", paramName));
        }
        import std.algorithm.searching : canFind;
        if (key.canFind("..") || key.canFind('/') || key.canFind('\\') || key.canFind(':') || key.canFind('\0'))
        {
            throw new InvalidArtifactKeyException(format("Invalid %s '%s': contains illegal path characters or traversal sequence", paramName, key));
        }
    }

    /**
     * Stores an artifact by streaming bytes from writer into a local zip file.
     * Uses atomic write via temp file + rename to prevent corruption.
     */
    void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
    {
        if (writer is null)
        {
            throw new Exception("Writer delegate cannot be null");
        }
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string destDir = buildPath(m_baseStorageDir, taskFingerprint);
        if (!exists(destDir))
        {
            mkdirRecurse(destDir);
        }

        string destPath = buildPath(destDir, artifactId ~ ".zip");

        string tempPath = format("%s.tmp.%d.%d", destPath, thisProcessID, unpredictableSeed());

        {
            auto f = File(tempPath, "wb");
            scope(failure)
            {
                if (exists(tempPath))
                {
                    try { remove(tempPath); } catch (Exception) {}
                }
            }

            writer((const(ubyte)[] chunk) {
                if (chunk.length > 0)
                {
                    f.rawWrite(chunk);
                }
            });
            f.flush();
            f.close();
        }

        if (exists(destPath))
        {
            remove(destPath);
        }
        rename(tempPath, destPath);
    }

    /**
     * Retrieves an artifact from local storage and streams chunks into sink.
     */
    void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
        {
            throw new Exception("Sink delegate cannot be null");
        }
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string sourcePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        if (!exists(sourcePath) || !isFile(sourcePath))
        {
            throw new ArtifactNotFoundException(format("Artifact not found in storage: fingerprint='%s', artifactId='%s' (looked at %s)", taskFingerprint, artifactId, sourcePath));
        }

        auto f = File(sourcePath, "rb");
        ubyte[64 * 1024] buffer;
        while (!f.eof)
        {
            ubyte[] chunk = f.rawRead(buffer[]);
            if (chunk.length > 0)
            {
                sink(chunk);
            }
        }
    }

    /**
     * Checks if an artifact exists in local storage.
     */
    bool artifactExists(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0) return false;
        try
        {
            validateStorageKey(taskFingerprint, "taskFingerprint");
            validateStorageKey(artifactId, "artifactId");
        }
        catch (Exception)
        {
            return false;
        }

        string filePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        return exists(filePath) && isFile(filePath);
    }

    /**
     * Deletes an artifact from local storage, cleaning up empty fingerprint directories.
     */
    void deleteArtifact(string taskFingerprint, string artifactId)
    {
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string filePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        if (exists(filePath))
        {
            remove(filePath);

            string parentDir = buildPath(m_baseStorageDir, taskFingerprint);
            try
            {
                if (exists(parentDir))
                {
                    bool empty = true;
                    foreach (entry; dirEntries(parentDir, SpanMode.shallow))
                    {
                        empty = false;
                        break;
                    }
                    if (empty)
                    {
                        rmdir(parentDir);
                    }
                }
            }
            catch (Exception) {}
        }
    }

    /**
     * Local filesystem storage does not support presigned URLs.
     * Returns null so callers fall back to server-proxied upload.
     */
    override string presignUpload(string taskFingerprint, string artifactId)
    {
        return null;
    }

    /**
     * Local filesystem storage does not support presigned URLs.
     * Returns null so callers fall back to server-proxied download.
     */
    override string presignDownload(string taskFingerprint, string artifactId)
    {
        return null;
    }
}

unittest
{
    import std.array : appender;
    import std.exception : assertThrown;
    import std.file : rmdirRecurse, tempDir, write;

    string base = buildPath(tempDir, format("confector_local_artifact_test_%d", thisProcessID));
    if (exists(base)) rmdirRecurse(base);
    scope(exit) if (exists(base)) rmdirRecurse(base);

    // A base directory is required; a missing one is created, a file in its place is refused
    assertThrown!Exception(new LocalArtifactStorage(""));
    auto storage = new LocalArtifactStorage(buildPath(base, "store"));
    assert(isDir(buildPath(base, "store")));
    write(buildPath(base, "file"), "x");
    assertThrown!Exception(new LocalArtifactStorage(buildPath(base, "file")));

    // Store, read back, check and delete one artifact
    assert(!storage.artifactExists("fp1", "out"));
    storage.storeArtifactStream("fp1", "out", (void delegate(const(ubyte)[]) sink) {
        sink(cast(const(ubyte)[]) "hello ");
        sink(cast(const(ubyte)[]) "world");
    });
    assert(storage.artifactExists("fp1", "out"));
    auto read = appender!(ubyte[]);
    storage.retrieveArtifactStream("fp1", "out", (const(ubyte)[] chunk) { read.put(chunk); });
    assert(cast(string) read.data == "hello world");
    storage.deleteArtifact("fp1", "out");
    assert(!storage.artifactExists("fp1", "out"));
    assert(!exists(buildPath(base, "store", "fp1")), "An emptied fingerprint directory is removed");
    assertThrown!ArtifactNotFoundException(storage.retrieveArtifactStream("fp1", "out", (const(ubyte)[] chunk) {}));

    // Keys cannot escape the base directory
    assertThrown!InvalidArtifactKeyException(storage.storeArtifactStream("..", "out", (void delegate(const(ubyte)[]) sink) {}));
    assertThrown!InvalidArtifactKeyException(storage.retrieveArtifactStream("fp1", "a:b", (const(ubyte)[] chunk) {}));
    assert(storage.presignUpload("fp1", "out") is null && storage.presignDownload("fp1", "out") is null);
}
