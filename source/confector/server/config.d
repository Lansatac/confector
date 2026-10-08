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
 * Storage and Database configuration.
 */
struct StorageConfig
{
    @Description("MongoDB host and database name")
    string mongoHost = "mongo:27017/confector";

    @Description("Path to MongoDB authentication secret file")
    string secretPath = "/run/secrets/mongo-readwrite-password";

    @Required
    @Description("Base directory for artifact storage (required)")
    string artifactsDir = "";
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
 * Top-level Server configuration.
 */
struct ServerConfig
{
    @Description("Default server log level (trace, debug, info, warn, error)")
    string logLevel = "info";

    HttpConfig http;
    StorageConfig storage;
    PluginsConfig plugins;
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
    assert(cfg.storage.mongoHost == "mongo:27017/confector");
    assert(cfg.storage.artifactsDir == "");
    assert(cfg.plugins.bundledPluginsDir == "plugins");
}
