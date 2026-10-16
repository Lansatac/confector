module confector.core.document_collection;

/**
 * Typed access to one DocumentStore collection, the building block of the core's domain stores
 * (design record: bead confector-z7z.4). A document is a plain data type serialized with
 * vibe.data.json, plus any derived index key fields the collection adds next to the type's own
 * fields (for example a fixed-width sort key made from a timestamp); derived fields are written
 * on every write and stripped before the content is deserialized.
 *
 * Correctness may depend only on reads by id and compare-and-set writes on a single document.
 * Queries are for discovery: they may lag behind writes, so callers must tolerate stale or
 * missing results.
 */

import confector.plugin_api.document_store;

import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable, nullable;
import vibe.data.json : Json, deserializeJson, serializeToJson;

/**
 * A document's value together with the version it was read or written at. Pass the version back
 * to a compare-and-set write; the write fails with DocumentConflictException if the document
 * changed since. Versioned forwards to its value, except for a field of the value named `value`
 * or `version_`, which is reached through `.value`.
 */
struct Versioned(T)
{
    T value;
    ulong version_;
    alias value this;
}

/**
 * Puts the value of `found` in `value` and returns true, or returns false if `found` is null.
 * For callers that only read: `stores.projects.get(id).tryValue(project)`.
 */
bool tryValue(T)(Nullable!(Versioned!T) found, out T value)
{
    if (found.isNull) return false;
    value = found.get.value;
    return true;
}

/// One page of typed query results. See QueryPage.
struct Page(T)
{
    Versioned!T[] items;
    /// Pass as IndexQuery.cursor to fetch the next page; null when there are no more results.
    string nextCursor;
}

/// A stored document whose content does not deserialize as the collection's type.
class MalformedDocumentException : Exception
{
    string collection;
    string id;

    this(string msg, string collection, string id, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.collection = collection;
        this.id = id;
    }
}

/**
 * Typed documents of type `T` in one collection. Every method throws on failure, as
 * DocumentStore does; none returns a sentinel.
 */
final class DocumentCollection(T)
{
    /// Computes the derived index key fields of a value: field name -> key value. A field left
    /// out of the result is left out of the document, so the document is not in indexes on it.
    alias DerivedFields = string[string] function(in T value);

    private DocumentStore m_store;
    private CollectionSpec m_spec;
    private const(string)[] m_derivedNames;
    private DerivedFields m_derive;

    /**
     * Declares `spec` on `store`. `derivedNames` lists every field `derive` may add; they must
     * not be fields of `T`'s serialized form. `derive` may be null when there are none.
     */
    this(DocumentStore store, CollectionSpec spec, const(string)[] derivedNames = null, DerivedFields derive = null)
    {
        if (store is null)
        {
            throw new Exception(format("The '%s' collection requires a document store", spec.name));
        }
        if ((derivedNames.length > 0) != (derive !is null))
        {
            throw new Exception(format("The '%s' collection must name its derived fields exactly when it derives any", spec.name));
        }
        m_store = store;
        m_spec = spec;
        m_derivedNames = derivedNames;
        m_derive = derive;
        m_store.declare([spec]);
    }

    @property string name() const { return m_spec.name; }

    /// Reads a document by id. Strongly consistent. Null if it does not exist.
    Nullable!(Versioned!T) get(string id)
    {
        auto document = m_store.get(m_spec.name, id);
        if (document.isNull) return Nullable!(Versioned!T).init;
        return nullable(decode(document.get));
    }

    /// Creates a document at version 1. Throws DocumentConflictException if it exists.
    Versioned!T create(string id, T value)
    {
        return decode(m_store.create(m_spec.name, id, encode(id, value)));
    }

    /**
     * Replaces a document if it is still at `expectedVersion`. Throws DocumentConflictException
     * if it does not exist or has changed since; the caller re-reads and decides again.
     */
    Versioned!T replace(string id, T value, ulong expectedVersion)
    {
        return decode(m_store.replace(m_spec.name, id, encode(id, value), expectedVersion));
    }

    /// Removes a document if it is still at `expectedVersion`. Throws DocumentConflictException
    /// if it does not exist or has changed since.
    void remove(string id, ulong expectedVersion)
    {
        m_store.remove(m_spec.name, id, expectedVersion);
    }

    /**
     * Writes `value` whether or not the document exists, over whatever version is current: the
     * last writer wins. Only for records edited by people (configuration), where the latest edit
     * is the one that should stand. Throws DocumentConflictException if another write lands
     * between this method's read and its write.
     */
    Versioned!T put(string id, T value)
    {
        auto current = m_store.get(m_spec.name, id);
        if (current.isNull) return create(id, value);
        return replace(id, value, current.get.version_);
    }

    /// Removes a document at whatever version is current. Returns false if it did not exist.
    /// Like put, only for configuration records. Throws DocumentConflictException if another
    /// write lands between this method's read and its removal.
    bool removeLatest(string id)
    {
        auto current = m_store.get(m_spec.name, id);
        if (current.isNull) return false;
        m_store.remove(m_spec.name, id, current.get.version_);
        return true;
    }

    /// Looks up one page in a declared index. May lag behind writes.
    Page!T query(const IndexQuery lookup)
    {
        auto page = m_store.query(m_spec.name, lookup);
        Page!T result;
        result.nextCursor = page.nextCursor;
        foreach (document; page.documents)
        {
            result.items ~= decode(document);
        }
        return result;
    }

    /**
     * Follows `lookup` from its cursor through every page until `max` documents are collected or
     * the results end. `lookup.limit` is the page size. May lag behind writes.
     */
    Versioned!T[] queryAll(IndexQuery lookup, size_t max = size_t.max)
    {
        Versioned!T[] result;
        while (result.length < max)
        {
            auto page = query(lookup);
            foreach (item; page.items)
            {
                if (result.length == max) break;
                result ~= item;
            }
            if (page.nextCursor.length == 0) break;
            lookup.cursor = page.nextCursor;
        }
        return result;
    }

    private Json encode(string id, T value)
    {
        Json content = serializeToJson(value);
        if (m_derive is null) return content;
        foreach (field, key; m_derive(value))
        {
            if (!canFindName(m_derivedNames, field))
            {
                throw new Exception(format("The '%s' collection derived field '%s', which it does not declare", m_spec.name, field));
            }
            if (field in content)
            {
                throw new Exception(format("Derived field '%s' of document '%s' in collection '%s' collides with a field of the document",
                    field, id, m_spec.name));
            }
            content[field] = Json(key);
        }
        return content;
    }

    private Versioned!T decode(Document document)
    {
        Json content = document.content;
        foreach (field; m_derivedNames)
        {
            if (field in content) content.remove(field);
        }
        try
        {
            return Versioned!T(deserializeJson!T(content), document.version_);
        }
        catch (Exception e)
        {
            throw new MalformedDocumentException(format("Document '%s' in collection '%s' is not a valid %s: %s",
                document.id, m_spec.name, T.stringof, e.msg), m_spec.name, document.id);
        }
    }

    private static bool canFindName(const(string)[] names, string name)
    {
        foreach (n; names)
        {
            if (n == name) return true;
        }
        return false;
    }
}

/**
 * A fixed-width UTC form of an ISO 8601 timestamp (`SysTime.toISOExtString`, as the build model
 * stores them) that sorts as text in time order, for index sort keys: `2026-10-15T14:02:00.0000000Z`.
 * Stored timestamps do not sort as text themselves, because toISOExtString leaves out zero
 * fractional seconds.
 *
 * Throws: Exception if `timestamp` is not an ISO 8601 extended timestamp.
 */
string sortableTimestamp(string timestamp)
{
    SysTime time;
    try
    {
        time = SysTime.fromISOExtString(timestamp);
    }
    catch (Exception e)
    {
        throw new Exception(format("'%s' is not an ISO 8601 timestamp: %s", timestamp, e.msg));
    }
    return sortableTime(time);
}

/// The sortable form (see sortableTimestamp) of `time`.
string sortableTime(in SysTime time)
{
    auto utc = time.toUTC();
    return format("%04d-%02d-%02dT%02d:%02d:%02d.%07dZ", utc.year, cast(int) utc.month, utc.day,
        utc.hour, utc.minute, utc.second, utc.fracSecs.total!"hnsecs");
}

/// A fixed-width decimal form of `number` that sorts as text in numeric order, for index sort keys.
string sortableNumber(ulong number) pure @safe
{
    return format("%020d", number);
}

/**
 * An unambiguous key made of several parts, for index keys over more than one field: the parts
 * as a JSON array, so no part can be confused with a separator.
 */
string compositeKey(const(string)[] parts...) @safe
{
    Json array = Json.emptyArray;
    foreach (part; parts) array ~= Json(part);
    return array.toString();
}

/// A document id made of several parts: the SHA-256 of their compositeKey, in hex, so ids stay
/// within maxKeyBytes however long the parts are.
string hashedId(const(string)[] parts...) @safe
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;

    return toHexString!(LetterCase.lower)(sha256Of(compositeKey(parts))).idup;
}

version (unittest)
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.algorithm.searching : canFind;
    import vibe.data.serialization : optional;

    private struct Item
    {
        string id;
        string group;
        @optional string[] tags;
        @optional long count;
    }

    private enum CollectionSpec itemsSpec = CollectionSpec("items", [IndexSpec("by_group", "group", "rank")]);

    private DocumentCollection!Item items(DocumentStore store)
    {
        return new DocumentCollection!Item(store, itemsSpec, ["rank"],
            (in Item item) => ["rank": sortableNumber(cast(ulong) item.count)]);
    }
}

unittest
{
    // Typed create, get, replace and remove, with compare-and-set on the version
    auto collection = items(new InMemoryDocumentStore());
    assert(collection.get("a").isNull);

    auto created = collection.create("a", Item("a", "g", ["x"], 3));
    assert(created.version_ == 1 && created.value == Item("a", "g", ["x"], 3));
    assert(created.group == "g", "Versioned forwards to its value");

    bool conflict = false;
    try collection.create("a", Item("a", "g"));
    catch (DocumentConflictException) conflict = true;
    assert(conflict, "Creating an existing document must conflict");

    auto replaced = collection.replace("a", Item("a", "g", null, 4), created.version_);
    assert(replaced.version_ == 2 && replaced.count == 4);

    conflict = false;
    try collection.replace("a", Item("a", "g", null, 5), created.version_);
    catch (DocumentConflictException) conflict = true;
    assert(conflict, "A stale version must conflict");
    assert(collection.get("a").get.count == 4);

    Item read;
    assert(collection.get("a").tryValue(read) && read.count == 4);
    assert(!collection.get("missing").tryValue(read));

    conflict = false;
    try collection.remove("a", created.version_);
    catch (DocumentConflictException) conflict = true;
    assert(conflict);
    collection.remove("a", replaced.version_);
    assert(collection.get("a").isNull);
}

unittest
{
    // Derived fields are stored for indexes but never reach the typed value
    auto store = new InMemoryDocumentStore();
    auto collection = items(store);
    foreach (i, n; [5, 1, 3]) collection.create(format("i%s", i), Item(format("i%s", i), "g", null, n));
    collection.create("other", Item("other", "h", null, 2));

    auto raw = store.get("items", "i0").get.content;
    assert(raw["rank"].get!string == sortableNumber(5));
    assert(collection.get("i0").get.value == Item("i0", "g", null, 5));

    IndexQuery lookup;
    lookup.index = "by_group";
    lookup.partitionKey = "g";
    lookup.limit = 2;
    auto first = collection.query(lookup);
    assert(first.items.length == 2 && first.items[0].count == 1 && first.items[1].count == 3);
    assert(first.nextCursor.length > 0);

    auto all = collection.queryAll(lookup);
    assert(all.length == 3 && all[2].count == 5, "queryAll follows the cursor");
    assert(collection.queryAll(lookup, 1).length == 1);
    lookup.descending = true;
    assert(collection.queryAll(lookup)[0].count == 5);
}

unittest
{
    // put writes whether or not the document exists; removeLatest removes at any version
    auto collection = items(new InMemoryDocumentStore());
    assert(collection.put("a", Item("a", "g")).version_ == 1);
    assert(collection.put("a", Item("a", "g", null, 2)).version_ == 2);
    assert(collection.removeLatest("a"));
    assert(!collection.removeLatest("a"));
}

unittest
{
    // put and removeLatest conflict, rather than overwrite, when another write lands between
    // their read and their write
    import confector.testing.memory_document_store : InterleavingDocumentStore;

    auto documents = new InMemoryDocumentStore();
    auto other = items(documents);
    auto interleaving = new InterleavingDocumentStore(documents);
    auto collection = items(interleaving);

    interleaving.beforeNextWrite = () { other.create("a", Item("a", "g", null, 1)); };
    bool conflict = false;
    try collection.put("a", Item("a", "g", null, 2));
    catch (DocumentConflictException) conflict = true;
    assert(conflict, "put must not overwrite a document created after its read");
    assert(collection.get("a").get.count == 1);

    interleaving.beforeNextWrite = () { other.put("a", Item("a", "g", null, 3)); };
    conflict = false;
    try collection.put("a", Item("a", "g", null, 4));
    catch (DocumentConflictException) conflict = true;
    assert(conflict, "put must not overwrite a version written after its read");
    assert(collection.get("a").get.count == 3);

    interleaving.beforeNextWrite = () { other.put("a", Item("a", "g", null, 5)); };
    conflict = false;
    try collection.removeLatest("a");
    catch (DocumentConflictException) conflict = true;
    assert(conflict, "removeLatest must not remove a version written after its read");
    assert(collection.get("a").get.count == 5);
}

unittest
{
    // A document that does not deserialize fails loudly, naming it
    auto store = new InMemoryDocumentStore();
    auto collection = items(store);
    store.create("items", "bad", Json(["count": Json("many")]));
    bool threw = false;
    try collection.get("bad");
    catch (MalformedDocumentException e) threw = e.id == "bad" && e.msg.canFind("'bad'");
    assert(threw);

    // A derived field that collides with a field of the type, or is not declared, fails loudly
    auto colliding = new DocumentCollection!Item(store, CollectionSpec("colliding", null), ["group"],
        (in Item item) => ["group": "x"]);
    threw = false;
    try colliding.create("a", Item("a", "g"));
    catch (Exception e) threw = e.msg.canFind("collides");
    assert(threw);

    auto undeclared = new DocumentCollection!Item(store, CollectionSpec("undeclared", null), ["rank"],
        (in Item item) => ["other": "x"]);
    threw = false;
    try undeclared.create("a", Item("a", "g"));
    catch (Exception e) threw = e.msg.canFind("does not declare");
    assert(threw);
}

unittest
{
    // Sortable keys sort as text in time and numeric order
    assert(sortableTimestamp("2026-10-15T14:02:00Z") == "2026-10-15T14:02:00.0000000Z");
    assert(sortableTimestamp("2026-10-15T14:02:00.5Z") == "2026-10-15T14:02:00.5000000Z");
    assert(sortableTimestamp("2026-10-15T16:02:00+02:00") == "2026-10-15T14:02:00.0000000Z");
    assert(sortableTimestamp("2026-10-15T14:02:00Z") < sortableTimestamp("2026-10-15T14:02:00.1Z"));
    bool threw = false;
    try sortableTimestamp("yesterday");
    catch (Exception e) threw = e.msg.canFind("yesterday");
    assert(threw);

    assert(sortableNumber(9) < sortableNumber(10));
    assert(sortableNumber(0).length == 20);

    // Composite keys and hashed ids cannot be confused by separators in parts
    assert(compositeKey("a/b", "c") != compositeKey("a", "b/c"));
    assert(compositeKey("a", "b") == `["a","b"]`);
    assert(hashedId("a", "b") != hashedId("a", "b", ""));
    assert(hashedId("a", "b") == hashedId("a", "b") && hashedId("a").length == 64);
}
