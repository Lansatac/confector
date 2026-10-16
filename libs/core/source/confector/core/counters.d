module confector.core.counters;

/**
 * Named counters in the state store (design record: bead confector-z7z.4), such as the
 * per-project chain numbers. Each counter is one document, `{"value": n}`, with the counter's
 * name as its id, incremented by compare-and-set on the document's version, so concurrent
 * increments each get their own value and none is lost. A counter that was never incremented is
 * at 0; the first value handed out is 1.
 */

import confector.core.document_collection;
import confector.plugin_api.document_store;

import std.format : format;
import vibe.data.json : Json;

/// The state store collection holding counters, keyed by counter name.
enum CollectionSpec countersCollection = CollectionSpec("counters", null);

/// A counter's stored value.
struct Counter
{
    long value;
}

/**
 * Reads and increments named counters in a DocumentStore.
 */
final class CounterStore
{
    /// How many times `next` re-reads and retries after losing a compare-and-set to a concurrent
    /// increment of the same counter before failing. Every lost attempt means another increment
    /// succeeded, so this is reached only under sustained contention on one counter.
    enum maxAttempts = 100;

    private DocumentCollection!Counter m_counters;

    /// Declares `countersCollection` on `store`.
    this(DocumentStore store)
    {
        m_counters = new DocumentCollection!Counter(store, countersCollection);
    }

    /// Returns the last value `next` handed out for `name`, or 0 if it never did.
    ulong current(string name)
    {
        requireName(name);
        auto counter = m_counters.get(name);
        return counter.isNull ? 0 : checked(name, counter.get.value.value);
    }

    /**
     * Increments counter `name` and returns its new value, starting at 1. Concurrent calls each
     * get a distinct value.
     *
     * Throws: Exception if `name` is empty, the stored counter is malformed, or every one of
     * `maxAttempts` attempts lost to a concurrent increment.
     */
    ulong next(string name)
    {
        requireName(name);
        foreach (attempt; 0 .. maxAttempts)
        {
            auto counter = m_counters.get(name);
            try
            {
                if (counter.isNull)
                {
                    m_counters.create(name, Counter(1));
                    return 1;
                }
                const value = checked(name, counter.get.value.value) + 1;
                m_counters.replace(name, Counter(cast(long) value), counter.get.version_);
                return value;
            }
            catch (DocumentConflictException)
            {
                // A concurrent increment won; read its value and count on from it.
            }
        }
        throw new Exception(format("Could not increment counter '%s': %s attempts in a row lost to concurrent increments", name, maxAttempts));
    }

    private static void requireName(string name)
    {
        if (name.length == 0)
        {
            throw new Exception("A counter needs a name");
        }
    }

    private static ulong checked(string name, long value)
    {
        if (value <= 0)
        {
            throw new Exception(format("Counter '%s' in collection '%s' is malformed: its value %s is not positive",
                name, countersCollection.name, value));
        }
        return cast(ulong) value;
    }
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.algorithm.searching : canFind;

    // Counters start at 0, hand out 1, 2, ... and are independent and durable
    auto documents = new InMemoryDocumentStore();
    auto counters = new CounterStore(documents);
    assert(counters.current("a") == 0);
    assert(counters.next("a") == 1);
    assert(counters.next("a") == 2);
    assert(counters.next("b") == 1);
    assert(counters.current("a") == 2);
    assert(new CounterStore(documents.restart()).next("a") == 3);

    bool threw = false;
    try counters.next("");
    catch (Exception) threw = true;
    assert(threw, "An unnamed counter must throw");

    // A malformed counter fails loudly, naming it
    documents.create(countersCollection.name, "bad", Json(["value": Json(0)]));
    threw = false;
    try counters.next("bad");
    catch (Exception e) threw = e.msg.canFind("'bad'");
    assert(threw);
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import core.thread : Thread;

    // Increments from many threads at once each get a distinct value, and none is lost
    auto documents = new InMemoryDocumentStore();
    enum threadCount = 4;
    enum perThread = 25;
    ulong[][threadCount] results;
    Thread[] threads;
    foreach (t; 0 .. threadCount)
    {
        auto counters = new CounterStore(documents);
        threads ~= new Thread(((size_t index, CounterStore c) => () {
            foreach (i; 0 .. perThread) results[index] ~= c.next("shared");
        })(t, counters));
    }
    foreach (thread; threads) thread.start();
    foreach (thread; threads) thread.join();

    bool[ulong] seen;
    foreach (perThreadResults; results)
    {
        foreach (value; perThreadResults)
        {
            assert(value !in seen, "Two increments got the same value");
            seen[value] = true;
        }
    }
    assert(seen.length == threadCount * perThread);
    assert(new CounterStore(documents).current("shared") == threadCount * perThread);
}
