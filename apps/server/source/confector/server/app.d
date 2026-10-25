module confector.server.app;

import std.functional : toDelegate;
import std.file : exists, isDir;
import std.path : buildPath;
import std.process : environment;

import vibe.vibe;

import confector.config;
import confector.core.state_stores : StateStores;
import confector.core.worker_signing_key : SigningKeySource, generateWorkerSigningKey;
import confector.server.backends : Backends, buildBackends;
import confector.server.config : ServerConfig, registerServerConfigDefinitions, loadServerConfig, requireExecutionConfig, requireWorkerPoolConfig, requireWorkerTokenConfig;
import confector.server.route_access : AuthorizedRoutes;
import confector.api.model : Role;

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
/// its document store. Worker tokens are signed and checked with `workerTokenKey`; receiving work
/// is admitted only with `workerPoolCredential`. Every route is registered with its access, and
/// user requests are authenticated by `backends.authenticator`.
AuthorizedRoutes createRouter(Backends backends, StateStores stores, string schedulerCallbackSecret, string workerTokenKey,
    string workerPoolCredential, uint maxExecutionAttempts)
{
    auto authenticator = backends.authenticator;
    auto router = new AuthorizedRoutes(authenticator);

    // Static assets
    string publicDir = exists("public") ? "public" : (exists("../public") ? "../public" : "public");
    if (exists(buildPath(publicDir, "images", "favicon.ico")))
        router.get("/favicon.ico", Role.viewer, serveStaticFile(buildPath(publicDir, "images", "favicon.ico")));
    else
        router.get("/favicon.ico", Role.viewer, serveStaticFile("public/images/favicon.ico"));

    auto fsettings = new HTTPFileServerSettings();
    fsettings.serverPathPrefix = "/static";
    router.get("/static/*", Role.viewer, serveStaticFiles(publicDir, fsettings));

    // API endpoints and the artifact routes workers use
    router.include(artifactsRouter(authenticator, backends.artifactStore, workerTokenKey, stores));
    router.include(apiRouter(authenticator, schedulerCallbackSecret, workerTokenKey, workerPoolCredential,
        maxExecutionAttempts, backends.dispatchQueue, stores));

    // Dashboard, projects, tasks and repositories UI. Build views wait for request intake
    // and request state (beads confector-z7z.23.7 and confector-z7z.49.x)
    router.include(dashboardRouter(authenticator, stores));
    router.get("/projects", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });

    router.include(repositoryRouter(authenticator, stores));
    router.get("/repositories", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/repositories/"); });

    // Paths no route matches are answered 401 or 404 by authentication. Worker paths keep their own
    // answer, which is no answer here.
    router.answerUnmatched(["/api/v1/artifacts/", "/api/v1/queue/", "/api/v1/executions/"]);

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

/// The directory holding the server's configuration file, from CONFECTOR_CONFIG_DIR, or empty when
/// it is unset: the server then runs on environment variables alone.
string configDirectory()
{
    return environment.get("CONFECTOR_CONFIG_DIR", "");
}

/// Loads the server's configuration from `configDir`, which holds confector.json. An empty
/// `configDir` loads no file: the settings come from environment variables alone. A non-empty
/// one must be an existing directory containing a parseable configuration file. Any failure
/// throws, naming the path and the error.
ConfigRegistry loadConfigRegistry(string configDir)
{
    auto configRegistry = new ConfigRegistry();
    registerServerConfigDefinitions(configRegistry);

    if (configDir.length == 0)
    {
        logInfo("[config] CONFECTOR_CONFIG_DIR is not set, reading configuration from environment variables only.");
        return configRegistry;
    }

    if (!(exists(configDir) && isDir(configDir)))
        throw new Exception("[config] Configuration directory '" ~ configDir ~ "' does not exist or is not a directory.");

    string cfgPath = configDir.buildPath("confector.json");
    if (!exists(cfgPath))
        throw new Exception("[config] No configuration file found in '" ~ configDir ~ "': expected '" ~ cfgPath ~ "'.");

    configRegistry.loadConfigFile(cfgPath);
    logInfo("[config] Loaded configuration file from %s", cfgPath);
    return configRegistry;
}

void main()
{
    auto configRegistry = loadConfigRegistry(configDirectory());
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
    requireWorkerPoolConfig(serverConfig.workerPool);
    requireWorkerTokenConfig(serverConfig.workerTokens);

    // A missing or invalid backend setting, or an unreachable MongoDB, ends startup here.
    // Constructing StateStores declares every collection, which needs the database.
    Backends backends = buildBackends(serverConfig);
    auto stores = new StateStores(backends.documentStore);
    logInfo("[state] State is kept in MongoDB database '%s'.", serverConfig.documentStore.database);

    auto signingKey = stores.workerSigningKeys.resolve(serverConfig.workerTokens.signingKey, () => generateWorkerSigningKey());
    if (signingKey.source == SigningKeySource.generated)
        logWarn("[auth] Generated the worker token signing key and stored it in the document store. Backups and exports of the store now hold the key; set server.workerTokens.signingKey to use a key of your own.");
    else if (signingKey.source == SigningKeySource.configured)
        logInfo("[auth] Worker tokens are signed with the configured signing key.");

    auto router = createRouter(backends, stores, serverConfig.scheduler.callbackSecret,
        signingKey.key, serverConfig.workerPool.credential, serverConfig.execution.maxAttempts);
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
    import confector.api.model : ExecutionStatus, TaskExecution;
    import confector.backends.scheduler.local : LocalScheduler;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.core.worker_token : InputArtifact, WorkerTokenClaims, mintWorkerToken, workerTokenHeader;
    import std.datetime.systime : Clock;
    import std.uri : encodeComponent;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;
    import confector.server.authenticator : FixedAuthenticator, Identity;
    import std.typecons : Nullable;

    Backends backends;
    backends.documentStore = new InMemoryDocumentStore();
    backends.dispatchQueue = new InMemoryDispatchQueue();
    backends.scheduler = new LocalScheduler("test-scheduler-secret", "http://127.0.0.1:8080");
    // The worker routes check their own tokens, so no user identity is needed to reach them
    backends.authenticator = new FixedAuthenticator(Nullable!Identity.init);
    auto artifacts = new InMemoryArtifactStorage();
    backends.artifactStore = artifacts;
    enum testSigningKey = "0123456789abcdef0123456789abcdef";
    auto testStores = new StateStores(backends.documentStore);
    TaskExecution execution;
    execution.id = "exe_1";
    execution.projectId = "proj";
    execution.taskId = "task";
    execution.createdAt = "2026-10-16T10:00:00Z";
    execution.fingerprint = "fp1";
    execution.status = ExecutionStatus.queued;
    execution.attempts = 1;
    testStores.executions.createIfAbsent(execution);
    auto router = createRouter(backends, testStores, "test-scheduler-secret", testSigningKey,
        "pool-credential-0123456789abcdef0123456789abcdef", 3);

    struct Answer { int status; string body; }

    // The worker token of an execution that uploads under "fp1" and downloads "fp1"'s artifact
    // "100% done.zip" as an input
    WorkerTokenClaims claims;
    claims.executionId = "exe_1";
    claims.fingerprint = "fp1";
    claims.receipt = "receipt_1";
    claims.attempt = 1;
    claims.expiresAt = Clock.currTime.toUnixTime() + 600;
    claims.inputs = [InputArtifact("fp1", "100% done.zip")];
    const token = mintWorkerToken(testSigningKey, claims);

    Answer call(HTTPMethod method, string path, string body = null)
    {
        InetHeaderMap headers;
        headers[workerTokenHeader] = token;
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method, headers,
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

    // A worker never deletes
    assert(call(HTTPMethod.DELETE, prefix ~ "/" ~ fp ~ "/" ~ id).status == HTTPStatus.forbidden);
    assert(artifacts.artifactExists("fp1", rawId));

    // Without a token, none of these routes is reached, and the API router does not answer them
    auto sinkWithoutToken = createMemoryOutputStream();
    auto resWithoutToken = createTestHTTPServerResponse(sinkWithoutToken, null, TestHTTPResponseMode.bodyOnly);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost" ~ prefix ~ "/" ~ fp ~ "/" ~ id ~ "/download"),
        HTTPMethod.GET), resWithoutToken);
    assert(resWithoutToken.statusCode == HTTPStatus.unauthorized);

    // The artifacts page is gone
    auto sink = createMemoryOutputStream();
    auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/artifacts/"), HTTPMethod.GET), res);
    assert(res.headerWritten && res.statusCode == HTTPStatus.unauthorized, "No page answers /artifacts/: an anonymous request is refused");
}

unittest
{
    import std.algorithm : map, sort;
    import std.array : array, join;
    import std.format : format;
    import std.string : split, startsWith;
    import std.typecons : Nullable;
    import confector.api.model : Role;
    import confector.backends.scheduler.local : LocalScheduler;
    import confector.server.authenticator : FixedAuthenticator, Identity, testIdentity;
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.testing.memory_document_store : InMemoryDocumentStore;

    Backends backends;
    backends.documentStore = new InMemoryDocumentStore();
    backends.dispatchQueue = new InMemoryDispatchQueue();
    backends.scheduler = new LocalScheduler("test-scheduler-secret", "http://127.0.0.1:8080");
    backends.artifactStore = new InMemoryArtifactStorage();
    auto testStores = new StateStores(backends.documentStore);
    enum signingKey = "0123456789abcdef0123456789abcdef";
    enum poolCredential = "pool-credential-0123456789abcdef0123456789abcdef";

    // The server's routes, as they are built for a user with `identity`
    AuthorizedRoutes routesAs(Nullable!Identity identity)
    {
        backends.authenticator = new FixedAuthenticator(identity);
        return createRouter(backends, testStores, "test-scheduler-secret", signingKey, poolCredential, 3);
    }

    // The route table: every route as "METHOD path access", where access is the role a user needs or
    // the credential that protects the route. A route added without a row here fails the test.
    auto registered = routesAs(testIdentity(Role.admin)).rules()
        .map!(rule => format("%s %s %s", rule.method, rule.path, rule.access)).array;
    registered.sort();

    string[] table = [
        "GET /favicon.ico viewer",
        "GET /static/* viewer",
        "GET /projects viewer",
        "GET /repositories viewer",

        "GET /api/v1/artifacts/presign-upload worker-token",
        "GET /api/v1/artifacts/presign-download worker-token",
        "POST /api/v1/artifacts/:fingerprint/:artifactId/upload worker-token",
        "GET /api/v1/artifacts/_head/:fingerprint/:artifactId worker-token",
        "GET /api/v1/artifacts/:fingerprint/:artifactId/download worker-token",
        "DELETE /api/v1/artifacts/:fingerprint/:artifactId worker-token",

        "POST /api/v1/queue/receive worker-pool-credential",
        "POST /api/v1/queue/ack worker-token",
        "POST /api/v1/queue/extend worker-token",
        "POST /api/v1/queue/release worker-token",
        "GET /api/v1/executions/:execution_id/logs viewer",
        "POST /api/v1/executions/:execution_id/logs worker-token",
        "POST /api/v1/executions/:execution_id/complete worker-token",
        "POST /api/v1/projects/run member",
        "POST /api/v1/projects/:id/run scheduler-secret",
        "GET /api/v1/projects viewer",
        "POST /api/v1/projects member",
        "GET /api/v1/projects/:id viewer",
        "DELETE /api/v1/projects/:id member",
        "GET /api/v1/projects/:id/tasks viewer",
        "POST /api/v1/projects/:id/tasks member",
        "GET /api/v1/projects/:id/tasks/:taskId viewer",
        "DELETE /api/v1/projects/:id/tasks/:taskId member",

        "GET / viewer",
        "GET /projects/ viewer",
        "GET /projects/add member",
        "POST /projects/add member",
        "GET /projects/details viewer",
        "GET /projects/edit member",
        "POST /projects/save member",
        "POST /projects/delete member",
        "GET /projects/tasks/add member",
        "GET /projects/tasks/edit member",
        "POST /projects/tasks/save member",
        "POST /projects/tasks/delete member",
        "POST /projects/run member",
        "GET /tasks/details viewer",

        "GET /repositories/ viewer",
        "GET /repositories/add admin",
        "POST /repositories/add admin",
        "POST /repositories/edit admin",
        "GET /repositories/details viewer",
    ];
    table.sort();
    assert(registered == table, "The routes differ from the route table:\n" ~ registered.join("\n"));

    // Every route has a role or an exclusion, and never both
    foreach (rule; routesAs(testIdentity(Role.admin)).rules())
        assert(rule.role.isNull != rule.excludedBy.isNull, rule.path);

    // A concrete request for each user route: a request without an identity is answered 401, and one whose
    // role is too low is answered 403. Refused requests never reach a handler, so none needs a body.
    string concretePath(string pattern)
    {
        return pattern.split("/").map!(segment => segment.startsWith(":") || segment == "*" ? "x" : segment).join("/");
    }

    int statusOf(AuthorizedRoutes routes, HTTPMethod method, string path)
    {
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method);
        auto res = createTestHTTPServerResponse();
        routes.handleRequest(req, res);
        assert(res.headerWritten, "No route answered " ~ path);
        return res.statusCode;
    }

    auto nobody = routesAs(Nullable!Identity.init);
    auto viewer = routesAs(testIdentity(Role.viewer));
    auto member = routesAs(testIdentity(Role.member));
    foreach (rule; routesAs(testIdentity(Role.admin)).rules())
    {
        if (rule.role.isNull) continue;
        const path = concretePath(rule.path);
        const label = format("%s %s", rule.method, path);
        assert(statusOf(nobody, rule.method, path) == HTTPStatus.unauthorized, label);
        if (rule.role.get != Role.viewer)
            assert(statusOf(viewer, rule.method, path) == HTTPStatus.forbidden, label);
        if (rule.role.get == Role.admin)
            assert(statusOf(member, rule.method, path) == HTTPStatus.forbidden, label);
    }
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.exception : collectException;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.process : thisProcessID;

    // The directory comes from CONFECTOR_CONFIG_DIR, which is optional
    enum dirVar = "CONFECTOR_CONFIG_DIR";
    const savedDir = environment.get(dirVar);
    scope (exit)
    {
        if (savedDir is null) environment.remove(dirVar); else environment[dirVar] = savedDir;
    }
    // Unset, the server runs on environment variables alone: no file is read, and the settings
    // come from the environment
    enum databaseVar = "CONFECTOR_SERVER_DOCUMENT_STORE_DATABASE";
    const savedDatabase = environment.get(databaseVar);
    scope (exit)
    {
        if (savedDatabase is null) environment.remove(databaseVar); else environment[databaseVar] = savedDatabase;
    }
    environment.remove(dirVar);
    environment[databaseVar] = "from_environment";
    assert(configDirectory() == "");
    assert(loadServerConfig(loadConfigRegistry(configDirectory())).documentStore.database == "from_environment");
    environment[dirVar] = "/from/environment";
    assert(configDirectory() == "/from/environment");

    const root = buildPath(tempDir, "confector_app_config_test_" ~ thisProcessID.to!string);
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);

    // A directory that does not exist fails, naming it
    const missingDir = buildPath(root, "missing");
    auto missingDirError = collectException(loadConfigRegistry(missingDir));
    assert(missingDirError !is null && missingDirError.msg.canFind(missingDir), "A missing directory must throw");

    // A path that names a file, not a directory, fails with the same message, naming it
    const notDir = buildPath(root, "not-a-directory.json");
    write(notDir, `{"server": {"http": {"port": 9125}}}`);
    auto fileNotDir = collectException(loadConfigRegistry(notDir));
    assert(fileNotDir !is null && fileNotDir.msg.canFind(notDir) && fileNotDir.msg.canFind("is not a directory"),
        "A file named as the directory must throw, naming it");

    // A directory without a configuration file fails, naming the file it expected
    const emptyDir = buildPath(root, "empty");
    mkdirRecurse(emptyDir);
    auto noFile = collectException(loadConfigRegistry(emptyDir));
    assert(noFile !is null && noFile.msg.canFind(buildPath(emptyDir, "confector.json")), "A missing file must throw");

    // A file that does not parse fails, naming the file and the parse error
    const brokenDir = buildPath(root, "broken");
    mkdirRecurse(brokenDir);
    const brokenFile = buildPath(brokenDir, "confector.json");
    write(brokenFile, `{"server": {"http": `);
    auto broken = collectException(loadConfigRegistry(brokenDir));
    assert(broken !is null && broken.msg.canFind(brokenFile) && broken.msg.canFind("Failed to read or parse"),
        "An unparseable file must throw, naming it");

    // A valid file loads its settings
    const validDir = buildPath(root, "valid");
    mkdirRecurse(validDir);
    write(buildPath(validDir, "confector.json"), `{"server": {"http": {"port": 9123}}}`);
    assert(loadServerConfig(loadConfigRegistry(validDir)).http.port == 9123);

    // A file whose content is not an object fails, naming the file
    const arrayDir = buildPath(root, "array");
    mkdirRecurse(arrayDir);
    const arrayFile = buildPath(arrayDir, "confector.json");
    write(arrayFile, `[{"server": {"http": {"port": 9124}}}]`);
    auto notObject = collectException(loadConfigRegistry(arrayDir));
    assert(notObject !is null && notObject.msg.canFind(arrayFile), "A non-object file must throw, naming it");
}
