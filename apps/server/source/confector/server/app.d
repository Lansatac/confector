module confector.server.app;

import std.conv : to;
import std.file : exists, isDir;
import std.format : format;
import std.functional : toDelegate;
import std.path : buildPath;
import std.process : environment;

import vibe.vibe;

import confector.config;
import confector.server.config : ServerConfig, registerServerConfigDefinitions, loadServerConfig, requireDocumentStoreConfig, requireSchedulerConfig;
import confector.core.executor : CapacityBroker, ComputeProvisioner, ComputeProvider, WorkerRecord;
import confector.core.plugin : Plugin, PluginCategory, PluginRegistry;
import confector.core.plugin_loader : PluginLoader;
import confector.core.state_stores : StateStores;
import confector.mongo_helpers : MongoConnection;
import confector.plugins.document_store.mongo : MongoDocumentStore;
import confector.plugin_api.scheduler : ScheduleEntry;
import confector.server.storage.configured_storage : ConfiguredArtifactStorage;
import confector.plugin_api.dispatch_queue : DispatchQueue;
import confector.plugin_api.model : QueueDemand;
import confector.server.orchestrator.capacity_broker : DefaultCapacityBroker;
import confector.core.execution_dispatcher : queuedDemand;

import confector.server.controller.api_controller : apiRouter;
import confector.server.controller.artifacts_controller : artifactsRouter;
import confector.server.controller.dashboard_controller : dashboardRouter;
import confector.server.controller.repositorycontroller : repositoryRouter;

/// Renders the default error page.
void errorPage(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
{
    res.render!("error.dt", req, error);
}

/// Discovers and loads the bundled plugins.
void initPlugins(string bundledPluginsDir = "")
{
    Plugin[] bundledPlugins;
    string[] searchDirs = bundledPluginsDir.length > 0
        ? [bundledPluginsDir]
        : ["./plugins"];
    foreach (pluginDir; searchDirs)
    {
        if (exists(pluginDir) && isDir(pluginDir))
        {
            bundledPlugins ~= PluginLoader.instance.loadBundledPlugins(
              pluginDir,
              [PluginCategory.definition,
               PluginCategory.worker,
               PluginCategory.artifact,
               PluginCategory.queue,
               PluginCategory.scheduler]
              );
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

    logInfo("[plugins] Active plugins in registry: %d", PluginRegistry.instance.allPlugins().length);
}

/// Configures application URL routing.
URLRouter createRouter(
    DispatchQueue dispatchQueue,
    StateStores stores,
    string schedulerCallbackSecret,
    CapacityBroker capacityBroker = null,
    ConfiguredArtifactStorage configuredStorage = null)
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

    // API endpoints
    router.any("/api/v1/*", apiRouter(schedulerCallbackSecret, dispatchQueue, stores, capacityBroker));

    // Dashboard, projects, tasks, repositories and artifacts UI. Build views wait for request intake
    // and chain state (beads confector-z7z.23.7 and confector-z7z.49.x)
    router.any("/projects/*", dashboardRouter(stores));
    router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });

    router.any("/tasks/*", dashboardRouter(stores));

    router.get("/", dashboardRouter(stores));

    router.any("/repositories/*", repositoryRouter(stores));
    router.get("/repositories", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/repositories/"); });

    router.any("/artifacts/*", artifactsRouter(PluginRegistry.instance, configuredStorage));
    router.get("/artifacts", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/artifacts/"); });

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
    // Connect ConfigRegistry to PluginRegistry for scoped plugin configs
    PluginRegistry.instance.setConfigRegistry(configRegistry);

    // Load typed server configuration
    ServerConfig serverConfig = loadServerConfig(configRegistry);

    // Scheduler callbacks are authenticated by a shared secret; without one the server cannot
    // start, because the scheduler always calls back into it.
    requireSchedulerConfig(serverConfig.scheduler);

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

    // Load all plugins (storage, queue, definition, worker, artifact) via plugin loader
    initPlugins(serverConfig.plugins.bundledPluginsDir);

    // The state stores run over the Mongo document store, configured under server.documentStore.
    // Missing settings or an unreachable MongoDB end startup here (constructing StateStores
    // declares every collection, which needs the database). Choosing the backend from
    // configuration is bead confector-z7z.31.1.
    requireDocumentStoreConfig(serverConfig.documentStore);
    auto stores = new StateStores(new MongoDocumentStore(
        new MongoConnection(serverConfig.documentStore.connectionString),
        serverConfig.documentStore.database));
    logInfo("[state] State is kept in MongoDB database '%s'.", serverConfig.documentStore.database);

    DispatchQueue dispatchQueue = PluginRegistry.instance.getDispatchQueue();
    if (dispatchQueue is null)
    {
        throw new Exception("No dispatch queue plugin registered: the server cannot start without one.");
    }
    logInfo("Using dispatch queue %s.", typeid(cast(Object) dispatchQueue).name);

    // Validate that at least one artifact storage plugin is registered
    auto artifactStorage = PluginRegistry.instance.getDefaultArtifactStorage();
    if (artifactStorage is null)
    {
        throw new Exception("No artifact storage plugin registered: the server cannot start without one.");
    }

    auto configuredStorage = new ConfiguredArtifactStorage(PluginRegistry.instance);

    // Demand is the executions sent and waiting for a worker, read from the state store; the
    // scheduler asks the broker to evaluate it (/broker/evaluate).
    auto capacityBroker = new DefaultCapacityBroker(() => queuedDemand(stores.executions));

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
                logInfo("[capacity_broker] Registered plugin provisioner '%s' (maxCapacity=%d)",
                  prov.providerType, prov.maxCapacity);
            }
            else
            {
                logWarn("[capacity_broker] ComputeProvider '%s' returned null from createProvisioner(), skipping",
                  provider.providerType);
            }
        }
    }

    // Warn if no provisioners were registered — builds will silently fail without them
    if (capacityBroker.provisioners.length == 0)
    {
        logWarn("[capacity_broker] No compute provisioners registered. Builds will queue but never execute. " ~
         "Ensure at least one ComputeProvider plugin (e.g., local_process) is loaded in '%s'.",
          serverConfig.plugins.bundledPluginsDir);
    }
    else
    {
        logInfo("[capacity_broker] %d provisioner(s) registered, total capacity: %d", capacityBroker.provisioners.length, capacityBroker.maxCapacity);
    }

    // Load scheduler plugin
    auto scheduler = PluginRegistry.instance.getDefaultScheduler();
    if (scheduler is null)
        throw new Exception("No scheduler plugin registered; capacity evaluation cannot run");

    // Configure router and server settings
    auto router = createRouter(dispatchQueue,
      stores,
      serverConfig.scheduler.callbackSecret,
      capacityBroker,
      configuredStorage);
    auto settings = createServerSettings(serverConfig.http.port);
    if (serverConfig.http.bindAddress.length > 0)
    {
        settings.bindAddresses = [serverConfig.http.bindAddress];
    }

    listenHTTP(settings, router);

    // Start the scheduler plugin
    if (scheduler !is null)
    {
        scheduler.start();
        logInfo("[scheduler] Scheduler plugin started");

        // Register capacity evaluation schedule entry
        ScheduleEntry capacityEntry;
        capacityEntry.id = "capacity-evaluate";
        capacityEntry.name = "Capacity Broker Evaluation";
        capacityEntry.uri = format("http://127.0.0.1:%d/api/v1/broker/evaluate", serverConfig.http.port);
        capacityEntry.httpMethod = "POST";
        int evalInterval = serverConfig.capacity.evaluationIntervalMinutes;
        if (evalInterval < 1) evalInterval = 1;
        if (evalInterval == 1)
            capacityEntry.cronExpression = "* * * * *";
        else
            capacityEntry.cronExpression = format("*/%d * * * *", evalInterval);
        capacityEntry.recurring = true;
        scheduler.schedule(capacityEntry);
        logInfo("[scheduler] Registered capacity evaluation entry (every %d min)", evalInterval);
    }

    logInfo("Starting server on port %d", serverConfig.http.port);
    runApplication();
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;

    auto configRegistry = new ConfigRegistry();
    registerServerConfigDefinitions(configRegistry);
    PluginRegistry.instance.setConfigRegistry(configRegistry);

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto queue = new InMemoryDispatchQueue();
    auto broker = new DefaultCapacityBroker(() => queuedDemand(stores.executions));

    class TestProvisioner : ComputeProvisioner
    {
        @property string providerType() const { return "local"; }
        @property size_t activeInstanceCount() const { return 0; }
        @property size_t maxCapacity() const { return 4; }
        bool canProvision(in QueueDemand demand) const { return true; }
        void requestCapacity(in QueueDemand demand) {}
    }

    broker.registerProvisioner(new TestProvisioner());

    auto router = createRouter(queue, stores, "test-scheduler-secret", broker);
    assert(router !is null);

    assert(broker.provisioners.length == 1);
    assert(broker.maxCapacity >= 1);
}