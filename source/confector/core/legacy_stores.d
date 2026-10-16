module confector.core.legacy_stores;

/**
 * State stores for records of the build model that BuildRequest, BuildChain, TaskExecution and
 * FingerprintClaim replace, kept only for the BuildCoordinator and the controllers that read what
 * it writes. Each is removed with its last user:
 *
 * - LegacyBuildStore (BuildRecord, TaskExecutionRecord) and ResultCacheStore (CachedResult): with
 *   the BuildCoordinator (bead confector-z7z.23.10).
 * - BuildLogStore: when build logs move to the log store (bead confector-z7z.31.12). Build logs
 *   never belong in the state store line by line (AGENTS.md, "Backends and extensions"); this is
 *   the interim home of the logs the coordinator and workers already write.
 * - TriggerRuleStore: when trigger rules become part of the project definition (bead
 *   confector-z7z.23.7).
 * - WorkerStore: when compute pools replace worker records (bead confector-z7z.31.5).
 * - VcsStateStore (VcsRepositoryState, VcsChangeRecord): when tracked branches replace them (bead
 *   confector-z7z.24.1).
 *
 * The records are written whole, last writer wins (`DocumentCollection.put`), as the
 * BuildCoordinator, which serializes its own writes under one lock, has always written them. Do
 * not build anything new on these stores.
 */

import confector.core.counters : CounterStore;
import confector.core.document_collection;
import confector.core.model;
import confector.plugin_api.document_store;

import std.algorithm.searching : canFind;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.typecons : Nullable;

/// Page size of the queries that list everything they find.
private enum size_t pageSize = 100;

/// The partition key value of the listing indexes, which hold every document of a collection.
private enum string everything = "all";

/**
 * The sortable form of a legacy timestamp, which is either ISO 8601 extended
 * (`toISOExtString`) or basic (`toISOString`, as the coordinator writes them, in local time when
 * no zone is given).
 *
 * Throws: Exception if it is neither.
 */
private string legacySortKey(string timestamp)
{
    if (timestamp.canFind('-')) return sortableTimestamp(timestamp);
    try
    {
        return sortableTime(SysTime.fromISOString(timestamp));
    }
    catch (Exception e)
    {
        throw new Exception(format("'%s' is not an ISO 8601 timestamp: %s", timestamp, e.msg));
    }
}

private string now()
{
    return Clock.currTime.toUTC().toISOExtString();
}

/// How many times `mutate` re-reads and retries after losing a compare-and-set before failing.
/// Every lost attempt means another write succeeded, so this is reached only under sustained
/// contention on one document.
private enum maxMutationAttempts = 100;

/**
 * Applies `change` to document `id` by compare-and-set: reads it, applies `change`, and writes
 * it at the version read, re-reading and applying `change` again whenever a concurrent write
 * wins, so no write is lost. A missing document is made with `create` and then changed, or, when
 * `create` is null, is an error.
 */
private void mutate(T)(DocumentCollection!T collection, string id, scope T delegate() create,
    scope void delegate(ref T) change)
{
    foreach (attempt; 0 .. maxMutationAttempts)
    {
        auto current = collection.get(id);
        try
        {
            if (current.isNull)
            {
                if (create is null)
                {
                    throw new Exception(format("Document '%s' in collection '%s' does not exist", id, collection.name));
                }
                T value = create();
                change(value);
                collection.create(id, value);
                return;
            }
            T value = current.get.value;
            change(value);
            collection.replace(id, value, current.get.version_);
            return;
        }
        catch (DocumentConflictException)
        {
            // A concurrent write won; read what it wrote and apply the change to that.
        }
    }
    throw new Exception(format("Could not update document '%s' in collection '%s': %s attempts in a row lost to concurrent writes",
        id, collection.name, maxMutationAttempts));
}

/**
 * Build records and the task execution records of each build, as the BuildCoordinator keeps
 * them. A build's task records are read by id, one per task of the build's chain
 * (`BuildRecord.chainTasks`).
 */
final class LegacyBuildStore
{
    private DocumentCollection!BuildRecord m_builds;
    private DocumentCollection!TaskExecutionRecord m_tasks;

    /// Declares the legacy build and task record collections on `store`.
    this(DocumentStore store)
    {
        m_builds = new DocumentCollection!BuildRecord(store,
            CollectionSpec("legacy_builds", [IndexSpec("all", "listing", "started_key")]),
            ["listing", "started_key"],
            (in BuildRecord build) => ["listing": everything, "started_key": legacySortKey(build.startedAt)]);
        m_tasks = new DocumentCollection!TaskExecutionRecord(store,
            CollectionSpec("legacy_task_records",
                [IndexSpec("recent", "listing", "started_key"), IndexSpec("by_task", "project_task", "started_key")]),
            ["listing", "started_key", "project_task"], &taskFields);
    }

    private static string[string] taskFields(in TaskExecutionRecord record)
    {
        string[string] fields = ["listing": everything, "started_key": legacySortKey(record.startedAt)];
        if (record.projectId.length > 0) fields["project_task"] = compositeKey(record.projectId, record.taskId);
        return fields;
    }

    /**
     * Records a new build. Throws if it has no id or start time, and DocumentConflictException
     * if the build exists.
     */
    void createBuild(BuildRecord build)
    {
        if (build.buildId.length == 0 || build.startedAt.length == 0)
        {
            throw new Exception(format("Build record '%s' needs a build id and a start time", build.buildId));
        }
        m_builds.create(build.buildId, build);
    }

    /**
     * Applies `change` to build `buildId` by compare-and-set, re-reading and applying it again
     * whenever a concurrent write wins, so no update is lost. Throws if the build does not
     * exist or `change` alters its id.
     */
    void updateBuild(string buildId, scope void delegate(ref BuildRecord) change)
    {
        mutate(m_builds, buildId, null, (ref BuildRecord build) {
            change(build);
            if (build.buildId != buildId)
            {
                throw new Exception(format("Updating build '%s' cannot change its id to '%s'", buildId, build.buildId));
            }
        });
    }

    /// Reads build `buildId`. Returns false if it does not exist.
    bool getBuild(string buildId, out BuildRecord build)
    {
        return m_builds.get(buildId).tryValue(build);
    }

    /// Lists builds, most recently started first, at most `limit` of them. Discovery.
    BuildRecord[] listBuilds(size_t limit = 50)
    {
        IndexQuery lookup;
        lookup.index = "all";
        lookup.partitionKey = everything;
        lookup.descending = true;
        lookup.limit = pageSize;
        BuildRecord[] result;
        foreach (item; m_builds.queryAll(lookup, limit)) result ~= item.value;
        return result;
    }

    /// Reads the record of task `taskId` in build `buildId`. Returns false if there is none.
    bool getTaskExecution(string buildId, string taskId, out TaskExecutionRecord record)
    {
        return m_tasks.get(hashedId(buildId, taskId)).tryValue(record);
    }

    /// Reads the recorded status of task `taskId` in build `buildId`. Returns false if there is
    /// no record.
    bool getTaskStatus(string buildId, string taskId, out TaskStatus status)
    {
        TaskExecutionRecord record;
        if (!getTaskExecution(buildId, taskId, record)) return false;
        status = cast(TaskStatus) record.status;
        return true;
    }

    /**
     * Applies `change` to the record of task `taskId` in build `buildId` by compare-and-set,
     * re-reading and applying it again whenever a concurrent write wins. Throws if there is no
     * such record (setTaskStatus creates it) or `change` alters its build or task.
     */
    void updateTaskExecution(string buildId, string taskId, void delegate(ref TaskExecutionRecord) change)
    {
        mutate(m_tasks, hashedId(buildId, taskId), null, checkedTaskChange(buildId, taskId, change));
    }

    /**
     * Sets the status (and, when given, the error message) of task `taskId` in build `buildId`
     * by compare-and-set. The first status set creates the record, under the build's project,
     * starting now.
     *
     * Throws: Exception if the record does not exist yet and neither does the build.
     */
    void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null)
    {
        TaskExecutionRecord create()
        {
            BuildRecord build;
            if (!getBuild(buildId, build))
            {
                throw new Exception(format("Cannot record task '%s' of build '%s': the build does not exist", taskId, buildId));
            }
            TaskExecutionRecord record;
            record.buildId = buildId;
            record.taskId = taskId;
            record.projectId = build.projectId;
            record.projectName = build.projectName;
            record.startedAt = now();
            return record;
        }

        mutate(m_tasks, hashedId(buildId, taskId), &create, checkedTaskChange(buildId, taskId, (ref TaskExecutionRecord record) {
            record.status = status;
            if (errorMessage.length > 0) record.errorMessage = errorMessage;
        }));
    }

    private static void delegate(ref TaskExecutionRecord) checkedTaskChange(string buildId, string taskId,
        void delegate(ref TaskExecutionRecord) change)
    {
        return (ref TaskExecutionRecord record) {
            change(record);
            if (record.buildId != buildId || record.taskId != taskId)
            {
                throw new Exception(format("Updating the record of task '%s' in build '%s' cannot move it", taskId, buildId));
            }
        };
    }

    /// The records of build `buildId`'s tasks, one per task of its chain that has a record.
    /// Empty if the build does not exist. Strongly consistent: reads each record by id.
    TaskExecutionRecord[] getTaskExecutionsForBuild(string buildId)
    {
        BuildRecord build;
        if (!getBuild(buildId, build)) return null;
        TaskExecutionRecord[] records;
        foreach (task; build.chainTasks)
        {
            TaskExecutionRecord record;
            if (getTaskExecution(buildId, task.id, record)) records ~= record;
        }
        return records;
    }

    /// The recorded status of each of build `buildId`'s tasks that has a record (see
    /// getTaskExecutionsForBuild).
    TaskStatus[string] getTaskStatusesForBuild(string buildId)
    {
        TaskStatus[string] statuses;
        foreach (record; getTaskExecutionsForBuild(buildId))
        {
            statuses[record.taskId] = cast(TaskStatus) record.status;
        }
        return statuses;
    }

    /// Lists task records across builds, most recently started first, at most `limit` of them,
    /// keeping only those with status `statusFilter` and project `projectIdFilter` when given.
    /// Discovery.
    TaskExecutionRecord[] listRecentTaskExecutions(size_t limit = 50, string statusFilter = null, string projectIdFilter = null)
    {
        IndexQuery lookup;
        lookup.index = "recent";
        lookup.partitionKey = everything;
        lookup.descending = true;
        lookup.limit = pageSize;
        TaskExecutionRecord[] result;
        while (result.length < limit)
        {
            auto page = m_tasks.query(lookup);
            foreach (item; page.items)
            {
                if (statusFilter.length > 0 && item.status != statusFilter) continue;
                if (projectIdFilter.length > 0 && item.projectId != projectIdFilter) continue;
                if (result.length == limit) break;
                result ~= item.value;
            }
            if (page.nextCursor.length == 0) break;
            lookup.cursor = page.nextCursor;
        }
        return result;
    }

    /// Lists task `taskId` of project `projectId`'s records, most recently started first, at
    /// most `limit` of them. Discovery.
    TaskExecutionRecord[] listTaskExecutionsForTask(string projectId, string taskId, size_t limit = 20)
    {
        if (projectId.length == 0 || taskId.length == 0)
        {
            throw new Exception("Listing a task's executions needs a project id and a task id");
        }
        IndexQuery lookup;
        lookup.index = "by_task";
        lookup.partitionKey = compositeKey(projectId, taskId);
        lookup.descending = true;
        lookup.limit = pageSize;
        TaskExecutionRecord[] result;
        foreach (item; m_tasks.queryAll(lookup, limit)) result ~= item.value;
        return result;
    }
}

/**
 * The BuildCoordinator's result cache: the result a cache hit reuses, keyed by fingerprint
 * alone (a fingerprint covers the project and task), so every fingerprint keeps its own entry
 * (bead confector-yv9). The latest success at a fingerprint replaces an earlier one.
 */
final class ResultCacheStore
{
    private DocumentCollection!CachedResult m_results;

    /// Declares the result cache collection on `store`.
    this(DocumentStore store)
    {
        m_results = new DocumentCollection!CachedResult(store, CollectionSpec("legacy_result_cache", null));
    }

    /// Records `result` as the result to reuse at `fingerprint`.
    void save(string fingerprint, CachedResult result)
    {
        if (fingerprint.length == 0) throw new Exception("A cached result needs a fingerprint");
        m_results.put(fingerprint, result);
    }

    /// Reads the result to reuse at `fingerprint`. Returns false if there is none.
    bool get(string fingerprint, out CachedResult result)
    {
        return m_results.get(fingerprint).tryValue(result);
    }
}

/// One stored log line: line `seq` (from 1) of log `log`.
struct LogLine
{
    string log;
    long seq;
    string line;
}

/**
 * Build and task logs, one document per line, numbered by a counter per log so lines read back
 * in the order they were appended. See the module documentation: logs move to the log store.
 */
final class BuildLogStore
{
    private DocumentCollection!LogLine m_lines;
    private CounterStore m_counters;

    /// Declares the log line and counter collections on `store`.
    this(DocumentStore store)
    {
        m_lines = new DocumentCollection!LogLine(store,
            CollectionSpec("legacy_log_lines", [IndexSpec("by_log", "log", "seq_key")]),
            ["seq_key"], (in LogLine line) => ["seq_key": sortableNumber(line.seq)]);
        m_counters = new CounterStore(store);
    }

    /// Appends a line to build `buildId`'s log.
    void appendBuildLog(string buildId, string line)
    {
        append(compositeKey("build", buildId), line);
    }

    /// Build `buildId`'s log lines, in order. Discovery: may lag behind appends.
    string[] getBuildLogs(string buildId)
    {
        return read(compositeKey("build", buildId));
    }

    /// Appends a line to task `taskId`'s log in build `buildId`.
    void appendTaskLog(string buildId, string taskId, string line)
    {
        append(compositeKey("task", buildId, taskId), line);
    }

    /// Task `taskId`'s log lines in build `buildId`, in order. Discovery: may lag behind appends.
    string[] getTaskLogs(string buildId, string taskId)
    {
        return read(compositeKey("task", buildId, taskId));
    }

    /// Longest line stored, in UTF-8 bytes. A longer line is cut at this length and marked, so
    /// one runaway line cannot exceed the state store's document size limit.
    enum size_t maxLineBytes = 64 * 1024;

    /// `line`, cut to at most maxLineBytes (on a character boundary) with a note of how much was
    /// cut, if it is longer.
    static string truncated(string line)
    {
        import std.utf : stride;

        if (line.length <= maxLineBytes) return line;
        enum string marker = " [line truncated: %s of %s bytes dropped]";
        const budget = maxLineBytes - 64; // room for the marker
        size_t end = 0;
        while (end < line.length)
        {
            const next = end + stride(line, end);
            if (next > budget) break;
            end = next;
        }
        return line[0 .. end] ~ format(marker, line.length - end, line.length);
    }

    private void append(string log, string line)
    {
        line = truncated(line);
        const seq = m_counters.next(compositeKey("log", log));
        m_lines.create(hashedId(log, sortableNumber(seq)), LogLine(log, cast(long) seq, line));
    }

    private string[] read(string log)
    {
        IndexQuery lookup;
        lookup.index = "by_log";
        lookup.partitionKey = log;
        lookup.limit = 1000;
        string[] lines;
        foreach (item; m_lines.queryAll(lookup)) lines ~= item.line;
        return lines;
    }
}

/**
 * Trigger rules, by id.
 */
final class TriggerRuleStore
{
    private DocumentCollection!TriggerRuleRecord m_rules;

    /// Declares the trigger rule collection on `store`.
    this(DocumentStore store)
    {
        m_rules = new DocumentCollection!TriggerRuleRecord(store,
            CollectionSpec("trigger_rules", [IndexSpec("all", "listing", "id")]),
            ["listing"], (in TriggerRuleRecord rule) => ["listing": everything]);
    }

    /// Writes `rule` (last edit wins).
    void save(TriggerRuleRecord rule)
    {
        if (rule.id.length == 0) throw new Exception("A trigger rule needs an id");
        m_rules.put(rule.id, rule);
    }

    /// Lists every trigger rule, by id. Discovery.
    TriggerRuleRecord[] list()
    {
        return listAll(m_rules);
    }

    /// Removes rule `id`. Returns false if it did not exist.
    bool remove(string id)
    {
        return m_rules.removeLatest(id);
    }
}

/**
 * Worker records (compute provider configurations), by id.
 */
final class WorkerStore
{
    private DocumentCollection!WorkerRecord m_workers;

    /// Declares the worker collection on `store`.
    this(DocumentStore store)
    {
        m_workers = new DocumentCollection!WorkerRecord(store,
            CollectionSpec("workers", [IndexSpec("all", "listing", "id")]),
            ["listing"], (in WorkerRecord worker) => ["listing": everything]);
    }

    /// Writes `worker` (last edit wins).
    void save(WorkerRecord worker)
    {
        if (worker.id.length == 0) throw new Exception("A worker record needs an id");
        m_workers.put(worker.id, worker);
    }

    /// Reads worker `id`. Returns false if it does not exist.
    bool get(string id, out WorkerRecord worker)
    {
        return m_workers.get(id).tryValue(worker);
    }

    /// Lists every worker record, by id. Discovery.
    WorkerRecord[] list()
    {
        return listAll(m_workers);
    }

    /// Removes worker `id`. Returns false if it did not exist.
    bool remove(string id)
    {
        return m_workers.removeLatest(id);
    }
}

/**
 * The latest known revision of each repository URL and ref, and the changes detected between
 * revisions, as webhooks and polling record them.
 */
final class VcsStateStore
{
    private DocumentCollection!VcsRepositoryState m_states;
    private DocumentCollection!VcsChangeRecord m_changes;

    /// Declares the repository state and change collections on `store`.
    this(DocumentStore store)
    {
        m_states = new DocumentCollection!VcsRepositoryState(store, CollectionSpec("vcs_repository_states", null));
        m_changes = new DocumentCollection!VcsChangeRecord(store,
            CollectionSpec("vcs_changes", [IndexSpec("by_repository", "repository_url", "detected_key")]),
            ["detected_key"], (in VcsChangeRecord change) => ["detected_key": legacySortKey(change.detectedAt)]);
    }

    /// Writes the latest state of `state.repositoryUrl` at `state.targetRef`.
    void saveState(VcsRepositoryState state)
    {
        if (state.repositoryUrl.length == 0) throw new Exception("A repository state needs a repository URL");
        m_states.put(hashedId(state.repositoryUrl, state.targetRef), state);
    }

    /// Reads the latest state of `repositoryUrl` at `targetRef`. Returns false if there is none.
    bool getState(string repositoryUrl, string targetRef, out VcsRepositoryState state)
    {
        return m_states.get(hashedId(repositoryUrl, targetRef)).tryValue(state);
    }

    /// Records a detected change.
    void recordChange(VcsChangeRecord change)
    {
        if (change.id.length == 0 || change.repositoryUrl.length == 0)
        {
            throw new Exception("A change record needs an id and a repository URL");
        }
        m_changes.create(change.id, change);
    }

    /// The latest `limit` changes of `repositoryUrl`, oldest first. Discovery.
    VcsChangeRecord[] listChanges(string repositoryUrl, size_t limit = 20)
    {
        IndexQuery lookup;
        lookup.index = "by_repository";
        lookup.partitionKey = repositoryUrl;
        return latest(lookup, limit);
    }

    private VcsChangeRecord[] latest(IndexQuery lookup, size_t limit)
    {
        import std.algorithm.mutation : reverse;

        lookup.descending = true;
        lookup.limit = pageSize;
        VcsChangeRecord[] result;
        foreach (item; m_changes.queryAll(lookup, limit)) result ~= item.value;
        result.reverse();
        return result;
    }
}

/// Every value in a collection's "all" listing index.
private T[] listAll(T)(DocumentCollection!T collection)
{
    IndexQuery lookup;
    lookup.index = "all";
    lookup.partitionKey = everything;
    lookup.limit = pageSize;
    T[] result;
    foreach (item; collection.queryAll(lookup)) result ~= item.value;
    return result;
}

version (unittest)
{
    import confector.core.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    private bool throwsWith(scope void delegate() action, string text)
    {
        try action();
        catch (Exception e) return e.msg.canFind(text);
        return false;
    }
}

unittest
{
    // Builds and their task records; a build's tasks are those of its chain
    auto documents = new InMemoryDocumentStore();
    auto builds = new LegacyBuildStore(documents);

    BuildRecord build;
    build.buildId = "b1";
    build.projectId = "game";
    build.projectName = "Game";
    build.status = "queued";
    build.startedAt = "20261015T140200.5";
    ChainTask compile; compile.id = "compile";
    ChainTask test; test.id = "test";
    build.chainTasks = [compile, test];
    builds.createBuild(build);

    BuildRecord read;
    assert(builds.getBuild("b1", read) && read == build);
    assert(!builds.getBuild("b2", read));
    assert(throwsWith({ builds.createBuild(build); }, "already exists"), "A build is created once");

    builds.setTaskStatus("b1", "compile", TaskStatus.running);
    TaskStatus status;
    assert(builds.getTaskStatus("b1", "compile", status) && status == TaskStatus.running);
    assert(!builds.getTaskStatus("b1", "test", status));
    assert(builds.getTaskStatusesForBuild("b1") == ["compile": TaskStatus.running]);

    // The first status creates the record under the build's project
    builds.setTaskStatus("b1", "test", TaskStatus.succeeded);
    builds.updateTaskExecution("b1", "test", (ref TaskExecutionRecord record) {
        record.durationMs = 85;
        record.fingerprint = "fp_test";
    });
    TaskExecutionRecord record;
    assert(builds.getTaskExecution("b1", "test", record));
    assert(record.projectId == "game" && record.projectName == "Game" && record.startedAt.length > 0);
    assert(record.durationMs == 85 && record.status == "succeeded");
    assert(builds.getTaskStatusesForBuild("b1") == ["compile": TaskStatus.running, "test": TaskStatus.succeeded]);

    builds.setTaskStatus("b1", "compile", TaskStatus.failed, "boom");
    assert(builds.getTaskExecution("b1", "compile", record) && record.status == "failed" && record.errorMessage == "boom");
    assert(builds.getTaskExecutionsForBuild("b1").length == 2);
    assert(builds.getTaskExecutionsForBuild("missing").length == 0);

    builds.updateBuild("b1", (ref BuildRecord b) { b.status = "failed"; });
    assert(builds.getBuild("b1", read) && read.status == "failed" && read.chainTasks.length == 2);

    // Missing builds and records, and moving a record, fail loudly
    assert(throwsWith({ builds.setTaskStatus("missing", "t", TaskStatus.running); }, "does not exist"));
    assert(throwsWith({ builds.updateTaskExecution("b1", "lint", (ref TaskExecutionRecord r) {}); }, "does not exist"));
    assert(throwsWith({ builds.updateBuild("missing", (ref BuildRecord b) {}); }, "does not exist"));
    assert(throwsWith({ builds.updateBuild("b1", (ref BuildRecord b) { b.buildId = "b9"; }); }, "cannot change its id"));
    assert(throwsWith({ builds.updateTaskExecution("b1", "test", (ref TaskExecutionRecord r) { r.taskId = "lint"; }); }, "cannot move"));

    // A restarted process reads the same records
    auto restarted = new LegacyBuildStore(documents.restart());
    assert(restarted.getTaskStatusesForBuild("b1").length == 2);
}

unittest
{
    // Status changes and build updates are compare-and-set: a write that lands between another
    // writer's read and write is not lost; the other writer re-reads and applies its change to it
    auto documents = new InMemoryDocumentStore();
    auto other = new LegacyBuildStore(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto builds = new LegacyBuildStore(interleaving);

    BuildRecord build;
    build.buildId = "b1";
    build.projectId = "game";
    build.startedAt = "2026-10-15T14:02:00Z";
    ChainTask compile; compile.id = "compile";
    build.chainTasks = [compile];
    builds.createBuild(build);
    builds.setTaskStatus("b1", "compile", TaskStatus.queued);

    interleaving.beforeNextWrite = () {
        other.updateTaskExecution("b1", "compile", (ref TaskExecutionRecord r) { r.fingerprint = "fp1"; });
    };
    builds.setTaskStatus("b1", "compile", TaskStatus.running);
    TaskExecutionRecord record;
    assert(builds.getTaskExecution("b1", "compile", record));
    assert(record.status == "running" && record.fingerprint == "fp1", "Neither write is lost");

    interleaving.beforeNextWrite = () {
        other.updateBuild("b1", (ref BuildRecord b) { b.executedTasks ~= "compile"; });
    };
    builds.updateBuild("b1", (ref BuildRecord b) { b.status = "succeeded"; });
    BuildRecord read;
    assert(builds.getBuild("b1", read) && read.status == "succeeded" && read.executedTasks == ["compile"]);
}

unittest
{
    // Builds and task records are listed newest first, filtered, and per task
    auto builds = new LegacyBuildStore(new InMemoryDocumentStore());
    foreach (i, startedAt; ["2026-10-01T10:00:00Z", "2026-10-03T10:00:00Z", "2026-10-02T10:00:00Z"])
    {
        BuildRecord build;
        build.buildId = format("b%s", i);
        build.projectId = i == 2 ? "other" : "proj";
        build.startedAt = startedAt;
        builds.createBuild(build);

        builds.setTaskStatus(build.buildId, "t1", i == 1 ? TaskStatus.failed : TaskStatus.succeeded);
        builds.updateTaskExecution(build.buildId, "t1", (ref TaskExecutionRecord record) { record.startedAt = startedAt; });
    }

    auto listed = builds.listBuilds(2);
    assert(listed.length == 2 && listed[0].buildId == "b1" && listed[1].buildId == "b2");

    auto recent = builds.listRecentTaskExecutions();
    assert(recent.length == 3 && recent[0].buildId == "b1");
    assert(builds.listRecentTaskExecutions(50, "succeeded").length == 2);
    assert(builds.listRecentTaskExecutions(50, null, "proj").length == 2);
    assert(builds.listRecentTaskExecutions(1, "succeeded")[0].buildId == "b2");

    auto history = builds.listTaskExecutionsForTask("proj", "t1");
    assert(history.length == 2 && history[0].buildId == "b1" && history[1].buildId == "b0");
    assert(builds.listTaskExecutionsForTask("proj", "t1", 1).length == 1);
    assert(builds.listTaskExecutionsForTask("nobody", "t1").length == 0);

    // A build without an id or a start time fails loudly rather than getting defaults
    assert(throwsWith({ builds.createBuild(BuildRecord.init); }, "needs a build id and a start time"));
    BuildRecord undated;
    undated.buildId = "undated";
    assert(throwsWith({ builds.createBuild(undated); }, "needs a build id and a start time"));
    BuildRecord badTime;
    badTime.buildId = "bad";
    badTime.startedAt = "yesterday";
    assert(throwsWith({ builds.createBuild(badTime); }, "yesterday"));
}

unittest
{
    // The result cache keeps every fingerprint's own entry (bead confector-yv9)
    auto cache = new ResultCacheStore(new InMemoryDocumentStore());
    ArtifactMetadata artifact;
    artifact.artifactId = "out.zip";
    CachedResult older;
    older.artifacts = [artifact];
    older.definitionHash = "def1";
    cache.save("fp_old", older);
    CachedResult newer;
    newer.definitionHash = "def2";
    cache.save("fp_new", newer);

    CachedResult read;
    assert(cache.get("fp_old", read) && read.definitionHash == "def1" && read.artifacts[0].artifactId == "out.zip");
    assert(cache.get("fp_new", read) && read.definitionHash == "def2");
    assert(!cache.get("fp_none", read));
}

unittest
{
    // Logs read back in append order, per build and per task
    auto logs = new BuildLogStore(new InMemoryDocumentStore());
    foreach (i; 0 .. 12) logs.appendBuildLog("b1", format("line %s", i));
    logs.appendTaskLog("b1", "t1", "task line");
    logs.appendBuildLog("b2", "other build");

    auto lines = logs.getBuildLogs("b1");
    assert(lines.length == 12 && lines[0] == "line 0" && lines[11] == "line 11", "Line 10 sorts after line 9");
    assert(logs.getTaskLogs("b1", "t1") == ["task line"]);
    assert(logs.getTaskLogs("b1", "t2").length == 0);
    assert(logs.getBuildLogs("b2") == ["other build"]);

    // A line too long for the state store is cut on a character boundary and marked, not
    // rejected
    import std.array : replicate;
    import std.utf : validate;
    string huge = "\u00e9".replicate(BuildLogStore.maxLineBytes); // two bytes per character
    logs.appendTaskLog("b1", "huge", huge);
    auto stored = logs.getTaskLogs("b1", "huge");
    assert(stored.length == 1 && stored[0].length <= BuildLogStore.maxLineBytes);
    assert(stored[0].canFind("[line truncated:") && stored[0].canFind(format("of %s bytes dropped]", huge.length)));
    validate(stored[0]);
    assert(BuildLogStore.truncated("short") == "short");
}

unittest
{
    // Trigger rules and worker records: written whole, listed and removed
    auto documents = new InMemoryDocumentStore();
    auto rules = new TriggerRuleStore(documents);
    TriggerRuleRecord rule;
    rule.id = "trig_1";
    rule.triggerType = "cron";
    rules.save(rule);
    rule.criteria = "0 0 * * 0";
    rules.save(rule);
    assert(rules.list() == [rule]);
    assert(rules.remove("trig_1") && !rules.remove("trig_1") && rules.list().length == 0);

    auto workers = new WorkerStore(documents);
    WorkerRecord worker;
    worker.id = "w1";
    worker.providerType = "local";
    workers.save(worker);
    WorkerRecord read;
    assert(workers.get("w1", read) && read.providerType == "local");
    assert(workers.list().length == 1);
    assert(workers.remove("w1") && !workers.get("w1", read));
}

unittest
{
    // Repository states by URL and ref; changes listed per repository
    auto vcs = new VcsStateStore(new InMemoryDocumentStore());
    VcsRepositoryState state;
    state.repositoryUrl = "https://example.com/game.git";
    state.providerType = "git";
    state.targetRef = "main";
    state.revision = "abc";
    vcs.saveState(state);
    state.revision = "def";
    vcs.saveState(state);

    VcsRepositoryState read;
    assert(vcs.getState("https://example.com/game.git", "main", read) && read.revision == "def");
    assert(!vcs.getState("https://example.com/game.git", "dev", read));

    foreach (i, url; ["https://example.com/game.git", "https://example.com/game.git", "https://example.com/tools.git"])
    {
        VcsChangeRecord change;
        change.id = format("change-%s", i);
        change.repositoryUrl = url;
        change.detectedAt = format("2026-10-09T1%s:00:00Z", i);
        vcs.recordChange(change);
    }
    auto changes = vcs.listChanges("https://example.com/game.git");
    assert(changes.length == 2 && changes[0].id == "change-0" && changes[1].id == "change-1");
    auto latest = vcs.listChanges("https://example.com/game.git", 1);
    assert(latest.length == 1 && latest[0].id == "change-1");
    assert(vcs.listChanges("https://example.com/none.git").length == 0);
}
