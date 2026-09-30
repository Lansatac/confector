module confector.core.storage;

import confector.core.model;
import std.file : exists, isFile, isDir, mkdirRecurse, read, write, copy;
import std.path : buildPath, dirName, baseName;
import std.format : format;
import std.datetime.systime : Clock;

/**
 * Interface for artifact storage backends (e.g. Local filesystem, S3-compatible object storage).
 */
interface ArtifactStorage
{
    /**
     * Stores an artifact produced by a task build.
     */
    ArtifactMetadata storeArtifact(string buildId, string taskId, string localFilePath, string artifactType = "file");

    /**
     * Retrieves an artifact from storage and writes it to a target local path.
     */
    void retrieveArtifact(string buildId, string taskId, string artifactPath, string targetLocalPath);

    /**
     * Checks if an artifact exists in storage.
     */
    bool artifactExists(string buildId, string taskId, string artifactPath);

    /**
     * Gets metadata for a stored artifact if present.
     */
    bool getArtifactMetadata(string buildId, string taskId, string artifactPath, out ArtifactMetadata metadata);
}

/**
 * Local filesystem implementation of ArtifactStorage.
 */
class LocalArtifactStorage : ArtifactStorage
{
    private string m_baseStorageDir;

    this(string baseStorageDir = ".confector/artifacts")
    {
        m_baseStorageDir = baseStorageDir;
        if (!exists(m_baseStorageDir))
        {
            mkdirRecurse(m_baseStorageDir);
        }
    }

    override ArtifactMetadata storeArtifact(string buildId, string taskId, string localFilePath, string artifactType = "file")
    {
        import confector.core.fingerprinter : computeFileSha256;
        import std.file : getSize;

        if (!exists(localFilePath) || !isFile(localFilePath))
        {
            throw new Exception(format("Cannot store artifact; local file does not exist: %s", localFilePath));
        }

        string sha256 = computeFileSha256(localFilePath);
        ulong sizeBytes = getSize(localFilePath);
        string filename = baseName(localFilePath);

        string relativeStoragePath = buildPath(buildId, taskId, filename);
        string destPath = buildPath(m_baseStorageDir, relativeStoragePath);

        string destDir = dirName(destPath);
        if (!exists(destDir))
        {
            mkdirRecurse(destDir);
        }

        copy(localFilePath, destPath);

        ArtifactMetadata meta;
        meta.artifactId = format("%s_%s_%s", buildId, taskId, filename);
        meta.buildId = buildId;
        meta.taskId = taskId;
        meta.filePath = localFilePath;
        meta.sha256 = sha256;
        meta.sizeBytes = sizeBytes;
        meta.storageBackend = "local";
        meta.storageUri = destPath;
        meta.createdAt = Clock.currTime.toISOString();

        return meta;
    }

    override void retrieveArtifact(string buildId, string taskId, string artifactPath, string targetLocalPath)
    {
        string filename = baseName(artifactPath);
        string sourcePath = buildPath(m_baseStorageDir, buildId, taskId, filename);

        if (!exists(sourcePath))
        {
            throw new Exception(format("Artifact not found in storage: %s (looked at %s)", artifactPath, sourcePath));
        }

        string targetDir = dirName(targetLocalPath);
        if (targetDir.length > 0 && !exists(targetDir))
        {
            mkdirRecurse(targetDir);
        }

        copy(sourcePath, targetLocalPath);
    }

    override bool artifactExists(string buildId, string taskId, string artifactPath)
    {
        string filename = baseName(artifactPath);
        string sourcePath = buildPath(m_baseStorageDir, buildId, taskId, filename);
        return exists(sourcePath) && isFile(sourcePath);
    }

    override bool getArtifactMetadata(string buildId, string taskId, string artifactPath, out ArtifactMetadata metadata)
    {
        import confector.core.fingerprinter : computeFileSha256;
        import std.file : getSize, timeLastModified;

        string filename = baseName(artifactPath);
        string sourcePath = buildPath(m_baseStorageDir, buildId, taskId, filename);

        if (!exists(sourcePath) || !isFile(sourcePath))
        {
            return false;
        }

        metadata.artifactId = format("%s_%s_%s", buildId, taskId, filename);
        metadata.buildId = buildId;
        metadata.taskId = taskId;
        metadata.filePath = artifactPath;
        metadata.sha256 = computeFileSha256(sourcePath);
        metadata.sizeBytes = getSize(sourcePath);
        metadata.storageBackend = "local";
        metadata.storageUri = sourcePath;
        metadata.createdAt = timeLastModified(sourcePath).toISOString();
        return true;
    }
}

/**
 * Interface for build and task state persistence (caching, status tracking, metadata).
 */
interface BuildStateRepository
{
    /**
     * Records or updates the status of a task execution.
     */
    void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null);

    /**
     * Retrieves the recorded status of a task.
     */
    bool getTaskStatus(string buildId, string taskId, out TaskStatus status);

    /**
     * Records a successful execution fingerprint for memoization.
     */
    void saveCachedFingerprint(string taskId, string fingerprint, ArtifactMetadata[] producedArtifacts);

    /**
     * Checks if a cached fingerprint is recorded and returns previously produced artifact metadata.
     */
    bool getCachedFingerprint(string taskId, string fingerprint, out ArtifactMetadata[] producedArtifacts);
}

/**
 * In-memory thread-safe implementation of BuildStateRepository.
 */
class InMemoryBuildStateRepository : BuildStateRepository
{
    private struct CacheRecord
    {
        string fingerprint;
        ArtifactMetadata[] artifacts;
    }

    private TaskStatus[string] m_taskStatuses;
    private CacheRecord[string] m_fingerprintCache;

    private static string statusKey(string buildId, string taskId) pure nothrow @safe
    {
        return buildId ~ ":" ~ taskId;
    }

    private static string cacheKey(string taskId, string fingerprint) pure nothrow @safe
    {
        return taskId ~ ":" ~ fingerprint;
    }

    override void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null)
    {
        m_taskStatuses[statusKey(buildId, taskId)] = status;
    }

    override bool getTaskStatus(string buildId, string taskId, out TaskStatus status)
    {
        auto p = statusKey(buildId, taskId) in m_taskStatuses;
        if (p !is null)
        {
            status = *p;
            return true;
        }
        return false;
    }

    override void saveCachedFingerprint(string taskId, string fingerprint, ArtifactMetadata[] producedArtifacts)
    {
        CacheRecord rec;
        rec.fingerprint = fingerprint;
        rec.artifacts = producedArtifacts;
        m_fingerprintCache[cacheKey(taskId, fingerprint)] = rec;
    }

    override bool getCachedFingerprint(string taskId, string fingerprint, out ArtifactMetadata[] producedArtifacts)
    {
        auto p = cacheKey(taskId, fingerprint) in m_fingerprintCache;
        if (p !is null)
        {
            producedArtifacts = p.artifacts;
            return true;
        }
        return false;
    }
}

unittest
{
    import std.file : rmdirRecurse;

    string testDir = "test_artifacts_storage";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto storage = new LocalArtifactStorage(testDir);
    auto stateRepo = new InMemoryBuildStateRepository();

    // Create a dummy file
    string sampleFile = buildPath(testDir, "output.txt");
    mkdirRecurse(testDir);
    write(sampleFile, "test artifact contents");

    auto meta = storage.storeArtifact("b1", "t1", sampleFile, "file");
    assert(meta.buildId == "b1");
    assert(meta.taskId == "t1");
    assert(meta.sha256.length > 0);
    assert(storage.artifactExists("b1", "t1", "output.txt"));

    string retrievedFile = buildPath(testDir, "retrieved.txt");
    storage.retrieveArtifact("b1", "t1", "output.txt", retrievedFile);
    assert(exists(retrievedFile));
    assert(read(retrievedFile) == "test artifact contents");

    stateRepo.saveCachedFingerprint("t1", "hash123", [meta]);
    ArtifactMetadata[] cachedMetas;
    assert(stateRepo.getCachedFingerprint("t1", "hash123", cachedMetas));
    assert(cachedMetas.length == 1);
    assert(cachedMetas[0].sha256 == meta.sha256);
}
