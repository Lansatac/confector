module confector.testing.memory_artifact_storage;

/**
 * In-memory artifact storage for unit testing only (package confector-testing; never wire it
 * into production code). The in-memory dispatch queue is
 * confector.testing.memory_dispatch_queue and the in-memory document store, over which the state
 * stores (confector.core.state_stores) run in tests, is confector.testing.memory_document_store.
 */

import confector.plugin_api.model;
import std.format : format;
import std.json : JSONValue;


/**
 * In-memory implementation of ArtifactStorage for unit testing.
 * Stores artifacts as byte arrays in a hash map keyed by (fingerprint, artifactId).
 */
class InMemoryArtifactStorage : ArtifactStorage
{
    private ubyte[][string] m_artifacts;

    private static string artifactKey(string taskFingerprint, string artifactId) pure nothrow @safe
    {
        return taskFingerprint ~ "\0" ~ artifactId;
    }

    override void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
    {
        if (writer is null)
            throw new Exception("Writer delegate cannot be null");
        if (taskFingerprint.length == 0)
            throw new Exception("taskFingerprint cannot be empty");
        if (artifactId.length == 0)
            throw new Exception("artifactId cannot be empty");

        import std.array : Appender;
        Appender!(ubyte[]) buffer;
        writer((const(ubyte)[] chunk) {
            if (chunk.length > 0)
                buffer.put(chunk);
        });
        m_artifacts[artifactKey(taskFingerprint, artifactId)] = buffer.data;
    }

    override void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
            throw new Exception("Sink delegate cannot be null");

        string key = artifactKey(taskFingerprint, artifactId);
        if (key !in m_artifacts)
            throw new Exception(format("Artifact not found in storage: fingerprint='%s', artifactId='%s'", taskFingerprint, artifactId));

        sink(m_artifacts[key]);
    }

    override bool artifactExists(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0) return false;
        return (artifactKey(taskFingerprint, artifactId) in m_artifacts) !is null;
    }

    override void deleteArtifact(string taskFingerprint, string artifactId)
    {
        string key = artifactKey(taskFingerprint, artifactId);
        if (key in m_artifacts)
            m_artifacts.remove(key);
    }

    @property string backendType() const pure nothrow @safe
    {
        return "memory";
    }

    @property string displayName() const pure nothrow @safe
    {
        return "In-Memory (Test)";
    }

    @property string description() const
    {
        return "In-memory artifact storage for unit testing only.";
    }

    JSONValue defaultConfig() const
    {
        return JSONValue(string[string].init);
    }

    string[] validateConfig(in JSONValue config) const
    {
        return null;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        return "<p>In-memory storage (test only) — no configuration required.</p>";
    }

    override string presignUpload(string taskFingerprint, string artifactId)
    {
        return null; // In-memory storage does not support presigned URLs; fall back to proxy
    }

    override string presignDownload(string taskFingerprint, string artifactId)
    {
        return null; // In-memory storage does not support presigned URLs; fall back to proxy
    }
}

unittest
{
    auto storage = new InMemoryArtifactStorage();

    // Test stream-based content-addressed artifact storage
    string fingerprint = "fp123";
    string artifactId = "output.txt";
    string contents = "test artifact contents";

    // Store artifact via stream
    storage.storeArtifactStream(fingerprint, artifactId, (void delegate(const(ubyte)[]) sink) {
        sink(cast(ubyte[])contents.dup);
    });

    // Verify artifact exists
    assert(storage.artifactExists(fingerprint, artifactId));
    assert(!storage.artifactExists(fingerprint, "nonexistent"));
    assert(!storage.artifactExists("", artifactId));

    // Retrieve artifact via stream
    import std.array : Appender;
    Appender!(ubyte[]) retrievedBuffer;
    storage.retrieveArtifactStream(fingerprint, artifactId, (const(ubyte)[] chunk) {
        retrievedBuffer.put(chunk);
    });
    assert(retrievedBuffer.data == contents.dup);

    // Delete artifact
    storage.deleteArtifact(fingerprint, artifactId);
    assert(!storage.artifactExists(fingerprint, artifactId));

    // Test retrieval of nonexistent artifact
    bool caughtNotFound = false;
    try
    {
        storage.retrieveArtifactStream("no_such_fp", "no_such_art", (chunk) {});
    }
    catch (Exception)
    {
        caughtNotFound = true;
    }
    assert(caughtNotFound);
}
