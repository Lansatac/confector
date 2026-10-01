module confector.storage.mongo_repository;

import confector.core.model;
import confector.core.storage;

import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.collection : MongoCollection, FindOptions, UpdateOptions;
import vibe.data.json;
import vibe.data.bson;

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

    this(MongoClient client, string dbName = "confector")
    {
        m_statusCollection = client.getCollection(format("%s.task_statuses", dbName));
        m_cacheCollection = client.getCollection(format("%s.fingerprint_cache", dbName));
        m_buildsCollection = client.getCollection(format("%s.builds", dbName));
        m_logsCollection = client.getCollection(format("%s.build_logs", dbName));
        m_triggersCollection = client.getCollection(format("%s.triggers", dbName));
        m_projectsCollection = client.getCollection(format("%s.projects", dbName));
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
            // Fallback or log if mongo communication fails
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

            build = deserializeBson!BuildRecord(doc);
            return true;
        }
        catch (Exception e)
        {
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
                    list ~= deserializeBson!BuildRecord(doc);
                }
                catch (Exception e) {}
            }
        }
        catch (Exception e)
        {
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
                    list ~= deserializeBson!TriggerRuleRecord(doc);
                }
                catch (Exception e) {}
            }
        }
        catch (Exception e)
        {
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

            project = deserializeBson!ProjectRecord(doc);
            return true;
        }
        catch (Exception e)
        {
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
                    list ~= deserializeBson!ProjectRecord(doc);
                }
                catch (Exception e) {}
            }
        }
        catch (Exception e)
        {
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
            return false;
        }
    }
}
