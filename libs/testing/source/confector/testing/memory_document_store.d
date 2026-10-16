module confector.testing.memory_document_store;

import confector.plugin_api.document_store;
import std.format : format;
import std.typecons : Nullable, nullable;
import vibe.data.json : Json, parseJsonString;

/**
 * DocumentStore kept in process memory. Used by tests; passes the DocumentStore conformance
 * suite (confector.testing.conformance.document_store). Queries are strongly consistent, which a
 * real backend need not be.
 *
 * Stored and returned contents are deep copies, so callers cannot change stored documents
 * except through the interface. Content is stored as the JSON text parsed again, as the
 * contract requires. Instances made by restart() share their data and lock on it.
 */
class InMemoryDocumentStore : DocumentStore
{
    /// What a restart keeps: the declared specs and the documents, like a real backend's
    /// database. Which collections this instance has declared since it was created is not kept.
    private static final class Backing
    {
        CollectionSpec[string] specs;
        Document[string][string] documents; // collection -> id -> document
    }

    private Backing m_backing;
    private CollectionSpec[string] m_specs; // declared through this instance

    this()
    {
        m_backing = new Backing;
    }

    private this(Backing backing)
    {
        m_backing = backing;
    }

    /**
     * A new store over the same documents and declared specs, as if the process had restarted
     * against the same database: nothing is declared through it yet, so callers must declare
     * before using it. The original store stays usable.
     */
    InMemoryDocumentStore restart()
    {
        return new InMemoryDocumentStore(m_backing);
    }

    override void declare(const(CollectionSpec)[] collections)
    {
        synchronized (m_backing)
        {
            // Validate everything before changing anything, so a bad declaration leaves no trace.
            CollectionSpec[string] added;
            foreach (spec; collections)
            {
                validateCollectionSpec(spec);
                if (auto existing = spec.name in m_backing.specs)
                    checkRedeclaration(*existing, spec);
                else if (auto pending = spec.name in added)
                    checkRedeclaration(*pending, spec);
                else
                    added[spec.name] = CollectionSpec(spec.name, spec.indexes.dup);
            }
            foreach (spec; collections)
            {
                if (spec.name !in m_backing.specs)
                    m_backing.specs[spec.name] = added[spec.name];
                m_specs[spec.name] = m_backing.specs[spec.name];
            }
        }
    }

    override Nullable!Document get(string collection, string id)
    {
        synchronized (m_backing)
        {
            specFor(collection);
            if (auto documents = collection in m_backing.documents)
                if (auto document = id in *documents)
                    return nullable(copyOf(*document));
            return Nullable!Document.init;
        }
    }

    override Document create(string collection, string id, Json content)
    {
        synchronized (m_backing)
        {
            auto validated = validateDocumentText(specFor(collection), id, content);
            if (auto documents = collection in m_backing.documents)
                if (id in *documents)
                    throw new DocumentConflictException(format("Document '%s' already exists in collection '%s'", id, collection), collection, id);
            // Stored in the form every backend returns: the JSON text parsed again.
            auto document = Document(id, 1, validated.content);
            m_backing.documents[collection][id] = document;
            return copyOf(document);
        }
    }

    override Document replace(string collection, string id, Json content, ulong expectedVersion)
    {
        synchronized (m_backing)
        {
            auto validated = validateDocumentText(specFor(collection), id, content);
            auto current = expectVersion(collection, id, expectedVersion, "replace");
            auto document = Document(id, current.version_ + 1, validated.content);
            m_backing.documents[collection][id] = document;
            return copyOf(document);
        }
    }

    override void remove(string collection, string id, ulong expectedVersion)
    {
        synchronized (m_backing)
        {
            specFor(collection);
            expectVersion(collection, id, expectedVersion, "remove");
            m_backing.documents[collection].remove(id);
        }
    }

    override QueryPage query(string collection, const IndexQuery lookup)
    {
        import std.algorithm.sorting : sort;

        synchronized (m_backing)
        {
            const index = validateIndexQuery(specFor(collection), lookup);

            Entry[] entries;
            if (auto documents = collection in m_backing.documents)
            {
                foreach (ref document; *documents)
                {
                    // A key field that is missing or not a string leaves the document out of the index.
                    auto partition = index.partitionKey in document.content;
                    if (partition is null || partition.type != Json.Type.string || partition.get!string != lookup.partitionKey)
                        continue;
                    string sortValue;
                    if (index.sortKey.length > 0)
                    {
                        auto sortField = index.sortKey in document.content;
                        if (sortField is null || sortField.type != Json.Type.string)
                            continue;
                        sortValue = sortField.get!string;
                        if (!lookup.sortKeyFrom.isNull && sortValue < lookup.sortKeyFrom.get)
                            continue;
                        if (!lookup.sortKeyTo.isNull && sortValue > lookup.sortKeyTo.get)
                            continue;
                    }
                    entries ~= Entry(Position(sortValue, document.id), &document);
                }
            }

            // Ties on the sort key, and indexes without one, are ordered by id so paging is stable.
            if (lookup.descending)
                entries.sort!((a, b) => a.position > b.position);
            else
                entries.sort!((a, b) => a.position < b.position);

            size_t start = 0;
            if (lookup.cursor.length > 0)
            {
                const after = decodeCursor(lookup.cursor);
                while (start < entries.length
                       && (lookup.descending ? entries[start].position >= after : entries[start].position <= after))
                    start++;
            }

            QueryPage page;
            foreach (entry; entries[start .. $])
            {
                if (page.documents.length == lookup.limit)
                {
                    page.nextCursor = encodeCursor(entries[start + page.documents.length - 1].position);
                    break;
                }
                page.documents ~= copyOf(*entry.document);
            }
            return page;
        }
    }

    /// Where a document falls in an index: by sort key, then by id.
    private static struct Position
    {
        string sortValue;
        string id;

        int opCmp(const Position other) const @safe pure nothrow
        {
            import std.algorithm.comparison : cmp;

            if (auto bySort = cmp(sortValue, other.sortValue))
                return bySort;
            return cmp(id, other.id);
        }
    }

    private static struct Entry
    {
        Position position;
        Document* document;
    }

    private static string encodeCursor(const Position position)
    {
        return Json([Json(position.sortValue), Json(position.id)]).toString();
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

    private Document expectVersion(string collection, string id, ulong expectedVersion, string operation)
    {
        if (auto documents = collection in m_backing.documents)
        {
            if (auto document = id in *documents)
            {
                if (document.version_ != expectedVersion)
                    throw new DocumentConflictException(format(
                        "Cannot %s document '%s' in collection '%s': expected version %s, found %s",
                        operation, id, collection, expectedVersion, document.version_), collection, id);
                return *document;
            }
        }
        throw new DocumentConflictException(format(
            "Cannot %s document '%s' in collection '%s' at version %s: it does not exist",
            operation, id, collection, expectedVersion), collection, id);
    }

    private static Document copyOf(const ref Document document)
    {
        return Document(document.id, document.version_, document.content.clone());
    }
}

import std.typecons : Nullable;

/**
 * For tests: passes everything through to `inner`, running `beforeNextWrite` (once) just
 * before the next create, replace or remove, to interleave a concurrent writer
 * deterministically.
 */
final class InterleavingDocumentStore : DocumentStore
{
    DocumentStore inner;
    void delegate() beforeNextWrite;

    this(DocumentStore inner) { this.inner = inner; }

    private void interleave()
    {
        if (beforeNextWrite is null) return;
        auto run = beforeNextWrite;
        beforeNextWrite = null;
        run();
    }

    override void declare(const(CollectionSpec)[] collections) { inner.declare(collections); }
    override Nullable!Document get(string collection, string id) { return inner.get(collection, id); }
    override Document create(string collection, string id, Json content)
    {
        interleave();
        return inner.create(collection, id, content);
    }
    override Document replace(string collection, string id, Json content, ulong expectedVersion)
    {
        interleave();
        return inner.replace(collection, id, content, expectedVersion);
    }
    override void remove(string collection, string id, ulong expectedVersion)
    {
        interleave();
        inner.remove(collection, id, expectedVersion);
    }
    override QueryPage query(string collection, const IndexQuery lookup) { return inner.query(collection, lookup); }
}
