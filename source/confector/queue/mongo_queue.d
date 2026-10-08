module confector.queue.mongo_queue;

import confector.queue.queue;
import confector.core.model;
import confector.core.json_compat : sanitizeBson, getBsonLong, getBsonInt;

import vibe.db.mongo.client : MongoClient;
import vibe.db.mongo.collection : MongoCollection, FindOptions, UpdateOptions;
import vibe.data.json;
import vibe.data.bson;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

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
        doc["executor_type"] = Bson(message.executorType);

        try
        {
            doc["work_order"] = serializeToBson(message.workOrder);
        }
        catch (Exception e)
        {
            logError("Failed to serialize work order for task '%s' (build '%s'): %s", message.taskId, message.buildId, e.msg);
        }

        try
        {
            doc["execution_payload"] = serializeToBson(message.executionPayload);
        }
        catch (Exception e)
        {
            logError("Failed to serialize execution payload for task '%s' (build '%s'): %s", message.taskId, message.buildId, e.msg);
            doc["execution_payload"] = Bson.emptyObject;
        }

        try
        {
            doc["task_node"] = serializeToBson(message.taskNode);
        }
        catch (Exception e)
        {
            logError("Failed to serialize task node for task '%s' (build '%s'): %s", message.taskId, message.buildId, e.msg);
            doc["task_node"] = Bson.emptyObject;
        }

        doc["created_at"] = Bson(message.createdAt);
        doc["attempt"] = Bson(message.attempt);
        doc["max_attempts"] = Bson(message.maxAttempts);
        doc["timeout_seconds"] = Bson(cast(long)message.timeoutSeconds);
        doc["visible_after"] = Bson(visibleAfter);
        doc["status"] = Bson("pending");
        doc["receipt_handle"] = Bson(cast(string)null);

        try
        {
            m_queueCollection.insertOne(doc);
            logInfo("[mongo_queue] Enqueued task '%s' for build '%s' (messageId='%s', visible_after=%d)", message.taskId, message.buildId, message.messageId, visibleAfter);
        }
        catch (Exception e)
        {
            logError("[mongo_queue] Failed to insert task message into MongoDB queue (task '%s', build '%s'): %s\n%s", message.taskId, message.buildId, e.msg, e.toString());
            throw e;
        }
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30, const(string[]) supportedExecutorTypes = null)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;

        for (size_t i = 0; i < maxMessages; i++)
        {
            Bson query = Bson.emptyObject;
            Bson statusFilter = Bson.emptyObject;
            statusFilter["$in"] = serializeToBson(["pending", "in_flight"]);
            query["status"] = statusFilter;

            Bson visFilter = Bson.emptyObject;
            visFilter["$lte"] = Bson(now);
            query["visible_after"] = visFilter;

            if (supportedExecutorTypes.length > 0)
            {
                Bson[] execOr;
                foreach (t; supportedExecutorTypes)
                {
                    if (t.length == 0)
                    {
                        execOr ~= Bson(["executor_type": Bson("")]);
                        execOr ~= Bson(["executor_type": Bson(cast(string)null)]);
                        execOr ~= Bson(["executor_type": Bson(["$exists": Bson(false)])]);
                    }
                    else
                    {
                        execOr ~= Bson(["executor_type": Bson(t)]);
                    }
                }
                query["$or"] = Bson(execOr);
            }

            Bson candidate;
            try
            {
                auto cursor = m_queueCollection.find(query, FindOptions.init);
                if (cursor.empty)
                {
                    break;
                }
                candidate = cursor.front;
            }
            catch (Exception e)
            {
                logError("[mongo_queue] Failed to query MongoDB work queue during dequeue (now=%d): %s\n%s", now, e.msg, e.toString());
                break;
            }

            string msgId = candidate.tryIndex("message_id").isNull ? "" : candidate["message_id"].get!string;
            string bId = candidate.tryIndex("build_id").isNull ? "" : candidate["build_id"].get!string;
            string tId = candidate.tryIndex("task_id").isNull ? "" : candidate["task_id"].get!string;
            string stat = candidate.tryIndex("status").isNull ? "" : candidate["status"].get!string;
            long visAfter = candidate.tryIndex("visible_after").isNull ? 0 : getBsonLong(candidate["visible_after"]);
            int attempt = candidate.tryIndex("attempt").isNull ? 1 : getBsonInt(candidate["attempt"], 1);
            int maxAttempts = candidate.tryIndex("max_attempts").isNull ? 3 : getBsonInt(candidate["max_attempts"], 3);

            logInfo("[mongo_queue] Dequeue candidate found: msgId='%s', task='%s', build='%s', status='%s', visible_after=%d, attempt=%d/%d", msgId, tId, bId, stat, visAfter, attempt, maxAttempts);

            // Check if max attempts exceeded on visibility timeout expiration
            if (!candidate.tryIndex("status").isNull && candidate["status"].get!string == "in_flight")
            {
                attempt++;
                if (attempt > maxAttempts)
                {
                    // Move to dead letter
                    logWarn("[mongo_queue] Message '%s' exceeded max attempts (%d/%d), moving to dead letter queue", msgId, attempt, maxAttempts);
                    Bson dlDoc = candidate;
                    dlDoc["error_reason"] = Bson("Visibility timeout expired and max attempts reached");
                    dlDoc["dead_lettered_at"] = Bson(Clock.currTime.toISOString());
                    try
                    {
                        m_deadLetterCollection.insertOne(dlDoc);
                        Bson delQuery = Bson.emptyObject;
                        delQuery["message_id"] = Bson(msgId);
                        m_queueCollection.deleteOne(delQuery);
                    }
                    catch (Exception e)
                    {
                        logError("[mongo_queue] Failed to dead-letter message '%s' in MongoDB queue: %s\n%s", msgId, e.msg, e.toString());
                    }
                    continue;
                }
            }

            string receiptHandle = "rcpt_" ~ randomUUID().toString();
            long newVisibleAfter = now + visibilityTimeoutSeconds;

            Bson updateQuery = Bson.emptyObject;
            updateQuery["message_id"] = Bson(msgId);
            Bson updateVisFilter = Bson.emptyObject;
            updateVisFilter["$lte"] = Bson(now);
            updateQuery["visible_after"] = updateVisFilter;

            Bson update = Bson.emptyObject;
            Bson setFields = Bson.emptyObject;
            setFields["status"] = Bson("in_flight");
            setFields["receipt_handle"] = Bson(receiptHandle);
            setFields["visible_after"] = Bson(newVisibleAfter);
            setFields["attempt"] = Bson(attempt);
            update["$set"] = setFields;

            try
            {
                auto modRes = m_queueCollection.updateOne(updateQuery, update);
                logInfo("[mongo_queue] Claim update for message '%s' (receiptHandle='%s'): matched=%d, modified=%d", msgId, receiptHandle, modRes.matchedCount, modRes.modifiedCount);
                if (modRes.matchedCount > 0)
                {
                    TaskQueueMessage msg;
                    msg.messageId = msgId;
                    msg.receiptHandle = receiptHandle;
                    msg.buildId = bId;
                    msg.taskId = tId;
                    msg.nodeFingerprint = candidate.tryIndex("node_fingerprint").isNull ? "" : candidate["node_fingerprint"].get!string;

                    try
                    {
                        if (!candidate.tryIndex("work_order").isNull && candidate["work_order"].type != Bson.Type.null_)
                        {
                            msg.workOrder = deserializeBson!WorkOrder(sanitizeBson(candidate["work_order"]));
                        }
                    }
                    catch (Exception e)
                    {
                        logError("[mongo_queue] Failed to deserialize work order for task '%s' (msg '%s', build '%s'): %s\n%s", msg.taskId, msgId, msg.buildId, e.msg, e.toString());
                    }

                    try
                    {
                        if (!candidate.tryIndex("execution_payload").isNull && candidate["execution_payload"].type != Bson.Type.null_)
                        {
                            msg.executionPayload = deserializeBson!TaskExecutionPayload(sanitizeBson(candidate["execution_payload"]));
                        }
                    }
                    catch (Exception e)
                    {
                        logError("[mongo_queue] Failed to deserialize execution payload for task '%s' (msg '%s', build '%s'): %s\n%s", msg.taskId, msgId, msg.buildId, e.msg, e.toString());
                    }

                    try
                    {
                        if (!candidate.tryIndex("task_node").isNull && candidate["task_node"].type != Bson.Type.null_)
                        {
                            msg.taskNode = deserializeBson!TaskNode(sanitizeBson(candidate["task_node"]));
                        }
                    }
                    catch (Exception e)
                    {
                        logError("[mongo_queue] Failed to deserialize task node for task '%s' (msg '%s', build '%s'): %s\n%s", msg.taskId, msgId, msg.buildId, e.msg, e.toString());
                    }

                    msg.createdAt = candidate.tryIndex("created_at").isNull ? "" : candidate["created_at"].get!string;
                    msg.attempt = attempt;
                    msg.maxAttempts = maxAttempts;
                    msg.timeoutSeconds = candidate.tryIndex("timeout_seconds").isNull ? 900 : cast(size_t)getBsonLong(candidate["timeout_seconds"], 900);
                    msg.visibleAfterUnix = newVisibleAfter;

                    result ~= msg;
                    logInfo("[mongo_queue] Successfully claimed and delivered message '%s' for task '%s' (build '%s')", msgId, msg.taskId, msg.buildId);
                }
                else
                {
                    logWarn("[mongo_queue] Could not claim message '%s' (matchedCount=0, likely updated concurrently)", msgId);
                }
            }
            catch (Exception e)
            {
                logError("[mongo_queue] Failed to update and claim message '%s' from MongoDB work queue: %s\n%s", msgId, e.msg, e.toString());
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
        logInfo("[mongo_queue] Ack receiptHandle '%s': deletedCount=%d", receiptHandle, res.deletedCount);
        if (res.deletedCount == 0)
        {
            throw new Exception(format("Message with receipt handle '%s' not found or already completed in MongoDB queue", receiptHandle));
        }
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        logInfo("[mongo_queue] Nack receiptHandle '%s' (requeue=%s, reason='%s')", receiptHandle, requeue, errorReason);
        Bson query = Bson.emptyObject;
        query["receipt_handle"] = Bson(receiptHandle);
        query["status"] = Bson("in_flight");

        auto doc = m_queueCollection.findOne(query, FindOptions.init);
        if (doc.isNull || doc.type == Bson.Type.null_)
        {
            return;
        }

        int attempt = getBsonInt(doc["attempt"], 1);
        int maxAttempts = getBsonInt(doc["max_attempts"], 3);

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
            msg.messageId = doc.tryIndex("message_id").isNull ? "" : doc["message_id"].get!string;
            msg.buildId = doc.tryIndex("build_id").isNull ? "" : doc["build_id"].get!string;
            msg.taskId = doc.tryIndex("task_id").isNull ? "" : doc["task_id"].get!string;
            msg.nodeFingerprint = doc.tryIndex("node_fingerprint").isNull ? "" : doc["node_fingerprint"].get!string;

            try
            {
                if (!doc.tryIndex("execution_payload").isNull && doc["execution_payload"].type != Bson.Type.null_)
                {
                    msg.executionPayload = deserializeBson!TaskExecutionPayload(sanitizeBson(doc["execution_payload"]));
                }
            }
            catch (Exception e)
            {
                logError("Failed to deserialize dead-letter execution payload (msg '%s'): %s", msg.messageId, e.msg);
            }

            try
            {
                if (!doc.tryIndex("task_node").isNull && doc["task_node"].type != Bson.Type.null_)
                {
                    msg.taskNode = deserializeBson!TaskNode(sanitizeBson(doc["task_node"]));
                }
            }
            catch (Exception e)
            {
                logError("Failed to deserialize dead-letter task node (msg '%s'): %s", msg.messageId, e.msg);
            }

            msg.createdAt = doc.tryIndex("created_at").isNull ? "" : doc["created_at"].get!string;
            msg.attempt = doc.tryIndex("attempt").isNull ? 1 : getBsonInt(doc["attempt"], 1);
            msg.maxAttempts = doc.tryIndex("max_attempts").isNull ? 3 : getBsonInt(doc["max_attempts"], 3);
            msg.errorReason = doc.tryIndex("error_reason").isNull ? "" : doc["error_reason"].get!string;
            result ~= msg;
        }
        return result;
    }

    override ulong getPendingCount()
    {
        Bson query = Bson.emptyObject;
        query["status"] = Bson("pending");
        Bson visFilter = Bson.emptyObject;
        visFilter["$lte"] = Bson(currentUnixTime());
        query["visible_after"] = visFilter;

        return m_queueCollection.countDocuments(query);
    }

    override TaskQueueMessage[] getPendingMessages(size_t limit = 50)
    {
        TaskQueueMessage[] result;
        try
        {
            Bson query = Bson.emptyObject;
            Bson statusFilter = Bson.emptyObject;
            statusFilter["$in"] = serializeToBson(["pending", "in_flight"]);
            query["status"] = statusFilter;

            Bson visFilter = Bson.emptyObject;
            visFilter["$lte"] = Bson(currentUnixTime());
            query["visible_after"] = visFilter;

            FindOptions opts;
            opts.limit = cast(int)limit;
            auto cursor = m_queueCollection.find(query, opts);
            while (!cursor.empty)
            {
                Bson candidate = cursor.front;
                cursor.popFront();

                TaskQueueMessage msg;
                msg.messageId = candidate.tryIndex("message_id").isNull ? "" : candidate["message_id"].get!string;
                if (!candidate.tryIndex("receipt_handle").isNull && candidate["receipt_handle"].type == Bson.Type.string)
                    msg.receiptHandle = candidate["receipt_handle"].get!string;
                msg.buildId = candidate.tryIndex("build_id").isNull ? "" : candidate["build_id"].get!string;
                msg.taskId = candidate.tryIndex("task_id").isNull ? "" : candidate["task_id"].get!string;
                msg.executorType = candidate.tryIndex("executor_type").isNull ? "" : candidate["executor_type"].get!string;
                if (!candidate.tryIndex("node_fingerprint").isNull && candidate["node_fingerprint"].type == Bson.Type.string)
                    msg.nodeFingerprint = candidate["node_fingerprint"].get!string;

                try
                {
                    if (!candidate.tryIndex("work_order").isNull && candidate["work_order"].type != Bson.Type.null_)
                    {
                        msg.workOrder = deserializeBson!WorkOrder(sanitizeBson(candidate["work_order"]));
                    }
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize pending work order (msg '%s'): %s", msg.messageId, e.msg);
                }

                try
                {
                    if (!candidate.tryIndex("execution_payload").isNull && candidate["execution_payload"].type != Bson.Type.null_)
                    {
                        msg.executionPayload = deserializeBson!TaskExecutionPayload(sanitizeBson(candidate["execution_payload"]));
                    }
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize pending execution payload (msg '%s'): %s", msg.messageId, e.msg);
                }

                try
                {
                    if (!candidate.tryIndex("task_node").isNull && candidate["task_node"].type != Bson.Type.null_)
                    {
                        msg.taskNode = deserializeBson!TaskNode(sanitizeBson(candidate["task_node"]));
                    }
                }
                catch (Exception e)
                {
                    logError("Failed to deserialize pending task node (msg '%s'): %s", msg.messageId, e.msg);
                }

                if (!candidate.tryIndex("created_at").isNull && candidate["created_at"].type == Bson.Type.string)
                    msg.createdAt = candidate["created_at"].get!string;
                msg.attempt = candidate.tryIndex("attempt").isNull ? 1 : getBsonInt(candidate["attempt"], 1);
                msg.maxAttempts = candidate.tryIndex("max_attempts").isNull ? 3 : getBsonInt(candidate["max_attempts"], 3);
                msg.timeoutSeconds = candidate.tryIndex("timeout_seconds").isNull ? 900 : cast(size_t)getBsonLong(candidate["timeout_seconds"], 900);
                msg.visibleAfterUnix = candidate.tryIndex("visible_after").isNull ? currentUnixTime() : getBsonLong(candidate["visible_after"], currentUnixTime());
                result ~= msg;
            }
        }
        catch (Exception e)
        {
            logError("Failed to get pending messages from MongoDB queue: %s", e.msg);
        }
        return result;
    }
}

unittest
{
    import std.json : parseJSON;

    // Test TaskQueueMessage BSON serialization & deserialization with complex TaskNode
    TaskQueueMessage msg;
    msg.messageId = "test-msg-1";
    msg.buildId = "bld-123";
    msg.taskId = "build-task";

    TaskNode node;
    node.id = "build-task";
    node.name = "Build Task";
    node.steps = [
        BuildStep("Clone", "clone_repository", ["repository": "https://example.com/repo.git"], "", "", "", ""),
        BuildStep("Compile", "bash", ["executable": "bash"], "dub build", "", "", "{\"flags\": \"-v\"}")
    ];
    node.setCustomComponent("custom_prop", parseJSON("{\"enabled\": true}"));
    msg.taskNode = node;

    msg.executionPayload.expectedOutputs = [OutputArtifactDecl("app", "out/app")];
    Bson nodeBson = serializeToBson(msg.taskNode);
    Bson payloadBson = serializeToBson(msg.executionPayload);
    TaskExecutionPayload deserializedPayload = deserializeBson!TaskExecutionPayload(sanitizeBson(payloadBson));
    assert(deserializedPayload.expectedOutputs.length == 1);
    assert(deserializedPayload.expectedOutputs[0].path == "out/app");

    TaskNode deserializedNode = deserializeBson!TaskNode(sanitizeBson(nodeBson));
    assert(deserializedNode.id == "build-task");
    assert(deserializedNode.steps.length == 2);
    assert(deserializedNode.steps[0].type == "clone_repository");
    assert(deserializedNode.steps[1].type == "bash");
    assert(deserializedNode.hasCustomComponent("custom_prop"));

    // Test dequeue query structure
    long now = 1791006690;
    Bson query = Bson.emptyObject;
    Bson statusFilter = Bson.emptyObject;
    statusFilter["$in"] = serializeToBson(["pending", "in_flight"]);
    query["status"] = statusFilter;

    Bson visFilter = Bson.emptyObject;
    visFilter["$lte"] = Bson(now);
    query["visible_after"] = visFilter;

    assert(!query.tryIndex("status").isNull);
    assert(!query["status"].tryIndex("$in").isNull);
    assert(query["status"]["$in"].type == Bson.Type.array);
    assert(query["status"]["$in"].length == 2);
    assert(!query.tryIndex("visible_after").isNull);
    assert(!query["visible_after"].tryIndex("$lte").isNull);
    assert(query["visible_after"]["$lte"].get!long == now);
}
