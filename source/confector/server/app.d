module app;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.encoding : BOM, getBOM;
import std.file : exists, isDir, read;
import std.format : format;
import std.functional : toDelegate;
import std.path : buildPath;
import std.process : environment;
import std.string : split, strip;

import vibe.vibe;

import confector.config;
import confector.server.config : ServerConfig, registerServerConfigDefinitions, loadServerConfig;
import confector.core.executor : CapacityBroker, ComputeProvisioner, ComputeProvider, WorkerRecord;
import confector.core.plugin : Plugin, PluginCategory, PluginRegistry;
import confector.core.plugin_loader : PluginLoader;
import confector.core.storage : BuildStateRepository, LocalArtifactStorage, InMemoryBuildStateRepository;
import confector.queue.mongo_queue : MongoWorkQueue;
import confector.queue.queue : WorkQueue, InMemoryWorkQueue;
import confector.runner.capacity_broker : DefaultCapacityBroker;
import confector.runner.coordinator : BuildCoordinator;
import confector.runner.engine : TaskEngine;
import confector.storage.mongo_repository : MongoBuildStateRepository;

import controller.admin_controller : adminRouter;
import controller.api_controller : apiRouter;
import controller.dashboard_controller : dashboardRouter;
import controller.executor_controller : executorRouter;
import controller.repositorycontroller : repositoryRouter;

/// Renders the default error page.
void errorPage(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
{
    res.render!("error.dt", req, error);
}

/// Reads a secret file, handling various BOM encodings.
string readSecretFile(string path)
{
    if (!exists(path))
        return "";

    try
    {
        auto raw = cast(const(ubyte)[]) read(path);
        if (raw.length == 0)
            return "";

        auto bom = getBOM(raw);
        auto payload = raw[bom.sequence.length .. $];

        switch (bom.schema)
        {
            case BOM.utf16le:
                return (cast(const(wchar)[]) payload).to!string.strip;
            case BOM.utf16be:
                // Byte-swap big-endian UTF-16 to host endian
                wchar[] wbuf = new wchar[](payload.length / 2);
                for (size_t i = 0; i + 1 < payload.length; i += 2)
                    wbuf[i / 2] = cast(wchar)((payload[i] << 8) | payload[i + 1]);
                return wbuf.to!string.strip;
            case BOM.utf32le:
                return (cast(const(dchar)[]) payload).to!string.strip;
            case BOM.utf8:
            case BOM.none:
            default:
                return (cast(const(char)[]) payload).to!string.strip;
        }
    }
    catch (Exception e)
    {
        logError("Could not read mongo secret: ", e.msg);
        return "";
    }
}

/// Holds database client, state repository, and work queue instances.
struct StorageContext
{
    MongoClient client;
    BuildStateRepository stateRepo;
    WorkQueue workQueue;
}

/// Initializes MongoDB storage and queue. Fails fast if MongoDB connection fails.
StorageContext initStorage(string mongoHost = "mongo:27017/confector", string secretPath = "/run/secrets/mongo-readwrite-password")
{
    StorageContext ctx;
    string password = readSecretFile(secretPath);

    string mongoUri;
    if (password.length > 0)
    {
        mongoUri = "mongodb://dev-read-write:" ~ password ~ "@" ~ mongoHost;
        logInfo("Connecting to mongo at %s (authenticated)...", mongoHost);
    }
    else
    {
        mongoUri = "mongodb://" ~ mongoHost;
        logInfo("Connecting to mongo at %s...", mongoHost);
    }

    try
    {
        ctx.client = connectMongoDB(mongoUri);
        ctx.stateRepo = new MongoBuildStateRepository(ctx.client);
        ctx.workQueue = new MongoWorkQueue(ctx.client);
        logInfo("Connected to mongo.");
    }
    catch (Exception e)
    {
        logError("Fatal: Failed to connect to MongoDB at %s: %s", mongoUri, e.msg);
        throw new Exception(format("Failed to connect to MongoDB at %s: %s", mongoUri, e.msg), e);
    }

    return ctx;
}

/// Discovers and loads bundled plugins as well as dynamically configured plugins via server config / CONFECTOR_PLUGINS.
void initPlugins(string bundledPluginsDir = "", string extraPlugins = "")
{
    // Automatically load bundled plugins from bin/plugins and plugins directories (definition and worker plugins only)
    Plugin[] bundledPlugins;
    string[] searchDirs = bundledPluginsDir.length > 0
        ? [bundledPluginsDir]
        : ["./plugins"];
    foreach (pluginDir; searchDirs)
    {
        if (exists(pluginDir) && isDir(pluginDir))
        {
            bundledPlugins ~= PluginLoader.instance.loadBundledPlugins(pluginDir, [PluginCategory.definition, PluginCategory.worker]);
        }
    }

    if (bundledPlugins.length > 0)
    {
        foreach (p; bundledPlugins)
        {
            logInfo("[plugins] Loaded bundled plugin '%s' v%s (%s)", p.name, p.versionString, p.category);
        }
    }
    else
    {
        logInfo("[plugins] No bundled plugins found in ./plugins.");
    }

    // Dynamically load additional configured plugins via extraPlugins or CONFECTOR_PLUGINS
    string confectorPluginsEnv = extraPlugins.length > 0 ? extraPlugins : environment.get("CONFECTOR_PLUGINS", "");
    string[] pluginPaths;
    if (confectorPluginsEnv.length > 0)
    {
        version (Windows)
        {
            pluginPaths = confectorPluginsEnv.split(";");
        }
        else
        {
            pluginPaths = confectorPluginsEnv.split(":");
        }

        if (pluginPaths.length == 1 && confectorPluginsEnv.canFind(","))
        {
            pluginPaths = confectorPluginsEnv.split(",");
        }
    }

    if (pluginPaths.length > 0)
    {
        foreach (path; pluginPaths)
        {
            string trimmed = path.strip;
            if (trimmed.length > 0)
            {
                try
                {
                    auto p = PluginLoader.instance.loadPlugin(trimmed, false, [PluginCategory.definition, PluginCategory.worker]);
                    if (p !is null)
                    {
                        logInfo("[plugins] Dynamically loaded plugin '%s' v%s (%s) from %s", p.name, p.versionString, p.category, trimmed);
                    }
                }
                catch (Exception e)
                {
                    logWarn("[plugins] Failed to load configured plugin '%s': %s", trimmed, e.msg);
                }
            }
        }
    }
    else
    {
        logInfo("[plugins] No additional external plugins configured via CONFECTOR_PLUGINS.");
    }

    logInfo("[plugins] Active plugins in registry: %d", PluginRegistry.instance.allPlugins().length);
}

/// Configures application URL routing.
URLRouter createRouter(
    TaskEngine taskEngine,
    WorkQueue workQueue,
    BuildCoordinator buildCoordinator,
    BuildStateRepository stateRepo,
    CapacityBroker capacityBroker = null)
{
    auto router = new URLRouter();

    // Static assets
    string publicDir = exists("public") ? "public" : (exists("../public") ? "../public" : "public");
    if (exists(buildPath(publicDir, "images", "favicon.ico")))
        router.get("/favicon.ico", serveStaticFile(buildPath(publicDir, "images", "favicon.ico")));
    else
        router.get("/favicon.ico", serveStaticFile("public/images/favicon.ico"));

    auto fsettings = new HTTPFileServerSettings();
    fsettings.serverPathPrefix = "/static";
    router.get("/static/*", serveStaticFiles(publicDir, fsettings));

    // API & serverless execution endpoints
    auto api = apiRouter(taskEngine, workQueue, buildCoordinator);
    router.any("/api/v1/*", api);
    router.any("/api/*", api);

    // Dashboard, builds, projects, executors, and admin UI
    router.any("/projects/*", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));
    router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });

    router.any("/builds/*", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));
    router.get("/builds", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/builds/"); });

    router.any("/tasks/*", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));
    router.get("/tasks", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/tasks/"); });

    router.any("/executors/*", executorRouter(stateRepo, PluginRegistry.instance, capacityBroker, workQueue));
    router.get("/executors", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/executors/"); });

    router.any("/admin/*", adminRouter(PluginRegistry.instance, PluginLoader.instance));
    router.get("/admin", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/admin/plugins"); });

    router.get("/", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));

    router.any("/repositories/*", repositoryRouter(stateRepo));
    router.get("/repositories", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/repositories/"); });

    return router;
}

/// Configures HTTP server settings.
HTTPServerSettings createServerSettings(ushort port = 8080)
{
    auto settings = new HTTPServerSettings();
    settings.port = port;
    settings.errorPageHandler = toDelegate(&errorPage);
    settings.options = HTTPServerOption.defaults;

    debug settings.options = HTTPServerOption.defaults | HTTPServerOption.errorStackTraces;
    // debug settings.accessLogToConsole = true;

    return settings;
}

ConfigRegistry loadConfigRegistry()
{
    string configDir = environment.get("CONFECTOR_CONFIG_DIR", "");
    if (configDir.length == 0)
    {
        logWarn("[config] CONFECTOR_CONFIG_DIR not set, using default './config'");
        configDir = "./config";
    }

    auto configRegistry = new ConfigRegistry();
    registerServerConfigDefinitions(configRegistry);

    auto configLoaded = false;

    foreach (cfgPath; [configDir.buildPath("confector.json"), configDir.buildPath("confector.yaml")])
    {
        if (exists(cfgPath))
        {
            try
            {
                configRegistry.loadConfigFile(cfgPath);
                logInfo("[config] Loaded configuration file from %s", cfgPath);
                configLoaded = true;
                break;
            }
            catch (Exception e)
            {
                logWarn("[config] Failed to load config file '%s': %s", cfgPath, e.msg);
            }
        }
    }

    if (!configLoaded)
    {
        logWarn("[config] No valid configuration file found, continuing with defaults.");
    }

    return configRegistry;
}

void main()
{
    // Initialize central ConfigRegistry
    auto configRegistry = loadConfigRegistry();
    registerServerConfigDefinitions(configRegistry);
    // Connect ConfigRegistry to PluginRegistry for scoped plugin configs
    PluginRegistry.instance.setConfigRegistry(configRegistry);

    // Load typed server configuration
    ServerConfig serverConfig = loadServerConfig(configRegistry);

    // Configure log level
    LogLevel configuredLogLevel = LogLevel.info;
    switch (serverConfig.logLevel.toLower())
    {
        case "trace": configuredLogLevel = LogLevel.trace; break;
        case "debug": configuredLogLevel = LogLevel.debug_; break;
        case "info": configuredLogLevel = LogLevel.info; break;
        case "warn": configuredLogLevel = LogLevel.warn; break;
        case "error": configuredLogLevel = LogLevel.error; break;
        default: break;
    }
    setLogLevel(configuredLogLevel);

    // Initialize database & work queues
    auto storage = initStorage(serverConfig.storage.mongoHost, serverConfig.storage.secretPath);

    // Automatically load plugins
    initPlugins(serverConfig.plugins.bundledPluginsDir, serverConfig.plugins.confectorPlugins);

    // Initialize execution engine, coordinator & storage
    auto artifactStorage = new LocalArtifactStorage(serverConfig.storage.artifactsDir);
    auto taskEngine = new TaskEngine(artifactStorage, storage.stateRepo);
    auto buildCoordinator = new BuildCoordinator(artifactStorage, storage.stateRepo, storage.workQueue);
    logInfo("Initialized Confector execution engine and build coordinator.");

    // Initialize capacity broker
    auto capacityBroker = new DefaultCapacityBroker(storage.workQueue, buildCoordinator);

    // Register any provisioners from loaded plugins via ComputeProvider.createProvisioner()
    foreach (plugin; PluginRegistry.instance.allPlugins())
    {
        if (auto provider = cast(ComputeProvider) plugin)
        {
            WorkerRecord record;
            record.providerType = provider.providerType;
            record.enabled = true;
            record.configuration = provider.defaultConfig();
            auto prov = provider.createProvisioner(record);
            if (prov !is null)
            {
                capacityBroker.registerProvisioner(prov);
                logInfo("[capacity_broker] Registered plugin provisioner '%s' (maxCapacity=%d)", prov.providerType, prov.maxCapacity);
            }
            else
            {
                logWarn("[capacity_broker] ComputeProvider '%s' returned null from createProvisioner(), skipping", provider.providerType);
            }
        }
    }

    // Warn if no provisioners were registered — builds will silently fail without them
    if (capacityBroker.provisioners.length == 0)
    {
        logError("[capacity_broker] CRITICAL: No compute provisioners registered. Builds will queue but never execute.");
        logError("[capacity_broker] Ensure at least one ComputeProvider plugin (e.g., local_process) is loaded in '%s'.", serverConfig.plugins.bundledPluginsDir);
    }
    else
    {
        logInfo("[capacity_broker] %d provisioner(s) registered, total capacity: %d", capacityBroker.provisioners.length, capacityBroker.maxCapacity);
    }

    // Start capacity broker evaluation loop
    capacityBroker.start();
    logInfo("[capacity_broker] Started capacity evaluation loop.");

    // Configure router and server settings
    auto router = createRouter(taskEngine, storage.workQueue, buildCoordinator, storage.stateRepo, capacityBroker);
    auto settings = createServerSettings(serverConfig.http.port);
    if (serverConfig.http.bindAddress.length > 0)
    {
        settings.bindAddresses = [serverConfig.http.bindAddress];
    }

    listenHTTP(settings, router);

    logInfo("Starting server on port %d", serverConfig.http.port);
    runApplication();
}

unittest
{
    auto configRegistry = new ConfigRegistry();
    registerServerConfigDefinitions(configRegistry);
    PluginRegistry.instance.setConfigRegistry(configRegistry);

    auto stateRepo = new InMemoryBuildStateRepository();
    auto queue = new InMemoryWorkQueue();
    auto storage = new LocalArtifactStorage("test_app_storage");
    auto engine = new TaskEngine(storage, stateRepo);
    auto coordinator = new BuildCoordinator(storage, stateRepo, queue);
    auto broker = new DefaultCapacityBroker(queue, coordinator);

    class TestProvisioner : ComputeProvisioner
    {
        @property string providerType() const { return "local"; }
        @property size_t activeInstanceCount() const { return 0; }
        @property size_t maxCapacity() const { return 4; }
        bool canProvision(in QueueDemand demand) const { return true; }
        void requestCapacity(in QueueDemand demand) {}
    }

    broker.registerProvisioner(new TestProvisioner());

    auto router = createRouter(engine, queue, coordinator, stateRepo, null, broker);
    assert(router !is null);

    assert(broker.provisioners.length == 1);
    assert(broker.maxCapacity >= 1);

    import std.file : exists, rmdirRecurse;
    if (exists("test_app_storage")) rmdirRecurse("test_app_storage");
}