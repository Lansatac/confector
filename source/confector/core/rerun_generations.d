module confector.core.rerun_generations;

/**
 * Rerun generations (design record: bead confector-z7z.15; AGENTS.md, "Re-running a task"): the
 * durable record of each base fingerprint's reruns, and the shell that reads it to evaluate a
 * chain's fingerprints with the pure core (confector.core.input_resolution.chainResolution).
 *
 * The record lives in the state store as one document per base fingerprint, with the base as
 * its id:
 *
 *     { "records": [ { "generation": 1 }, { "generation": 2 } ] }
 *
 * A base's current generation is its last record's; a base without a document is at
 * generation 0. Records are only ever appended, by compare-and-set on the document's version,
 * so concurrent bumps of one base each get their own generation and none is lost. Correctness
 * depends only on reads by id and compare-and-set (bead confector-z7z.4), so the collection
 * declares no index.
 */

import confector.core.input_resolution : GraphResolution, RerunGenerations, chainResolution, unreadRerunBases;
import confector.core.model : ChainTask;
import confector.plugin_api.document_store;

import vibe.data.json : Json;

import std.format : format;

/// The state store collection holding rerun generation records, keyed by base fingerprint.
enum CollectionSpec rerunGenerationsCollection = CollectionSpec("rerun_generations", null);

/**
 * Reads the current rerun generation of every base in `bases`, returning an entry for each:
 * 0 for a base that was never rerun.
 */
alias RerunGenerationReader = RerunGenerations delegate(in string[] bases);

/**
 * Reads and bumps rerun generations in a DocumentStore.
 */
final class RerunGenerationStore
{
    /// How many times `bump` re-reads and retries after losing a compare-and-set to a
    /// concurrent bump of the same base before failing. Every lost attempt means another bump
    /// succeeded, so this is reached only under sustained contention on one base.
    enum maxBumpAttempts = 100;

    private DocumentStore m_store;

    /// Declares `rerunGenerationsCollection` on `store`.
    this(DocumentStore store)
    {
        if (store is null)
        {
            throw new Exception("RerunGenerationStore requires a document store");
        }
        m_store = store;
        m_store.declare([rerunGenerationsCollection]);
    }

    /**
     * Returns the current rerun generation of every base in `bases`, 0 for a base never rerun.
     * Strongly consistent: reads each base by id.
     *
     * Throws: Exception if a base is empty or its stored record is malformed.
     */
    RerunGenerations read(in string[] bases)
    {
        RerunGenerations result;
        foreach (base; bases)
        {
            requireBase(base);
            auto document = m_store.get(rerunGenerationsCollection.name, base);
            result[base] = document.isNull ? 0 : current(storedGenerations(document.get));
        }
        return result;
    }

    /**
     * Appends a new rerun generation for `base` and returns it. The new generation is one more
     * than the highest the base has ever had, so a rerun always yields a fingerprint no earlier
     * generation had. Concurrent bumps of the same base never collide: each gets a distinct
     * generation.
     *
     * Throws: Exception if `base` is empty, its stored record is malformed, or every one of
     * `maxBumpAttempts` attempts lost to a concurrent bump; DocumentTooLargeException if the
     * record outgrows the state store's document size limit.
     */
    ulong bump(string base)
    {
        requireBase(base);
        const collection = rerunGenerationsCollection.name;
        foreach (attempt; 0 .. maxBumpAttempts)
        {
            auto document = m_store.get(collection, base);
            try
            {
                if (document.isNull)
                {
                    m_store.create(collection, base, recordsContent([1]));
                    return 1;
                }
                auto generations = storedGenerations(document.get);
                ulong next = 0;
                foreach (generation; generations)
                {
                    if (generation > next) next = generation;
                }
                ++next;
                m_store.replace(collection, base, recordsContent(generations ~ next), document.get.version_);
                return next;
            }
            catch (DocumentConflictException)
            {
                // A concurrent bump of this base won; read its record and append after it.
            }
        }
        throw new Exception(format("Could not bump the rerun generation of base fingerprint %s: %s attempts in a row lost to concurrent bumps",
            base, maxBumpAttempts));
    }

    private static void requireBase(string base)
    {
        if (base.length == 0)
        {
            throw new Exception("A rerun generation needs a base fingerprint");
        }
    }

    private static ulong current(in ulong[] generations)
    {
        return generations[$ - 1];
    }

    /// The generations a stored record holds, oldest first. Throws if it is malformed.
    private static ulong[] storedGenerations(in Document document)
    {
        string malformed(string why)
        {
            return format("Rerun generation record '%s' in collection '%s' is malformed: %s",
                document.id, rerunGenerationsCollection.name, why);
        }

        auto records = "records" in document.content;
        if (records is null || records.type != Json.Type.array || records.length == 0)
        {
            throw new Exception(malformed("'records' must be a non-empty array"));
        }
        ulong[] result;
        foreach (size_t i; 0 .. records.length)
        {
            const record = (*records)[i];
            auto generation = record.type == Json.Type.object ? "generation" in record : null;
            if (generation is null || generation.type != Json.Type.int_ || generation.get!long <= 0)
            {
                throw new Exception(malformed(format("record %s has no positive integer 'generation'", i)));
            }
            result ~= cast(ulong) generation.get!long;
        }
        return result;
    }

    private static Json recordsContent(in ulong[] generations)
    {
        Json records = Json.emptyArray;
        foreach (generation; generations)
        {
            Json record = Json.emptyObject;
            record["generation"] = Json(cast(long) generation);
            records ~= record;
        }
        Json content = Json.emptyObject;
        content["records"] = records;
        return content;
    }
}

/**
 * Evaluates `chain` at the current rerun generations: reads, with `read`, the generations of
 * the bases `unreadRerunBases` reports until none are left, then returns `chainResolution`.
 * Bases depend on upstream fingerprints, so each round reads one more level of the graph; a
 * chain needs at most as many reads as its longest path has tasks.
 *
 * Throws: Exception if `read` returns no generation for a base it was asked for; whatever
 * `read` and `chainResolution` throw.
 */
GraphResolution readChainResolution(string projectId, in ChainTask[] chain, scope RerunGenerationReader read)
{
    RerunGenerations generations;
    for (auto unread = unreadRerunBases(projectId, chain, generations); unread.length > 0;
        unread = unreadRerunBases(projectId, chain, generations))
    {
        auto readGenerations = read(unread);
        foreach (base; unread)
        {
            auto generation = base in readGenerations;
            if (generation is null)
            {
                throw new Exception(format("Reading rerun generations returned none for base fingerprint %s", base));
            }
            generations[base] = *generation;
        }
    }
    return chainResolution(projectId, chain, generations);
}

version (unittest)
{
    import confector.core.dag : TaskGraph;
    import confector.core.input_resolution : freezeChain, resolveGraphInputs;
    import confector.core.memory_document_store : InMemoryDocumentStore;
    import confector.core.model;
    import confector.plugin_api.input_resolver : InputPin;

    import std.algorithm.searching : canFind;
    import std.typecons : Nullable;

    /// Passes everything through to `inner`, running `beforeNextWrite` (once) just before the
    /// next create or replace, to interleave a concurrent writer deterministically.
    private final class InterleavingStore : DocumentStore
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
        override void remove(string collection, string id, ulong expectedVersion) { inner.remove(collection, id, expectedVersion); }
        override QueryPage query(string collection, const IndexQuery lookup) { return inner.query(collection, lookup); }
    }

    /// A chain of compile -> test -> report plus an independent lint, at revision `sha`.
    private ChainTask[] sampleChain(string sha)
    {
        TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
        TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
        TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
        TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game", "main");
        auto graph = new TaskGraph([compile, test, report, lint]);
        InputPin[InputDecl] none;
        InputPin[InputDecl] pins = [repositoryInput("game", "main"): InputPin(Json(sha))];
        return freezeChain(graph, resolveGraphInputs(graph, none, pins));
    }
}

unittest
{
    // Generations start at 0, each bump appends the next, and bases are independent
    auto store = new RerunGenerationStore(new InMemoryDocumentStore());
    assert(store.read(["a", "b"]) == ["a": 0UL, "b": 0UL]);
    assert(store.read([]).length == 0);

    assert(store.bump("a") == 1);
    assert(store.bump("a") == 2);
    assert(store.bump("b") == 1);
    assert(store.read(["a", "b", "c"]) == ["a": 2UL, "b": 1UL, "c": 0UL]);

    bool threw = false;
    try store.bump("");
    catch (Exception) threw = true;
    assert(threw, "An empty base must throw");
    threw = false;
    try store.read([""]);
    catch (Exception) threw = true;
    assert(threw);
}

unittest
{
    // The record is durable and append-only: a restarted process reads the same generations
    // and every earlier record is kept
    auto documents = new InMemoryDocumentStore();
    auto store = new RerunGenerationStore(documents);
    store.bump("a");
    store.bump("a");
    store.bump("a");

    auto restarted = new RerunGenerationStore(documents.restart());
    assert(restarted.read(["a"]) == ["a": 3UL]);
    assert(restarted.bump("a") == 4);

    auto stored = documents.get(rerunGenerationsCollection.name, "a").get;
    assert(stored.content["records"].length == 4);
    foreach (i; 0 .. 4) assert(stored.content["records"][i]["generation"].get!long == i + 1);
}

unittest
{
    // A bump that never reuses an earlier generation, even if the last record is lower
    // (as a future "accept the previous result" override may append)
    auto documents = new InMemoryDocumentStore();
    auto store = new RerunGenerationStore(documents);
    Json content = Json.emptyObject;
    content["records"] = Json([Json(["generation": Json(1)]), Json(["generation": Json(2)]), Json(["generation": Json(1)])]);
    documents.create(rerunGenerationsCollection.name, "a", content);
    assert(store.read(["a"]) == ["a": 1UL], "The current generation is the last record's");
    assert(store.bump("a") == 3);

    // A malformed record fails loudly, naming it
    foreach (bad; [`{}`, `{"records": []}`, `{"records": [{"generation": 0}]}`, `{"records": [{"generation": "1"}]}`, `{"records": [1]}`])
    {
        import vibe.data.json : parseJsonString;
        documents.create(rerunGenerationsCollection.name, "bad", parseJsonString(bad));
        bool threw = false;
        try store.read(["bad"]);
        catch (Exception ex) threw = ex.msg.canFind("'bad'");
        assert(threw, bad);
        threw = false;
        try store.bump("bad");
        catch (Exception ex) threw = ex.msg.canFind("'bad'");
        assert(threw, bad);
        documents.remove(rerunGenerationsCollection.name, "bad", documents.get(rerunGenerationsCollection.name, "bad").get.version_);
    }
}

unittest
{
    // Concurrent bumps do not collide: a bump that loses the race, whether to create the record
    // or to append to it, re-reads and takes the next generation
    auto documents = new InMemoryDocumentStore();
    auto racer = new RerunGenerationStore(documents);
    auto interleaving = new InterleavingStore(documents);
    auto store = new RerunGenerationStore(interleaving);

    interleaving.beforeNextWrite = () { assert(racer.bump("a") == 1); };
    assert(store.bump("a") == 2, "Losing the create must not overwrite the winner's generation");

    interleaving.beforeNextWrite = () { assert(racer.bump("a") == 3); };
    assert(store.bump("a") == 4, "Losing the append must not overwrite the winner's generation");

    assert(store.read(["a"]) == ["a": 4UL]);
    assert(documents.get(rerunGenerationsCollection.name, "a").get.content["records"].length == 4);
}

unittest
{
    // Bumps from many threads at once each get a distinct generation, and none is lost
    import core.thread : Thread;

    auto documents = new InMemoryDocumentStore();
    enum threadCount = 4;
    enum bumpsPerThread = 25;
    ulong[][threadCount] results;
    Thread[] threads;
    foreach (t; 0 .. threadCount)
    {
        auto store = new RerunGenerationStore(documents);
        threads ~= new Thread(((size_t index, RerunGenerationStore s) => () {
            foreach (i; 0 .. bumpsPerThread) results[index] ~= s.bump("shared");
        })(t, store));
    }
    foreach (thread; threads) thread.start();
    foreach (thread; threads) thread.join();

    bool[ulong] seen;
    foreach (perThread; results)
    {
        foreach (generation; perThread)
        {
            assert(generation !in seen, "Two bumps got the same generation");
            seen[generation] = true;
        }
    }
    assert(seen.length == threadCount * bumpsPerThread);
    assert(new RerunGenerationStore(documents).read(["shared"]) == ["shared": cast(ulong) threadCount * bumpsPerThread]);
}

unittest
{
    // readChainResolution reads generations a level at a time, and bumping a task's generation
    // in the store changes its fingerprint and every downstream one, in every chain sharing the
    // task's base
    auto store = new RerunGenerationStore(new InMemoryDocumentStore());
    size_t reads;
    RerunGenerationReader reader = (in string[] bases) { ++reads; return store.read(bases); };

    auto chain = sampleChain("aaa111");
    auto sameInputs = sampleChain("aaa111"); // another chain (say, another branch) at the same revision
    auto otherRevision = sampleChain("bbb222");

    auto before = readChainResolution("p", chain, reader);
    assert(reads == 3, "compile and lint, then test, then report");
    assert(readChainResolution("p", sameInputs, reader).fingerprints == before.fingerprints);
    auto otherBefore = readChainResolution("p", otherRevision, reader);

    assert(store.bump(before.bases["compile"]) == 1);

    auto after = readChainResolution("p", chain, reader);
    foreach (id; ["compile", "test", "report"]) assert(after.fingerprints[id] != before.fingerprints[id], id);
    assert(after.fingerprints["lint"] == before.fingerprints["lint"]);
    assert(readChainResolution("p", sameInputs, reader).fingerprints == after.fingerprints);
    assert(readChainResolution("p", otherRevision, reader).fingerprints == otherBefore.fingerprints);

    // A downstream task's new base starts at generation 0 and can be rerun on its own
    assert(store.read([after.bases["test"]]) == [after.bases["test"]: 0UL]);
    store.bump(after.bases["test"]);
    auto testRerun = readChainResolution("p", chain, reader);
    assert(testRerun.fingerprints["compile"] == after.fingerprints["compile"]);
    assert(testRerun.fingerprints["test"] != after.fingerprints["test"]);
    assert(testRerun.fingerprints["report"] != after.fingerprints["report"]);
}

unittest
{
    // A reader that leaves out a base it was asked for fails loudly rather than defaulting
    RerunGenerationReader forgetful = (in string[] bases) { RerunGenerations none; return none; };
    bool threw = false;
    try readChainResolution("p", sampleChain("aaa111"), forgetful);
    catch (Exception ex) threw = ex.msg.canFind("returned none");
    assert(threw);
}
