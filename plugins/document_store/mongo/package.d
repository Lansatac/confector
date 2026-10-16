module plugins.document_store.mongo;

import confector.mongo_helpers : bson_value, document, MongoConnection;
import confector.plugin_api.document_store;
import std.format : format;
import std.typecons : Nullable, nullable;
import vibe.data.json : Json, parseJsonString;

/**
 * DocumentStore on MongoDB (requires MongoDB 4.2 or later).
 *
 * Each declared collection "name" is the MongoDB collection "doc_name" in the configured
 * database, and its declaration (the CollectionSpec) is remembered as one document, with the
 * collection name as _id, in the collection "docstore_specs" (which no declared collection can
 * be named, as they all start with "doc_"): { _id: <name>, spec: <JSON text>, ready: <bool> }.
 * ready becomes true once the collection's existing documents have their index entries. A
 * document is stored as:
 *
 *     { _id: <id>, v: <version, a long>, content: <compact JSON text>, ix: { <index>: { p, s } } }
 *
 * - The content is kept as JSON text, not as embedded BSON, so field names ('$', '.', empty),
 *   number types and key order round-trip exactly, and so content fields can never collide with
 *   _id, v or ix.
 * - ix holds, for each declared index the document is in, its partition key (p) and sort key
 *   (s). A document whose key fields are missing or are not strings has no entry for that index.
 *   Declared indexes are MongoDB compound indexes on (ix.<index>.p, ix.<index>.s, _id) that are
 *   partial on the existence of ix.<index>.p, so documents outside an index cost nothing in it.
 *
 * Correctness rests on single-document atomic operations:
 * - create is an insert; the unique _id makes a concurrent or repeated create fail with a
 *   duplicate key error (code 11000), reported as DocumentConflictException.
 * - replace is an update filtered on {_id, v: expected}; remove is a delete with the same
 *   filter. Exactly one matching document means the compare-and-set won; zero means it lost.
 *   After a lost race the document is read again only to word the exception.
 * - get and the writes go to the primary, so they are strongly consistent. Queries read the
 *   same primary but are only promised to be eventually consistent by the interface.
 *
 * Ordering: MongoDB compares strings without a collation by the bytes of their UTF-8
 * encoding, which is the order the DocumentStore contract specifies. The collections are
 * created implicitly with no collation, and queries pass none. Ties on the sort key are
 * ordered by id, also bytewise.
 *
 * Each instance uses one connection and serializes its own calls; use one instance per
 * connection.
 */
class MongoDocumentStore : DocumentStore
{
    private enum collectionPrefix = "doc_";
    private enum indexPrefix = "ix_";
    /// Documents fetched per round trip while collecting a page; a page can hold up to
    /// MongoDB's 16 MB reply limit worth of documents, so the rest comes through getMore.
    private enum batchSize = 1000;
    private enum duplicateKeyCode = 11000;

    private MongoConnection m_connection;
    private string m_database;
    private CollectionSpec[string] m_specs;

    this(MongoConnection connection, string database)
    {
        if (connection is null)
            throw new Exception("MongoDocumentStore requires a connection");
        if (database.length == 0)
            throw new Exception("MongoDocumentStore requires a database name");
        m_connection = connection;
        m_database = database;
    }

    /**
     * Declares collections. A collection's spec is remembered in the database, so declaring it
     * with a different spec than it was first declared with throws DocumentStoreUsageException,
     * in this process, after a restart, or from another process.
     *
     * The first declaration of a collection claims it by inserting { spec, ready: false }
     * before it writes any index entry, so only one spec is ever backfilled: a declarer with a
     * different spec loses the claim (a duplicate key), finds the other spec and throws. After
     * the claim, the declarer creates the indexes, adds the index entries to the documents
     * already in the collection, and sets ready. A declarer that finds the same spec claimed
     * but not ready (another process is backfilling, or crashed doing it) does the backfill
     * itself instead of waiting: the backfill is idempotent, each update is filtered on the
     * document's version, and every declarer writes the same entries, so concurrent backfills
     * are harmless and a crashed claim never wedges the collection.
     *
     * Changes to the instance's declared collections are all or nothing. The database changes
     * are not: a failure partway may leave earlier collections claimed or created, which a
     * repeated declare completes.
     */
    override void declare(const(CollectionSpec)[] collections)
    {
        synchronized (this)
        {
            // Validate everything before changing anything, so a bad declaration leaves no trace.
            CollectionSpec[string] added;
            foreach (spec; collections)
            {
                validateCollectionSpec(spec);
                if (auto existing = spec.name in m_specs)
                    checkRedeclaration(*existing, spec);
                else if (auto pending = spec.name in added)
                    checkRedeclaration(*pending, spec);
                else
                    added[spec.name] = CollectionSpec(spec.name, spec.indexes.dup);
            }
            StoredSpec[string] ready;
            foreach (name, spec; added)
            {
                auto stored = loadSpec(name);
                if (!stored.isNull)
                {
                    checkAgainstStored(stored.get.spec, spec);
                    ready[name] = stored.get;
                }
            }
            foreach (name, spec; added)
            {
                bool needsBackfill = true;
                if (auto stored = name in ready)
                    needsBackfill = !stored.ready;
                else
                {
                    auto winner = claimSpec(spec);
                    needsBackfill = winner.isNull || !winner.get.ready;
                }
                createIndexes(spec);
                if (needsBackfill)
                {
                    backfillIndexEntries(spec);
                    markReady(spec);
                }
            }
            foreach (name, spec; added)
                m_specs[name] = spec;
        }
    }

    override Nullable!Document get(string collection, string id)
    {
        synchronized (this)
        {
            specFor(collection);
            auto found = findDocuments(collection, document([bson_value("_id", id)]), document([]), 1);
            if (found.length == 0)
                return Nullable!Document.init;
            return nullable(toDocument(collection, found[0]));
        }
    }

    override Document create(string collection, string id, Json content)
    {
        synchronized (this)
        {
            const spec = specFor(collection);
            auto validated = validateDocumentText(spec, id, content);
            const text = checkedText(collection, id, validated.text);
            auto reply = command(document([
                bson_value("insert", collectionName(collection)),
                bson_value("documents", [document([
                    bson_value("_id", id),
                    bson_value("v", 1L),
                    bson_value("content", text),
                    bson_value("ix", indexEntries(spec, content)),
                ])]),
            ]), format("create document '%s' in collection '%s'", id, collection), duplicateKeyCode);
            if (writeErrorCode(reply) == duplicateKeyCode)
                throw new DocumentConflictException(format("Document '%s' already exists in collection '%s'", id, collection), collection, id);
            expectCount(reply, 1, format("create document '%s' in collection '%s'", id, collection));
            return Document(id, 1, validated.content);
        }
    }

    override Document replace(string collection, string id, Json content, ulong expectedVersion)
    {
        synchronized (this)
        {
            const spec = specFor(collection);
            auto validated = validateDocumentText(spec, id, content);
            const text = checkedText(collection, id, validated.text);
            if (!storable(expectedVersion))
                throw lostCompareAndSet(collection, id, expectedVersion, "replace");
            const next = expectedVersion + 1;
            if (!storable(next))
                throw new DocumentStoreUsageException(format("Document '%s' in collection '%s' has reached the highest version the store can hold", id, collection));
            auto reply = command(document([
                bson_value("update", collectionName(collection)),
                bson_value("updates", [document([
                    bson_value("q", document([bson_value("_id", id), bson_value("v", cast(long) expectedVersion)])),
                    bson_value("u", document([bson_value("$set", document([
                        bson_value("v", cast(long) next),
                        bson_value("content", text),
                        bson_value("ix", indexEntries(spec, content)),
                    ]))])),
                ])]),
            ]), format("replace document '%s' in collection '%s'", id, collection));
            if (reply["n"].get!long != 1)
                throw lostCompareAndSet(collection, id, expectedVersion, "replace");
            return Document(id, next, validated.content);
        }
    }

    override void remove(string collection, string id, ulong expectedVersion)
    {
        synchronized (this)
        {
            specFor(collection);
            if (!storable(expectedVersion))
                throw lostCompareAndSet(collection, id, expectedVersion, "remove");
            auto reply = command(document([
                bson_value("delete", collectionName(collection)),
                bson_value("deletes", [document([
                    bson_value("q", document([bson_value("_id", id), bson_value("v", cast(long) expectedVersion)])),
                    bson_value("limit", 1),
                ])]),
            ]), format("remove document '%s' from collection '%s'", id, collection));
            if (reply["n"].get!long != 1)
                throw lostCompareAndSet(collection, id, expectedVersion, "remove");
        }
    }

    override QueryPage query(string collection, const IndexQuery lookup)
    {
        synchronized (this)
        {
            const index = validateIndexQuery(specFor(collection), lookup);
            const hasSortKey = index.sortKey.length > 0;
            const partition = partitionPath(index);
            const sort = sortPath(index);

            document[] conditions = [
                document([bson_value(partition, lookup.partitionKey)]),
                // Lets MongoDB use the partial index.
                document([bson_value(partition, document([bson_value("$exists", true)]))]),
            ];
            if (hasSortKey && (!lookup.sortKeyFrom.isNull || !lookup.sortKeyTo.isNull))
            {
                bson_value[] bounds;
                if (!lookup.sortKeyFrom.isNull)
                    bounds ~= bson_value("$gte", lookup.sortKeyFrom.get);
                if (!lookup.sortKeyTo.isNull)
                    bounds ~= bson_value("$lte", lookup.sortKeyTo.get);
                conditions ~= document([bson_value(sort, document(bounds))]);
            }
            if (lookup.cursor.length > 0)
            {
                const after = decodeCursor(lookup.cursor);
                const op = lookup.descending ? "$lt" : "$gt";
                if (hasSortKey)
                    conditions ~= document([bson_value("$or", [
                        document([bson_value(sort, document([bson_value(op, after.sortValue)]))]),
                        document([bson_value(sort, after.sortValue), bson_value("_id", document([bson_value(op, after.id)]))]),
                    ])]);
                else
                    conditions ~= document([bson_value("_id", document([bson_value(op, after.id)]))]);
            }

            const direction = lookup.descending ? -1 : 1;
            auto sortSpec = hasSortKey
                ? document([bson_value(sort, direction), bson_value("_id", direction)])
                : document([bson_value("_id", direction)]);

            // One more than the page, to learn whether there is a next page.
            const wanted = lookup.limit == size_t.max ? size_t.max : lookup.limit + 1;
            auto found = findDocuments(collection, document([bson_value("$and", conditions)]), sortSpec, wanted,
                indexPrefix ~ index.name);

            QueryPage page;
            document lastReturned;
            foreach (raw; found)
            {
                if (page.documents.length == lookup.limit)
                {
                    page.nextCursor = encodeCursor(lastReturned, index);
                    break;
                }
                page.documents ~= toDocument(collection, raw);
                lastReturned = raw;
            }
            return page;
        }
    }

    /// Cursor position: the sort key value (empty for an index without one) and the id of the
    /// last document returned.
    private static struct Position
    {
        string sortValue;
        string id;
    }

    private static string encodeCursor(document lastReturned, const IndexSpec index)
    {
        string sortValue;
        if (index.sortKey.length > 0)
            sortValue = lastReturned["ix"].get!document[index.name].get!document["s"].get!string;
        return Json([Json(sortValue), Json(lastReturned["_id"].get!string)]).toString();
    }

    private static Position decodeCursor(string cursor)
    {
        Json parsed;
        try
            parsed = parseJsonString(cursor);
        catch (Exception e)
            throw new DocumentStoreUsageException(format("Malformed query cursor '%s': %s", cursor, e.msg));
        if (parsed.type != Json.Type.array || parsed.length != 2
            || parsed[0].type != Json.Type.string || parsed[1].type != Json.Type.string)
            throw new DocumentStoreUsageException(format("Malformed query cursor '%s'", cursor));
        return Position(parsed[0].get!string, parsed[1].get!string);
    }

    private const(CollectionSpec) specFor(string collection)
    {
        if (auto spec = collection in m_specs)
            return *spec;
        throw new DocumentStoreUsageException(format("Collection '%s' was not declared", collection));
    }

    private static string collectionName(string collection)
    {
        return collectionPrefix ~ collection;
    }

    private static string partitionPath(const IndexSpec index)
    {
        return "ix." ~ index.name ~ ".p";
    }

    private static string sortPath(const IndexSpec index)
    {
        return "ix." ~ index.name ~ ".s";
    }

    /// Key pattern of an index: partition key, sort key, then _id as the tie break.
    private static document indexKeys(const IndexSpec index)
    {
        bson_value[] keys = [bson_value(partitionPath(index), 1)];
        if (index.sortKey.length > 0)
            keys ~= bson_value(sortPath(index), 1);
        keys ~= bson_value("_id", 1);
        return document(keys);
    }

    /// The ix field of a document: the key values of every index the content belongs to. A
    /// document is in an index only if its key fields are present non-empty strings of at most
    /// maxKeyBytes. Writes are checked by validateDocument, so this only leaves out documents
    /// stored before their collection was declared with the index.
    private static document indexEntries(const CollectionSpec spec, Json content)
    {
        static string keyValue(Json content, string field)
        {
            auto value = field in content;
            if (value is null || value.type != Json.Type.string)
                return null;
            const text = value.get!string;
            return text.length == 0 || text.length > maxKeyBytes ? null : text;
        }

        bson_value[] entries;
        foreach (index; spec.indexes)
        {
            const partition = keyValue(content, index.partitionKey);
            if (partition is null)
                continue;
            bson_value[] keys = [bson_value("p", partition)];
            if (index.sortKey.length > 0)
            {
                const sort = keyValue(content, index.sortKey);
                if (sort is null)
                    continue;
                keys ~= bson_value("s", sort);
            }
            entries ~= bson_value(index.name, document(keys));
        }
        return document(entries);
    }

    /// Throws rather than store an id or content text that is not valid UTF-8.
    private static string checkedText(string collection, string id, string text)
    {
        import std.utf : validate, UTFException;

        try
        {
            validate(id);
            validate(text);
        }
        catch (UTFException e)
            throw new DocumentStoreUsageException(format("Document '%s' in collection '%s' holds text that is not valid UTF-8: %s", id, collection, e.msg));
        return text;
    }

    private static Document toDocument(string collection, document raw)
    {
        const id = raw["_id"].get!string;
        const text = raw["content"].get!string;
        Json content;
        try
            content = parseJsonString(text);
        catch (Exception e)
            throw new Exception(format("Document '%s' in collection '%s' holds content that is not JSON (%s): %s", id, collection, e.msg, text));
        if (content.type != Json.Type.object)
            throw new Exception(format("Document '%s' in collection '%s' holds content that is not a JSON object: %s", id, collection, text));
        return Document(id, cast(ulong) raw["v"].get!long, content);
    }

    private document[] findDocuments(string collection, document filter, document sort, size_t limit, string hint = null)
    {
        return findRaw(collectionName(collection), format("read collection '%s'", collection), filter, sort, limit, hint);
    }

    /// Documents of a MongoDB collection matching a filter, in the given sort order, up to `limit`.
    private document[] findRaw(string physical, string what, document filter, document sort, size_t limit, string hint = null)
    {
        bson_value[] fields = [
            bson_value("find", physical),
            bson_value("filter", filter),
            bson_value("limit", limit > long.max ? long.max : cast(long) limit),
            bson_value("batchSize", cast(int) batchSize),
        ];
        if (sort.length > 0)
            fields ~= bson_value("sort", sort);
        if (hint.length > 0)
            fields ~= bson_value("hint", hint);
        auto reply = command(document(fields), what);

        document[] found;
        long cursorId;
        try
        {
            bool first = true;
            for (;;)
            {
                auto cursor = reply["cursor"].get!document;
                cursorId = cursor["id"].get!long;
                foreach (value; cursor[first ? "firstBatch" : "nextBatch"].get!(const(bson_value)[]))
                    found ~= value.get!document;
                first = false;
                if (cursorId == 0 || found.length >= limit)
                    break;
                reply = command(document([
                    bson_value("getMore", cursorId),
                    bson_value("collection", physical),
                    bson_value("batchSize", cast(int) batchSize),
                ]), what);
            }
        }
        catch (Exception e)
        {
            // Do not leave the server cursor open; if that fails too, chain it to the original.
            if (cursorId != 0)
            {
                try
                    killCursor(physical, cursorId, what);
                catch (Exception killFailure)
                {
                    Throwable last = e;
                    while (last.next !is null)
                        last = last.next;
                    last.next = killFailure;
                }
            }
            throw e;
        }
        if (cursorId != 0)
            killCursor(physical, cursorId, what);
        return found;
    }

    private void killCursor(string physical, long cursorId, string what)
    {
        command(document([
            bson_value("killCursors", physical),
            bson_value("cursors", [bson_value("", cursorId)]),
        ]), what);
    }

    private enum specsCollection = "docstore_specs";
    /// MongoDB error codes for an index that already exists with other options or keys.
    private enum indexOptionsConflictCode = 85;
    private enum indexKeySpecsConflictCode = 86;

    /// Creates the declared indexes (and the collection). Synchronous: the indexes are usable
    /// when it returns. An index of the same name with other keys already existing, which can
    /// only be a database whose remembered spec was lost, is a usage error.
    private void createIndexes(const CollectionSpec spec)
    {
        if (spec.indexes.length == 0)
            return;
        document[] indexes;
        foreach (index; spec.indexes)
            indexes ~= document([
                bson_value("key", indexKeys(index)),
                bson_value("name", indexPrefix ~ index.name),
                bson_value("partialFilterExpression", document([
                    bson_value(partitionPath(index), document([bson_value("$exists", true)])),
                ])),
            ]);
        const what = format("create the indexes of collection '%s'", spec.name);
        auto reply = m_connection.runCommand(m_database, document([
            bson_value("createIndexes", collectionName(spec.name)),
            bson_value("indexes", indexes),
        ]), false, "MongoDB command to " ~ what);
        if (reply["ok"].get!double == 1)
        {
            checkWriteConcern(reply, what);
            return;
        }
        const code = reply["code"] != bson_value.init ? reply["code"].get!int : 0;
        const message = format("MongoDB failed to %s: %s", what, reply["errmsg"].toString());
        if (code == indexOptionsConflictCode || code == indexKeySpecsConflictCode)
            throw new DocumentStoreUsageException(message ~ ". The collection already has an index of that name with different keys.");
        throw new Exception(message);
    }

    private static struct StoredSpec
    {
        CollectionSpec spec;
        /// Whether the collection's existing documents have their index entries. A record
        /// without the field is treated as not ready, which only repeats an idempotent backfill.
        bool ready;
    }

    private Nullable!StoredSpec loadSpec(string name)
    {
        auto found = findRaw(specsCollection, format("read the remembered spec of collection '%s'", name),
            document([bson_value("_id", name)]), document([]), 1);
        if (found.length == 0)
            return Nullable!StoredSpec.init;
        auto record = found[0];
        const text = record["spec"].get!string;
        try
        {
            auto json = parseJsonString(text);
            StoredSpec stored;
            stored.spec.name = json["name"].get!string;
            foreach (entry; json["indexes"])
                stored.spec.indexes ~= IndexSpec(entry["name"].get!string, entry["partitionKey"].get!string, entry["sortKey"].get!string);
            const readyField = record["ready"];
            stored.ready = readyField != bson_value.init && readyField.get!bool;
            return nullable(stored);
        }
        catch (Exception e)
            throw new Exception(format("The remembered spec of collection '%s' is not valid (%s): %s", name, e.msg, text));
    }

    /// checkRedeclaration, with where to look and what it means for an operator.
    private static void checkAgainstStored(const CollectionSpec stored, const CollectionSpec declared)
    {
        try
            checkRedeclaration(stored, declared);
        catch (DocumentStoreUsageException e)
            throw new DocumentStoreUsageException(format(
                "%s (the remembered spec is the document with _id '%s' in the MongoDB collection %s; a migration has to change it together with the ix entries of the collection's documents)",
                e.msg, stored.name, specsCollection));
    }

    /**
     * Claims a collection for a spec by inserting it with ready false. Returns null if this call
     * made the claim, or the existing record if another declarer claimed it first, after
     * checking that it holds the same spec (throwing if not).
     */
    private Nullable!StoredSpec claimSpec(const CollectionSpec spec)
    {
        auto indexes = Json.emptyArray;
        foreach (index; spec.indexes)
            indexes ~= Json(["name": Json(index.name), "partitionKey": Json(index.partitionKey), "sortKey": Json(index.sortKey)]);
        const text = Json(["name": Json(spec.name), "indexes": indexes]).toString();
        const what = format("remember the spec of collection '%s'", spec.name);
        auto reply = command(document([
            bson_value("insert", specsCollection),
            bson_value("documents", [document([bson_value("_id", spec.name), bson_value("spec", text), bson_value("ready", false)])]),
        ]), what, duplicateKeyCode);
        if (writeErrorCode(reply) != duplicateKeyCode)
            return Nullable!StoredSpec.init;
        auto existing = loadSpec(spec.name);
        if (existing.isNull)
            throw new Exception("MongoDB reported a duplicate remembered spec for collection '" ~ spec.name ~ "' that it then could not find");
        checkAgainstStored(existing.get.spec, spec);
        return existing;
    }

    private void markReady(const CollectionSpec spec)
    {
        const what = format("mark collection '%s' ready", spec.name);
        auto reply = command(document([
            bson_value("update", specsCollection),
            bson_value("updates", [document([
                bson_value("q", document([bson_value("_id", spec.name)])),
                bson_value("u", document([bson_value("$set", document([bson_value("ready", true)]))])),
            ])]),
        ]), what);
        expectCount(reply, 1, what);
    }

    /// Adds the ix entries of every index in the spec to the documents already in the
    /// collection. Each update is filtered on the document's version, so a document changed
    /// meanwhile is read again and recomputed rather than overwritten with stale entries;
    /// writers that know the spec maintain ix themselves.
    private void backfillIndexEntries(const CollectionSpec spec)
    {
        enum maxAttempts = 1000;
        const physical = collectionName(spec.name);
        const what = format("add index entries to the documents of collection '%s'", spec.name);
        string after;
        for (;;)
        {
            auto filter = after is null ? document([]) : document([bson_value("_id", document([bson_value("$gt", after)]))]);
            auto batch = findRaw(physical, what, filter, document([bson_value("_id", 1)]), batchSize);
            if (batch.length == 0)
                return;
            foreach (raw; batch)
            {
                auto current = raw;
                foreach (attempt; 0 .. maxAttempts)
                {
                    const id = current["_id"].get!string;
                    auto reply = command(document([
                        bson_value("update", physical),
                        bson_value("updates", [document([
                            bson_value("q", document([bson_value("_id", id), bson_value("v", current["v"].get!long)])),
                            bson_value("u", document([bson_value("$set", document([
                                bson_value("ix", indexEntries(spec, toDocument(spec.name, current).content)),
                            ]))])),
                        ])]),
                    ]), what);
                    if (reply["n"].get!long == 1)
                        break;
                    auto reread = findRaw(physical, what, document([bson_value("_id", id)]), document([]), 1);
                    if (reread.length == 0)
                        break;  // removed meanwhile
                    current = reread[0];
                    if (attempt == maxAttempts - 1)
                        throw new Exception(format("Document '%s' in collection '%s' changed %s times while its index entries were added", id, spec.name, maxAttempts));
                }
            }
            after = batch[$ - 1]["_id"].get!string;
        }
    }

    /// Runs a command, throwing if it or any of its writes failed. A write error with the code
    /// `tolerated` is left in the reply for the caller to handle.
    private document command(document cmd, string what, int tolerated = 0)
    {
        auto reply = m_connection.runCommand(m_database, cmd, true, "MongoDB command to " ~ what);
        auto writeErrors = reply["writeErrors"];
        if (writeErrors != bson_value.init && !(tolerated != 0 && writeErrorCode(reply) == tolerated))
            throw new Exception(format("MongoDB failed to %s: %s", what, writeErrors.toString()));
        checkWriteConcern(reply, what);
        return reply;
    }

    private static void checkWriteConcern(document reply, string what)
    {
        auto writeConcernError = reply["writeConcernError"];
        if (writeConcernError != bson_value.init)
            throw new Exception(format("MongoDB failed to %s: %s", what, writeConcernError.toString()));
    }

    /// The code of the first write error in a reply, or 0 if it has none.
    private static int writeErrorCode(document reply)
    {
        auto writeErrors = reply["writeErrors"];
        if (writeErrors == bson_value.init)
            return 0;
        auto errors = writeErrors.get!(const(bson_value)[]);
        if (errors.length == 0)
            return 0;
        return errors[0].get!document["code"].get!int;
    }

    private static void expectCount(document reply, long expected, string what)
    {
        const n = reply["n"].get!long;
        if (n != expected)
            throw new Exception(format("MongoDB affected %s documents, not %s, trying to %s", n, expected, what));
    }

    /// Versions are stored as signed 64 bit integers.
    private static bool storable(ulong version_)
    {
        return version_ <= long.max;
    }

    /// The exception for a compare-and-set that matched nothing. The document is read again to
    /// word the message; the exception is the same whatever that read finds.
    private DocumentConflictException lostCompareAndSet(string collection, string id, ulong expectedVersion, string operation)
    {
        auto current = findDocuments(collection, document([bson_value("_id", id)]), document([]), 1);
        if (current.length == 0)
            return new DocumentConflictException(format(
                "Cannot %s document '%s' in collection '%s' at version %s: it does not exist",
                operation, id, collection, expectedVersion), collection, id);
        return new DocumentConflictException(format(
            "Cannot %s document '%s' in collection '%s': expected version %s, found %s",
            operation, id, collection, expectedVersion, current[0]["v"].get!long), collection, id);
    }
}

/**
 * Runs the DocumentStore conformance suite against a real MongoDB. Set CONFECTOR_TEST_MONGO_URI
 * to a server the tests may write to, for example:
 *
 *     docker run -d --rm -p 127.0.0.1:27027:27017 mongo
 *     CONFECTOR_TEST_MONGO_URI=mongodb://127.0.0.1:27027 dub test :mongo_document_store
 *
 * The tests drop and recreate the database confector_document_store_test.
 */
unittest
{
    import confector.testing.conformance.document_store : checkDocumentStore;
    import std.process : environment;

    const uri = environment.get("CONFECTOR_TEST_MONGO_URI", null);
    if (uri.length == 0)
        throw new Exception("The Mongo document store tests need CONFECTOR_TEST_MONGO_URI set to a MongoDB they may write to.");
    enum database = "confector_document_store_test";

    checkDocumentStore(
        () {
            auto connection = new MongoConnection(uri);
            connection.runCommand(database, document([bson_value("dropDatabase", 1)]), true, "drop the test database");
            return new MongoDocumentStore(connection, database);
        },
        // A restart is a new instance on a new connection to the same database.
        (previous) => new MongoDocumentStore(new MongoConnection(uri), database));
}

/// A collection that already holds documents written without index entries (as before its
/// collection was declared with the index) is backfilled by the first declare.
unittest
{
    import std.process : environment;
    import vibe.data.json : parseJsonString;

    const uri = environment.get("CONFECTOR_TEST_MONGO_URI", null);
    if (uri.length == 0)
        throw new Exception("The Mongo document store tests need CONFECTOR_TEST_MONGO_URI set to a MongoDB they may write to.");
    enum database = "confector_document_store_backfill_test";

    auto connection = new MongoConnection(uri);
    connection.runCommand(database, document([bson_value("dropDatabase", 1)]), true, "drop the test database");
    void insertRaw(string id, string content)
    {
        connection.runCommand(database, document([
            bson_value("insert", "doc_things"),
            bson_value("documents", [document([bson_value("_id", id), bson_value("v", 4L), bson_value("content", content)])]),
        ]), true, "insert a document without index entries");
    }
    insertRaw("old", `{"owner":"ann","created":"1"}`);
    insertRaw("numeric-owner", `{"owner":7,"created":"1"}`);
    insertRaw("other-owner", `{"owner":"bob","created":"1"}`);

    auto store = new MongoDocumentStore(new MongoConnection(uri), database);
    store.declare([CollectionSpec("things", [IndexSpec("by_owner", "owner", "created")])]);
    IndexQuery query = { index: "by_owner", partitionKey: "ann", limit: 10 };
    auto page = store.query("things", query);
    assert(page.documents.length == 1 && page.documents[0].id == "old" && page.documents[0].version_ == 4,
        "declare did not backfill the index entries of an existing document");
    query.partitionKey = "7";
    assert(store.query("things", query).documents.length == 0);
    // The document with a non-string key stays readable, and replacing it is checked as usual.
    assert(!store.get("things", "numeric-owner").isNull);
}

/**
 * Declarers racing to claim a collection that already holds documents. Whatever the
 * interleaving, exactly one spec wins, the loser gets DocumentStoreUsageException, and every
 * document carries index entries for the winner's keys only. A claim left unfinished by a
 * crashed declarer is completed by a declarer with the same spec and refused to a different one.
 */
unittest
{
    import core.thread : Thread;
    import std.format : format;
    import std.process : environment;

    const uri = environment.get("CONFECTOR_TEST_MONGO_URI", null);
    if (uri.length == 0)
        throw new Exception("The Mongo document store tests need CONFECTOR_TEST_MONGO_URI set to a MongoDB they may write to.");
    enum database = "confector_document_store_claim_test";
    enum documentCount = 300;

    auto admin = new MongoConnection(uri);
    void reset()
    {
        admin.runCommand(database, document([bson_value("dropDatabase", 1)]), true, "drop the test database");
        document[] documents;
        foreach (i; 0 .. documentCount)
            documents ~= document([
                bson_value("_id", format("d%04s", i)), bson_value("v", 1L),
                bson_value("content", `{"owner":"o","creator":"c","created":"1"}`),
            ]);
        admin.runCommand(database, document([bson_value("insert", "doc_things"), bson_value("documents", documents)]), true, "insert documents");
    }
    const byOwner = CollectionSpec("things", [IndexSpec("by_x", "owner", "created")]);
    const byCreator = CollectionSpec("things", [IndexSpec("by_x", "creator", "created")]);
    size_t found(MongoDocumentStore store, string partition)
    {
        IndexQuery query = { index: "by_x", partitionKey: partition, limit: 1000 };
        return store.query("things", query).documents.length;
    }

    // A race between two different specs, repeated because the interleaving varies.
    foreach (round; 0 .. 5)
    {
        reset();
        auto stores = [new MongoDocumentStore(new MongoConnection(uri), database), new MongoDocumentStore(new MongoConnection(uri), database)];
        const specs = [byOwner, byCreator];
        bool[2] declared;
        bool[2] refused;
        string[2] other;
        void declareWith(size_t n)
        {
            try
            {
                stores[n].declare([specs[n]]);
                declared[n] = true;
            }
            catch (DocumentStoreUsageException)
                refused[n] = true;
            catch (Exception e)
                other[n] = e.msg;
        }
        // One delegate per thread: a closure made in a loop body would share the loop variable.
        Thread[] threads = [new Thread({ declareWith(0); }), new Thread({ declareWith(1); })];
        foreach (thread; threads)
            thread.start();
        foreach (thread; threads)
            thread.join();
        assert(declared[0] != declared[1] && refused[0] != refused[1], format("round %s: not exactly one declarer won (declared %s, refused %s, other %s)", round, declared, refused, other));
        const winner = declared[0] ? 0 : 1;
        assert(found(stores[winner], winner == 0 ? "o" : "c") == documentCount, format("round %s: the winner's index is incomplete", round));
        // The loser's keys were never written into ix.
        auto raw = admin.runCommand(database, document([
            bson_value("count", "doc_things"),
            bson_value("query", document([bson_value("ix.by_x.p", winner == 0 ? "c" : "o")])),
        ]), true, "count foreign index entries");
        assert(raw["n"].get!long == 0, format("round %s: index entries of the losing spec exist", round));
    }

    // A claim left unfinished by a crashed declarer.
    reset();
    admin.runCommand(database, document([
        bson_value("insert", "docstore_specs"),
        bson_value("documents", [document([
            bson_value("_id", "things"),
            bson_value("spec", `{"name":"things","indexes":[{"name":"by_x","partitionKey":"owner","sortKey":"created"}]}`),
            bson_value("ready", false),
        ])]),
    ]), true, "leave a claim unfinished");
    auto other = new MongoDocumentStore(new MongoConnection(uri), database);
    bool refusedDifferent;
    try
        other.declare([byCreator]);
    catch (DocumentStoreUsageException)
        refusedDifferent = true;
    assert(refusedDifferent, "a different spec was accepted over an unfinished claim");
    auto finisher = new MongoDocumentStore(new MongoConnection(uri), database);
    finisher.declare([byOwner]);
    assert(found(finisher, "o") == documentCount, "a declarer with the claimed spec did not complete the backfill");
    auto record = admin.runCommand(database, document([bson_value("find", "docstore_specs"), bson_value("filter", document([]))]), true, "read the claim");
    assert(record["cursor"].get!document["firstBatch"].get!(const(bson_value)[])[0].get!document["ready"].get!bool, "the claim was not marked ready");
}
