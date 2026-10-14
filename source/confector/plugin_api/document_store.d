module confector.plugin_api.document_store;

/**
 * The state store backend interface: a small document store with versioned
 * compare-and-set and declared index queries (design record: bead confector-z7z.4).
 *
 * Domain logic (chains, executions, branches, ...) is core code written on top of this
 * interface, so a new backend (DynamoDB, Postgres, SQLite) only has to provide these
 * primitives.
 *
 * Consistency contract:
 * - get() and the compare-and-set writes (create, replace, remove) on a single document are
 *   strongly consistent. Correctness may depend only on these.
 * - query() is for discovery and may lag behind writes (for example DynamoDB global secondary
 *   indexes). Callers must tolerate stale or missing results.
 * - There are no multi-document transactions.
 */

import std.typecons : Nullable;
import vibe.data.json : Json;

/// Largest document a store accepts, in bytes, measured as compact JSON (Json.toString()) by
/// validateDocument. Larger data belongs in the artifact or log store.
enum size_t maxDocumentBytes = 256 * 1024;

/// Longest document id or indexed key value, in UTF-8 bytes. Chosen to fit DynamoDB, whose sort
/// keys are limited to 1024 bytes, and common SQL and Mongo index key limits.
enum size_t maxKeyBytes = 1024;

/**
 * An index over one collection. Every query is a lookup in a declared index: equality on the
 * partition key, plus an optional range on the sort key.
 *
 * Key fields are top-level fields of the document content and hold non-empty strings of at most
 * maxKeyBytes. Sort keys are ordered by their UTF-8 bytes; encode numbers and times so that this
 * order is the one you want (for example zero-padded numbers, ISO 8601 UTC timestamps).
 *
 * Indexes are sparse: a document without the partition key field (or, when the index has one,
 * the sort key field) is not in the index. Writes reject key fields that are not strings, but a
 * document stored before its collection gained an index may hold one; such a document is also
 * not in the index.
 */
struct IndexSpec
{
    /// Matches [a-z][a-z0-9_]*, so every backend can use it as an object name.
    string name;
    string partitionKey;
    /// Empty when the index has no sort key; results are then in an unspecified order. Must
    /// differ from the partition key.
    string sortKey;
}

/// A collection and its indexes, declared by the core at startup.
struct CollectionSpec
{
    /// Matches [a-z][a-z0-9_]*, so every backend can use it as an object name.
    string name;
    IndexSpec[] indexes;
}

/**
 * A stored document. The version starts at 1 on create and increases by one on each replace.
 *
 * Content field names are not reserved: a backend that stores the id and version alongside the
 * content must keep them from colliding with content fields.
 */
struct Document
{
    string id;
    ulong version_;
    /// Always a JSON object.
    Json content;
}

/// An index lookup.
struct IndexQuery
{
    string index;
    /// Must not be empty.
    string partitionKey;
    /// Inclusive lower bound on the sort key; null for no bound. Requires an index sort key.
    Nullable!string sortKeyFrom;
    /// Inclusive upper bound on the sort key; null for no bound. Requires an index sort key and,
    /// with a lower bound, must not sort before it.
    Nullable!string sortKeyTo;
    /// Return results in descending sort key order.
    bool descending;
    /// Maximum number of documents in one page; must be positive. A page may hold fewer.
    size_t limit;
    /// The nextCursor of the previous page of the same query, or null for the first page.
    /// Cursors are opaque; a malformed one throws DocumentStoreUsageException.
    string cursor;
}

/// One page of query results.
struct QueryPage
{
    Document[] documents;
    /// Pass as IndexQuery.cursor to fetch the next page. Null when there are no more results;
    /// a backend may also return a cursor whose page turns out to be empty.
    string nextCursor;
}

/**
 * A document store backend. Every method throws on failure; none returns a sentinel.
 *
 * Operations on a collection or index that was not declared throw DocumentStoreUsageException,
 * as do invalid arguments: see validateCollectionSpec, validateDocument and validateIndexQuery,
 * which every backend calls so that all backends enforce the contract the same way.
 */
interface DocumentStore
{
    /**
     * Declares collections and their indexes, creating them in the backend if needed, and
     * returns once they can be queried. Called by the core at startup before any other operation.
     * Declaring a collection again with an identical spec is a no-op; with a different spec it
     * throws DocumentStoreUsageException.
     */
    void declare(const(CollectionSpec)[] collections);

    /// Reads a document by id. Strongly consistent. Null if it does not exist.
    Nullable!Document get(string collection, string id);

    /**
     * Creates a document at version 1. Throws DocumentConflictException if a document with
     * that id exists, and DocumentTooLargeException if the content exceeds maxDocumentBytes.
     */
    Document create(string collection, string id, Json content);

    /**
     * Replaces a document if its current version is expectedVersion, and returns it at the
     * next version. Throws DocumentConflictException if the document does not exist or has a
     * different version, and DocumentTooLargeException if the content exceeds maxDocumentBytes.
     */
    Document replace(string collection, string id, Json content, ulong expectedVersion);

    /**
     * Removes a document if its current version is expectedVersion. Throws
     * DocumentConflictException if the document does not exist or has a different version.
     */
    void remove(string collection, string id, ulong expectedVersion);

    /// Looks up documents in a declared index. May lag behind writes.
    QueryPage query(string collection, const IndexQuery lookup);
}

/// A create or compare-and-set write lost: the document exists, is missing, or has another
/// version. Re-read and decide again.
class DocumentConflictException : Exception
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

/// Document content exceeds maxDocumentBytes.
class DocumentTooLargeException : Exception
{
    string collection;
    string id;
    size_t sizeBytes;

    this(string msg, string collection, string id, size_t sizeBytes, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.collection = collection;
        this.id = id;
        this.sizeBytes = sizeBytes;
    }
}

/// The store was used incorrectly: an undeclared collection or index, or an invalid argument.
class DocumentStoreUsageException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

// Validation shared by backends, so every backend enforces the contract the same way.

/**
 * Throws DocumentStoreUsageException unless the collection and index names are valid object
 * names, every index has a unique name and a partition key, and no sort key repeats its
 * partition key.
 */
void validateCollectionSpec(const CollectionSpec spec) @safe pure
{
    import std.format : format;

    if (!isObjectName(spec.name))
        throw new DocumentStoreUsageException(format("Collection name '%s' does not match [a-z][a-z0-9_]*", spec.name));
    foreach (i, index; spec.indexes)
    {
        if (!isObjectName(index.name))
            throw new DocumentStoreUsageException(format("Index name '%s' on collection '%s' does not match [a-z][a-z0-9_]*", index.name, spec.name));
        if (index.partitionKey.length == 0)
            throw new DocumentStoreUsageException(format("Index '%s' on collection '%s' has no partition key", index.name, spec.name));
        if (index.sortKey == index.partitionKey)
            throw new DocumentStoreUsageException(format("Index '%s' on collection '%s' uses '%s' as both partition key and sort key", index.name, spec.name, index.partitionKey));
        foreach (other; spec.indexes[0 .. i])
            if (other.name == index.name)
                throw new DocumentStoreUsageException(format("Collection '%s' declares index '%s' twice", spec.name, index.name));
    }
}

/// Throws DocumentStoreUsageException unless a repeated declaration of a collection is identical
/// to the existing one.
void checkRedeclaration(const CollectionSpec existing, const CollectionSpec incoming) @safe pure
{
    import std.format : format;

    if (existing != incoming)
        throw new DocumentStoreUsageException(format(
            "Collection '%s' is already declared as %s; cannot redeclare it as %s", existing.name, existing, incoming));
}

/// Returns the named index of a collection, or throws DocumentStoreUsageException.
IndexSpec findIndex(const CollectionSpec spec, string indexName) @safe pure
{
    import std.format : format;

    foreach (index; spec.indexes)
        if (index.name == indexName)
            return index;
    throw new DocumentStoreUsageException(format("Index '%s' is not declared on collection '%s'", indexName, spec.name));
}

/**
 * Checks a document about to be written: an id of 1 to maxKeyBytes bytes, content that is a
 * JSON object, a non-empty string of at most maxKeyBytes in every indexed field that is present,
 * and a size within maxDocumentBytes. Returns the size. Throws DocumentStoreUsageException or
 * DocumentTooLargeException.
 */
size_t validateDocument(const CollectionSpec spec, string id, Json content) @safe
{
    import std.format : format;

    if (id.length == 0 || id.length > maxKeyBytes)
        throw new DocumentStoreUsageException(format("Document id in collection '%s' is %s bytes; it must be 1 to %s", spec.name, id.length, maxKeyBytes));
    if (content.type != Json.Type.object)
        throw new DocumentStoreUsageException(format("Document '%s' in collection '%s' must be a JSON object, not %s", id, spec.name, jsonTypeName(content.type)));
    foreach (index; spec.indexes)
    {
        foreach (field; [index.partitionKey, index.sortKey])
        {
            if (field.length == 0)
                continue;
            // `in` rather than opIndex: opIndex adds missing keys to the object.
            auto value = field in content;
            if (value is null)
                continue;
            if (value.type != Json.Type.string)
                throw new DocumentStoreUsageException(format(
                    "Field '%s' of document '%s' in collection '%s' is a key of index '%s' and must be a string, not %s",
                    field, id, spec.name, index.name, jsonTypeName(value.type)));
            const length = value.get!string.length;
            if (length == 0 || length > maxKeyBytes)
                throw new DocumentStoreUsageException(format(
                    "Field '%s' of document '%s' in collection '%s' is a key of index '%s' and is %s bytes; it must be 1 to %s",
                    field, id, spec.name, index.name, length, maxKeyBytes));
        }
    }
    const sizeBytes = content.toString().length;
    if (sizeBytes > maxDocumentBytes)
        throw new DocumentTooLargeException(format(
            "Document '%s' in collection '%s' is %s bytes; the limit is %s. Store large data in the artifact or log store.",
            id, spec.name, sizeBytes, maxDocumentBytes), spec.name, id, sizeBytes);
    return sizeBytes;
}

/**
 * Checks a query against its collection and returns the index it names. Throws
 * DocumentStoreUsageException for an undeclared index, an empty partition key, a limit of 0, a
 * sort key range on an index without a sort key, or an upper bound below the lower bound.
 */
IndexSpec validateIndexQuery(const CollectionSpec spec, const IndexQuery lookup) @safe pure
{
    import std.format : format;

    auto index = findIndex(spec, lookup.index);
    if (lookup.partitionKey.length == 0)
        throw new DocumentStoreUsageException(format("Query on index '%s' of collection '%s' has an empty partition key", lookup.index, spec.name));
    if (lookup.limit == 0)
        throw new DocumentStoreUsageException(format("Query on index '%s' of collection '%s' has a limit of 0", lookup.index, spec.name));
    if ((!lookup.sortKeyFrom.isNull || !lookup.sortKeyTo.isNull) && index.sortKey.length == 0)
        throw new DocumentStoreUsageException(format("Index '%s' of collection '%s' has no sort key, so a query on it cannot have a sort key range", lookup.index, spec.name));
    if (!lookup.sortKeyFrom.isNull && !lookup.sortKeyTo.isNull && lookup.sortKeyTo.get < lookup.sortKeyFrom.get)
        throw new DocumentStoreUsageException(format("Query on index '%s' of collection '%s' has upper bound '%s' below lower bound '%s'",
            lookup.index, spec.name, lookup.sortKeyTo.get, lookup.sortKeyFrom.get));
    return index;
}

private bool isObjectName(string name) @safe pure nothrow @nogc
{
    if (name.length == 0 || !(name[0] >= 'a' && name[0] <= 'z'))
        return false;
    foreach (c; name)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    return true;
}

/// Formatting Json.Type directly trips over its deprecated member aliases.
private string jsonTypeName(Json.Type type) @safe pure nothrow
{
    final switch (type)
    {
        case Json.Type.undefined: return "undefined";
        case Json.Type.null_: return "null";
        case Json.Type.bool_: return "a boolean";
        case Json.Type.int_: return "an integer";
        case Json.Type.bigInt: return "an integer";
        case Json.Type.float_: return "a number";
        case Json.Type.string: return "a string";
        case Json.Type.array: return "an array";
        case Json.Type.object: return "an object";
    }
}
