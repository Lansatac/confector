module confector.server.app;

import std.functional : toDelegate;
import std.file : exists;
import std.path : buildPath;
import std.process : environment;

import vibe.vibe;

import confector.config;
import confector.core.state_stores : StateStores;
import confector.server.backends : Backends, buildBackends;
import confector.server.config : ServerConfig, registerServerConfigDefinitions, loadServerConfig, requireExecutionConfig;

import confector.server.controller.api_controller : apiRouter;
import confector.server.controller.artifacts_controller : artifactsRouter;
import confector.server.controller.dashboard_controller : dashboardRouter;
import confector.server.controller.repositorycontroller : repositoryRouter;

/// Renders the default error page.
void errorPage(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
{
    res.render!("error.dt", req, error);
}

/// Configures application URL routing over `backends` and `stores`, the state stores kept in
/// its document store.
URLRouter createRouter(Backends backends, StateStores stores, string schedulerCallbackSecret, uint maxExecutionAttempts)
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

    // API endpoints. The artifact routes come first, so the API router never answers them.
    router.any("/api/v1/artifacts/*", artifactsRouter(backends.artifactStore));
    router.any("/api/v1/*", apiRouter(schedulerCallbackSecret, maxExecutionAttempts, backends.dispatchQueue, stores));

    // Dashboard, projects, tasks and repositories UI. Build views wait for request intake
    // and chain state (beads confector-z7z.23.7 and confector-z7z.49.x)
    router.any("/projects/*", dashboardRouter(stores));
    router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });

    router.any("/tasks/*", dashboardRouter(stores));

    router.get("/", dashboardRouter(stores));

    router.any("/repositories/*", repositoryRouter(stores));
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
    auto configRegistry = loadConfigRegistry();
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

    requireExecutionConfig(serverConfig.execution);

    // A missing or invalid backend setting, or an unreachable MongoDB, ends startup here.
    // Constructing StateStores declares every collection, which needs the database.
    Backends backends = buildBackends(serverConfig);
    auto stores = new StateStores(backends.documentStore);
    logInfo("[state] State is kept in MongoDB database '%s'.", serverConfig.documentStore.database);

    auto router = createRouter(backends, stores, serverConfig.scheduler.callbackSecret, serverConfig.execution.maxAttempts);
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
    import confector.backends.scheduler.local : LocalScheduler;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.uri : encodeComponent;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    Backends backends;
    backends.documentStore = new InMemoryDocumentStore();
    backends.dispatchQueue = new InMemoryDispatchQueue();
    backends.scheduler = new LocalScheduler("test-scheduler-secret", "http://127.0.0.1:8080");
    auto artifacts = new InMemoryArtifactStorage();
    backends.artifactStore = artifacts;
    auto router = createRouter(backends, new StateStores(backends.documentStore), "test-scheduler-secret", 3);

    struct Answer { int status; string body; }

    Answer call(HTTPMethod method, string path, string body = null)
    {
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method, InetHeaderMap.init,
            createMemoryStream(cast(ubyte[]) body.dup, false));
        router.handleRequest(req, res);
        assert(res.headerWritten, "No route answered " ~ path);
        return Answer(res.statusCode, cast(string) sink.data);
    }

    // Every path the runner's HttpArtifactStorage (libs/runner_core http_artifact_storage.d)
    // requests, built the same way, reaches the artifact routes and the configured store. The
    // artifact id needs encoding, and must arrive decoded exactly once.
    enum prefix = "/api/v1/artifacts";
    enum rawId = "100% done.zip";
    const fp = encodeComponent("fp1"), id = encodeComponent(rawId);
    const query = "?fingerprint=" ~ fp ~ "&artifactId=" ~ id;

    auto presignUpload = call(HTTPMethod.GET, prefix ~ "/presign-upload" ~ query);
    assert(presignUpload.status == HTTPStatus.ok && parseJsonString(presignUpload.body) == Json.emptyObject, presignUpload.body);
    auto presignDownload = call(HTTPMethod.GET, prefix ~ "/presign-download" ~ query);
    assert(presignDownload.status == HTTPStatus.ok && parseJsonString(presignDownload.body) == Json.emptyObject, presignDownload.body);

    assert(call(HTTPMethod.HEAD, prefix ~ "/_head/" ~ fp ~ "/" ~ id).status == HTTPStatus.notFound);
    assert(call(HTTPMethod.POST, prefix ~ "/" ~ fp ~ "/" ~ id ~ "/upload", "artifact bytes").status == HTTPStatus.ok);
    assert(artifacts.artifactExists("fp1", rawId), "The upload reached the configured store under the decoded id");
    assert(call(HTTPMethod.HEAD, prefix ~ "/_head/" ~ fp ~ "/" ~ id).status == HTTPStatus.ok);

    auto download = call(HTTPMethod.GET, prefix ~ "/" ~ fp ~ "/" ~ id ~ "/download");
    assert(download.status == HTTPStatus.ok && download.body == "artifact bytes", download.body);

    assert(call(HTTPMethod.DELETE, prefix ~ "/" ~ fp ~ "/" ~ id).status == HTTPStatus.ok);
    assert(!artifacts.artifactExists("fp1", rawId));
    assert(call(HTTPMethod.HEAD, prefix ~ "/_head/" ~ fp ~ "/" ~ id).status == HTTPStatus.notFound);

    // The artifacts page is gone
    auto sink = createMemoryOutputStream();
    auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/artifacts/"), HTTPMethod.GET), res);
    assert(!res.headerWritten, "No route answers /artifacts/");
}
