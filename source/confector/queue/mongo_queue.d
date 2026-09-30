module confector.queue.mongo_queue;

import confector.queue.queue;
import confector.core.model;

import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.collection : MongoCollection, FindOptions, UpdateOptions;
import vibe.data.json;
import vibe.data.bson;

import std.format : format;
import std.datetime.systime : Clock;
import std.uuid : randomUUID;

/**
 * MongoDB-backed implementation of WorkQueue for persistent multi-worker environments.
 */
class MongoWorkQueue : WorkQueue
{
    private MongoCollection m_queueCollection;
    private MongoCollection m_deadLetterCollection;

    this(MongoClient client, string dbName = "confector")
    {
        m_queueCollection = client.getCollection(format("%s.work_queue", dbName));
        m_deadLetterCollection = client.getCollection(format("%s.dead_letters", dbName));
    }

    private static long currentUnixTime()
    {
        return Clock.currTime.toUnixTime();
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

        long now = currentUnixTime();
        long visibleAfter = message.visibleAfterUnix > 0 ? message.visibleAfterUnix : now;

        Bson doc = Bson.emptyObject;
        doc["message_id"] = Bson(message.messageId);
        doc["build_id"] = Bson(message.buildId);
        doc["task_id"] = Bson(message.taskId);
        doc["node_fingerprint"] = Bson(message.nodeFingerprint);
        doc["execution_payload"] = serializeToBson(message.executionPayload);
        doc["task_node"] = serializeToBson(message.taskNode);
        doc["created_at"] = Bson(message.createdAt);
        doc["attempt"] = Bson(message.attempt);
        doc["max_attempts"] = Bson(message.maxAttempts);
        doc["timeout_seconds"] = Bson(cast(long)message.timeoutSeconds);
        doc["visible_after"] = Bson(visibleAfter);
        doc["status"] = Bson("pending");
        doc["receipt_handle"] = Bson(cast(string)null);

        m_queueCollection.insertOne(doc);
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;

        for (size_t i = 0; i < maxMessages; i++)
        {
            Bson query = Bson.emptyObject;
            query["status"] = Bson.emptyObject;
            query["status"]["$in"] = serializeToBson(["pending", "in_flight"]);
            query["visible_after"] = Bson.emptyObject;
            query["visible_after"]["$lte"] = Bson(now);

            auto cursor = m_queueCollection.find(query, FindOptions.init);
            if (cursor.empty)
            {
                break;
            }

            Bson candidate = cursor.front;
            string msgId = candidate["message_id"].get!string;
            int attempt = candidate["attempt"].to!int;
            int maxAttempts = candidate["max_attempts"].to!int;

            // Check if max attempts exceeded on visibility timeout expiration
            if (candidate["status"].get!string == "in_flight")
            {
                attempt++;
                if (attempt > maxAttempts)
                {
                    // Move to dead letter
                    Bson dlDoc = candidate;
                    dlDoc["error_reason"] = Bson("Visibility timeout expired and max attempts reached");
                    dlDoc["dead_lettered_at"] = Bson(Clock.currTime.toISOString());
                    m_deadLetterCollection.insertOne(dlDoc);

                    Bson delQuery = Bson.emptyObject;
                    delQuery["message_id"] = Bson(msgId);
                    m_queueCollection.deleteOne(delQuery);
                    continue;
                }
            }

            string receiptHandle = "rcpt_" ~ randomUUID().toString();
            long newVisibleAfter = now + visibilityTimeoutSeconds;

            Bson updateQuery = Bson.emptyObject;
            updateQuery["message_id"] = Bson(msgId);
            updateQuery["visible_after"] = Bson.emptyObject;
            updateQuery["visible_after"]["$lte"] = Bson(now);

            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["status"] = Bson("in_flight");
            setFields["receipt_handle"] = Bson(receiptHandle);
            setFields["visible_after"] = Bson(newVisibleAfter);
            setFields["attempt"] = Bson(attempt);
            update["$set"] = setFields;

            auto modRes = m_queueCollection.updateOne(updateQuery, update);
            if (modRes.matchedCount > 0)
            {
                TaskQueueMessage msg;
                msg.messageId = msgId;
                msg.receiptHandle = receiptHandle;
                msg.buildId = candidate["build_id"].get!string;
                msg.taskId = candidate["task_id"].get!string;
                msg.nodeFingerprint = candidate["node_fingerprint"].get!string;
                msg.executionPayload = deserializeBson!TaskExecutionPayload(candidate["execution_payload"]);
                msg.taskNode = deserializeBson!TaskNode(candidate["task_node"]);
                msg.createdAt = candidate["created_at"].get!string;
                msg.attempt = attempt;
                msg.maxAttempts = maxAttempts;
                msg.timeoutSeconds = cast(size_t)candidate["timeout_seconds"].to!long;
                msg.visibleAfterUnix = newVisibleAfter;

                result ~= msg;
            }
        }

        return result;
    }

    override void ack(string receiptHandle)
    {
        Bson query = Bson.emptyObject;
        query["receipt_handle"] = Bson(receiptHandle);
        query["status"] = Bson("in_flight");

        auto res = m_queueCollection.deleteOne(query);
        if (res.deletedCount == 0)
        {
            throw new Exception(format("Message with receipt handle '%s' not found or already completed in MongoDB queue", receiptHandle));
        }
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        Bson query = Bson.emptyObject;
        query["receipt_handle"] = Bson(receiptHandle);
        query["status"] = Bson("in_flight");

        auto doc = m_queueCollection.findOne(query, FindOptions.init);
        if (doc.isNull || doc.type == Bson.Type.null_)
        {
            return;
        }

        int attempt = doc["attempt"].to!int;
        int maxAttempts = doc["max_attempts"].to!int;

        if (!requeue || attempt >= maxAttempts)
        {
            // Move to dead letter
            Bson dlDoc = doc;
            dlDoc["error_reason"] = Bson(errorReason.length > 0 ? errorReason : "NACK with no retry");
            dlDoc["dead_lettered_at"] = Bson(Clock.currTime.toISOString());
            m_deadLetterCollection.insertOne(dlDoc);

            m_queueCollection.deleteOne(query);
        }
        else
        {
            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["status"] = Bson("pending");
            setFields["receipt_handle"] = Bson(cast(string)null);
            setFields["attempt"] = Bson(attempt + 1);
            setFields["visible_after"] = Bson(currentUnixTime());
            if (errorReason.length > 0)
            {
                setFields["last_error"] = Bson(errorReason);
            }
            update["$set"] = setFields;

            m_queueCollection.updateOne(query, update);
        }
    }

    override void heartbeat(string receiptHandle, long extensionSeconds = 30)
    {
        long newVisibleAfter = currentUnixTime() + extensionSeconds;

        Bson query = Bson.emptyObject;
        query["receipt_handle"] = Bson(receiptHandle);
        query["status"] = Bson("in_flight");

        Bson update = Bson.emptyObject;
        Bson setFields = Bson.emptyObject;
        setFields["visible_after"] = Bson(newVisibleAfter);
        update["$set"] = setFields;

        auto res = m_queueCollection.updateOne(query, update);
        if (res.matchedCount == 0)
        {
            throw new Exception(format("Cannot heartbeat MongoDB message; receipt handle '%s' not found or expired", receiptHandle));
        }
    }

    override TaskQueueMessage[] getDeadLetterMessages()
    {
        TaskQueueMessage[] result;
        auto cursor = m_deadLetterCollection.find(Bson.emptyObject, FindOptions.init);
        while (!cursor.empty)
        {
            Bson doc = cursor.front;
            cursor.popFront();

            TaskQueueMessage msg;
            msg.messageId = doc["message_id"].get!string;
            msg.buildId = doc["build_id"].get!string;
            msg.taskId = doc["task_id"].get!string;
            msg.nodeFingerprint = doc["node_fingerprint"].get!string;
            msg.executionPayload = deserializeBson!TaskExecutionPayload(doc["execution_payload"]);
            msg.taskNode = deserializeBson!TaskNode(doc["task_node"]);
            msg.createdAt = doc["created_at"].get!string;
            msg.attempt = doc["attempt"].to!int;
            msg.maxAttempts = doc["max_attempts"].to!int;
            msg.errorReason = doc.tryIndex("error_reason").isNull ? "" : doc["error_reason"].get!string;
            result ~= msg;
        }
        return result;
    }

    override ulong getPendingCount()
    {
        Bson query = Bson.emptyObject;
        query["status"] = Bson("pending");
        query["visible_after"] = Bson.emptyObject;
        query["visible_after"]["$lte"] = Bson(currentUnixTime());

        return m_queueCollection.countDocuments(query);
    }
}
