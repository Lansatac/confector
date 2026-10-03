module confector.storage.mongo_repository;

import confector.core.model;
import confector.core.storage;
import confector.core.executor : ExecutorRecord;
import confector.core.json_compat : sanitizeBson;

import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.collection : MongoCollection, FindOptions, UpdateOptions;
import vibe.data.json;
import vibe.data.bson;
import vibe.core.log : logError, logWarn, logDebug;

import std.format : format;
import std.datetime.systime : Clock;

/**
 * MongoDB-backed implementation of BuildStateRepository.
 */
class MongoBuildStateRepository : BuildStateRepository
{
    private MongoCollection m_statusCollection;
    private MongoCollection m_cacheCollection;
    private MongoCollection m_buildsCollection;
    private MongoCollection m_logsCollection;
    private MongoCollection m_triggersCollection;
    private MongoCollection m_projectsCollection;
    private MongoCollection m_repositoriesCollection;
    private MongoCollection m_executorsCollection;

    this(MongoClient client, string dbName = "confector")
    {
        m_statusCollection = client.getCollection(format("%s.task_statuses", dbName));
        m_cacheCollection = client.getCollection(format("%s.fingerprint_cache", dbName));
        m_buildsCollection = client.getCollection(format("%s.builds", dbName));
        m_logsCollection = client.getCollection(format("%s.build_logs", dbName));
        m_triggersCollection = client.getCollection(format("%s.triggers", dbName));
        m_projectsCollection = client.getCollection(format("%s.projects", dbName));
        m_repositoriesCollection = client.getCollection(format("%s.repositories", dbName));
        m_executorsCollection = client.getCollection(format("%s.executors", dbName));
    }

    override void setTaskStatus(string buildId, string taskId, TaskStatus status, string errorMessage = null)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(buildId);
            query["task_id"] = Bson(taskId);

            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["build_id"] = Bson(buildId);
            setFields["task_id"] = Bson(taskId);
            setFields["status"] = Bson(cast(string)status);
            setFields["updated_at"] = Bson(Clock.currTime.toISOString());
            if (errorMessage.length > 0)
            {
                setFields["error_message"] = Bson(errorMessage);
            }
            update["$set"] = setFields;

            UpdateOptions opts;
            opts.upsert = true;
            m_statusCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to set task status (buildId=%s, taskId=%s): %s", buildId, taskId, e.msg);
        }
    }

    override bool getTaskStatus(string buildId, string taskId, out TaskStatus status)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(buildId);
            query["task_id"] = Bson(taskId);

            auto doc = m_statusCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            auto pStatus = doc.tryIndex("status");
            if (!pStatus.isNull && pStatus.get.type == Bson.Type.string)
            {
                status = cast(TaskStatus)pStatus.get.get!string;
                return true;
            }
        }
        catch (Exception e)
        {
            logWarn("Failed to get task status (buildId=%s, taskId=%s): %s", buildId, taskId, e.msg);
        }
        return false;
    }

    override void saveCachedFingerprint(string taskId, string fingerprint, ArtifactMetadata[] producedArtifacts)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["task_id"] = Bson(taskId);
            query["fingerprint"] = Bson(fingerprint);

            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["task_id"] = Bson(taskId);
            setFields["fingerprint"] = Bson(fingerprint);
            setFields["artifacts"] = serializeToBson(producedArtifacts);
            setFields["cached_at"] = Bson(Clock.currTime.toISOString());
            update["$set"] = setFields;

            UpdateOptions opts;
            opts.upsert = true;
            m_cacheCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to save cached fingerprint (taskId=%s): %s", taskId, e.msg);
        }
    }

    override bool getCachedFingerprint(string taskId, string fingerprint, out ArtifactMetadata[] producedArtifacts)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["task_id"] = Bson(taskId);
            query["fingerprint"] = Bson(fingerprint);

            auto doc = m_cacheCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            auto pArt = doc.tryIndex("artifacts");
            if (!pArt.isNull)
            {
                producedArtifacts = deserializeBson!(ArtifactMetadata[])(pArt.get);
                return true;
            }
        }
        catch (Exception e)
        {
            logWarn("Failed to get cached fingerprint (taskId=%s): %s", taskId, e.msg);
        }
        return false;
    }

    override void recordBuild(BuildRecord build)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(build.buildId);

            Bson update = Bson.emptyObject;
            update["$set"] = serializeToBson(build);

            UpdateOptions opts;
            opts.upsert = true;
            m_buildsCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to record build (buildId=%s): %s", build.buildId, e.msg);
        }
    }

    override bool getBuild(string buildId, out BuildRecord build)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(buildId);

            auto doc = m_buildsCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            build = deserializeBson!BuildRecord(sanitizeBson(doc));
            return true;
        }
        catch (Exception e)
        {
            logWarn("Failed to get build (buildId=%s): %s", buildId, e.msg);
            return false;
        }
    }

    override BuildRecord[] listBuilds(size_t limit = 50)
    {
        BuildRecord[] list;
        try
        {
            FindOptions opts;
            opts.sort = Bson(["started_at": Bson(-1)]);
            opts.limit = cast(int)limit;
            auto cursor = m_buildsCollection.find(Bson.emptyObject, opts);
            foreach (doc; cursor)
            {
                try
                {
                    list ~= deserializeBson!BuildRecord(sanitizeBson(doc));
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize build record: %s", e.msg);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to list builds: %s", e.msg);
        }
        return list;
    }

    override void appendBuildLog(string buildId, string line)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(buildId);

            Bson update = Bson.emptyObject;
            Bson pushField = Bson.emptyObject;
            pushField["lines"] = Bson(line);
            update["$push"] = pushField;

            Bson setField = Bson.emptyObject;
            setField["build_id"] = Bson(buildId);
            setField["updated_at"] = Bson(Clock.currTime.toISOString());
            update["$set"] = setField;

            UpdateOptions opts;
            opts.upsert = true;
            m_logsCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to append build log (buildId=%s): %s", buildId, e.msg);
        }
    }

    override string[] getBuildLogs(string buildId)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["build_id"] = Bson(buildId);

            auto doc = m_logsCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return [];
            }

            auto pLines = doc.tryIndex("lines");
            if (!pLines.isNull && pLines.get.type == Bson.Type.array)
            {
                string[] lines;
                foreach (Bson item; pLines.get)
                {
                    if (item.type == Bson.Type.string)
                    {
                        lines ~= item.get!string;
                    }
                }
                return lines;
            }
        }
        catch (Exception e)
        {
            logWarn("Failed to get build logs (buildId=%s): %s", buildId, e.msg);
        }
        return [];
    }

    override void saveTriggerRule(TriggerRuleRecord rule)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(rule.id);

            Bson update = Bson.emptyObject;
            update["$set"] = serializeToBson(rule);

            UpdateOptions opts;
            opts.upsert = true;
            m_triggersCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to save trigger rule (id=%s): %s", rule.id, e.msg);
        }
    }

    override TriggerRuleRecord[] listTriggerRules()
    {
        TriggerRuleRecord[] list;
        try
        {
            auto cursor = m_triggersCollection.find();
            foreach (doc; cursor)
            {
                try
                {
                    list ~= deserializeBson!TriggerRuleRecord(sanitizeBson(doc));
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize trigger rule: %s", e.msg);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to list trigger rules: %s", e.msg);
        }
        return list;
    }

    override bool deleteTriggerRule(string ruleId)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(ruleId);
            auto res = m_triggersCollection.deleteOne(query);
            return res.deletedCount > 0;
        }
        catch (Exception e)
        {
            logError("Failed to delete trigger rule (id=%s): %s", ruleId, e.msg);
            return false;
        }
    }

    override void saveProject(in ProjectRecord project)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(project.id);

            Bson update = Bson.emptyObject;
            update["$set"] = serializeToBson(project);

            UpdateOptions opts;
            opts.upsert = true;
            m_projectsCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to save project (id=%s): %s", project.id, e.msg);
        }
    }

    override bool getProject(string projectId, out ProjectRecord project)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(projectId);

            auto doc = m_projectsCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            project = deserializeBson!ProjectRecord(sanitizeBson(doc));
            return true;
        }
        catch (Exception e)
        {
            logWarn("Failed to get project (id=%s): %s", projectId, e.msg);
            return false;
        }
    }

    override ProjectRecord[] listProjects()
    {
        ProjectRecord[] list;
        try
        {
            auto cursor = m_projectsCollection.find();
            foreach (doc; cursor)
            {
                try
                {
                    list ~= deserializeBson!ProjectRecord(sanitizeBson(doc));
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize project record: %s", e.msg);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to list projects from MongoDB: %s", e.msg);
        }
        return list;
    }

    override bool deleteProject(string projectId)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(projectId);
            auto res = m_projectsCollection.deleteOne(query);
            return res.deletedCount > 0;
        }
        catch (Exception e)
        {
            logError("Failed to delete project (id=%s): %s", projectId, e.msg);
            return false;
        }
    }

    override void saveRepository(in RepositoryRecord repo)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["name"] = Bson(repo.name);

            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["name"] = Bson(repo.name);
            setFields["address"] = Bson(repo.address);
            if (repo.createdAt.length > 0)
            {
                setFields["created_at"] = Bson(repo.createdAt);
            }
            update["$set"] = setFields;

            UpdateOptions opts;
            opts.upsert = true;
            m_repositoriesCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to save repository (name=%s): %s", repo.name, e.msg);
        }
    }

    override bool getRepository(string name, out RepositoryRecord repo)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["name"] = Bson(name);

            auto doc = m_repositoriesCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            repo = deserializeBson!RepositoryRecord(doc);
            return true;
        }
        catch (Exception e)
        {
            logWarn("Failed to get repository (name=%s): %s", name, e.msg);
            return false;
        }
    }

    override RepositoryRecord[] listRepositories()
    {
        RepositoryRecord[] list;
        try
        {
            auto cursor = m_repositoriesCollection.find();
            foreach (doc; cursor)
            {
                try
                {
                    RepositoryRecord r;
                    auto pName = doc.tryIndex("name");
                    if (!pName.isNull && pName.get.type == Bson.Type.string)
                        r.name = pName.get.get!string;
                    auto pAddr = doc.tryIndex("address");
                    if (!pAddr.isNull && pAddr.get.type == Bson.Type.string)
                        r.address = pAddr.get.get!string;
                    auto pCreated = doc.tryIndex("created_at");
                    if (!pCreated.isNull && pCreated.get.type == Bson.Type.string)
                        r.createdAt = pCreated.get.get!string;
                    if (r.name.length > 0)
                    {
                        list ~= r;
                    }
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize repository: %s", e.msg);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to list repositories: %s", e.msg);
        }
        return list;
    }

    override bool deleteRepository(string name)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["name"] = Bson(name);
            auto res = m_repositoriesCollection.deleteOne(query);
            return res.deletedCount > 0;
        }
        catch (Exception e)
        {
            logError("Failed to delete repository (name=%s): %s", name, e.msg);
            return false;
        }
    }

    override void saveExecutor(in ExecutorRecord executor)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(executor.id);

            Bson update = Bson.emptyObject;
            Bson setFields = serializeToBson(executor);
            update["$set"] = setFields;

            UpdateOptions opts;
            opts.upsert = true;
            m_executorsCollection.updateOne(query, update, opts);
        }
        catch (Exception e)
        {
            logError("Failed to save executor (id=%s): %s", executor.id, e.msg);
        }
    }

    override bool getExecutor(string id, out ExecutorRecord executor)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(id);

            auto doc = m_executorsCollection.findOne(query, FindOptions.init);
            if (doc.isNull || doc.type == Bson.Type.null_)
            {
                return false;
            }

            executor = deserializeBson!ExecutorRecord(sanitizeBson(doc));
            return true;
        }
        catch (Exception e)
        {
            logWarn("Failed to get executor (id=%s): %s", id, e.msg);
            return false;
        }
    }

    override ExecutorRecord[] listExecutors()
    {
        ExecutorRecord[] list;
        try
        {
            auto cursor = m_executorsCollection.find();
            foreach (doc; cursor)
            {
                try
                {
                    list ~= deserializeBson!ExecutorRecord(sanitizeBson(doc));
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize executor record: %s", e.msg);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to list executors: %s", e.msg);
        }
        return list;
    }

    override bool deleteExecutor(string id)
    {
        try
        {
            Bson query = Bson.emptyObject;
            query["id"] = Bson(id);
            auto res = m_executorsCollection.deleteOne(query);
            return res.deletedCount > 0;
        }
        catch (Exception e)
        {
            logError("Failed to delete executor (id=%s): %s", id, e.msg);
            return false;
        }
    }
}

unittest
{
    import vibe.data.bson : serializeToBson, deserializeBson;
    import vibe.data.json : parseJsonString;
    import vibe.db.mongo.client : parseJsonToBson = serializeToBson;

    string oldMongoJson = `{"_id":{"$oid":"6abdaa639a9dd776c18490f7"},"id":"confector","created_at":"20261001T003339.8549745","default_pipeline_id":"","description":"","name":"Confector","repository_url":"","tasks":[{"id":"confector-test","name":"Test Confector","depends_on":[],"inputs":{"repositories":["confector"],"upstream_artifacts":[],"parameters":{}},"outputs":{"artifacts":[]},"script":"","steps":[{"name":"Clone Repository","type":"clone_repository","parameters":{"repository":"https://github.com/Lansatac/confector.git"},"script":"","command":"","working_directory":"","environment":{},"properties":null},{"name":"Execute Script","type":"bash","parameters":{"executable":"bash"},"script":"dub test","command":"","working_directory":"","environment":{},"properties":null}],"triggers":[],"timeout_seconds":900,"environment":{},"components":{}}],"updated_at":"20261001T003339.8549745"}`;
    auto jsonVal = parseJsonString(oldMongoJson);
    Bson bsonDoc = serializeToBson(jsonVal);
    ProjectRecord project = deserializeBson!ProjectRecord(bsonDoc);
    assert(project.id == "confector");
    assert(project.name == "Confector");
    assert(project.tasks.length == 1);
    assert(project.tasks[0].id == "confector-test");
    assert(project.tasks[0].steps.length == 2);
    assert(project.tasks[0].steps[0].type == "clone_repository");
    assert(project.tasks[0].steps[1].type == "bash");

    // Test Bson with undefined properties and sanitization
    Bson stepBson = Bson.emptyObject;
    stepBson["name"] = Bson("Clone");
    stepBson["type"] = Bson("git");
    stepBson["properties"] = Bson(Bson.Type.undefined, null);
    BuildStep step = deserializeBson!BuildStep(sanitizeBson(stepBson));
    assert(step.type == "git");

    // Test Bson with object properties sanitized to JSON string
    Bson stepBson2 = Bson.emptyObject;
    stepBson2["name"] = Bson("Build");
    stepBson2["type"] = Bson("bash");
    Bson propsObj = Bson.emptyObject;
    propsObj["flags"] = Bson("-v");
    stepBson2["properties"] = propsObj;
    BuildStep step2 = deserializeBson!BuildStep(sanitizeBson(stepBson2));
    assert(step2.type == "bash");
    assert(step2.propertiesJson.length > 0);

    // Re-serialize to BSON and deserialize
    Bson reBson = serializeToBson(project);
    ProjectRecord reProject = deserializeBson!ProjectRecord(reBson);
    assert(reProject.id == "confector");
    assert(reProject.tasks.length == 1);
}
