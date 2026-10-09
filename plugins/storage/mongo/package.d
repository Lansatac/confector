module plugins.storage.mongo;

import std.format;
import vibe.data.json : Json;

import confector.mongo_helpers : MongoHelpers, toJsonString, fromJsonString, document, bson_value, LogEntry, FingerprintCacheEntry;
import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, PluginCategory, StateStoragePlugin, ConfigDefinition;
import kaleidic.mongo_standalone : MongoConnection;

import std.datetime.systime : Clock;

/**
 * MongoDB-backed implementation of BuildStateRepository as a dynamic plugin.
 */
class MongoStoragePlugin : StateStoragePlugin, BuildStateRepository
{
    private PluginContext m_context;
    private MongoHelpers m_db;

    @property string name() const { return "mongo-storage"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "MongoDB-backed build state repository"; }
    @property PluginCategory category() const { return PluginCategory.storage; }

    ConfigDefinition[] configDefinitions() const
    {
        return [
            ConfigDefinition("connectionString", "CONFECTOR_MONGO_URI", Json("mongodb://mongo:27017"), "MongoDB connection URI", false),
            ConfigDefinition("dbName", "", Json("confector"), "MongoDB database name", false)
        ];
    }

    void initialize(PluginContext context = null)
    {
        if (context is null)
        {
            throw new Exception("[mongo-storage] PluginContext must not be null; the host failed to provide configuration.");
        }

        m_context = context;
        string connectionString = context.config.getString("connectionString", "mongodb://mongo:27017");
        string dbName = context.config.getString("dbName", "confector");

        auto connection = new MongoConnection(connectionString);
        m_db = MongoHelpers(connection, dbName);
        m_context.info(format("Connected to MongoDB at %s, database: %s", connectionString, dbName));
    }

    void shutdown()
    {
    }

    @property string backendType() const pure nothrow @safe
    {
        return "mongo";
    }

    override void recordTaskExecution(TaskExecutionRecord record)
    {
        if (record.startedAt.length == 0)
            record.startedAt = Clock.currTime.toISOString();
        auto json = toJsonString(record);
        m_db.upsert("task_statuses", "build_id", record.buildId, json);
    }

    override bool getTaskExecution(string buildId, string taskId, out TaskExecutionRecord record)
    {
        auto json = m_db.findOneByKeys("task_statuses", buildId, taskId);
        if (json is null || json.length == 0)
            return false;
        record = fromJsonString!TaskExecutionRecord(json);
        return true;
    }

    override TaskExecutionRecord[] getTaskExecutionsForBuild(string buildId)
    {
        TaskExecutionRecord[] list;
        auto query = document([bson_value("build_id", buildId.idup)]);
        auto results = m_db.findMany("task_statuses", query);
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!TaskExecutionRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize task execution: %s", e.msg)); }
        }
        return list;
    }

    override TaskExecutionRecord[] listRecentTaskExecutions(size_t limit = 50, string statusFilter = null, string projectIdFilter = null)
    {
        TaskExecutionRecord[] list;
        bson_value[] queryFields;
        if (statusFilter.length > 0)
            queryFields ~= bson_value("status", statusFilter.idup);
        if (projectIdFilter.length > 0)
            queryFields ~= bson_value("project_id", projectIdFilter.idup);
        auto query = document(queryFields);
        auto results = m_db.findMany("task_statuses", query, cast(int)limit);
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!TaskExecutionRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize task execution: %s", e.msg)); }
        }
        return list;
    }

    override TaskExecutionRecord[] listTaskExecutionsForTask(string projectId, string taskId, size_t limit = 20)
    {
        TaskExecutionRecord[] list;
        bson_value[] queryFields;
        if (taskId.length > 0)
            queryFields ~= bson_value("task_id", taskId.idup);
        if (projectId.length > 0)
            queryFields ~= bson_value("project_id", projectId.idup);
        auto query = document(queryFields);
        auto results = m_db.findMany("task_statuses", query, cast(int)limit);
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!TaskExecutionRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize task execution: %s", e.msg)); }
        }
        return list;
    }

    override void appendTaskLog(string buildId, string taskId, string line)
    {
        // Store logs as JSON with build_id, task_id, and line
        auto logEntry = LogEntry(buildId, taskId, line, Clock.currTime.toISOString());
        auto json = toJsonString(logEntry);
        m_db.insertOne("task_logs", json);
    }

    override string[] getTaskLogs(string buildId, string taskId)
    {
        string[] lines;
        auto query = document([
            bson_value("build_id", buildId.idup),
            bson_value("task_id", taskId.idup)
        ]);
        auto results = m_db.findMany("task_logs", query);
        foreach (jsonStr; results)
        {
            try
            {
                auto entry = fromJsonString!LogEntry(jsonStr);
                lines ~= entry.line;
            }
            catch (Exception e) { m_context.error(format("Failed to deserialize task log: %s", e.msg)); }
        }
        return lines;
    }

    override TaskStatus[string] getTaskStatusesForBuild(string buildId)
    {
        TaskStatus[string] statuses;
        auto query = document([bson_value("build_id", buildId.idup)]);
        auto results = m_db.findMany("task_statuses", query);
        foreach (jsonStr; results)
        {
            try
            {
                auto record = fromJsonString!TaskExecutionRecord(jsonStr);
                statuses[record.taskId] = cast(TaskStatus)record.status;
            }
            catch (Exception e) { m_context.error(format("Failed to deserialize task execution: %s", e.msg)); }
        }
        return statuses;
    }

    override void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null)
    {
        auto record = TaskExecutionRecord();
        record.buildId = buildId;
        record.taskId = taskId;
        record.status = cast(string)status;
        if (errorMessage.length > 0)
            record.errorMessage = errorMessage;
        auto json = toJsonString(record);
        m_db.upsert("task_statuses", "build_id", buildId, json);
    }

    override bool getTaskStatus(string buildId, string taskId, out TaskStatus status)
    {
        auto json = m_db.findOneByKeys("task_statuses", buildId, taskId);
        if (json is null || json.length == 0)
            return false;
        auto record = fromJsonString!TaskExecutionRecord(json);
        status = cast(TaskStatus)record.status;
        return true;
    }

    override void saveCachedFingerprint(string taskId, string fingerprint, ArtifactMetadata[] producedArtifacts)
    {
        auto cacheEntry = FingerprintCacheEntry(taskId, fingerprint, producedArtifacts, Clock.currTime.toISOString());
        auto json = toJsonString(cacheEntry);
        m_db.upsert("fingerprint_cache", "task_id", taskId, json);
    }

    override bool getCachedFingerprint(string taskId, string fingerprint, out ArtifactMetadata[] producedArtifacts)
    {
        auto json = m_db.findOne("fingerprint_cache", "task_id", taskId);
        if (json is null || json.length == 0)
            return false;
        auto entry = fromJsonString!FingerprintCacheEntry(json);
        if (entry.fingerprint != fingerprint)
            return false;
        producedArtifacts = entry.artifacts;
        return true;
    }

    override void recordBuild(BuildRecord build)
    {
        auto json = toJsonString(build);
        m_db.upsert("builds", "build_id", build.buildId, json);
    }

    override bool getBuild(string buildId, out BuildRecord build)
    {
        auto json = m_db.findOne("builds", "build_id", buildId);
        if (json is null || json.length == 0)
            return false;
        build = fromJsonString!BuildRecord(json);
        return true;
    }

    override BuildRecord[] listBuilds(size_t limit = 50)
    {
        BuildRecord[] list;
        auto results = m_db.findMany("builds", document([]), cast(int)limit);
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!BuildRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize build record: %s", e.msg)); }
        }
        return list;
    }

    override void appendBuildLog(string buildId, string line)
    {
        auto logEntry = LogEntry(buildId, "", line, Clock.currTime.toISOString());
        auto json = toJsonString(logEntry);
        m_db.insertOneWithKey("build_logs", "build_id", buildId, json);
    }

    override string[] getBuildLogs(string buildId)
    {
        string[] lines;
        auto query = document([bson_value("build_id", buildId.idup)]);
        auto results = m_db.findMany("build_logs", query);
        foreach (jsonStr; results)
        {
            try
            {
                auto entry = fromJsonString!LogEntry(jsonStr);
                lines ~= entry.line;
            }
            catch (Exception e) { m_context.error(format("Failed to deserialize build log: %s", e.msg)); }
        }
        return lines;
    }

    override void saveTriggerRule(TriggerRuleRecord rule)
    {
        auto json = toJsonString(rule);
        m_db.upsert("triggers", "id", rule.id, json);
    }

    override TriggerRuleRecord[] listTriggerRules()
    {
        TriggerRuleRecord[] list;
        auto results = m_db.findMany("triggers", document([]));
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!TriggerRuleRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize trigger rule: %s", e.msg)); }
        }
        return list;
    }

    override bool deleteTriggerRule(string ruleId)
    {
        return m_db.deleteOne("triggers", "id", ruleId);
    }

    override void saveProject(in ProjectRecord project)
    {
        auto json = toJsonString(project);
        m_db.upsert("projects", "id", project.id, json);
    }

    override bool getProject(string projectId, out ProjectRecord project)
    {
        auto json = m_db.findOne("projects", "id", projectId);
        if (json is null || json.length == 0)
            return false;
        project = fromJsonString!ProjectRecord(json);
        return true;
    }

    override ProjectRecord[] listProjects()
    {
        ProjectRecord[] list;
        auto results = m_db.findMany("projects", document([]));
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!ProjectRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize project: %s", e.msg)); }
        }
        return list;
    }

    override bool deleteProject(string projectId)
    {
        return m_db.deleteOne("projects", "id", projectId);
    }

    override void saveRepository(in RepositoryRecord repo)
    {
        auto json = toJsonString(repo);
        m_db.upsert("repositories", "name", repo.name, json);
    }

    override bool getRepository(string name, out RepositoryRecord repo)
    {
        auto json = m_db.findOne("repositories", "name", name);
        if (json is null || json.length == 0)
            return false;
        repo = fromJsonString!RepositoryRecord(json);
        return true;
    }

    override RepositoryRecord[] listRepositories()
    {
        RepositoryRecord[] list;
        auto results = m_db.findMany("repositories", document([]));
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!RepositoryRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize repository: %s", e.msg)); }
        }
        return list;
    }

    override bool deleteRepository(string name)
    {
        return m_db.deleteOne("repositories", "name", name);
    }

    override void saveExecutor(in WorkerRecord executor)
    {
        auto json = toJsonString(executor);
        m_db.upsert("executors", "id", executor.id, json);
    }

    override bool getExecutor(string id, out WorkerRecord executor)
    {
        auto json = m_db.findOne("executors", "id", id);
        if (json is null || json.length == 0)
            return false;
        executor = fromJsonString!WorkerRecord(json);
        return true;
    }

    override WorkerRecord[] listExecutors()
    {
        WorkerRecord[] list;
        auto results = m_db.findMany("executors", document([]));
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!WorkerRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize executor: %s", e.msg)); }
        }
        return list;
    }

    override bool deleteExecutor(string id)
    {
        return m_db.deleteOne("executors", "id", id);
    }

    override void saveRepositoryState(in VcsRepositoryState state)
    {
        auto json = toJsonString(state);
        m_db.upsert("vcs_repository_states", "repository_url", state.repositoryUrl, json);
    }

    override bool getRepositoryState(string repositoryUrl, string targetRef, out VcsRepositoryState state)
    {
        auto json = m_db.findOneByKeys("vcs_repository_states", repositoryUrl, targetRef);
        if (json is null || json.length == 0)
            return false;
        state = fromJsonString!VcsRepositoryState(json);
        return true;
    }

    override void recordRepositoryChange(in VcsChangeRecord change)
    {
        auto json = toJsonString(change);
        m_db.insertOne("vcs_change_records", json);
    }

    override VcsChangeRecord[] listRepositoryChanges(string repositoryUrl, size_t limit = 20)
    {
        VcsChangeRecord[] list;
        auto query = document([bson_value("repository_url", repositoryUrl.idup)]);
        auto results = m_db.findMany("vcs_change_records", query, cast(int)limit);
        foreach (jsonStr; results)
        {
            try { list ~= fromJsonString!VcsChangeRecord(jsonStr); }
            catch (Exception e) { m_context.error(format("Failed to deserialize VcsChangeRecord: %s", e.msg)); }
        }
        return list;
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new MongoStoragePlugin();
}
