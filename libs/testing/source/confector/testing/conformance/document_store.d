module confector.testing.conformance.document_store;

/**
 * Conformance suite for DocumentStore backends. Every backend, including in-memory test fakes,
 * must pass it (design record: bead confector-z7z.4).
 *
 * Run it from a backend's tests:
 *
 *     checkDocumentStore(() => new MyDocumentStore(freshTestDatabase()), (previous) => reopen(previous));
 *
 * The factory is called once per check and must return an empty store each time. The restart
 * function takes a store the factory returned and returns a new store over the same data, as a
 * process restart would: documents and declared collections are kept, but nothing is declared
 * through the new store until the test declares it. The original store stays usable.
 *
 * Query checks read their own writes immediately. A backend whose queries may lag in production
 * (such as DynamoDB global secondary indexes) must run the suite in a configuration where they
 * do not, such as a local emulator.
 */

import confector.plugin_api.document_store;
import std.format : format;
import std.typecons : nullable;
import vibe.data.json : Json;

/// A backend broke the DocumentStore contract.
class DocumentStoreConformanceException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Runs every check against stores from makeStore. Throws DocumentStoreConformanceException on
/// the first failure.
void checkDocumentStore(DocumentStore delegate() makeStore, DocumentStore delegate(DocumentStore) restart)
{
    foreach (check; checks)
        runCheck(check.name, () { check.run(makeStoreAndDeclare(makeStore)); });
    foreach (check; restartChecks)
        runCheck(check.name, () { auto store = makeStoreAndDeclare(makeStore); check.run(store, restart); });
}

private DocumentStore makeStoreAndDeclare(DocumentStore delegate() makeStore)
{
    auto store = makeStore();
    store.declare(collections);
    return store;
}

private void runCheck(string name, void delegate() run)
{
    try
        run();
    catch (Exception e)
        throw new DocumentStoreConformanceException(format("DocumentStore conformance check '%s' failed: %s%s",
            name, cast(DocumentStoreConformanceException) e ? "" : typeid(e).name ~ ": ", e.msg), e.file, e.line);
}

private:

struct Check
{
    string name;
    void function(DocumentStore) run;
}

struct RestartCheck
{
    string name;
    void function(DocumentStore, DocumentStore delegate(DocumentStore)) run;
}

immutable Check[] checks = [
    Check("create and get", &createAndGet),
    Check("content round-trips", &contentRoundTrips),
    Check("create conflicts", &createConflicts),
    Check("replace is compare-and-set", &replaceIsCompareAndSet),
    Check("remove is compare-and-set", &removeIsCompareAndSet),
    Check("stored documents are isolated from callers", &storedDocumentsAreIsolated),
    Check("size limit", &sizeLimit),
    Check("usage errors", &usageErrors),
    Check("declarations", &declarations),
    Check("query by partition and sort key", &queryByPartitionAndSortKey),
    Check("query sort key range", &querySortKeyRange),
    Check("query paging", &queryPaging),
    Check("query paging across writes", &queryPagingAcrossWrites),
    Check("query index without sort key", &queryIndexWithoutSortKey),
    Check("queries follow writes", &queriesFollowWrites),
    Check("numbers JSON cannot represent", &unrepresentableNumbers),
    Check("content reads back as parsed JSON text", &contentIsNormalized),
    Check("floats that do not parse back", &floatsThatDoNotParseBack),
];

immutable RestartCheck[] restartChecks = [
    RestartCheck("declarations survive a restart", &declarationsSurviveRestart),
];

enum things = "things";
enum byOwner = "by_owner";      // partition: owner, sort: created
enum byColor = "by_color";      // partition: color, no sort key
enum others = "others";

immutable CollectionSpec[] collections = [
    CollectionSpec(things, [IndexSpec(byOwner, "owner", "created"), IndexSpec(byColor, "color")]),
    CollectionSpec(others, []),
];

void expect(bool condition, lazy string message, string file = __FILE__, size_t line = __LINE__)
{
    if (!condition)
        throw new DocumentStoreConformanceException(message, file, line);
}

void expectThrows(E : Throwable)(scope void delegate() action, string what, string file = __FILE__, size_t line = __LINE__)
{
    try
        action();
    catch (E)
        return;
    catch (Exception e)
        throw new DocumentStoreConformanceException(format("%s: expected %s, got %s: %s", what, E.stringof, typeid(e).name, e.msg), file, line);
    throw new DocumentStoreConformanceException(format("%s: expected %s, nothing was thrown", what, E.stringof), file, line);
}

Json thing(string owner, string created, string color = null)
{
    auto content = Json.emptyObject;
    content["owner"] = owner;
    content["created"] = created;
    if (color !is null)
        content["color"] = color;
    return content;
}

string[] ids(const Document[] documents)
{
    string[] result;
    foreach (document; documents)
        result ~= document.id;
    return result;
}

/// Follows cursors until the end and returns every document, in order.
Document[] queryAll(DocumentStore store, IndexQuery query)
{
    Document[] all;
    foreach (pageNumber; 0 .. 1000)
    {
        auto page = store.query(things, query);
        expect(page.documents.length <= query.limit, format("page holds %s documents, more than the limit %s", page.documents.length, query.limit));
        all ~= page.documents;
        if (page.nextCursor.length == 0)
            return all;
        query.cursor = page.nextCursor;
    }
    throw new DocumentStoreConformanceException("query paging did not end after 1000 pages");
}

void createAndGet(DocumentStore store)
{
    expect(store.get(things, "a").isNull, "get of a missing document returned a document");

    auto content = thing("ann", "2026-01-01", "red");
    content["nested"] = Json(["x": Json(1), "y": Json([Json(true), Json(null)])]);
    auto created = store.create(things, "a", content);
    expect(created.id == "a", format("create returned id '%s'", created.id));
    expect(created.version_ == 1, format("create returned version %s, not 1", created.version_));
    expect(created.content == content, format("create returned content %s, not %s", created.content, content));

    auto fetched = store.get(things, "a");
    expect(!fetched.isNull, "get did not find a created document");
    expect(fetched.get.version_ == 1, format("get returned version %s, not 1", fetched.get.version_));
    expect(fetched.get.content == content, format("get returned content %s, not %s", fetched.get.content, content));

    expect(store.get(others, "a").isNull, "a document is visible in a collection it was not created in");
    store.create(others, "a", Json.emptyObject);
    expect(store.get(things, "a").get.content == content, "a document in another collection with the same id overwrote it");
}

void createConflicts(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1"));
    expectThrows!DocumentConflictException(() { store.create(things, "a", thing("bob", "2")); }, "create of an existing id");
    expect(store.get(things, "a").get.content["owner"].get!string == "ann", "a failed create changed the existing document");
}

void replaceIsCompareAndSet(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1"));
    auto replaced = store.replace(things, "a", thing("ann", "2"), 1);
    expect(replaced.version_ == 2, format("replace returned version %s, not 2", replaced.version_));
    expect(store.get(things, "a").get.version_ == 2, "get after replace did not return version 2");
    expect(store.get(things, "a").get.content["created"].get!string == "2", "get after replace did not return the new content");

    expectThrows!DocumentConflictException(() { store.replace(things, "a", thing("ann", "3"), 1); }, "replace with a stale version");
    expectThrows!DocumentConflictException(() { store.replace(things, "a", thing("ann", "3"), 3); }, "replace with a future version");
    expect(store.get(things, "a").get.content["created"].get!string == "2", "a failed replace changed the document");

    expectThrows!DocumentConflictException(() { store.replace(things, "missing", thing("ann", "1"), 1); }, "replace of a missing document");
    expect(store.get(things, "missing").isNull, "replace of a missing document created it");

    expect(store.replace(things, "a", thing("ann", "3"), 2).version_ == 3, "a second replace did not return version 3");
}

void removeIsCompareAndSet(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1"));
    store.replace(things, "a", thing("ann", "2"), 1);
    expectThrows!DocumentConflictException(() { store.remove(things, "a", 1); }, "remove with a stale version");
    expect(!store.get(things, "a").isNull, "a failed remove removed the document");

    store.remove(things, "a", 2);
    expect(store.get(things, "a").isNull, "get found a removed document");
    expectThrows!DocumentConflictException(() { store.remove(things, "a", 2); }, "remove of a removed document");

    auto recreated = store.create(things, "a", thing("ann", "3"));
    expect(recreated.version_ == 1, format("create after remove returned version %s, not 1", recreated.version_));
}

void storedDocumentsAreIsolated(DocumentStore store)
{
    auto content = thing("ann", "1");
    store.create(things, "a", content);
    content["owner"] = "mallory";
    expect(store.get(things, "a").get.content["owner"].get!string == "ann", "changing content after create changed the stored document");

    auto fetched = store.get(things, "a").get;
    fetched.content["owner"] = "mallory";
    expect(store.get(things, "a").get.content["owner"].get!string == "ann", "changing a document returned by get changed the stored document");

    auto replacement = thing("bob", "2");
    auto replaced = store.replace(things, "a", replacement, 1);
    replacement["owner"] = "mallory";
    replaced.content["owner"] = "mallory";
    expect(store.get(things, "a").get.content["owner"].get!string == "bob", "changing content after replace changed the stored document");

    IndexQuery query = { index: byOwner, partitionKey: "bob", limit: 10 };
    auto page = store.query(things, query);
    expect(page.documents.length == 1, format("query found %s documents, not 1", page.documents.length));
    page.documents[0].content["owner"] = "mallory";
    expect(store.get(things, "a").get.content["owner"].get!string == "bob", "changing a document returned by query changed the stored document");
}

void sizeLimit(DocumentStore store)
{
    import std.array : replicate;

    // {"owner":"ann","created":"1","pad":"..."} with the pad sized to land exactly on the limit.
    auto content = thing("ann", "1");
    content["pad"] = "";
    const overhead = content.toString().length;
    content["pad"] = "x".replicate(maxDocumentBytes - overhead);
    expect(content.toString().length == maxDocumentBytes, "test setup: content is not exactly at the limit");
    store.create(things, "at-limit", content);

    content["pad"] = "x".replicate(maxDocumentBytes - overhead + 1);
    expectThrows!DocumentTooLargeException(() { store.create(things, "over-limit", content); }, "create over the size limit");
    expect(store.get(things, "over-limit").isNull, "a create over the size limit stored the document");

    expectThrows!DocumentTooLargeException(() { store.replace(things, "at-limit", content, 1); }, "replace over the size limit");
    expect(store.get(things, "at-limit").get.version_ == 1, "a replace over the size limit changed the document");

    content["pad"] = "y".replicate(maxDocumentBytes - overhead);
    expect(store.replace(things, "at-limit", content, 1).version_ == 2, "a replace exactly at the size limit was not accepted");
}

void usageErrors(DocumentStore store)
{
    import std.array : replicate;

    expectThrows!DocumentStoreUsageException(() { store.get("undeclared", "a"); }, "get from an undeclared collection");
    expectThrows!DocumentStoreUsageException(() { store.create("undeclared", "a", Json.emptyObject); }, "create in an undeclared collection");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "", thing("ann", "1")); }, "create with an empty id");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", Json([Json(1)])); }, "create with content that is not an object");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", Json("text")); }, "create with string content");

    auto numericOwner = thing("ann", "1");
    numericOwner["owner"] = 7;
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", numericOwner); }, "create with a non-string partition key field");
    auto nullSortKey = thing("ann", "1");
    nullSortKey["created"] = Json(null);
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", nullSortKey); }, "create with a null sort key field");
    expect(store.get(things, "a").isNull, "a rejected create stored the document");

    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", thing("", "1")); }, "create with an empty partition key value");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", thing("ann", "")); }, "create with an empty sort key value");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "a", thing("x".replicate(maxKeyBytes + 1), "1")); }, "create with a key value over maxKeyBytes");
    expectThrows!DocumentStoreUsageException(() { store.create(things, "x".replicate(maxKeyBytes + 1), thing("ann", "1")); }, "create with an id over maxKeyBytes");
    store.create(things, "x".replicate(maxKeyBytes), thing("x".replicate(maxKeyBytes), "x".replicate(maxKeyBytes)));

    store.create(things, "a", thing("ann", "1"));
    expectThrows!DocumentStoreUsageException(() { store.replace(things, "a", numericOwner, 1); }, "replace with a non-string partition key field");

    IndexQuery undeclaredIndex = { index: "undeclared", partitionKey: "ann", limit: 10 };
    expectThrows!DocumentStoreUsageException(() { store.query(things, undeclaredIndex); }, "query of an undeclared index");
    IndexQuery zeroLimit = { index: byOwner, partitionKey: "ann", limit: 0 };
    expectThrows!DocumentStoreUsageException(() { store.query(things, zeroLimit); }, "query with a limit of 0");
    IndexQuery rangeWithoutSortKey = { index: byColor, partitionKey: "red", sortKeyFrom: nullable("a"), limit: 10 };
    expectThrows!DocumentStoreUsageException(() { store.query(things, rangeWithoutSortKey); }, "sort key range on an index without a sort key");
    IndexQuery undeclaredCollection = { index: byOwner, partitionKey: "ann", limit: 10 };
    expectThrows!DocumentStoreUsageException(() { store.query("undeclared", undeclaredCollection); }, "query of an undeclared collection");
    IndexQuery emptyPartition = { index: byOwner, partitionKey: "", limit: 10 };
    expectThrows!DocumentStoreUsageException(() { store.query(things, emptyPartition); }, "query with an empty partition key");
    IndexQuery invertedRange = { index: byOwner, partitionKey: "ann", sortKeyFrom: nullable("b"), sortKeyTo: nullable("a"), limit: 10 };
    expectThrows!DocumentStoreUsageException(() { store.query(things, invertedRange); }, "query with an upper bound below the lower bound");
    IndexQuery badCursor = { index: byOwner, partitionKey: "ann", limit: 10, cursor: "not a cursor" };
    expectThrows!DocumentStoreUsageException(() { store.query(things, badCursor); }, "query with a malformed cursor");
}

void declarations(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1", "red"));
    store.declare(collections);  // identical redeclaration is a no-op
    expect(store.get(things, "a").get.content["owner"].get!string == "ann", "redeclaring a collection lost its documents");

    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec(things, [IndexSpec(byOwner, "owner", "updated")])]);
    }, "redeclaring an index with a different sort key");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec(things, [IndexSpec(byOwner, "owner", "created"), IndexSpec(byColor, "shade")])]);
    }, "redeclaring an index with a different partition key");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec(things, [IndexSpec(byOwner, "owner", "created")])]);
    }, "redeclaring a collection without one of its indexes");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec(others, [IndexSpec("by_owner", "owner")])]);
    }, "redeclaring a collection with an added index");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("new", [IndexSpec("i", "k")]), CollectionSpec("new", [IndexSpec("j", "k")])]);
    }, "declaring one collection two different ways in one call");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("New", [])]);
    }, "declaring a collection whose name is not [a-z][a-z0-9_]*");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("new", [IndexSpec("by-key", "k")])]);
    }, "declaring an index whose name is not [a-z][a-z0-9_]*");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("new", [IndexSpec("i", "k", "k")])]);
    }, "declaring an index whose sort key is its partition key");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("new", [IndexSpec("i", "k"), IndexSpec("i", "k")])]);
    }, "declaring an index twice in one collection");
    expectThrows!DocumentStoreUsageException(() {
        store.declare([CollectionSpec("new", [IndexSpec("i", "")])]);
    }, "declaring an index without a partition key");

    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
    expect(store.query(things, query).documents.length == 1, "a rejected redeclaration changed an existing index");
    expectThrows!DocumentStoreUsageException(() { store.get("new", "a"); }, "using a collection from a rejected declaration");
}

void queryByPartitionAndSortKey(DocumentStore store)
{
    store.create(things, "a", thing("ann", "2026-03"));
    store.create(things, "b", thing("ann", "2026-01"));
    store.create(things, "c", thing("bob", "2026-02"));
    store.create(things, "d", thing("ann", "2026-02"));
    auto noSortKey = Json.emptyObject;
    noSortKey["owner"] = "ann";
    store.create(things, "e", noSortKey);           // sparse: missing the sort key
    store.create(things, "f", Json.emptyObject);    // sparse: missing the partition key

    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
    auto ascending = store.query(things, query).documents.ids;
    expect(ascending == ["b", "d", "a"], format("ascending query returned %s, not [b, d, a]", ascending));

    query.descending = true;
    auto descending = store.query(things, query).documents.ids;
    expect(descending == ["a", "d", "b"], format("descending query returned %s, not [a, d, b]", descending));

    query.partitionKey = "nobody";
    expect(store.query(things, query).documents.length == 0, "query of an empty partition returned documents");

    query.partitionKey = "bob";
    auto bob = store.query(things, query).documents;
    expect(bob.length == 1 && bob[0].id == "c" && bob[0].version_ == 1 && bob[0].content == thing("bob", "2026-02"),
        format("query returned %s, not document c at version 1", bob));
}

void querySortKeyRange(DocumentStore store)
{
    foreach (i, created; ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05"])
        store.create(things, format("t%s", i), thing("ann", created));

    IndexQuery query = { index: byOwner, partitionKey: "ann", sortKeyFrom: nullable("2026-02"), sortKeyTo: nullable("2026-04"), limit: 10 };
    auto between = store.query(things, query).documents.ids;
    expect(between == ["t1", "t2", "t3"], format("inclusive range query returned %s, not [t1, t2, t3]", between));

    query.descending = true;
    auto betweenDescending = store.query(things, query).documents.ids;
    expect(betweenDescending == ["t3", "t2", "t1"], format("descending range query returned %s, not [t3, t2, t1]", betweenDescending));

    query.descending = false;
    query.sortKeyTo.nullify();
    auto from = store.query(things, query).documents.ids;
    expect(from == ["t1", "t2", "t3", "t4"], format("lower-bound query returned %s, not [t1, t2, t3, t4]", from));

    query.sortKeyFrom.nullify();
    query.sortKeyTo = "2026-02";
    auto to = store.query(things, query).documents.ids;
    expect(to == ["t0", "t1"], format("upper-bound query returned %s, not [t0, t1]", to));

    // Sort keys compare by UTF-8 bytes, not by locale.
    store.create(things, "upper", thing("cy", "B"));
    store.create(things, "lower", thing("cy", "a"));
    store.create(things, "accent", thing("cy", "é"));
    IndexQuery bytes = { index: byOwner, partitionKey: "cy", limit: 10 };
    auto byteOrder = store.query(things, bytes).documents.ids;
    expect(byteOrder == ["upper", "lower", "accent"], format("sort keys are not in UTF-8 byte order: %s", byteOrder));
}

void queryPaging(DocumentStore store)
{
    string[] expected;
    foreach (i; 0 .. 7)
    {
        auto id = format("p%s", i);
        store.create(things, id, thing("ann", format("2026-%02d", i)));
        expected ~= id;
    }
    // Two documents share a sort key, so paging must also be stable across ties.
    store.create(things, "tie", thing("ann", "2026-03"));

    foreach (limit; [1, 2, 3, 8, 20])
    {
        IndexQuery query = { index: byOwner, partitionKey: "ann", limit: limit };
        auto all = queryAll(store, query).ids;
        expect(all.length == 8, format("paging with limit %s returned %s documents, not 8: %s", limit, all.length, all));
        foreach (i, id; ["p0", "p1", "p2", "p3", "p4", "p5", "p6"])
            expect(canFindId(all, id), format("paging with limit %s did not return %s", limit, id));
        expect(canFindId(all, "tie"), format("paging with limit %s did not return the tied document", limit));
        expect(all[0 .. 3] == ["p0", "p1", "p2"] && all[5 .. $] == ["p4", "p5", "p6"],
            format("paging with limit %s returned documents out of order: %s", limit, all));

        query.descending = true;
        auto reversed = queryAll(store, query).ids;
        expect(reversed.length == 8 && reversed[0 .. 3] == ["p6", "p5", "p4"] && reversed[5 .. $] == ["p2", "p1", "p0"],
            format("descending paging with limit %s returned %s", limit, reversed));
    }
}

void contentRoundTrips(DocumentStore store)
{
    import vibe.data.json : parseJsonString;

    auto content = parseJsonString(`{
        "owner": "ann", "created": "1",
        "float": 0.1, "negative": -2.5e-300, "big": 9007199254740993, "min": -9223372036854775808,
        "zero": 0, "bool": false, "null": null,
        "text": "quote \" backslash \\ newline \n tab \t nul \u0000 emoji \ud83d\ude00 accent \u00e9",
        "empty_array": [], "empty_object": {}, "nested": {"a": [1, "two", [3], {"four": 4}]},
        "$dollar": 1, "dotted.name": 2, "id": "content id", "version": "content version", "version_": 3
    }`);
    store.create(things, "a", content);
    auto stored = store.get(things, "a").get;
    expect(stored.id == "a" && stored.version_ == 1, format("content fields named like id and version changed the document's id or version: %s", stored));
    expect(stored.content == content, format("content did not round-trip:\n written %s\n read    %s", content, stored.content));

    store.create(things, "unicode \u00e9 / \U0001F600 . $", thing("ann", "2"));
    expect(!store.get(things, "unicode \u00e9 / \U0001F600 . $").isNull,"an id with non-ASCII and punctuation characters was not found");
}

void queryPagingAcrossWrites(DocumentStore store)
{
    foreach (i; 0 .. 6)
        store.create(things, format("p%s", i), thing("ann", format("2026-%02d", i)));

    // Remove the document a cursor points at and insert one before it: the next page still
    // continues after the cursor's position, neither skipping nor repeating documents.
    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 2 };
    auto first = store.query(things, query);
    expect(first.documents.ids == ["p0", "p1"], format("first page returned %s, not [p0, p1]", first.documents.ids));
    store.remove(things, "p1", 1);
    store.create(things, "early", thing("ann", "2025-12"));
    query.cursor = first.nextCursor;
    auto rest = queryAll(store, query).ids;
    expect(rest == ["p2", "p3", "p4", "p5"], format("pages after a write returned %s, not [p2, p3, p4, p5]", rest));
}

void queryIndexWithoutSortKey(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1", "red"));
    store.create(things, "b", thing("bob", "2", "blue"));
    store.create(things, "c", thing("cy", "3", "red"));
    store.create(things, "d", thing("dee", "4"));

    IndexQuery query = { index: byColor, partitionKey: "red", limit: 1 };
    auto red = queryAll(store, query).ids;
    expect(red.length == 2 && canFindId(red, "a") && canFindId(red, "c"), format("query by color returned %s, not a and c", red));
}

void queriesFollowWrites(DocumentStore store)
{
    store.create(things, "a", thing("ann", "1"));
    store.replace(things, "a", thing("bob", "1"), 1);

    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
    expect(store.query(things, query).documents.length == 0, "query still finds a document under its old partition key");
    query.partitionKey = "bob";
    auto bob = store.query(things, query).documents;
    expect(bob.length == 1 && bob[0].version_ == 2, format("query after replace returned %s, not document a at version 2", bob));

    store.remove(things, "a", 2);
    expect(store.query(things, query).documents.length == 0, "query still finds a removed document");
}

void unrepresentableNumbers(DocumentStore store)
{
    foreach (name, bad; ["NaN": double.nan, "infinity": double.infinity, "negative infinity": -double.infinity, "negative zero": -0.0])
    {
        auto top = thing("ann", "1");
        top["number"] = bad;
        expectThrows!DocumentStoreUsageException(() { store.create(things, "a", top); }, "create with " ~ name ~ " at the top level");
        auto nested = thing("ann", "1");
        nested["deep"] = Json(["list": Json([Json(1), Json(["x": Json(bad)])])]);
        expectThrows!DocumentStoreUsageException(() { store.create(things, "a", nested); }, "create with " ~ name ~ " nested in arrays and objects");
        expect(store.get(things, "a").isNull, "a rejected create stored the document");

        store.create(things, "b", thing("ann", "1"));
        expectThrows!DocumentStoreUsageException(() { store.replace(things, "b", top, 1); }, "replace with " ~ name);
        expect(store.get(things, "b").get.version_ == 1, "a rejected replace changed the document");
        store.remove(things, "b", 1);
    }

    auto fine = thing("ann", "1");
    fine["number"] = 1.5;
    store.create(things, "c", fine);
    expect(store.get(things, "c").get.content == fine, "finite floats did not round-trip");
}

/// Equal values of the same JSON types, all the way down (Json's own == is lenient between numbers).
bool sameJson(Json a, Json b)
{
    if (a.type != b.type)
        return false;
    switch (a.type)
    {
        case Json.Type.array:
            if (a.length != b.length)
                return false;
            foreach (i; 0 .. a.length)
                if (!sameJson(a[i], b[i]))
                    return false;
            return true;
        case Json.Type.object:
            if (a.length != b.length)
                return false;
            foreach (string key, value; a)
            {
                auto other = key in b;
                if (other is null || !sameJson(value, *other))
                    return false;
            }
            return true;
        default:
            return a == b;
    }
}

void contentIsNormalized(DocumentStore store)
{
    import std.bigint : BigInt;
    import vibe.data.json : parseJsonString;

    Json make(string owner, string created)
    {
        auto content = thing(owner, created);
        content["float"] = 2.0;
        content["big"] = Json(BigInt(5));
        content["nested"] = Json(["list": Json([Json(2.0), Json(BigInt(5)), Json(["deep": Json(3.0)])])]);
        return content;
    }

    void expectNormalized(Json written, Json actual, string where)
    {
        auto expected = parseJsonString(written.toString());
        expect(sameJson(expected, actual), format("%s returned %s (%s), not the parsed JSON text %s", where, actual, actual.toString(), expected));
    }

    auto content = make("ann", "1");
    expectNormalized(content, store.create(things, "a", content).content, "create");
    expectNormalized(content, store.get(things, "a").get.content, "get after create");
    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
    expectNormalized(content, store.query(things, query).documents[0].content, "query after create");

    auto replacement = make("ann", "2");
    expectNormalized(replacement, store.replace(things, "a", replacement, 1).content, "replace");
    expectNormalized(replacement, store.get(things, "a").get.content, "get after replace");
    expectNormalized(replacement, store.query(things, query).documents[0].content, "query after replace");
}

void floatsThatDoNotParseBack(DocumentStore store)
{
    foreach (name, big; ["double.max": double.max, "negative double.max": -double.max])
    {
        auto top = thing("ann", "1");
        top["number"] = big;
        auto nested = thing("ann", "1");
        nested["deep"] = Json(["list": Json([Json(1), Json(["x": Json(big)])])]);
        foreach (content; [top, nested])
        {
            expectThrows!DocumentStoreUsageException(() { store.create(things, "a", content); }, "create with " ~ name);
            expect(store.get(things, "a").isNull, "a rejected create stored the document");
        }

        auto original = thing("ann", "1");
        store.create(things, "b", original);
        foreach (content; [top, nested])
            expectThrows!DocumentStoreUsageException(() { store.replace(things, "b", content, 1); }, "replace with " ~ name);
        auto kept = store.get(things, "b");
        expect(!kept.isNull && kept.get.version_ == 1 && kept.get.content == original, "a rejected replace changed the document or made it unreadable");
        IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
        expect(queryAll(store, query).ids == ["b"], "a query after a rejected replace did not return the unchanged document");
        store.remove(things, "b", 1);
    }
}

void declarationsSurviveRestart(DocumentStore store, DocumentStore delegate(DocumentStore) restart)
{
    store.create(things, "a", thing("ann", "1", "red"));
    store.create(others, "o", Json.emptyObject);

    auto second = restart(store);
    expectThrows!DocumentStoreUsageException(() { second.get(things, "a"); }, "use of a collection before declaring it after a restart");

    // The specs are remembered across the restart, so a different spec is refused even though this
    // instance has not seen the collection, and queries cannot silently use a stale index.
    expectThrows!DocumentStoreUsageException(() {
        second.declare([CollectionSpec(things, [IndexSpec(byOwner, "creator", "created"), IndexSpec(byColor, "color")])]);
    }, "redeclaring an index with a different partition key after a restart");
    expectThrows!DocumentStoreUsageException(() {
        second.declare([CollectionSpec(things, [IndexSpec(byOwner, "owner", "created")])]);
    }, "redeclaring a collection without one of its indexes after a restart");
    expectThrows!DocumentStoreUsageException(() { second.get(things, "a"); }, "use of a collection whose declaration was rejected");

    second.declare(collections);
    expect(second.get(things, "a").get.content["owner"].get!string == "ann", "a document did not survive a restart");
    IndexQuery query = { index: byOwner, partitionKey: "ann", limit: 10 };
    expect(queryAll(second, query).ids == ["a"], "an index query after a restart did not find the document");
    query.index = byColor;
    query.partitionKey = "red";
    expect(queryAll(second, query).ids == ["a"], "a query on the other index after a restart did not find the document");

    // Both instances see each other's writes through the shared data.
    second.replace(things, "a", thing("bob", "2"), 1);
    expect(store.get(things, "a").get.version_ == 2, "a write through a restarted store is not visible to the original");
    expectThrows!DocumentConflictException(() { store.replace(things, "a", thing("cy", "3"), 1); }, "a stale replace through the original store");
}

bool canFindId(const string[] ids, string id)
{
    foreach (candidate; ids)
        if (candidate == id)
            return true;
    return false;
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    checkDocumentStore(
        () => cast(DocumentStore) new InMemoryDocumentStore(),
        (previous) => cast(DocumentStore) (cast(InMemoryDocumentStore) previous).restart());
}
