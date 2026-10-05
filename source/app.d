module app;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.encoding : BOM, getBOM;
import std.file : exists, isDir, read;
import std.format : format;
import std.functional : toDelegate;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writefln, writeln;
import std.string : split, strip;

import vibe.vibe;

import confector.core.executor : CapacityBroker, ComputeProvisioner;
import confector.core.plugin : Plugin, PluginCategory, PluginRegistry;
import confector.core.plugin_loader : PluginLoader;
import confector.core.storage : BuildStateRepository, LocalArtifactStorage, InMemoryBuildStateRepository;
import confector.queue.mongo_queue : MongoWorkQueue;
import confector.queue.queue : WorkQueue, InMemoryWorkQueue;
import confector.runner.capacity_broker : DefaultCapacityBroker;
import confector.runner.coordinator : BuildCoordinator;
import confector.runner.engine : TaskEngine;
import confector.storage.mongo_repository : MongoBuildStateRepository;
import plugins.executors.local_process : LocalProcessProvisioner, LocalProcessProvisionerConfig;

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
        writeln("Could not read mongo secret: ", e.msg);
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
        writefln("Connecting to mongo at %s (authenticated)...", mongoHost);
    }
    else
    {
        mongoUri = "mongodb://" ~ mongoHost;
        writefln("Connecting to mongo at %s...", mongoHost);
    }

    try
    {
        ctx.client = connectMongoDB(mongoUri);
        ctx.stateRepo = new MongoBuildStateRepository(ctx.client);
        ctx.workQueue = new MongoWorkQueue(ctx.client);
        writeln("Connected to mongo.");
    }
    catch (Exception e)
    {
        writefln("Fatal: Failed to connect to MongoDB at %s: %s", mongoUri, e.msg);
        throw new Exception(format("Failed to connect to MongoDB at %s: %s", mongoUri, e.msg), e);
    }

    return ctx;
}

/// Discovers and loads bundled plugins as well as dynamically configured plugins via CONFECTOR_PLUGINS.
void initPlugins()
{
    // Automatically load bundled plugins from bin/plugins and plugins directories (definition and worker plugins only)
    Plugin[] bundledPlugins;
    foreach (pluginDir; ["bin/plugins", "plugins", "./bin/plugins", "./plugins"])
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
            writefln("[plugins] Loaded bundled plugin '%s' v%s (%s)", p.name, p.versionString, p.category);
        }
    }
    else
    {
        writeln("[plugins] No bundled plugins found in ./plugins.");
    }

    // Dynamically load additional configured plugins via CONFECTOR_PLUGINS
    string confectorPluginsEnv = environment.get("CONFECTOR_PLUGINS", "");
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
                        writefln("[plugins] Dynamically loaded plugin '%s' v%s (%s) from %s", p.name, p.versionString, p.category, trimmed);
                    }
                }
                catch (Exception e)
                {
                    writefln("[plugins] Warning: Failed to load configured plugin '%s': %s", trimmed, e.msg);
                }
            }
        }
    }
    else
    {
        writeln("[plugins] No additional external plugins configured via CONFECTOR_PLUGINS.");
    }

    writefln("[plugins] Active plugins in registry: %d", PluginRegistry.instance.allPlugins().length);
}

/// Configures application URL routing.
URLRouter createRouter(
    TaskEngine taskEngine,
    WorkQueue workQueue,
    BuildCoordinator buildCoordinator,
    BuildStateRepository stateRepo,
    MongoClient client,
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
    router.any("/api/v1/*", apiRouter(taskEngine, workQueue, buildCoordinator));

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

void main()
{
    // Ensure info and error logs are printed to console
    setLogLevel(LogLevel.warn);
    debug setLogLevel(LogLevel.info);

    // Initialize database & work queues
    auto storage = initStorage();

    // Automatically load plugins
    initPlugins();

    // Initialize execution engine, coordinator & storage
    auto artifactStorage = new LocalArtifactStorage(".confector/artifacts");
    auto taskEngine = new TaskEngine(artifactStorage, storage.stateRepo);
    auto buildCoordinator = new BuildCoordinator(artifactStorage, storage.stateRepo, storage.workQueue);
    writeln("Initialized Confector execution engine and build coordinator (stateless control plane mode).");

    // Initialize capacity broker & register default local process provisioner
    auto capacityBroker = new DefaultCapacityBroker(storage.workQueue, buildCoordinator);

    LocalProcessProvisionerConfig localCfg;
    localCfg.runnerBinary = environment.get("CONFECTOR_RUNNER_BIN", "bin/confector-runner");
    localCfg.serverUrl = environment.get("CONFECTOR_SERVER_URL", "http://localhost:8080");
    localCfg.workspaceDir = environment.get("CONFECTOR_WORKSPACE_DIR", ".confector/workspaces");
    localCfg.storageDir = environment.get("CONFECTOR_STORAGE_DIR", ".confector/artifacts");
    localCfg.pluginsDir = environment.get("CONFECTOR_PLUGINS_DIR", "plugins");
    string concurrencyEnv = environment.get("CONFECTOR_LOCAL_CONCURRENCY", "");
    if (concurrencyEnv.length > 0)
    {
        try { localCfg.maxConcurrency = concurrencyEnv.to!size_t; } catch (Exception) {}
    }
    auto localProvisioner = new LocalProcessProvisioner(localCfg);
    capacityBroker.registerProvisioner(localProvisioner);
    writefln("[capacity_broker] Registered default LocalProcessProvisioner (maxCapacity=%d)", localProvisioner.maxCapacity);

    // Register any provisioners from loaded plugins
    foreach (plugin; PluginRegistry.instance.allPlugins())
    {
        if (auto prov = cast(ComputeProvisioner) plugin)
        {
            capacityBroker.registerProvisioner(prov);
            writefln("[capacity_broker] Registered plugin provisioner '%s' (maxCapacity=%d)", prov.providerType, prov.maxCapacity);
        }
    }

    // Start capacity broker evaluation loop
    capacityBroker.start();
    writeln("[capacity_broker] Started capacity evaluation loop.");

    // Configure router and server settings
    auto router = createRouter(taskEngine, storage.workQueue, buildCoordinator, storage.stateRepo, storage.client, capacityBroker);
    debug setLogLevel(LogLevel.info);
    auto settings = createServerSettings(8080);

    listenHTTP(settings, router);

    writeln("Starting server");
    runApplication();
}

unittest
{
    auto stateRepo = new InMemoryBuildStateRepository();
    auto queue = new InMemoryWorkQueue();
    auto storage = new LocalArtifactStorage("test_app_storage");
    auto engine = new TaskEngine(storage, stateRepo);
    auto coordinator = new BuildCoordinator(storage, stateRepo, queue);
    auto broker = new DefaultCapacityBroker(queue, coordinator);
    broker.registerProvisioner(new LocalProcessProvisioner());

    auto router = createRouter(engine, queue, coordinator, stateRepo, null, broker);
    assert(router !is null);

    assert(broker.provisioners.length == 1);
    assert(broker.maxCapacity >= 1);

    import std.file : exists, rmdirRecurse;
    if (exists("test_app_storage")) rmdirRecurse("test_app_storage");
}