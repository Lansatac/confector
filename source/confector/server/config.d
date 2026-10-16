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
 * Artifact storage configuration.
 */
struct StorageConfig
{
    @Required
    @Description("Base directory for artifact storage (required)")
    string artifactsDir = "";
}

/**
 * Where the server keeps its state: the MongoDB behind the document store. Both settings are
 * required and have no defaults; the server refuses to start without them (see
 * requireDocumentStoreConfig). The connection string is shared with the mongo-queue plugin
 * through CONFECTOR_MONGO_URI. This is an interim shape until backends are chosen from
 * configuration (bead confector-z7z.31.1).
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
 * Plugins subsystem configuration.
 */
struct PluginsConfig
{
    @Description("Directory for uploaded plugins")
    string pluginsUploadDir = "";

    @Description("Directory for bundled plugins")
    string bundledPluginsDir = "plugins";

    @Env("CONFECTOR_PLUGINS")
    @Description("List of additional plugins to load, separated by semicolon or comma")
    string confectorPlugins = "";
}

/**
 * Capacity broker configuration.
 */
struct CapacityConfig
{
    @Description("Interval in minutes between periodic capacity evaluations (default: 1)")
    int evaluationIntervalMinutes = 1;
}

/**
 * Top-level Server configuration.
 */
struct ServerConfig
{
    @Description("Default server log level (trace, debug, info, warn, error)")
    string logLevel = "info";

    HttpConfig http;
    StorageConfig storage;
    DocumentStoreConfig documentStore;
    PluginsConfig plugins;
    CapacityConfig capacity;
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
            ~ "(server.documentStore.database): the server cannot start without a document store.");
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
    assert(cfg.storage.artifactsDir == "");
    assert(cfg.plugins.bundledPluginsDir == "plugins");
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
