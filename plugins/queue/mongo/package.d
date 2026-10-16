module plugins.queue.mongo;

import confector.mongo_helpers : bson_value, document, MongoConnection;
import confector.plugin_api.dispatch_queue;
import confector.plugin_api.plugin : Plugin, PluginContext, PluginCategory, DispatchQueuePlugin, ConfigDefinition;
import core.time : Duration;
import std.format : format;
import vibe.data.json : Json;

/**
 * DispatchQueue on MongoDB (requires MongoDB 4.2 or later).
 *
 * Storage, in the configured database:
 * - dispatch_queues: one document per ensured queue, with the queue name as _id.
 * - dispatch_messages: one document per message: _id (a random UUID), queue, body (the message
 *   as compact JSON text, so field names and number types round-trip exactly), visibleAt (a date),
 *   receipt (the current delivery's token, or null when no delivery holds it) and receiveCount.
 *
 * Correctness rests on single-document atomic updates and the server's clock:
 * - Every lease and delay time is computed and compared with $$NOW on the server, so leases
 *   behave the same however many control-plane instances there are and whatever their clocks say.
 * - receive is one findAndModify per message that filters on visibleAt <= $$NOW and, in the same
 *   atomic update, moves visibleAt forward and stores a new receipt token. Two receivers can
 *   never lease the same message, and an expired lease is simply receivable again.
 * - ack, extend and release filter on the message id and receipt token (extend and release also
 *   on an unexpired lease), so a receipt from an earlier delivery never matches once the message
 *   has been delivered again.
 *
 * Each instance uses one connection and serializes its own calls; use one instance per
 * connection.
 */
class MongoDispatchQueue : DispatchQueue
{
    private enum queuesCollection = "dispatch_queues";
    private enum messagesCollection = "dispatch_messages";

    /// Receipts are "<message id>/<receipt token>"; message ids are UUIDs, which never contain it.
    private enum receiptSeparator = "/";

    private MongoConnection m_connection;
    private string m_database;
    /// Queues this instance has seen in dispatch_queues; a queue is never removed once ensured.
    private bool[string] m_knownQueues;

    this(MongoConnection connection, string database)
    {
        if (connection is null)
            throw new Exception("MongoDispatchQueue requires a connection");
        if (database.length == 0)
            throw new Exception("MongoDispatchQueue requires a database name");
        m_connection = connection;
        m_database = database;
    }

    override void ensureQueue(string queue)
    {
        validateQueueName(queue);
        synchronized (this)
        {
            command(document([
                bson_value("createIndexes", messagesCollection),
                bson_value("indexes", [document([
                    bson_value("key", document([bson_value("queue", 1), bson_value("visibleAt", 1)])),
                    bson_value("name", "queue_visible_at"),
                ])]),
            ]), "create the dispatch message index");
            auto reply = command(document([
                bson_value("update", queuesCollection),
                bson_value("updates", [document([
                    bson_value("q", document([bson_value("_id", queue)])),
                    bson_value("u", [document([bson_value("$set", document([
                        bson_value("ensuredAt", document([bson_value("$ifNull", [bson_value("", "$ensuredAt"), bson_value("", "$$NOW")])])),
                    ]))])]),
                    bson_value("upsert", true),
                ])]),
            ]), format("ensure queue '%s'", queue));
            expectCount(reply, 1, format("ensure queue '%s'", queue));
            m_knownQueues[queue] = true;
        }
    }

    override void send(string queue, Json message, Duration delay = Duration.zero)
    {
        import std.uuid : randomUUID;

        const text = validateMessage(queue, message);
        validateDelay(delay);
        synchronized (this)
        {
            expectEnsured(queue);
            // An upserting pipeline update rather than an insert, so visibleAt comes from $$NOW.
            const id = randomUUID().toString();
            auto reply = command(document([
                bson_value("update", messagesCollection),
                bson_value("updates", [document([
                    bson_value("q", document([bson_value("_id", id)])),
                    bson_value("u", [document([bson_value("$set", document([
                        bson_value("queue", literal(queue)),
                        bson_value("body", literal(text)),
                        bson_value("visibleAt", nowPlus(delay)),
                        bson_value("receipt", null),
                        bson_value("receiveCount", 0L),
                    ]))])]),
                    bson_value("upsert", true),
                ])]),
            ]), format("send a message to queue '%s'", queue));
            expectCount(reply, 1, format("send a message to queue '%s'", queue));
        }
    }

    override Lease[] receive(string queue, size_t maxMessages, Duration visibility)
    {
        import std.uuid : randomUUID;
        import vibe.data.json : parseJsonString;

        validateReceiveBatch(maxMessages);
        validateVisibility(visibility);
        synchronized (this)
        {
            expectEnsured(queue);
            Lease[] leases;
            foreach (i; 0 .. maxMessages)
            {
                const token = randomUUID().toString();
                auto reply = command(document([
                    bson_value("findAndModify", messagesCollection),
                    bson_value("query", document([
                        bson_value("queue", queue),
                        bson_value("$expr", document([bson_value("$lte", [bson_value("", "$visibleAt"), bson_value("", "$$NOW")])])),
                    ])),
                    bson_value("sort", document([bson_value("visibleAt", 1)])),
                    bson_value("update", [document([bson_value("$set", document([
                        bson_value("visibleAt", nowPlus(visibility)),
                        bson_value("receipt", literal(token)),
                        bson_value("receiveCount", document([bson_value("$add", [bson_value("", "$receiveCount"), bson_value("", 1L)])])),
                    ]))])]),
                    bson_value("new", true),
                    bson_value("fields", document([bson_value("body", 1), bson_value("receiveCount", 1)])),
                ]), format("receive from queue '%s'", queue));

                auto value = reply["value"];
                if (value == bson_value.init || isNull(value))
                    break;
                auto leased = value.get!document;
                const id = leased["_id"].get!string;
                const body = leased["body"].get!string;
                Json message;
                try
                    message = parseJsonString(body);
                catch (Exception e)
                    throw new Exception(format("Message '%s' in queue '%s' holds a body that is not JSON (%s): %s", id, queue, e.msg, body));
                leases ~= Lease(id ~ receiptSeparator ~ token, cast(uint) leased["receiveCount"].get!long, message);
            }
            return leases;
        }
    }

    override void ack(string queue, string receipt)
    {
        synchronized (this)
        {
            expectEnsured(queue);
            auto reply = command(document([
                bson_value("delete", messagesCollection),
                bson_value("deletes", [document([
                    bson_value("q", deliveryFilter(queue, receipt, false)),
                    bson_value("limit", 1),
                ])]),
            ]), format("acknowledge receipt '%s' on queue '%s'", receipt, queue));
            if (reply["n"].get!long != 1)
                throw leaseLost(queue, receipt, "acknowledge");
        }
    }

    override void extend(string queue, string receipt, Duration visibility)
    {
        validateVisibility(visibility);
        synchronized (this)
        {
            expectEnsured(queue);
            updateDelivery(queue, receipt, "extend", document([
                bson_value("visibleAt", nowPlus(visibility)),
            ]));
        }
    }

    override void release(string queue, string receipt, Duration delay = Duration.zero)
    {
        validateDelay(delay);
        synchronized (this)
        {
            expectEnsured(queue);
            updateDelivery(queue, receipt, "release", document([
                bson_value("visibleAt", nowPlus(delay)),
                bson_value("receipt", null),
            ]));
        }
    }

    /// Applies a $set to the message a receipt delivered, if that delivery's lease still holds.
    private void updateDelivery(string queue, string receipt, string operation, document set)
    {
        auto reply = command(document([
            bson_value("update", messagesCollection),
            bson_value("updates", [document([
                bson_value("q", deliveryFilter(queue, receipt, true)),
                bson_value("u", [document([bson_value("$set", set)])]),
            ])]),
        ]), format("%s receipt '%s' on queue '%s'", operation, receipt, queue));
        if (reply["n"].get!long != 1)
            throw leaseLost(queue, receipt, operation);
    }

    /// Matches the message a receipt delivered while the receipt is its current delivery and,
    /// if unexpired, while its lease has not expired.
    private document deliveryFilter(string queue, string receipt, bool unexpired)
    {
        import std.string : indexOf;

        const separator = receipt.indexOf(receiptSeparator);
        if (separator <= 0 || separator == receipt.length - 1)
            throw new DispatchQueueUsageException(format("Malformed receipt '%s' for queue '%s'", receipt, queue));
        bson_value[] fields = [
            bson_value("_id", receipt[0 .. separator]),
            bson_value("queue", queue),
            bson_value("receipt", receipt[separator + 1 .. $]),
        ];
        if (unexpired)
            fields ~= bson_value("$expr", document([bson_value("$gt", [bson_value("", "$visibleAt"), bson_value("", "$$NOW")])]));
        return document(fields);
    }

    private static LeaseLostException leaseLost(string queue, string receipt, string operation)
    {
        return new LeaseLostException(format(
            "Cannot %s receipt '%s' on queue '%s': the lease no longer holds (it expired, or the message was delivered again, released or removed)",
            operation, receipt, queue), queue, receipt);
    }

    private void expectEnsured(string queue)
    {
        validateQueueName(queue);
        if (queue in m_knownQueues)
            return;
        auto reply = command(document([
            bson_value("find", queuesCollection),
            bson_value("filter", document([bson_value("_id", queue)])),
            bson_value("limit", 1),
        ]), format("look up queue '%s'", queue));
        if (reply["cursor"].get!document["firstBatch"].get!(const(bson_value)[]).length == 0)
            throw new DispatchQueueUsageException(format("Queue '%s' was not ensured", queue));
        m_knownQueues[queue] = true;
    }

    /// Runs a command, throwing if it or any of its writes failed.
    private document command(document cmd, string what)
    {
        auto reply = m_connection.runCommand(m_database, cmd, true, "MongoDB command to " ~ what);
        auto writeErrors = reply["writeErrors"];
        if (writeErrors != bson_value.init)
            throw new Exception(format("MongoDB failed to %s: %s", what, writeErrors.toString()));
        auto writeConcernError = reply["writeConcernError"];
        if (writeConcernError != bson_value.init)
            throw new Exception(format("MongoDB failed to %s: %s", what, writeConcernError.toString()));
        return reply;
    }

    private static void expectCount(document reply, long expected, string what)
    {
        const n = reply["n"].get!long;
        if (n != expected)
            throw new Exception(format("MongoDB matched %s documents, not %s, trying to %s", n, expected, what));
    }

    /// {$add: [$$NOW, duration in milliseconds]}, a date on the server's clock.
    private static document nowPlus(Duration duration)
    {
        return document([bson_value("$add", [bson_value("", "$$NOW"), bson_value("", duration.total!"msecs")])]);
    }

    /// Pipeline updates read strings starting with '$' as field paths; $literal keeps them text.
    private static document literal(string value)
    {
        return document([bson_value("$literal", value)]);
    }

    private static bool isNull(const bson_value value)
    {
        static struct NullVisitor
        {
            bool visit(V)(const V) { return false; }
            bool visit(typeof(null)) { return true; }
            bool visit(ubyte, const(ubyte)[]) { return false; }
        }
        return value.visit(NullVisitor());
    }
}

/**
 * The MongoDB dispatch queue as a plugin. Both settings are required; there is no default
 * connection string or database.
 */
class MongoQueuePlugin : DispatchQueuePlugin, DispatchQueue
{
    private MongoDispatchQueue m_queue;

    @property string name() const { return "mongo-queue"; }
    @property string versionString() const { return "2.0.0"; }
    @property string description() const { return "MongoDB-backed dispatch queue"; }
    @property PluginCategory category() const { return PluginCategory.queue; }

    ConfigDefinition[] configDefinitions() const
    {
        return [
            ConfigDefinition("connectionString", "CONFECTOR_MONGO_URI", Json.undefined, "MongoDB connection URI", true),
            ConfigDefinition("dbName", "", Json.undefined, "MongoDB database name", true)
        ];
    }

    void initialize(PluginContext context = null)
    {
        if (context is null)
            throw new Exception("[mongo-queue] PluginContext must not be null; the host failed to provide configuration.");

        string connectionString = context.config.getString("connectionString");
        if (connectionString.length == 0)
            throw new Exception("[mongo-queue] Required setting 'connectionString' is missing (plugins.mongo-queue.connectionString or CONFECTOR_MONGO_URI).");
        string dbName = context.config.getString("dbName");
        if (dbName.length == 0)
            throw new Exception("[mongo-queue] Required setting 'dbName' is missing (plugins.mongo-queue.dbName).");

        m_queue = new MongoDispatchQueue(new MongoConnection(connectionString), dbName);
        context.info(format("Connected to MongoDB for the dispatch queue, database: %s", dbName));
    }

    void shutdown()
    {
    }

    override void ensureQueue(string queue) { initialized.ensureQueue(queue); }
    override void send(string queue, Json message, Duration delay = Duration.zero) { initialized.send(queue, message, delay); }
    override Lease[] receive(string queue, size_t maxMessages, Duration visibility) { return initialized.receive(queue, maxMessages, visibility); }
    override void ack(string queue, string receipt) { initialized.ack(queue, receipt); }
    override void extend(string queue, string receipt, Duration visibility) { initialized.extend(queue, receipt, visibility); }
    override void release(string queue, string receipt, Duration delay = Duration.zero) { initialized.release(queue, receipt, delay); }

    private MongoDispatchQueue initialized()
    {
        if (m_queue is null)
            throw new Exception("[mongo-queue] The plugin was used before initialize().");
        return m_queue;
    }
}

extern(C) export Plugin confector_create_plugin()
{
    return new MongoQueuePlugin();
}

/**
 * Runs the DispatchQueue conformance suite against a real MongoDB. Set CONFECTOR_TEST_MONGO_URI
 * to a server the tests may write to, for example:
 *
 *     docker run -d --rm -p 127.0.0.1:27027:27017 mongo
 *     CONFECTOR_TEST_MONGO_URI=mongodb://127.0.0.1:27027 dub test :mongo_queue
 *
 * The tests drop and recreate the database confector_dispatch_queue_test.
 */
unittest
{
    import confector.testing.conformance.dispatch_queue : checkDispatchQueue;
    import core.thread : Thread;
    import core.time : msecs;
    import std.process : environment;

    const uri = environment.get("CONFECTOR_TEST_MONGO_URI", null);
    if (uri.length == 0)
        throw new Exception("The Mongo dispatch queue tests need CONFECTOR_TEST_MONGO_URI set to a MongoDB they may write to.");
    enum database = "confector_dispatch_queue_test";

    checkDispatchQueue(
        (size_t clients) {
            auto admin = new MongoConnection(uri);
            admin.runCommand(database, document([bson_value("dropDatabase", 1)]), true, "drop the test database");
            auto result = new DispatchQueue[](clients);
            foreach (ref client; result)
                client = new MongoDispatchQueue(new MongoConnection(uri), database);
            return result;
        },
        // Lease times run on the server's clock, which can lag a local sleep by a few
        // milliseconds; wait a little longer so at least `elapsed` passes on the server.
        (Duration elapsed) { Thread.sleep(elapsed + 200.msecs); });
}
