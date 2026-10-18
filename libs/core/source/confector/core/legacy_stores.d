module confector.core.legacy_stores;

/**
 * State stores for records that are being replaced. Each is removed with its last user:
 *
 * - ExecutionLogStore: when build logs move to the log store (bead confector-z7z.31.12). Build
 *   logs never belong in the state store line by line (AGENTS.md, "Backends and extensions");
 *   this is the interim home of the log lines workers stream for their executions.
 * - TriggerRuleStore: when trigger rules become part of the project definition (bead
 *   confector-z7z.23.7).
 * - VcsStateStore (VcsRepositoryState, VcsChangeRecord): when tracked branches replace them (bead
 *   confector-z7z.24.1).
 *
 * The records are written whole, last writer wins (`DocumentCollection.put`); log lines are
 * created once each. Do not build anything new on these stores.
 */

import confector.core.counters : CounterStore;
import confector.core.document_collection;
import confector.core.model;
import confector.plugin_api.document_store;

import std.algorithm.searching : canFind;
import std.datetime.systime : SysTime;
import std.format : format;

/// Page size of the queries that list everything they find.
private enum size_t pageSize = 100;

/// The partition key value of the listing indexes, which hold every document of a collection.
private enum string everything = "all";

/**
 * The sortable form of a legacy timestamp, which is either ISO 8601 extended
 * (`toISOExtString`) or basic (`toISOString`, as the controllers write them, in local time when
 * no zone is given).
 *
 * Throws: Exception if it is neither.
 */
private string legacySortKey(string timestamp)
{
    if (timestamp.canFind('-')) return sortableTimestamp(timestamp);
    try
    {
        return sortableTime(SysTime.fromISOString(timestamp));
    }
    catch (Exception e)
    {
        throw new Exception(format("'%s' is not an ISO 8601 timestamp: %s", timestamp, e.msg));
    }
}

/// One stored log line: line `seq` (from 1) of log `log`.
struct LogLine
{
    string log;
    long seq;
    string line;
}

/**
 * Each execution's log, one document per line, numbered by a counter per log so lines read back
 * in the order they were appended. See the module documentation: logs move to the log store.
 */
final class ExecutionLogStore
{
    private DocumentCollection!LogLine m_lines;
    private CounterStore m_counters;

    /// Declares the log line and counter collections on `store`.
    this(DocumentStore store)
    {
        m_lines = new DocumentCollection!LogLine(store,
            CollectionSpec("legacy_log_lines", [IndexSpec("by_log", "log", "seq_key")]),
            ["seq_key"], (in LogLine line) => ["seq_key": sortableNumber(line.seq)]);
        m_counters = new CounterStore(store);
    }

    /// Appends a line to execution `executionId`'s log.
    ///
    /// Throws: Exception if `executionId` is empty.
    void append(string executionId, string line)
    {
        if (executionId.length == 0) throw new Exception("A log line needs the execution it belongs to");
        appendLine(compositeKey("execution", executionId), line);
    }

    /// Execution `executionId`'s log lines, in order. Discovery: may lag behind appends.
    string[] read(string executionId)
    {
        return readLines(compositeKey("execution", executionId));
    }

    /// Longest line stored, in UTF-8 bytes. A longer line is cut at this length and marked, so
    /// one runaway line cannot exceed the state store's document size limit.
    enum size_t maxLineBytes = 64 * 1024;

    /// `line`, cut to at most maxLineBytes (on a character boundary) with a note of how much was
    /// cut, if it is longer.
    static string truncated(string line)
    {
        import std.utf : stride;

        if (line.length <= maxLineBytes) return line;
        enum string marker = " [line truncated: %s of %s bytes dropped]";
        const budget = maxLineBytes - 64; // room for the marker
        size_t end = 0;
        while (end < line.length)
        {
            const next = end + stride(line, end);
            if (next > budget) break;
            end = next;
        }
        return line[0 .. end] ~ format(marker, line.length - end, line.length);
    }

    private void appendLine(string log, string line)
    {
        line = truncated(line);
        const seq = m_counters.next(compositeKey("log", log));
        m_lines.create(hashedId(log, sortableNumber(seq)), LogLine(log, cast(long) seq, line));
    }

    private string[] readLines(string log)
    {
        IndexQuery lookup;
        lookup.index = "by_log";
        lookup.partitionKey = log;
        lookup.limit = 1000;
        string[] lines;
        foreach (item; m_lines.queryAll(lookup)) lines ~= item.line;
        return lines;
    }
}

/**
 * Trigger rules, by id.
 */
final class TriggerRuleStore
{
    private DocumentCollection!TriggerRuleRecord m_rules;

    /// Declares the trigger rule collection on `store`.
    this(DocumentStore store)
    {
        m_rules = new DocumentCollection!TriggerRuleRecord(store,
            CollectionSpec("trigger_rules", [IndexSpec("all", "listing", "id")]),
            ["listing"], (in TriggerRuleRecord rule) => ["listing": everything]);
    }

    /// Writes `rule` (last edit wins).
    void save(TriggerRuleRecord rule)
    {
        if (rule.id.length == 0) throw new Exception("A trigger rule needs an id");
        m_rules.put(rule.id, rule);
    }

    /// Lists every trigger rule, by id. Discovery.
    TriggerRuleRecord[] list()
    {
        return listAll(m_rules);
    }

    /// Removes rule `id`. Returns false if it did not exist.
    bool remove(string id)
    {
        return m_rules.removeLatest(id);
    }
}

/**
 * The latest known revision of each repository URL and ref, and the changes detected between
 * revisions, as webhooks and polling record them.
 */
final class VcsStateStore
{
    private DocumentCollection!VcsRepositoryState m_states;
    private DocumentCollection!VcsChangeRecord m_changes;

    /// Declares the repository state and change collections on `store`.
    this(DocumentStore store)
    {
        m_states = new DocumentCollection!VcsRepositoryState(store, CollectionSpec("vcs_repository_states", null));
        m_changes = new DocumentCollection!VcsChangeRecord(store,
            CollectionSpec("vcs_changes", [IndexSpec("by_repository", "repository_url", "detected_key")]),
            ["detected_key"], (in VcsChangeRecord change) => ["detected_key": legacySortKey(change.detectedAt)]);
    }

    /// Writes the latest state of `state.repositoryUrl` at `state.targetRef`.
    void saveState(VcsRepositoryState state)
    {
        if (state.repositoryUrl.length == 0) throw new Exception("A repository state needs a repository URL");
        m_states.put(hashedId(state.repositoryUrl, state.targetRef), state);
    }

    /// Reads the latest state of `repositoryUrl` at `targetRef`. Returns false if there is none.
    bool getState(string repositoryUrl, string targetRef, out VcsRepositoryState state)
    {
        return m_states.get(hashedId(repositoryUrl, targetRef)).tryValue(state);
    }

    /// Records a detected change.
    void recordChange(VcsChangeRecord change)
    {
        if (change.id.length == 0 || change.repositoryUrl.length == 0)
        {
            throw new Exception("A change record needs an id and a repository URL");
        }
        m_changes.create(change.id, change);
    }

    /// The latest `limit` changes of `repositoryUrl`, oldest first. Discovery.
    VcsChangeRecord[] listChanges(string repositoryUrl, size_t limit = 20)
    {
        IndexQuery lookup;
        lookup.index = "by_repository";
        lookup.partitionKey = repositoryUrl;
        return latest(lookup, limit);
    }

    private VcsChangeRecord[] latest(IndexQuery lookup, size_t limit)
    {
        import std.algorithm.mutation : reverse;

        lookup.descending = true;
        lookup.limit = pageSize;
        VcsChangeRecord[] result;
        foreach (item; m_changes.queryAll(lookup, limit)) result ~= item.value;
        result.reverse();
        return result;
    }
}

/// Every value in a collection's "all" listing index.
private T[] listAll(T)(DocumentCollection!T collection)
{
    IndexQuery lookup;
    lookup.index = "all";
    lookup.partitionKey = everything;
    lookup.limit = pageSize;
    T[] result;
    foreach (item; collection.queryAll(lookup)) result ~= item.value;
    return result;
}

version (unittest)
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    private bool throwsWith(scope void delegate() action, string text)
    {
        try action();
        catch (Exception e) return e.msg.canFind(text);
        return false;
    }
}

unittest
{
    // Logs read back in append order, per execution
    auto logs = new ExecutionLogStore(new InMemoryDocumentStore());
    foreach (i; 0 .. 12) logs.append("exe_1", format("line %s", i));
    logs.append("exe_2", "other execution");

    auto lines = logs.read("exe_1");
    assert(lines.length == 12 && lines[0] == "line 0" && lines[11] == "line 11", "Line 10 sorts after line 9");
    assert(logs.read("exe_2") == ["other execution"]);
    assert(logs.read("exe_3").length == 0);
    assert(throwsWith({ logs.append("", "orphan"); }, "needs the execution"));

    // A line too long for the state store is cut on a character boundary and marked, not
    // rejected
    import std.array : replicate;
    import std.utf : validate;
    string huge = "\u00e9".replicate(ExecutionLogStore.maxLineBytes); // two bytes per character
    logs.append("exe_huge", huge);
    auto stored = logs.read("exe_huge");
    assert(stored.length == 1 && stored[0].length <= ExecutionLogStore.maxLineBytes);
    assert(stored[0].canFind("[line truncated:") && stored[0].canFind(format("of %s bytes dropped]", huge.length)));
    validate(stored[0]);
    assert(ExecutionLogStore.truncated("short") == "short");
}

unittest
{
    // Trigger rules: written whole, listed and removed
    auto documents = new InMemoryDocumentStore();
    auto rules = new TriggerRuleStore(documents);
    TriggerRuleRecord rule;
    rule.id = "trig_1";
    rule.triggerType = "cron";
    rules.save(rule);
    rule.criteria = "0 0 * * 0";
    rules.save(rule);
    assert(rules.list() == [rule]);
    assert(rules.remove("trig_1") && !rules.remove("trig_1") && rules.list().length == 0);

}

unittest
{
    // Repository states by URL and ref; changes listed per repository
    auto vcs = new VcsStateStore(new InMemoryDocumentStore());
    VcsRepositoryState state;
    state.repositoryUrl = "https://example.com/game.git";
    state.providerType = "git";
    state.targetRef = "main";
    state.revision = "abc";
    vcs.saveState(state);
    state.revision = "def";
    vcs.saveState(state);

    VcsRepositoryState read;
    assert(vcs.getState("https://example.com/game.git", "main", read) && read.revision == "def");
    assert(!vcs.getState("https://example.com/game.git", "dev", read));

    foreach (i, url; ["https://example.com/game.git", "https://example.com/game.git", "https://example.com/tools.git"])
    {
        VcsChangeRecord change;
        change.id = format("change-%s", i);
        change.repositoryUrl = url;
        change.detectedAt = format("2026-10-09T1%s:00:00Z", i);
        vcs.recordChange(change);
    }
    auto changes = vcs.listChanges("https://example.com/game.git");
    assert(changes.length == 2 && changes[0].id == "change-0" && changes[1].id == "change-1");
    auto latest = vcs.listChanges("https://example.com/game.git", 1);
    assert(latest.length == 1 && latest[0].id == "change-1");
    assert(vcs.listChanges("https://example.com/none.git").length == 0);
}
