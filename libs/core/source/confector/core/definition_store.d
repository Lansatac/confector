module confector.core.definition_store;

/**
 * Stored project definitions (AGENTS.md, "Pipeline
 * definitions"). Each request reads its project's definition once and runs every task with it,
 * so the definition is kept as an immutable document whose id is a hash of its content, and
 * requests refer to it by that id (`BuildRequest.definitionId`). Identical definitions are stored
 * once, however many requests use them.
 *
 * The content is canonical: tasks sorted by id, and the id is the SHA-256 of the definition's
 * canonical JSON (RFC 8785 style: sorted keys, no insignificant whitespace;
 * `confector.core.fingerprinter.canonicalPinned`). It covers everything in the definition, inputs
 * and display names included, unlike a task's definition hash
 * (`confector.core.definition_hash.computeDefinitionHash`), which covers only build configuration.
 * A definition is never replaced or removed. (Removing definitions no request references is
 * retention's job.)
 */

import confector.core.dag : TaskGraph;
import confector.core.document_collection;
import confector.core.fingerprinter : canonicalPinned, sha256Hex;
import confector.api.document_store;
import confector.api.model;

import vibe.data.json : Json, parseJsonString, serializeToJson;

import std.algorithm.sorting : sort;
import std.format : format;
import std.typecons : Nullable, nullable;

/// Project definitions, by definition id. Read only by id; never listed.
enum CollectionSpec projectDefinitionsCollection = CollectionSpec("project_definitions", null);

/// A definition that cannot be stored: a task without an id, or a task graph that is not valid.
class InvalidDefinitionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Returns `definition` in canonical form: its tasks sorted by id, as it reads back from the
 * store (serialized to JSON text and parsed again, so values that do not survive the text form
 * unchanged are normalized first).
 */
ProjectDefinition canonicalDefinition(in ProjectDefinition definition) @trusted
{
    import vibe.data.json : deserializeJson;

    ProjectDefinition sorted = deserializeJson!ProjectDefinition(serializeToJson(cast(ProjectDefinition) definition).toString());
    sorted.tasks.sort!((a, b) => a.id < b.id);
    return sorted;
}

/// Returns the id of `definition`: the SHA-256 of its canonical form's canonical JSON, in hex.
string definitionId(in ProjectDefinition definition) @trusted
{
    return sha256Hex(canonicalPinned(contentOf(canonicalDefinition(definition))));
}

/// Returns the definition a project kept by Confector has now: its record's tasks.
ProjectDefinition currentDefinition(in ProjectRecord project) @trusted
{
    return canonicalDefinition(ProjectDefinition(cast(TaskNode[]) project.tasks));
}

/// The stored content of a definition already in canonical form.
private Json contentOf(in ProjectDefinition definition) @trusted
{
    return parseJsonString(serializeToJson(cast(ProjectDefinition) definition).toString());
}

/**
 * Project definitions, immutable and keyed by `definitionId`.
 */
final class DefinitionStore
{
    private DocumentCollection!ProjectDefinition m_definitions;

    /// Declares `projectDefinitionsCollection` on `store`.
    this(DocumentStore store)
    {
        m_definitions = new DocumentCollection!ProjectDefinition(store, projectDefinitionsCollection);
    }

    /**
     * Stores `definition` unless it is stored already, and returns its id. Idempotent: storing
     * the same definition again, concurrently or later, writes nothing and returns the same id.
     *
     * Throws: InvalidDefinitionException if a task has no id or the tasks do not form a valid
     * graph (DAGValidationException's message is kept); DocumentTooLargeException if the
     * definition is larger than a document can be (maxDocumentBytes).
     */
    string put(in ProjectDefinition definition)
    {
        auto canonical = canonicalDefinition(definition);
        foreach (ref task; canonical.tasks)
        {
            if (task.id.length == 0) throw new InvalidDefinitionException("A task of the definition has no id");
        }
        try new TaskGraph(canonical.tasks);
        catch (DAGValidationException e)
        {
            throw new InvalidDefinitionException(format("The definition's tasks do not form a valid graph: %s", e.msg));
        }

        const content = contentOf(canonical);
        const id = sha256Hex(canonicalPinned(content));
        const size = content.toString().length;
        if (size > maxDocumentBytes)
        {
            throw new DocumentTooLargeException(format(
                "Definition %s is %s bytes, more than a stored document can hold (%s bytes); split the project or move large values out of its definition",
                id, size, maxDocumentBytes), projectDefinitionsCollection.name, id, size);
        }

        if (!m_definitions.get(id).isNull) return id;
        try
        {
            m_definitions.create(id, canonical);
        }
        catch (DocumentConflictException)
        {
            // Stored concurrently: the content is the same, because the id is its hash.
        }
        return id;
    }

    /**
     * Reads definition `id`. Null if it does not exist.
     *
     * Throws: MalformedDocumentException if the stored content does not hash to `id`.
     */
    Nullable!ProjectDefinition get(string id)
    {
        if (id.length == 0) throw new Exception("A definition id must not be empty");
        auto found = m_definitions.get(id);
        if (found.isNull) return Nullable!ProjectDefinition.init;
        const actual = definitionId(found.get.value);
        if (actual != id)
        {
            throw new MalformedDocumentException(format("Definition '%s' in collection '%s' has content hashing to %s",
                id, projectDefinitionsCollection.name, actual), projectDefinitionsCollection.name, id);
        }
        return nullable(found.get.value);
    }
}

version (unittest)
{
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import std.algorithm.searching : canFind;
    import std.array : replicate;

    private ProjectDefinition sampleDefinition()
    {
        TaskNode compile;
        compile.id = "compile";
        compile.name = "Compile";
        compile.inputs["src"] = repositoryInput("game");
        compile.steps = [BuildStep("Build", "bash", Json(["script": Json("make"), "jobs": Json(4)]))];
        compile.outputs.artifacts = [OutputArtifactDecl("bin", "out/*")];
        TaskNode test;
        test.id = "test";
        test.inputs["bin"] = taskOutputInput("compile", "bin");
        return ProjectDefinition([test, compile]);
    }

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }
}

unittest
{
    // The id is a hash of the whole definition, independent of task order and key order
    auto definition = sampleDefinition();
    const id = definitionId(definition);
    assert(id.length == 64);
    auto reordered = definition;
    reordered.tasks = [definition.tasks[1], definition.tasks[0]];
    assert(definitionId(reordered) == id, "Task order does not matter");
    assert(canonicalDefinition(definition).tasks[0].id == "compile");

    auto keyOrder = sampleDefinition();
    keyOrder.tasks[1].steps[0].config = Json.emptyObject;
    keyOrder.tasks[1].steps[0].config["jobs"] = 4;
    keyOrder.tasks[1].steps[0].config["script"] = "make";
    assert(definitionId(keyOrder) == id, "Config key order does not matter");

    // Everything in it counts, unlike a task's definition hash: inputs and display names too
    auto renamed = sampleDefinition();
    renamed.tasks[1].name = "Compile the game";
    assert(definitionId(renamed) != id);
    auto repinned = sampleDefinition();
    repinned.tasks[1].inputs["src"] = repositoryInput("game", RefSpec.fromString("release"));
    assert(definitionId(repinned) != id);
    auto restepped = sampleDefinition();
    restepped.tasks[1].steps[0].config["script"] = "make release";
    assert(definitionId(restepped) != id);
    assert(definitionId(ProjectDefinition.init) != id);

    // A project kept by Confector has its record's tasks as its definition
    ProjectRecord project;
    project.id = "game";
    project.tasks = definition.tasks.dup;
    assert(currentDefinition(project) == canonicalDefinition(definition));
    assert(definitionId(currentDefinition(project)) == id);
}

unittest
{
    // Stored once, by content; read back by id, equal to the canonical form
    auto documents = new InMemoryDocumentStore();
    auto definitions = new DefinitionStore(documents);
    auto definition = sampleDefinition();

    const id = definitions.put(definition);
    assert(id == definitionId(definition));
    auto read = definitions.get(id);
    assert(!read.isNull && read.get == canonicalDefinition(definition));
    assert(definitionId(read.get) == id, "What is read back hashes to its id");
    assert(definitions.get(definitionId(ProjectDefinition.init)).isNull);
    assert(throwsA!Exception({ definitions.get(""); }));

    // Storing it again writes nothing
    assert(definitions.put(definition) == id);
    assert(documents.get(projectDefinitionsCollection.name, id).get.version_ == 1);

    // Survives a restart
    assert(new DefinitionStore(documents.restart()).get(id).get == read.get);

    // A changed definition is another document; the first stays
    auto changed = sampleDefinition();
    changed.tasks[1].steps[0].config["script"] = "make release";
    const changedId = definitions.put(changed);
    assert(changedId != id && definitions.get(id).get == read.get);
    assert(definitions.get(changedId).get.tasks[0].steps[0].config["script"].get!string == "make release");

    // An empty definition is a definition
    const emptyId = definitions.put(ProjectDefinition.init);
    assert(definitions.get(emptyId).get.tasks.length == 0);
}

unittest
{
    // Concurrent puts of one definition both succeed with the same id, and one document is written
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto definitions = new DefinitionStore(interleaving);
    auto other = new DefinitionStore(documents);
    auto definition = sampleDefinition();

    string otherId;
    interleaving.beforeNextWrite = () { otherId = other.put(definition); };
    const id = definitions.put(definition);
    assert(id == otherId && documents.get(projectDefinitionsCollection.name, id).get.version_ == 1);
}

unittest
{
    // Invalid definitions fail loudly
    auto definitions = new DefinitionStore(new InMemoryDocumentStore());
    auto cyclic = sampleDefinition();
    cyclic.tasks[1].inputs["loop"] = taskOutputInput("test");
    assert(throwsA!InvalidDefinitionException({ definitions.put(cyclic); }));
    auto dangling = sampleDefinition();
    dangling.tasks[0].inputs["bin"] = taskOutputInput("missing");
    try
    {
        definitions.put(dangling);
        assert(false, "A dangling task output input must throw");
    }
    catch (InvalidDefinitionException e)
    {
        assert(e.msg.canFind("missing"));
    }
    auto duplicate = sampleDefinition();
    duplicate.tasks ~= duplicate.tasks[0];
    assert(throwsA!InvalidDefinitionException({ definitions.put(duplicate); }));
    auto anonymous = sampleDefinition();
    anonymous.tasks[0].id = "";
    assert(throwsA!InvalidDefinitionException({ definitions.put(anonymous); }));

    // A definition larger than a document is refused before anything is written
    auto huge = sampleDefinition();
    huge.tasks[0].environment["BIG"] = "x".replicate(maxDocumentBytes);
    try
    {
        definitions.put(huge);
        assert(false, "An oversized definition must throw");
    }
    catch (DocumentTooLargeException e)
    {
        assert(e.collection == projectDefinitionsCollection.name && e.sizeBytes > maxDocumentBytes);
        assert(e.msg.canFind(definitionId(huge)));
    }
}

unittest
{
    // Content that does not hash to its id is reported, not used
    auto documents = new InMemoryDocumentStore();
    auto definitions = new DefinitionStore(documents);
    const id = definitionId(sampleDefinition());
    documents.create(projectDefinitionsCollection.name, id, contentOf(ProjectDefinition.init));
    try
    {
        definitions.get(id);
        assert(false, "Tampered content must throw");
    }
    catch (MalformedDocumentException e)
    {
        assert(e.id == id);
    }
}
