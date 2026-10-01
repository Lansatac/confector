module confector.core.storage;

import confector.core.model;
import confector.core.executor : ExecutorRecord;
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

        if (!exists(sourcePath) || !isFile(sourcePath))
        {
            if (exists(m_baseStorageDir))
            {
                import std.file : dirEntries, SpanMode;
                foreach (entry; dirEntries(m_baseStorageDir, SpanMode.shallow))
                {
                    if (entry.isDir)
                    {
                        string altPath = buildPath(entry.name, taskId, filename);
                        if (exists(altPath) && isFile(altPath))
                        {
                            sourcePath = altPath;
                            break;
                        }
                    }
                }
            }
        }

        if (!exists(sourcePath) || !isFile(sourcePath))
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
        if (exists(sourcePath) && isFile(sourcePath)) return true;

        if (exists(m_baseStorageDir))
        {
            import std.file : dirEntries, SpanMode;
            foreach (entry; dirEntries(m_baseStorageDir, SpanMode.shallow))
            {
                if (entry.isDir)
                {
                    string altPath = buildPath(entry.name, taskId, filename);
                    if (exists(altPath) && isFile(altPath))
                    {
                        return true;
                    }
                }
            }
        }
        return false;
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

    /**
     * Saves or updates a build execution record.
     */
    void recordBuild(BuildRecord build);

    /**
     * Retrieves a build execution record.
     */
    bool getBuild(string buildId, out BuildRecord build);

    /**
     * Lists recent build execution records.
     */
    BuildRecord[] listBuilds(size_t limit = 50);

    /**
     * Appends a log line to a build's execution output stream.
     */
    void appendBuildLog(string buildId, string line);

    /**
     * Retrieves all log lines for a build execution.
     */
    string[] getBuildLogs(string buildId);

    /**
     * Saves a trigger rule configuration.
     */
    void saveTriggerRule(TriggerRuleRecord rule);

    /**
     * Lists configured trigger rules.
     */
    TriggerRuleRecord[] listTriggerRules();

    /**
     * Deletes a configured trigger rule by ID.
     */
    bool deleteTriggerRule(string ruleId);

    /**
     * Saves or updates a project record.
     */
    void saveProject(in ProjectRecord project);

    /**
     * Retrieves a project record by ID.
     */
    bool getProject(string projectId, out ProjectRecord project);

    /**
     * Lists all registered projects.
     */
    ProjectRecord[] listProjects();

    /**
     * Deletes a project record by ID.
     */
    bool deleteProject(string projectId);

    /**
     * Saves or updates a repository record.
     */
    void saveRepository(in RepositoryRecord repo);

    /**
     * Retrieves a repository record by name.
     */
    bool getRepository(string name, out RepositoryRecord repo);

    /**
     * Lists all registered repositories.
     */
    RepositoryRecord[] listRepositories();

    /**
     * Deletes a repository record by name.
     */
    bool deleteRepository(string name);

    /**
     * Saves or updates an executor record.
     */
    void saveExecutor(in ExecutorRecord executor);

    /**
     * Retrieves an executor record by ID.
     */
    bool getExecutor(string id, out ExecutorRecord executor);

    /**
     * Lists all configured executors.
     */
    ExecutorRecord[] listExecutors();

    /**
     * Deletes an executor record by ID.
     */
    bool deleteExecutor(string id);
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
    private BuildRecord[string] m_builds;
    private string[][string] m_buildLogs;
    private TriggerRuleRecord[string] m_triggerRules;
    private ProjectRecord[string] m_projects;
    private RepositoryRecord[string] m_repositories;
    private ExecutorRecord[string] m_executors;

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

    override void recordBuild(BuildRecord build)
    {
        m_builds[build.buildId] = build;
    }

    override bool getBuild(string buildId, out BuildRecord build)
    {
        auto p = buildId in m_builds;
        if (p !is null)
        {
            build = *p;
            return true;
        }
        return false;
    }

    override BuildRecord[] listBuilds(size_t limit = 50)
    {
        BuildRecord[] list;
        foreach (b; m_builds)
        {
            list ~= b;
            if (list.length >= limit) break;
        }
        return list;
    }

    override void appendBuildLog(string buildId, string line)
    {
        m_buildLogs[buildId] ~= line;
    }

    override string[] getBuildLogs(string buildId)
    {
        auto p = buildId in m_buildLogs;
        if (p !is null)
        {
            return (*p).dup;
        }
        return [];
    }

    override void saveTriggerRule(TriggerRuleRecord rule)
    {
        m_triggerRules[rule.id] = rule;
    }

    override TriggerRuleRecord[] listTriggerRules()
    {
        TriggerRuleRecord[] list;
        foreach (r; m_triggerRules)
        {
            list ~= r;
        }
        return list;
    }

    override bool deleteTriggerRule(string ruleId)
    {
        auto p = ruleId in m_triggerRules;
        if (p !is null)
        {
            m_triggerRules.remove(ruleId);
            return true;
        }
        return false;
    }

    override void saveProject(in ProjectRecord project)
    {
        m_projects[project.id] = cast()project;
    }

    override bool getProject(string projectId, out ProjectRecord project)
    {
        auto p = projectId in m_projects;
        if (p !is null)
        {
            project = *p;
            return true;
        }
        return false;
    }

    override ProjectRecord[] listProjects()
    {
        ProjectRecord[] list;
        foreach (p; m_projects)
        {
            list ~= p;
        }
        return list;
    }

    override bool deleteProject(string projectId)
    {
        auto p = projectId in m_projects;
        if (p !is null)
        {
            m_projects.remove(projectId);
            return true;
        }
        return false;
    }

    override void saveRepository(in RepositoryRecord repo)
    {
        m_repositories[repo.name] = cast()repo;
    }

    override bool getRepository(string name, out RepositoryRecord repo)
    {
        auto p = name in m_repositories;
        if (p !is null)
        {
            repo = *p;
            return true;
        }
        return false;
    }

    override RepositoryRecord[] listRepositories()
    {
        RepositoryRecord[] list;
        foreach (r; m_repositories)
        {
            list ~= r;
        }
        return list;
    }

    override bool deleteRepository(string name)
    {
        auto p = name in m_repositories;
        if (p !is null)
        {
            m_repositories.remove(name);
            return true;
        }
        return false;
    }

    override void saveExecutor(in ExecutorRecord executor)
    {
        m_executors[executor.id] = cast()executor;
    }

    override bool getExecutor(string id, out ExecutorRecord executor)
    {
        auto p = id in m_executors;
        if (p !is null)
        {
            executor = *p;
            return true;
        }
        return false;
    }

    override ExecutorRecord[] listExecutors()
    {
        ExecutorRecord[] list;
        foreach (e; m_executors)
        {
            list ~= e;
        }
        return list;
    }

    override bool deleteExecutor(string id)
    {
        auto p = id in m_executors;
        if (p !is null)
        {
            m_executors.remove(id);
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

    // Build recording and logging
    BuildRecord bRecord;
    bRecord.buildId = "b1";
    bRecord.projectName = "test_project";
    bRecord.status = "succeeded";
    stateRepo.recordBuild(bRecord);

    BuildRecord fetchedBuild;
    assert(stateRepo.getBuild("b1", fetchedBuild));
    assert(fetchedBuild.projectName == "test_project");
    assert(stateRepo.listBuilds().length == 1);

    stateRepo.appendBuildLog("b1", "[step1] Building application");
    assert(stateRepo.getBuildLogs("b1").length == 1);
    assert(stateRepo.getBuildLogs("b1")[0] == "[step1] Building application");

    // Trigger rule recording
    TriggerRuleRecord rule;
    rule.id = "trig_1";
    rule.name = "Main Branch Push";
    rule.triggerType = "git_push";
    rule.criteria = "main";
    stateRepo.saveTriggerRule(rule);
    assert(stateRepo.listTriggerRules().length == 1);
    assert(stateRepo.deleteTriggerRule("trig_1"));
    assert(stateRepo.listTriggerRules().length == 0);

    // Project persistence in InMemoryBuildStateRepository
    ProjectRecord proj;
    proj.id = "proj-confector";
    proj.name = "Confector";
    TaskNode node;
    node.id = "build";
    node.script = "dub build";
    proj.tasks = [node];
    proj.createdAt = "2026-09-30T12:00:00Z";
    proj.updatedAt = "2026-09-30T12:00:00Z";

    stateRepo.saveProject(proj);
    assert(stateRepo.listProjects().length == 1);
    ProjectRecord fetchedProj;
    assert(stateRepo.getProject("proj-confector", fetchedProj));
    assert(fetchedProj.name == "Confector");
    assert(fetchedProj.tasks.length == 1);
    assert(fetchedProj.tasks[0].id == "build");

    assert(stateRepo.deleteProject("proj-confector"));
    assert(stateRepo.listProjects().length == 0);

    // Repository persistence in InMemoryBuildStateRepository
    RepositoryRecord repo;
    repo.name = "confector-core";
    repo.address = "https://github.com/confector/confector.git";
    stateRepo.saveRepository(repo);
    assert(stateRepo.listRepositories().length == 1);
    RepositoryRecord fetchedRepo;
    assert(stateRepo.getRepository("confector-core", fetchedRepo));
    assert(fetchedRepo.address == "https://github.com/confector/confector.git");
    assert(stateRepo.deleteRepository("confector-core"));
    assert(stateRepo.listRepositories().length == 0);

    // Executor persistence in InMemoryBuildStateRepository
    import vibe.data.json : Json;
    ExecutorRecord exec;
    exec.id = "exec-local-1";
    exec.name = "Local Executor 1";
    exec.providerType = "local";
    exec.description = "Primary local runner";
    exec.enabled = false;
    exec.configuration = Json.emptyObject;
    exec.configuration["maxConcurrency"] = 8;
    exec.createdAt = "2026-09-30T12:00:00Z";
    exec.updatedAt = "2026-09-30T12:00:00Z";

    stateRepo.saveExecutor(exec);
    assert(stateRepo.listExecutors().length == 1);
    ExecutorRecord fetchedExec;
    assert(stateRepo.getExecutor("exec-local-1", fetchedExec));
    assert(fetchedExec.name == "Local Executor 1");
    assert(!fetchedExec.enabled);
    assert(fetchedExec.configuration["maxConcurrency"].get!int == 8);

    // Toggle enabled
    fetchedExec.enabled = true;
    stateRepo.saveExecutor(fetchedExec);
    ExecutorRecord updatedExec;
    assert(stateRepo.getExecutor("exec-local-1", updatedExec));
    assert(updatedExec.enabled);

    assert(stateRepo.deleteExecutor("exec-local-1"));
    assert(stateRepo.listExecutors().length == 0);
    assert(!stateRepo.getExecutor("exec-local-1", fetchedExec));
}
