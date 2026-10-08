module confector.core.storage;

import confector.core.model;
import confector.core.executor : WorkerRecord;
import std.file : exists, isFile, isDir, mkdirRecurse, read, write, copy, remove, rename, rmdir, dirEntries, SpanMode;
import std.path : buildPath, dirName, baseName;
import std.format : format;
import std.datetime.systime : Clock;


/**
 * Local filesystem implementation of ArtifactStorage.
 */
class LocalArtifactStorage : ArtifactStorage
{
    private string m_baseStorageDir;

    this(string baseStorageDir)
    {
        if (baseStorageDir.length == 0)
        {
            throw new Exception("baseStorageDir must not be empty");
        }
        m_baseStorageDir = baseStorageDir;
        if (!exists(m_baseStorageDir))
        {
            mkdirRecurse(m_baseStorageDir);
        }
    }

    private static void validateStorageKey(string key, string paramName)
    {
        if (key.length == 0)
        {
            throw new Exception(format("Invalid %s: key cannot be empty", paramName));
        }
        import std.algorithm.searching : canFind;
        if (key.canFind("..") || key.canFind('/') || key.canFind('\\') || key.canFind(':') || key.canFind('\0'))
        {
            throw new Exception(format("Invalid %s '%s': contains illegal path characters or traversal sequence", paramName, key));
        }
    }

    override void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
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

        import std.process : thisProcessID;
        import std.random : unpredictableSeed;
        string tempPath = format("%s.tmp.%d.%d", destPath, thisProcessID, unpredictableSeed);

        import std.stdio : File;
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

        import std.file : rename, remove;
        if (exists(destPath))
        {
            remove(destPath);
        }
        rename(tempPath, destPath);
    }

    override void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
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
            throw new Exception(format("Artifact not found in storage: fingerprint='%s', artifactId='%s' (looked at %s)", taskFingerprint, artifactId, sourcePath));
        }

        import std.stdio : File;
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

    override bool artifactExists(string taskFingerprint, string artifactId)
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

    override void deleteArtifact(string taskFingerprint, string artifactId)
    {
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string filePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        if (exists(filePath))
        {
            import std.file : remove, rmdir, dirEntries, SpanMode;
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

    @property string backendType() const pure nothrow @safe
    {
        return "local";
    }
}

/**
 * Interface for build and task state persistence (caching, status tracking, metadata).
 */
interface BuildStateRepository
{
    /**
     * Records or updates the granular execution record of a task.
     */
    void recordTaskExecution(TaskExecutionRecord record);

    /**
     * Retrieves the granular execution record of a task.
     */
    bool getTaskExecution(string buildId, string taskId, out TaskExecutionRecord record);

    /**
     * Lists recent task executions across all builds with optional filtering.
     */
    TaskExecutionRecord[] listRecentTaskExecutions(size_t limit = 50, string statusFilter = null, string projectIdFilter = null);

    /**
     * Lists execution records for a specific task (optionally scoped to a project).
     */
    TaskExecutionRecord[] listTaskExecutionsForTask(string projectId, string taskId, size_t limit = 20);

    /**
     * Appends a log line to a task's isolated output stream.
     */
    void appendTaskLog(string buildId, string taskId, string line);

    /**
     * Retrieves all log lines for a specific task execution.
     */
    string[] getTaskLogs(string buildId, string taskId);

    /**
     * Retrieves all task execution records for a build.
     */
    TaskExecutionRecord[] getTaskExecutionsForBuild(string buildId);

    /**
     * Retrieves all recorded task statuses for a build.
     */
    TaskStatus[string] getTaskStatusesForBuild(string buildId);

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
    void saveExecutor(in WorkerRecord executor);

    /**
     * Retrieves an executor record by ID.
     */
    bool getExecutor(string id, out WorkerRecord executor);

    /**
     * Lists all configured executors.
     */
    WorkerRecord[] listExecutors();

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
    private TaskExecutionRecord[string] m_taskRecords;
    private CacheRecord[string] m_fingerprintCache;
    private BuildRecord[string] m_builds;
    private string[][string] m_buildLogs;
    private string[][string] m_taskLogs;
    private TriggerRuleRecord[string] m_triggerRules;
    private ProjectRecord[string] m_projects;
    private RepositoryRecord[string] m_repositories;
    private WorkerRecord[string] m_executors;

    private static string statusKey(string buildId, string taskId) pure nothrow @safe
    {
        return buildId ~ ":" ~ taskId;
    }

    private static string cacheKey(string taskId, string fingerprint) pure nothrow @safe
    {
        return taskId ~ ":" ~ fingerprint;
    }

    override void recordTaskExecution(TaskExecutionRecord record)
    {
        string key = statusKey(record.buildId, record.taskId);
        if (record.projectId.length == 0 || record.projectName.length == 0)
        {
            if (auto pb = record.buildId in m_builds)
            {
                if (record.projectId.length == 0) record.projectId = pb.projectId;
                if (record.projectName.length == 0) record.projectName = pb.projectName;
            }
        }
        m_taskRecords[key] = record;
        m_taskStatuses[key] = cast(TaskStatus)record.status;
        if (auto pb = record.buildId in m_builds)
        {
            pb.taskRecords[record.taskId] = record;
        }
    }

    override TaskExecutionRecord[] listRecentTaskExecutions(size_t limit = 50, string statusFilter = null, string projectIdFilter = null)
    {
        TaskExecutionRecord[] list;
        foreach (k, rec; m_taskRecords)
        {
            if (statusFilter.length > 0 && rec.status != statusFilter) continue;
            if (projectIdFilter.length > 0 && rec.projectId != projectIdFilter) continue;
            list ~= rec;
        }
        if (list.length > limit)
        {
            list = list[$ - limit .. $];
        }
        return list;
    }

    override TaskExecutionRecord[] listTaskExecutionsForTask(string projectId, string taskId, size_t limit = 20)
    {
        TaskExecutionRecord[] list;
        foreach (k, rec; m_taskRecords)
        {
            if (taskId.length > 0 && rec.taskId != taskId) continue;
            if (projectId.length > 0 && rec.projectId != projectId) continue;
            list ~= rec;
        }
        import std.algorithm.sorting : sort;
        sort!((a, b) => a.startedAt > b.startedAt)(list);
        if (list.length > limit)
        {
            list = list[0 .. limit];
        }
        return list;
    }

    override void appendTaskLog(string buildId, string taskId, string line)
    {
        string key = statusKey(buildId, taskId);
        m_taskLogs[key] ~= line;
    }

    override string[] getTaskLogs(string buildId, string taskId)
    {
        string key = statusKey(buildId, taskId);
        if (auto p = key in m_taskLogs)
        {
            return *p;
        }
        return null;
    }

    override bool getTaskExecution(string buildId, string taskId, out TaskExecutionRecord record)
    {
        auto p = statusKey(buildId, taskId) in m_taskRecords;
        if (p !is null)
        {
            record = *p;
            return true;
        }
        return false;
    }

    override TaskExecutionRecord[] getTaskExecutionsForBuild(string buildId)
    {
        TaskExecutionRecord[] list;
        foreach (k, rec; m_taskRecords)
        {
            if (rec.buildId == buildId)
            {
                list ~= rec;
            }
        }
        return list;
    }

    override TaskStatus[string] getTaskStatusesForBuild(string buildId)
    {
        TaskStatus[string] statuses;
        string prefix = buildId ~ ":";
        foreach (k, status; m_taskStatuses)
        {
            if (k.length > prefix.length && k[0 .. prefix.length] == prefix)
            {
                string taskId = k[prefix.length .. $];
                statuses[taskId] = status;
            }
        }
        return statuses;
    }

    override void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null)
    {
        string key = statusKey(buildId, taskId);
        m_taskStatuses[key] = status;
        if (auto p = key in m_taskRecords)
        {
            p.status = cast(string)status;
            if (errorMessage.length > 0)
            {
                p.errorMessage = errorMessage;
            }
            if (auto pb = buildId in m_builds)
            {
                pb.taskRecords[taskId] = *p;
            }
        }
        else
        {
            TaskExecutionRecord rec;
            rec.buildId = buildId;
            rec.taskId = taskId;
            rec.status = cast(string)status;
            rec.errorMessage = errorMessage;
            m_taskRecords[key] = rec;
            if (auto pb = buildId in m_builds)
            {
                pb.taskRecords[taskId] = rec;
            }
        }
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

    override void saveExecutor(in WorkerRecord executor)
    {
        m_executors[executor.id] = cast()executor;
    }

    override bool getExecutor(string id, out WorkerRecord executor)
    {
        auto p = id in m_executors;
        if (p !is null)
        {
            executor = *p;
            return true;
        }
        return false;
    }

    override WorkerRecord[] listExecutors()
    {
        WorkerRecord[] list;
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

    // Test stream-based content-addressed artifact storage
    string fingerprint = "fp123";
    string artifactId = "output.txt";
    string contents = "test artifact contents";

    // Store artifact via stream
    storage.storeArtifactStream(fingerprint, artifactId, (void delegate(const(ubyte)[]) sink) {
        sink(cast(ubyte[])contents.dup);
    });

    // Verify artifact exists
    assert(storage.artifactExists(fingerprint, artifactId));
    assert(!storage.artifactExists(fingerprint, "nonexistent"));
    assert(!storage.artifactExists("", artifactId));

    // Retrieve artifact via stream
    import std.array : Appender;
    Appender!(ubyte[]) retrievedBuffer;
    storage.retrieveArtifactStream(fingerprint, artifactId, (const(ubyte)[] chunk) {
        retrievedBuffer.put(chunk);
    });
    assert(retrievedBuffer.data == contents.dup);

    // Delete artifact
    storage.deleteArtifact(fingerprint, artifactId);
    assert(!storage.artifactExists(fingerprint, artifactId));

    ArtifactMetadata testMeta;
    testMeta.sha256 = "abc123";
    stateRepo.saveCachedFingerprint("t1", "hash123", [testMeta]);
    ArtifactMetadata[] cachedMetas;
    assert(stateRepo.getCachedFingerprint("t1", "hash123", cachedMetas));
    assert(cachedMetas.length == 1);
    assert(cachedMetas[0].sha256 == "abc123");

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
    node.steps = [BuildStep("Build", "bash", null, "dub build")];
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
    import std.json : JSONValue;
    WorkerRecord exec;
    exec.id = "exec-local-1";
    exec.name = "Local Executor 1";
    exec.providerType = "local";
    exec.description = "Primary local runner";
    exec.enabled = false;
    exec.configuration = JSONValue(["maxConcurrency": JSONValue(8)]);
    exec.createdAt = "2026-09-30T12:00:00Z";
    exec.updatedAt = "2026-09-30T12:00:00Z";

    stateRepo.saveExecutor(exec);
    assert(stateRepo.listExecutors().length == 1);
    WorkerRecord fetchedExec;
    assert(stateRepo.getExecutor("exec-local-1", fetchedExec));
    assert(fetchedExec.name == "Local Executor 1");
    assert(!fetchedExec.enabled);
    assert(fetchedExec.configuration["maxConcurrency"].integer == 8);

    // Toggle enabled
    fetchedExec.enabled = true;
    stateRepo.saveExecutor(fetchedExec);
    WorkerRecord updatedExec;
    assert(stateRepo.getExecutor("exec-local-1", updatedExec));
    assert(updatedExec.enabled);

    assert(stateRepo.deleteExecutor("exec-local-1"));
    assert(stateRepo.listExecutors().length == 0);
    assert(!stateRepo.getExecutor("exec-local-1", fetchedExec));

    // Granular task execution and status tracking
    TaskExecutionRecord taskRec;
    taskRec.buildId = "b1";
    taskRec.taskId = "t1";
    taskRec.status = "succeeded";
    taskRec.fingerprint = "fp_t1";
    taskRec.durationMs = 150;
    taskRec.producedArtifacts = [testMeta];
    taskRec.upstreamArtifactHashes = ["t0": "hash0"];
    stateRepo.recordTaskExecution(taskRec);

    TaskExecutionRecord fetchedTaskRec;
    assert(stateRepo.getTaskExecution("b1", "t1", fetchedTaskRec));
    assert(fetchedTaskRec.taskId == "t1");
    assert(fetchedTaskRec.status == "succeeded");
    assert(fetchedTaskRec.fingerprint == "fp_t1");
    assert(fetchedTaskRec.durationMs == 150);
    assert(fetchedTaskRec.producedArtifacts.length == 1);
    assert(fetchedTaskRec.upstreamArtifactHashes["t0"] == "hash0");

    auto buildTaskRecs = stateRepo.getTaskExecutionsForBuild("b1");
    assert(buildTaskRecs.length == 1);
    assert(buildTaskRecs[0].taskId == "t1");

    auto buildStatuses = stateRepo.getTaskStatusesForBuild("b1");
    assert("t1" in buildStatuses);
    assert(buildStatuses["t1"] == TaskStatus.succeeded);

    stateRepo.setTaskStatus("b1", "t2", TaskStatus.running);
    auto buildStatuses2 = stateRepo.getTaskStatusesForBuild("b1");
    assert(buildStatuses2.length == 2);
    assert(buildStatuses2["t2"] == TaskStatus.running);

    // Test listTaskExecutionsForTask
    TaskExecutionRecord taskRec2;
    taskRec2.buildId = "b2";
    taskRec2.taskId = "t1";
    taskRec2.projectId = "proj_test";
    taskRec2.status = "cached";
    taskRec2.startedAt = "2026-10-01T10:00:00Z";
    stateRepo.recordTaskExecution(taskRec2);

    TaskExecutionRecord taskRec3;
    taskRec3.buildId = "b3";
    taskRec3.taskId = "t1";
    taskRec3.projectId = "proj_test";
    taskRec3.status = "failed";
    taskRec3.startedAt = "2026-10-02T10:00:00Z";
    stateRepo.recordTaskExecution(taskRec3);

    auto t1Execs = stateRepo.listTaskExecutionsForTask("proj_test", "t1");
    assert(t1Execs.length == 2);
    assert(t1Execs[0].buildId == "b3"); // sorted descending by startedAt
    assert(t1Execs[1].buildId == "b2");

    auto t1Limited = stateRepo.listTaskExecutionsForTask("proj_test", "t1", 1);
    assert(t1Limited.length == 1);
    assert(t1Limited[0].buildId == "b3");

    auto t1OtherProj = stateRepo.listTaskExecutionsForTask("proj_other", "t1");
    assert(t1OtherProj.length == 0);

    // ==========================================
    // Stream-based Content-Addressed Storage Tests
    // ==========================================
    import confector.core.zip_packager : ZipPackager;
    import std.array : Appender;

    string fp1 = "fingerprint_node_100";
    string art1 = "bin_app";

    assert(!storage.artifactExists(fp1, art1));

    // Test stream storage write
    storage.storeArtifactStream(fp1, art1, (sink) {
        sink(cast(const(ubyte)[]) "zip payload chunk 1; ");
        sink(cast(const(ubyte)[]) "zip payload chunk 2;");
    });

    assert(storage.artifactExists(fp1, art1));
    assert(exists(buildPath(testDir, fp1, art1 ~ ".zip")));

    // Test stream storage read
    Appender!(ubyte[]) retrievedBytes;
    storage.retrieveArtifactStream(fp1, art1, (const(ubyte)[] chunk) {
        retrievedBytes.put(chunk);
    });
    assert(cast(string) retrievedBytes.data == "zip payload chunk 1; zip payload chunk 2;");

    // Test ZipPackager round-trip with LocalArtifactStorage
    string wsDir = buildPath(testDir, "ws_source");
    string unpackDir = buildPath(testDir, "ws_unpacked");
    mkdirRecurse(buildPath(wsDir, "dist"));
    write(buildPath(wsDir, "dist", "bundle.js"), "console.log('hello');");
    write(buildPath(wsDir, "dist", "style.css"), "body { margin: 0; }");

    string fp2 = "fingerprint_node_200";
    string art2 = "dist_assets";

    storage.storeArtifactStream(fp2, art2, (sink) {
        ZipPackager.pack(wsDir, ["dist/*"], sink);
    });

    assert(storage.artifactExists(fp2, art2));

    ZipPackager.unpackStream((sink) {
        storage.retrieveArtifactStream(fp2, art2, sink);
    }, unpackDir);

    assert(exists(buildPath(unpackDir, "dist", "bundle.js")));
    assert(exists(buildPath(unpackDir, "dist", "style.css")));
    assert(cast(string) read(buildPath(unpackDir, "dist", "bundle.js")) == "console.log('hello');");
    assert(cast(string) read(buildPath(unpackDir, "dist", "style.css")) == "body { margin: 0; }");

    // Test deletion
    storage.deleteArtifact(fp1, art1);
    assert(!storage.artifactExists(fp1, art1));
    assert(!exists(buildPath(testDir, fp1, art1 ~ ".zip")));

    // Test key traversal validation
    bool caughtBadKey = false;
    try
    {
        storage.storeArtifactStream("../escape", "art", (sink) { sink([1, 2, 3]); });
    }
    catch (Exception)
    {
        caughtBadKey = true;
    }
    assert(caughtBadKey);
    assert(!storage.artifactExists("../escape", "art"));

    // Test retrieval of nonexistent artifact
    bool caughtNotFound = false;
    try
    {
        storage.retrieveArtifactStream("no_such_fp", "no_such_art", (chunk) {});
    }
    catch (Exception)
    {
        caughtNotFound = true;
    }
    assert(caughtNotFound);
}
