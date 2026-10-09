module plugins.queue.mongo;

import std.format;
import vibe.data.json : Json;

import confector.mongo_helpers : document, bson_value, toJsonString, fromJsonString;
import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, PluginCategory, WorkQueuePlugin, ConfigDefinition;
import kaleidic.mongo_standalone : MongoConnection;

import std.datetime.systime : Clock;
import std.uuid : randomUUID;

/**
 * MongoDB-backed implementation of WorkQueue as a dynamic plugin.
 */
class MongoQueuePlugin : WorkQueuePlugin, WorkQueue
{
    private PluginContext m_context;
    private MongoConnection m_connection;
    private string m_dbName;

    private string col(string name) { return m_dbName ~ "." ~ name; }

    @property string name() const { return "mongo-queue"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "MongoDB-backed work queue"; }
    @property PluginCategory category() const { return PluginCategory.queue; }

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
            throw new Exception("[mongo-queue] PluginContext must not be null; the host failed to provide configuration.");
        }

        m_context = context;
        string connectionString = context.config.getString("connectionString", "mongodb://mongo:27017");
        m_dbName = context.config.getString("dbName", "confector");

        m_connection = new MongoConnection(connectionString);
        m_context.info(format("Connected to MongoDB at %s, database: %s", connectionString, m_dbName));
    }

    void shutdown()
    {
    }

    @property string backendType() const pure nothrow @safe
    {
        return "mongo";
    }

    private static long currentUnixTime()
    {
        return Clock.currTime.toUnixTime();
    }

    // Build a BSON document from a TaskQueueMessage for storage
    private document messageToDoc(TaskQueueMessage msg, long visibleAfter)
    {
        bson_value[] fields;
        fields ~= bson_value("message_id", msg.messageId);
        fields ~= bson_value("build_id", msg.buildId);
        fields ~= bson_value("task_id", msg.taskId);
        fields ~= bson_value("node_fingerprint", msg.nodeFingerprint);
        fields ~= bson_value("executor_type", msg.executorType);
        fields ~= bson_value("created_at", msg.createdAt);
        fields ~= bson_value("attempt", msg.attempt);
        fields ~= bson_value("max_attempts", msg.maxAttempts);
        fields ~= bson_value("timeout_seconds", cast(long)msg.timeoutSeconds);
        fields ~= bson_value("visible_after", visibleAfter);
        fields ~= bson_value("status", "pending");

        try { fields ~= bson_value("work_order_json", toJsonString(msg.workOrder)); }
        catch (Exception e) { m_context.error(format("Failed to serialize work order: %s", e.msg)); fields ~= bson_value("work_order_json", ""); }

        try { fields ~= bson_value("execution_payload_json", toJsonString(msg.executionPayload)); }
        catch (Exception e) { m_context.error(format("Failed to serialize execution payload: %s", e.msg)); fields ~= bson_value("execution_payload_json", ""); }

        try { fields ~= bson_value("task_node_json", toJsonString(msg.taskNode)); }
        catch (Exception e) { m_context.error(format("Failed to serialize task node: %s", e.msg)); fields ~= bson_value("task_node_json", ""); }

        return document(fields);
    }

    // Parse a BSON document into a TaskQueueMessage
    private bool parseQueueMessage(document doc, out TaskQueueMessage msg)
    {
        msg = TaskQueueMessage.init;

        auto msgId = doc["message_id"];
        if (msgId !is bson_value.init) msg.messageId = msgId.toString();

        auto buildId = doc["build_id"];
        if (buildId !is bson_value.init) msg.buildId = buildId.toString();

        auto taskId = doc["task_id"];
        if (taskId !is bson_value.init) msg.taskId = taskId.toString();

        auto fp = doc["node_fingerprint"];
        if (fp !is bson_value.init) msg.nodeFingerprint = fp.toString();

        auto execType = doc["executor_type"];
        if (execType !is bson_value.init) msg.executorType = execType.toString();

        auto createdAt = doc["created_at"];
        if (createdAt !is bson_value.init) msg.createdAt = createdAt.toString();

        auto attempt = doc["attempt"];
        if (attempt !is bson_value.init) msg.attempt = attempt.get!int;
        else msg.attempt = 1;

        auto maxAttempts = doc["max_attempts"];
        if (maxAttempts !is bson_value.init) msg.maxAttempts = maxAttempts.get!int;
        else msg.maxAttempts = 3;

        auto timeout = doc["timeout_seconds"];
        if (timeout !is bson_value.init) msg.timeoutSeconds = cast(size_t)timeout.get!long;
        else msg.timeoutSeconds = 900;

        auto woJson = doc["work_order_json"];
        if (woJson !is bson_value.init)
        {
            try { msg.workOrder = fromJsonString!WorkOrder(woJson.toString()); }
            catch (Exception e) { m_context.error(format("Failed to deserialize work order: %s", e.msg)); }
        }

        auto epJson = doc["execution_payload_json"];
        if (epJson !is bson_value.init)
        {
            try { msg.executionPayload = fromJsonString!TaskExecutionPayload(epJson.toString()); }
            catch (Exception e) { m_context.error(format("Failed to deserialize execution payload: %s", e.msg)); }
        }

        auto tnJson = doc["task_node_json"];
        if (tnJson !is bson_value.init)
        {
            try { msg.taskNode = fromJsonString!TaskNode(tnJson.toString()); }
            catch (Exception e) { m_context.error(format("Failed to deserialize task node: %s", e.msg)); }
        }

        return true;
    }

    override void enqueue(TaskQueueMessage message)
    {
        if (message.messageId.length == 0)
            message.messageId = "msg_" ~ randomUUID().toString();
        if (message.createdAt.length == 0)
            message.createdAt = Clock.currTime.toISOString();
        if (message.maxAttempts <= 0)
            message.maxAttempts = 3;

        long now = currentUnixTime();
        long visibleAfter = message.visibleAfterUnix > 0 ? message.visibleAfterUnix : now;

        auto doc = messageToDoc(message, visibleAfter);

        m_connection.insert(false, col("work_queue"), [doc]);
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30, const(string[]) supportedExecutorTypes = null)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;

        for (size_t i = 0; i < maxMessages; i++)
        {
            bson_value[] queryFields;
            queryFields ~= bson_value("status", "pending");
            bson_value[] lteFields;
            lteFields ~= bson_value("$lte", now);
            queryFields ~= bson_value("visible_after", document(lteFields));

            if (supportedExecutorTypes.length > 0)
            {
                bson_value[] orClauses;
                foreach (t; supportedExecutorTypes)
                {
                    if (t.length == 0)
                    {
                        orClauses ~= bson_value("", document([bson_value("executor_type", "")]));
                        orClauses ~= bson_value("", document([bson_value("executor_type", cast(string)null)]));
                    }
                    else
                    {
                        orClauses ~= bson_value("", document([bson_value("executor_type", t)]));
                    }
                }
                queryFields ~= bson_value("$or", document(orClauses));
            }

            auto query = document(queryFields);

            document candidate;
            auto reply = m_connection.query(col("work_queue"), 0, 1, query);
            if (reply.documents.length == 0) break;
            candidate = reply.documents[0];

            string msgId = "";
            auto msgIdField = candidate["message_id"];
            if (msgIdField !is bson_value.init)
                msgId = msgIdField.toString();

            string receiptHandle = "rcpt_" ~ randomUUID().toString();
            long newVisibleAfter = now + visibilityTimeoutSeconds;

            auto updateQuery = document([bson_value("message_id", msgId)]);

            bson_value[] setFields;
            setFields ~= bson_value("status", "in_flight");
            setFields ~= bson_value("receipt_handle", receiptHandle);
            setFields ~= bson_value("visible_after", newVisibleAfter);
            auto attemptField = candidate["attempt"];
            if (attemptField !is bson_value.init)
                setFields ~= bson_value("attempt", attemptField.get!int);

            auto updateDoc = document([bson_value("$set", document(setFields))]);
            m_connection.update(col("work_queue"), false, false, updateQuery, updateDoc);

            TaskQueueMessage msg;
            parseQueueMessage(candidate, msg);
            msg.receiptHandle = receiptHandle;
            msg.visibleAfterUnix = newVisibleAfter;
            result ~= msg;
        }

        return result;
    }

    override void ack(string receiptHandle)
    {
        auto query = document([
            bson_value("receipt_handle", receiptHandle),
            bson_value("status", "in_flight")
        ]);
        m_connection.delete_(col("work_queue"), true, query);
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        auto query = document([
            bson_value("receipt_handle", receiptHandle),
            bson_value("status", "in_flight")
        ]);

        auto reply = m_connection.query(col("work_queue"), 0, 1, query);
        if (reply.documents.length == 0) return;

        document doc = reply.documents[0];

        int attempt = 1;
        auto attField = doc["attempt"];
        if (attField !is bson_value.init) attempt = attField.get!int;

        int maxAttempts = 3;
        auto maxField = doc["max_attempts"];
        if (maxField !is bson_value.init) maxAttempts = maxField.get!int;

        string msgId = "";
        auto msgIdField = doc["message_id"];
        if (msgIdField !is bson_value.init)
            msgId = msgIdField.toString();

        if (!requeue || attempt >= maxAttempts)
        {
            bson_value[] dlFields;
            foreach (bv; doc.values())
                dlFields ~= bson_value(cast(string)bv.name(), cast(bson_value)bv);
            dlFields ~= bson_value("error_reason", errorReason.length > 0 ? errorReason : "NACK with no retry");
            dlFields ~= bson_value("dead_lettered_at", Clock.currTime.toISOString());

            m_connection.insert(false, col("dead_letters"), [document(dlFields)]);

            auto delQuery = document([bson_value("message_id", msgId)]);
            m_connection.delete_(col("work_queue"), true, delQuery);
        }
        else
        {
            auto updateQuery = document([bson_value("receipt_handle", receiptHandle)]);

            bson_value[] setFields;
            setFields ~= bson_value("status", "pending");
            setFields ~= bson_value("receipt_handle", cast(string)null);
            setFields ~= bson_value("attempt", attempt + 1);
            setFields ~= bson_value("visible_after", currentUnixTime());

            auto updateDoc = document([bson_value("$set", document(setFields))]);
            m_connection.update(col("work_queue"), false, false, updateQuery, updateDoc);
        }
    }

    override void heartbeat(string receiptHandle, long extensionSeconds = 30)
    {
        long newVisibleAfter = currentUnixTime() + extensionSeconds;
        auto query = document([
            bson_value("receipt_handle", receiptHandle),
            bson_value("status", "in_flight")
        ]);

        bson_value[] setFields;
        setFields ~= bson_value("visible_after", newVisibleAfter);
        auto updateDoc = document([bson_value("$set", document(setFields))]);

        m_connection.update(col("work_queue"), false, false, query, updateDoc);
    }

    override TaskQueueMessage[] getDeadLetterMessages()
    {
        TaskQueueMessage[] result;
        auto reply = m_connection.query(col("dead_letters"), 0, 0, document([]));
        foreach (doc; reply.documents)
        {
            TaskQueueMessage msg;
            parseQueueMessage(doc, msg);

            auto errReason = doc["error_reason"];
            if (errReason !is bson_value.init)
                msg.errorReason = errReason.toString();

            result ~= msg;
        }
        return result;
    }

    override ulong getPendingCount()
    {
        long now = currentUnixTime();
        bson_value[] queryFields;
        queryFields ~= bson_value("status", "pending");
        bson_value[] lteFields;
        lteFields ~= bson_value("$lte", now);
        queryFields ~= bson_value("visible_after", document(lteFields));
        auto query = document(queryFields);

        auto reply = m_connection.query(col("work_queue"), 0, 0, query);
        return cast(ulong)reply.documents.length;
    }

    override TaskQueueMessage[] getPendingMessages(size_t limit = 50)
    {
        TaskQueueMessage[] result;
        long now = currentUnixTime();
        bson_value[] queryFields;
        queryFields ~= bson_value("status", "pending");
        bson_value[] lteFields;
        lteFields ~= bson_value("$lte", now);
        queryFields ~= bson_value("visible_after", document(lteFields));
        auto query = document(queryFields);

        auto reply = m_connection.query(col("work_queue"), 0, cast(int)limit, query);
        foreach (doc; reply.documents)
        {
            TaskQueueMessage msg;
            parseQueueMessage(doc, msg);

            auto rh = doc["receipt_handle"];
            if (rh !is bson_value.init)
                msg.receiptHandle = rh.toString();

            auto visAfter = doc["visible_after"];
            if (visAfter !is bson_value.init)
                msg.visibleAfterUnix = visAfter.get!long;

            result ~= msg;
        }
        return result;
    }
}

extern(C) export Plugin confector_create_plugin()
{
    return new MongoQueuePlugin();
}
