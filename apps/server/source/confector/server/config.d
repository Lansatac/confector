module confector.server.config;

import confector.config;
import vibe.data.json : Json;

/**
 * Server HTTP listener configuration.
 */
struct HttpConfig
{
    @Description("HTTP server listen port")
    ushort port = 8080;

    @Description("HTTP server bind address")
    string bindAddress = "0.0.0.0";
}

/**
 * The MongoDB that holds the document store and the dispatch queue. Both settings are required
 * and have no defaults; the server refuses to start without them (see
 * requireDocumentStoreConfig).
 */
struct DocumentStoreConfig
{
    @Required
    @Env("CONFECTOR_MONGO_URI")
    @Description("MongoDB connection URI for the document store (required), e.g. mongodb://mongo:27017")
    string connectionString = "";

    @Required
    @Description("MongoDB database holding the document store's collections (required)")
    string database = "";
}

/**
 * Scheduler callbacks. The scheduler fires HTTP requests back into the server (cron
 * triggers, VCS polling); each one must carry this secret, which the server checks and the
 * local scheduler sends. Required, with no default.
 */
struct SchedulerConfig
{
    @Required
    @Env("CONFECTOR_SCHEDULER_CALLBACK_SECRET")
    @Description("Secret the scheduler sends in the X-Confector-Scheduler-Secret header on every callback (required)")
    string callbackSecret = "";
}

/**
 * The artifact store: artifacts are kept as files under a base directory. Required, with no
 * default; the server refuses to start without it (see requireArtifactStoreConfig).
 */
struct ArtifactStoreConfig
{
    @Required
    @Description("Directory the local artifact store keeps artifacts in, created if missing (required)")
    string baseDirectory = "";
}

/**
 * Top-level Server configuration.
 */
struct ServerConfig
{
    @Description("Default server log level (trace, debug, info, warn, error)")
    string logLevel = "info";

    HttpConfig http;
    DocumentStoreConfig documentStore;
    SchedulerConfig scheduler;
    ArtifactStoreConfig artifactStore;
}

/**
 * Registers core server configuration definitions with the ConfigRegistry.
 */
void registerServerConfigDefinitions(ConfigRegistry registry)
{
    if (registry is null) return;

    registry.bindDefinition!ServerConfig("server");
}

/**
 * Throws, naming the missing setting, unless the document store is fully configured.
 */
void requireDocumentStoreConfig(in DocumentStoreConfig config)
{
    if (config.connectionString.length == 0)
        throw new Exception("[config] Required setting 'server.documentStore.connectionString' is missing "
            ~ "(server.documentStore.connectionString or CONFECTOR_MONGO_URI): the server cannot start without a document store.");
    if (config.database.length == 0)
        throw new Exception("[config] Required setting 'server.documentStore.database' is missing "
            ~ "(server.documentStore.database or " ~ keyToDefaultEnvVar("server.documentStore.database")
            ~ "): the server cannot start without a document store.");
}

/**
 * Throws, naming the missing setting, unless the scheduler callback secret is configured. The
 * scheduler calls back into the server on every schedule, so the server cannot run without it.
 */
void requireSchedulerConfig(in SchedulerConfig config)
{
    if (config.callbackSecret.length == 0)
        throw new Exception("[config] Required setting 'server.scheduler.callbackSecret' is missing "
            ~ "(server.scheduler.callbackSecret or CONFECTOR_SCHEDULER_CALLBACK_SECRET): the server cannot start "
            ~ "without it, because scheduler callbacks would be unauthenticated.");
}

/**
 * Throws, naming the missing setting, unless the artifact store is configured.
 */
void requireArtifactStoreConfig(in ArtifactStoreConfig config)
{
    if (config.baseDirectory.length == 0)
        throw new Exception("[config] Required setting 'server.artifactStore.baseDirectory' is missing "
            ~ "(server.artifactStore.baseDirectory or " ~ keyToDefaultEnvVar("server.artifactStore.baseDirectory")
            ~ "): the server cannot start without an artifact store.");
}

/**
 * Loads and binds ServerConfig from the ConfigRegistry.
 */
ServerConfig loadServerConfig(ConfigRegistry registry)
{
    if (registry is null)
    {
        return ServerConfig.init;
    }

    auto serverScope = registry.getScope("server");
    return serverScope.bind!ServerConfig();
}

unittest
{
    auto registry = new ConfigRegistry();
    registerServerConfigDefinitions(registry);

    auto cfg = loadServerConfig(registry);
    assert(cfg.logLevel == "info");
    assert(cfg.http.port == 8080);
    assert(cfg.http.bindAddress == "0.0.0.0");
    assert(cfg.documentStore.database == "");
    assert(cfg.scheduler.callbackSecret == "");
    assert(cfg.artifactStore.baseDirectory == "");
}

unittest
{
    import std.exception : assertThrown, collectException;
    import std.algorithm.searching : canFind;

    SchedulerConfig config;
    assertThrown!Exception(requireSchedulerConfig(config));
    auto message = collectException(requireSchedulerConfig(config));
    assert(message.msg.canFind("server.scheduler.callbackSecret"));

    config.callbackSecret = "s3cret";
    requireSchedulerConfig(config);
}

unittest
{
    import std.exception : assertThrown, collectException;

    DocumentStoreConfig config;
    assertThrown!Exception(requireDocumentStoreConfig(config));

    config.connectionString = "mongodb://mongo:27017";
    auto message = collectException(requireDocumentStoreConfig(config));
    assert(message !is null && message.msg.length > 0);
    import std.algorithm.searching : canFind;
    assert(message.msg.canFind("database"));

    config.database = "confector";
    requireDocumentStoreConfig(config);
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    ArtifactStoreConfig config;
    auto message = collectException(requireArtifactStoreConfig(config));
    assert(message !is null && message.msg.canFind("server.artifactStore.baseDirectory")
        && message.msg.canFind("CONFECTOR_SERVER_ARTIFACT_STORE_BASE_DIRECTORY"), message.msg);

    config.baseDirectory = "/artifacts";
    requireArtifactStoreConfig(config);
}

unittest
{
    import std.process : environment;

    // The environment variables the messages name do set the settings
    enum artifactVar = "CONFECTOR_SERVER_ARTIFACT_STORE_BASE_DIRECTORY";
    enum databaseVar = "CONFECTOR_SERVER_DOCUMENT_STORE_DATABASE";
    assert(keyToDefaultEnvVar("server.artifactStore.baseDirectory") == artifactVar);
    assert(keyToDefaultEnvVar("server.documentStore.database") == databaseVar);
    const savedArtifact = environment.get(artifactVar), savedDatabase = environment.get(databaseVar);
    scope(exit)
    {
        if (savedArtifact is null) environment.remove(artifactVar); else environment[artifactVar] = savedArtifact;
        if (savedDatabase is null) environment.remove(databaseVar); else environment[databaseVar] = savedDatabase;
    }
    environment[artifactVar] = "/from/environment";
    environment[databaseVar] = "from_environment";

    auto registry = new ConfigRegistry();
    registerServerConfigDefinitions(registry);
    auto cfg = loadServerConfig(registry);
    assert(cfg.artifactStore.baseDirectory == "/from/environment");
    assert(cfg.documentStore.database == "from_environment");
}
