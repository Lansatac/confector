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

    this(MongoClient client, string dbName = "confector")
    {
        m_statusCollection = client.getCollection(format("%s.task_statuses", dbName));
        m_cacheCollection = client.getCollection(format("%s.fingerprint_cache", dbName));
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
}
