module confector.server.config;

import confector.config;
import vibe.data.json : Json;

/**
 * Server HTTP listener configuration.
 */
struct HttpConfig
{
    ushort port = 8080;
    string bindAddress = "0.0.0.0";
}

/**
 * Storage and Database configuration.
 */
struct StorageConfig
{
    string mongoHost = "mongo:27017/confector";
    string secretPath = "/run/secrets/mongo-readwrite-password";
    string artifactsDir = ".confector/artifacts";
}

/**
 * Plugins subsystem configuration.
 */
struct PluginsConfig
{
    string pluginsDir = "plugins";
    string bundledPluginsDir = "bin/plugins";
    string confectorPlugins = "";
}

/**
 * Top-level Server configuration.
 */
struct ServerConfig
{
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

    // Log level
    registry.registerDefinition(ConfigDefinition(
        "server.logLevel",
        "CONFECTOR_LOG_LEVEL",
        Json("info"),
        "Default server log level (trace, debug, info, warn, error)"
    ));

    // HTTP configuration
    registry.registerDefinition(ConfigDefinition(
        "server.http.port",
        "CONFECTOR_SERVER_PORT",
        Json(8080),
        "HTTP server listen port"
    ));
    registry.registerDefinition(ConfigDefinition(
        "server.http.bindAddress",
        "CONFECTOR_BIND_ADDRESS",
        Json("0.0.0.0"),
        "HTTP server bind address"
    ));

    // Storage configuration
    registry.registerDefinition(ConfigDefinition(
        "server.storage.mongoHost",
        "CONFECTOR_MONGO_HOST",
        Json("mongo:27017/confector"),
        "MongoDB host and database name"
    ));
    registry.registerDefinition(ConfigDefinition(
        "server.storage.secretPath",
        "CONFECTOR_MONGO_SECRET_PATH",
        Json("/run/secrets/mongo-readwrite-password"),
        "Path to MongoDB authentication secret file"
    ));
    registry.registerDefinition(ConfigDefinition(
        "server.storage.artifactsDir",
        "CONFECTOR_STORAGE_DIR",
        Json(".confector/artifacts"),
        "Base directory for artifact storage"
    ));

    // Plugins configuration
    registry.registerDefinition(ConfigDefinition(
        "server.plugins.pluginsDir",
        "CONFECTOR_PLUGINS_DIR",
        Json("plugins"),
        "Directory containing plugin packages"
    ));
    registry.registerDefinition(ConfigDefinition(
        "server.plugins.confectorPlugins",
        "CONFECTOR_PLUGINS",
        Json(""),
        "Paths to extra dynamic plugin shared libraries"
    ));
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

    ServerConfig config;
    auto serverScope = registry.getScope("server");
    config.logLevel = serverScope.getString("logLevel", "info");

    auto httpScope = registry.getScope("server.http");
    config.http = httpScope.bind!HttpConfig();

    auto storageScope = registry.getScope("server.storage");
    config.storage = storageScope.bind!StorageConfig();

    auto pluginsScope = registry.getScope("server.plugins");
    config.plugins = pluginsScope.bind!PluginsConfig();

    return config;
}

unittest
{
    auto registry = new ConfigRegistry();
    registerServerConfigDefinitions(registry);

    auto cfg = loadServerConfig(registry);
    assert(cfg.logLevel == "info");
    assert(cfg.http.port == 8080);
    assert(cfg.storage.artifactsDir == ".confector/artifacts");
    assert(cfg.plugins.pluginsDir == "plugins");
}
