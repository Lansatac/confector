module confector.server.backends;

/**
 * The backends the server runs on, built once at startup from deployment configuration and
 * passed explicitly to whatever needs them (design record: bead confector-z7z.3). Nothing is
 * loaded at runtime and nothing is registered globally.
 *
 * Every setting is required: a missing or invalid one stops startup with an error naming it.
 * Each backend has one implementation for now (MongoDB for the document store and the dispatch
 * queue, the local scheduler, the local filesystem artifact store), so the configuration does
 * not name which one to use.
 */

import std.format : format;

import kaleidic.mongo_standalone : MongoConnection;
import confector.plugin_api.dispatch_queue : DispatchQueue;
import confector.plugin_api.document_store : DocumentStore;
import confector.plugin_api.model : ArtifactStorage;
import confector.plugin_api.scheduler : Scheduler;
import confector.plugins.artifact.local : LocalArtifactStorage;
import confector.plugins.document_store.mongo : MongoDocumentStore;
import confector.plugins.queue.mongo : MongoDispatchQueue;
import confector.plugins.scheduler.local : LocalScheduler;
import confector.server.config : HttpConfig, ServerConfig, requireArtifactStoreConfig, requireDocumentStoreConfig,
    requireSchedulerConfig;

/**
 * The server's backends. Every field is set once built.
 */
struct Backends
{
    /// Holds every state store's documents (confector.core.state_stores).
    DocumentStore documentStore;
    /// Delivers work to workers.
    DispatchQueue dispatchQueue;
    /// Calls back into the server on a schedule.
    Scheduler scheduler;
    /// Holds artifact bytes.
    ArtifactStorage artifactStore;
}

/**
 * The URL the local scheduler calls this server on: the address the server is bound to, or the
 * loopback address when it listens on every address (empty, 0.0.0.0 or ::). An IPv6 literal is
 * bracketed.
 */
string serverBaseUrl(in HttpConfig http)
{
    import std.algorithm.searching : canFind;

    string host = http.bindAddress;
    if (host.length == 0 || host == "0.0.0.0" || host == "::" || host == "[::]")
        host = "127.0.0.1";
    else if (host.canFind(':') && host[0] != '[')
        host = "[" ~ host ~ "]";
    return format("http://%s:%d", host, http.port);
}

unittest
{
    HttpConfig http;
    http.port = 9090;
    http.bindAddress = "0.0.0.0";
    assert(serverBaseUrl(http) == "http://127.0.0.1:9090");
    http.bindAddress = "";
    assert(serverBaseUrl(http) == "http://127.0.0.1:9090");
    http.bindAddress = "::";
    assert(serverBaseUrl(http) == "http://127.0.0.1:9090");
    http.bindAddress = "192.168.1.5";
    assert(serverBaseUrl(http) == "http://192.168.1.5:9090");
    http.bindAddress = "::1";
    assert(serverBaseUrl(http) == "http://[::1]:9090");
    http.bindAddress = "[::1]";
    assert(serverBaseUrl(http) == "http://[::1]:9090");
}

/**
 * Builds the backends `config` describes. Every setting is checked before any backend is built,
 * so a missing one fails startup without touching a database; an invalid one (an unreachable
 * MongoDB, an artifact directory that cannot be created) fails when its backend is built.
 *
 * The dispatch queue lives in the document store's MongoDB, on its own connection.
 */
Backends buildBackends(in ServerConfig config)
{
    requireDocumentStoreConfig(config.documentStore);
    requireSchedulerConfig(config.scheduler);
    requireArtifactStoreConfig(config.artifactStore);

    Backends backends;
    // The local backends first: they are cheap and fail without a database.
    backends.artifactStore = new LocalArtifactStorage(config.artifactStore.baseDirectory);
    backends.scheduler = new LocalScheduler(config.scheduler.callbackSecret, serverBaseUrl(config.http));
    backends.documentStore = new MongoDocumentStore(
        new MongoConnection(config.documentStore.connectionString), config.documentStore.database);
    backends.dispatchQueue = new MongoDispatchQueue(
        new MongoConnection(config.documentStore.connectionString), config.documentStore.database);
    return backends;
}

version (unittest)
{
    import confector.config : ConfigRegistry, keyToDefaultEnvVar;
    import vibe.data.json : Json, parseJsonString;

    /// The server configuration a confector.json with `json` as its content loads to.
    private ServerConfig configFrom(string json)
    {
        import confector.server.config : loadServerConfig, registerServerConfigDefinitions;

        auto registry = new ConfigRegistry(parseJsonString(json));
        registerServerConfigDefinitions(registry);
        return loadServerConfig(registry);
    }

    /// Builds the backends from `json` and returns the message startup fails with.
    private string startupFailure(string json)
    {
        import std.exception : collectException;

        auto failure = collectException(buildBackends(configFrom(json)));
        assert(failure !is null, "Startup must fail for " ~ json);
        return failure.msg;
    }

    /**
     * Unsets every environment variable that can supply a backend setting until the returned
     * value is destroyed, which restores them, so the tests see only their own configuration.
     */
    private auto withoutBackendEnvironment()
    {
        import std.process : environment;

        static struct Restore
        {
            string[string] saved;
            @disable this(this);
            ~this()
            {
                foreach (name, value; saved)
                    if (value is null) environment.remove(name); else environment[name] = value;
            }
        }

        Restore restore;
        foreach (name; ["CONFECTOR_MONGO_URI", "CONFECTOR_SCHEDULER_CALLBACK_SECRET",
            keyToDefaultEnvVar("server.documentStore.database"), keyToDefaultEnvVar("server.artifactStore.baseDirectory")])
        {
            restore.saved[name] = environment.get(name);
            environment.remove(name);
        }
        return restore;
    }

    /// A path under the temporary directory that does not exist.
    private string missingTempPath(string name)
    {
        import std.conv : to;
        import std.file : exists, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        auto path = buildPath(tempDir, "confector_backends_test_" ~ thisProcessID.to!string ~ "_" ~ name);
        assert(!exists(path), path ~ " is left over from an earlier run");
        return path;
    }
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists;

    auto environmentGuard = withoutBackendEnvironment();

    // Startup fails on each missing setting, naming it, before anything is connected or created:
    // the connection string points nowhere and the artifact directory is never made
    const artifactDirectory = missingTempPath("artifacts");
    const documentStore = `"documentStore": {"connectionString": "mongodb://unreachable.invalid:1", "database": "confector"}`;
    const scheduler = `"scheduler": {"callbackSecret": "s3cret"}`;
    const artifactStore = `"artifactStore": {"baseDirectory": ` ~ Json(artifactDirectory).toString() ~ `}`;

    auto noDocumentStore = startupFailure(`{"server": {` ~ scheduler ~ `, ` ~ artifactStore ~ `}}`);
    assert(noDocumentStore.canFind("server.documentStore.connectionString"), noDocumentStore);

    auto noDatabase = startupFailure(`{"server": {"documentStore": {"connectionString": "mongodb://unreachable.invalid:1"}, `
        ~ scheduler ~ `, ` ~ artifactStore ~ `}}`);
    assert(noDatabase.canFind("server.documentStore.database"), noDatabase);

    auto noSchedulerSecret = startupFailure(`{"server": {` ~ documentStore ~ `, ` ~ artifactStore ~ `}}`);
    assert(noSchedulerSecret.canFind("server.scheduler.callbackSecret"), noSchedulerSecret);

    assert(!exists(artifactDirectory), "A failed startup created the artifact directory");

    auto noArtifactStore = startupFailure(`{"server": {` ~ documentStore ~ `, ` ~ scheduler ~ `}}`);
    assert(noArtifactStore.canFind("server.artifactStore.baseDirectory"), noArtifactStore);
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, remove, write;

    auto environmentGuard = withoutBackendEnvironment();

    // An artifact directory that cannot be used fails startup, before any database is contacted
    string notADirectory = missingTempPath("file");
    write(notADirectory, "x");
    scope(exit) if (exists(notADirectory)) remove(notADirectory);

    auto failure = startupFailure(`{"server": {"documentStore": {"connectionString": "mongodb://unreachable.invalid:1", "database": "confector"}, `
        ~ `"scheduler": {"callbackSecret": "s3cret"}, "artifactStore": {"baseDirectory": `
        ~ Json(notADirectory).toString() ~ `}}}`);
    assert(failure.canFind(notADirectory) && failure.canFind("not a directory"), failure);
}
