module confector.core.test_storage;

/**
 * In-memory implementations of storage and queue interfaces for unit testing only.
 * Import this module conditionally in your unittest blocks:
 *
 *     unittest
 *     {
 *         import confector.core.test_storage;
 *         auto repo = new InMemoryBuildStateRepository();
 *         auto queue = new InMemoryWorkQueue();
 *         auto storage = new InMemoryArtifactStorage();
 *     }
 */

import confector.plugin_api.model;
import std.format : format;
import std.json : JSONValue;
import std.datetime.systime : Clock;
import std.uuid : randomUUID;


/**
 * In-memory implementation of ArtifactStorage for unit testing.
 * Stores artifacts as byte arrays in a hash map keyed by (fingerprint, artifactId).
 */
class InMemoryArtifactStorage : ArtifactStorage
{
    private ubyte[][string] m_artifacts;

    private static string artifactKey(string taskFingerprint, string artifactId) pure nothrow @safe
    {
        return taskFingerprint ~ "\0" ~ artifactId;
    }

    override void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
    {
        if (writer is null)
            throw new Exception("Writer delegate cannot be null");
        if (taskFingerprint.length == 0)
            throw new Exception("taskFingerprint cannot be empty");
        if (artifactId.length == 0)
            throw new Exception("artifactId cannot be empty");

        import std.array : Appender;
        Appender!(ubyte[]) buffer;
        writer((const(ubyte)[] chunk) {
            if (chunk.length > 0)
                buffer.put(chunk);
        });
        m_artifacts[artifactKey(taskFingerprint, artifactId)] = buffer.data;
    }

    override void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
            throw new Exception("Sink delegate cannot be null");

        string key = artifactKey(taskFingerprint, artifactId);
        if (key !in m_artifacts)
            throw new Exception(format("Artifact not found in storage: fingerprint='%s', artifactId='%s'", taskFingerprint, artifactId));

        sink(m_artifacts[key]);
    }

    override bool artifactExists(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0) return false;
        return (artifactKey(taskFingerprint, artifactId) in m_artifacts) !is null;
    }

    override void deleteArtifact(string taskFingerprint, string artifactId)
    {
        string key = artifactKey(taskFingerprint, artifactId);
        if (key in m_artifacts)
            m_artifacts.remove(key);
    }

    @property string backendType() const pure nothrow @safe
    {
        return "memory";
    }

    @property string displayName() const pure nothrow @safe
    {
        return "In-Memory (Test)";
    }

    @property string description() const
    {
        return "In-memory artifact storage for unit testing only.";
    }

    JSONValue defaultConfig() const
    {
        return JSONValue(string[string].init);
    }

    string[] validateConfig(in JSONValue config) const
    {
        return null;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        return "<p>In-memory storage (test only) — no configuration required.</p>";
    }

    override string presignUpload(string taskFingerprint, string artifactId)
    {
        return null; // In-memory storage does not support presigned URLs; fall back to proxy
    }

    override string presignDownload(string taskFingerprint, string artifactId)
    {
        return null; // In-memory storage does not support presigned URLs; fall back to proxy
    }
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

    @property string backendType() const pure nothrow @safe
    {
        return "memory";
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


/**
 * In-memory implementation of WorkQueue for testing only.
 */
class InMemoryWorkQueue : WorkQueue
{
    private struct QueueEntry
    {
        TaskQueueMessage message;
        bool inFlight = false;
        long visibleAfterUnix = 0;
        string activeReceiptHandle;
    }

    private QueueEntry[] m_entries;
    private TaskQueueMessage[] m_deadLetters;

    private static long currentUnixTime()
    {
        return Clock.currTime.toUnixTime();
    }

    @property string backendType() const pure nothrow @safe
    {
        return "memory";
    }

    override void enqueue(TaskQueueMessage message)
    {
        if (message.messageId.length == 0)
        {
            message.messageId = "msg_" ~ randomUUID().toString();
        }
        if (message.createdAt.length == 0)
        {
            message.createdAt = Clock.currTime.toISOString();
        }
        if (message.maxAttempts <= 0)
        {
            message.maxAttempts = 3;
        }

        QueueEntry entry;
        entry.message = message;
        entry.inFlight = false;
        entry.visibleAfterUnix = message.visibleAfterUnix > 0 ? message.visibleAfterUnix : currentUnixTime();
        m_entries ~= entry;
    }

    private static bool matchesExecutor(const(TaskQueueMessage) msg, const(string[]) supportedExecutorTypes)
    {
        if (supportedExecutorTypes.length == 0)
        {
            return true;
        }
        string msgExec = msg.executorType;
        foreach (t; supportedExecutorTypes)
        {
            if (t == msgExec || (t.length == 0 && msgExec.length == 0))
            {
                return true;
            }
        }
        return false;
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30, const(string[]) supportedExecutorTypes = null)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;

        foreach (ref entry; m_entries)
        {
            if (result.length >= maxMessages)
            {
                break;
            }

            if (!matchesExecutor(entry.message, supportedExecutorTypes))
            {
                continue;
            }

            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                string handle = "rcpt_" ~ randomUUID().toString();
                entry.inFlight = true;
                entry.activeReceiptHandle = handle;
                entry.visibleAfterUnix = now + visibilityTimeoutSeconds;

                TaskQueueMessage msg = entry.message;
                msg.receiptHandle = handle;
                msg.visibleAfterUnix = entry.visibleAfterUnix;
                result ~= msg;
            }
            else if (entry.inFlight && entry.visibleAfterUnix <= now)
            {
                // Visibility timeout expired without ACK -> retry attempt
                entry.message.attempt++;
                if (entry.message.attempt > entry.message.maxAttempts)
                {
                    // Move to dead letter
                    entry.message.errorReason = "Visibility timeout expired and max attempts reached";
                    m_deadLetters ~= entry.message;
                    entry.inFlight = false;
                    entry.visibleAfterUnix = long.max; // mark inactive
                }
                else
                {
                    string handle = "rcpt_" ~ randomUUID().toString();
                    entry.activeReceiptHandle = handle;
                    entry.visibleAfterUnix = now + visibilityTimeoutSeconds;

                    TaskQueueMessage msg = entry.message;
                    msg.receiptHandle = handle;
                    msg.visibleAfterUnix = entry.visibleAfterUnix;
                    result ~= msg;
                }
            }
        }

        // Cleanup dead letters from active entries
        QueueEntry[] remaining;
        foreach (entry; m_entries)
        {
            if (entry.visibleAfterUnix != long.max)
            {
                remaining ~= entry;
            }
        }
        m_entries = remaining;

        return result;
    }

    override void ack(string receiptHandle)
    {
        QueueEntry[] remaining;
        bool found = false;

        foreach (entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                found = true;
                continue; // removed from queue
            }
            remaining ~= entry;
        }

        if (!found)
        {
            throw new Exception(format("Message with receipt handle '%s' not found or already acknowledged", receiptHandle));
        }

        m_entries = remaining;
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        foreach (ref entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                entry.message.errorReason = errorReason;
                entry.inFlight = false;
                entry.activeReceiptHandle = null;

                if (!requeue || entry.message.attempt >= entry.message.maxAttempts)
                {
                    m_deadLetters ~= entry.message;
                    entry.visibleAfterUnix = long.max; // mark for cleanup
                }
                else
                {
                    entry.message.attempt++;
                    entry.visibleAfterUnix = currentUnixTime(); // make available immediately
                }
                break;
            }
        }

        // Cleanup dead letters
        QueueEntry[] remaining;
        foreach (entry; m_entries)
        {
            if (entry.visibleAfterUnix != long.max)
            {
                remaining ~= entry;
            }
        }
        m_entries = remaining;
    }

    override void heartbeat(string receiptHandle, long extensionSeconds = 30)
    {
        long now = currentUnixTime();
        foreach (ref entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                entry.visibleAfterUnix = now + extensionSeconds;
                return;
            }
        }
        throw new Exception(format("Cannot heartbeat; receipt handle '%s' not found or expired", receiptHandle));
    }

    override TaskQueueMessage[] getDeadLetterMessages()
    {
        return m_deadLetters.dup;
    }

    override ulong getPendingCount()
    {
        long now = currentUnixTime();
        ulong count = 0;
        foreach (entry; m_entries)
        {
            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                count++;
            }
        }
        return count;
    }

    override TaskQueueMessage[] getPendingMessages(size_t limit = 50)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;
        foreach (ref entry; m_entries)
        {
            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                result ~= entry.message;
                if (result.length >= limit) break;
            }
        }
        return result;
    }
}
