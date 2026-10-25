module confector.server.config;

import confector.config;
import confector.core.work_orders : defaultMaxAttempts;
import confector.core.worker_pool_credential : minimumWorkerPoolCredentialLength;
import confector.core.worker_token : minimumSigningKeyLength;
import std.format : format;
import std.uni : sicmp;
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
 * The MongoDB that holds the document store. Both settings are required
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
 * The worker pool credential: the one credential every runner presents to receive work from
 * /queue/receive. Required, with no default, and never generated: workers must be given it, so
 * the server cannot invent it. The server refuses to start without one of at least 32 bytes (see
 * requireWorkerPoolConfig).
 */
struct WorkerPoolConfig
{
    @Required
    @Env("CONFECTOR_WORKER_POOL_CREDENTIAL")
    @Description("Credential every runner presents in the X-Confector-Worker-Pool-Credential header to receive work (required, at least 32 bytes, e.g. from openssl rand -hex 32)")
    string credential = "";
}

/**
 * Worker tokens. The server signs a token per execution and checks it on every worker route. The
 * key is optional: unset, the server uses the installation's key, generated once and kept in the
 * document store (see WorkerSigningKeyStore). A configured key overrides it.
 */
struct WorkerTokenConfig
{
    @Env("CONFECTOR_WORKER_TOKEN_SIGNING_KEY")
    @Description("Secret key the server signs per-execution worker tokens with, overriding the installation's key kept in the document store (optional; when set, at least 32 bytes, e.g. from openssl rand -hex 32)")
    string signingKey = "";
}

/**
 * The identity headers an authenticating proxy sets. The groups header holds comma-separated group
 * names.
 */
struct ProxyHeadersConfig
{
    @Description("Header holding the authenticated user's subject (default X-Forwarded-User)")
    string user = "X-Forwarded-User";

    @Description("Header holding the user's email address (default X-Forwarded-Email)")
    string email = "X-Forwarded-Email";

    @Description("Header holding the user's comma-separated group names (default X-Forwarded-Groups)")
    string groups = "X-Forwarded-Groups";
}

/**
 * The emails and group names, as the proxy sends them, that hold each global role. An identity
 * that matches several roles holds the highest; one that matches none holds no role and is refused
 * everywhere a role is needed.
 */
struct RoleMappingConfig
{
    @Description("Emails and group names that hold the admin role")
    string[] admins;

    @Description("Emails and group names that hold the member role")
    string[] members;

    @Description("Emails and group names that hold the viewer role")
    string[] viewers;
}

/**
 * The trusted proxy: an authenticating proxy (such as oauth2-proxy) signs users in, sets their
 * identity headers and sends `secret` in `secretHeader` on every request. The server reads the
 * identity headers only from a request carrying that secret, compared in constant time. The secret
 * is required, with no default; the server refuses to start without it (see requireTrustedProxyConfig).
 */
struct TrustedProxyConfig
{
    @Description("Header the proxy sends the shared secret in (default X-Confector-Proxy-Secret)")
    string secretHeader = "X-Confector-Proxy-Secret";

    @Required
    @Env("CONFECTOR_AUTH_PROXY_SECRET")
    @Description("Shared secret the proxy sends in the secret header on every request (required, at least 32 bytes, e.g. from openssl rand -hex 32)")
    string secret = "";

    ProxyHeadersConfig headers;
    RoleMappingConfig roles;
}

/**
 * Authentication: who makes each request. The trusted proxy is the only authenticator for now.
 */
struct AuthConfig
{
    TrustedProxyConfig trustedProxy;
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
 * How executions are retried after an infrastructure failure. Optional: every setting has a
 * default.
 */
struct ExecutionConfig
{
    @Description("How many times a worker may claim one execution before it fails with \"lease lost N times\": "
        ~ "a worker that dies or loses its lease counts as one attempt, a task that fails is never retried "
        ~ "automatically (optional, default 3, at least 1)")
    uint maxAttempts = defaultMaxAttempts;
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
    WorkerPoolConfig workerPool;
    WorkerTokenConfig workerTokens;
    ArtifactStoreConfig artifactStore;
    ExecutionConfig execution;
    AuthConfig auth;
}

/**
 * Registers core server configuration definitions with the ConfigRegistry.
 */
void registerServerConfigDefinitions(ConfigRegistry registry)
{
    if (registry is null)
        throw new Exception("[config] Cannot register server configuration without a configuration registry.");

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
 * Throws, naming the setting and its environment variable, unless the worker pool credential is
 * configured and at least minimumWorkerPoolCredentialLength bytes long. Without it /queue/receive
 * could not admit any runner, so the server cannot start. The credential is never in the message.
 */
void requireWorkerPoolConfig(in WorkerPoolConfig config)
{
    if (config.credential.length == 0)
        throw new Exception("[config] Required setting 'server.workerPool.credential' is missing "
            ~ "(server.workerPool.credential or CONFECTOR_WORKER_POOL_CREDENTIAL): the server cannot start "
            ~ "without it, because runners could not receive work.");
    if (config.credential.length < minimumWorkerPoolCredentialLength)
        throw new Exception(format("[config] Setting 'server.workerPool.credential' (or CONFECTOR_WORKER_POOL_CREDENTIAL) "
            ~ "must be at least %d bytes, not %d: the server cannot start with a credential that short. "
            ~ "Generate one with openssl rand -hex 32.", minimumWorkerPoolCredentialLength, config.credential.length));
}

/**
 * Throws, naming the setting and its environment variable, if a configured worker token signing key
 * is shorter than minimumSigningKeyLength. Unset, the installation's key is used, so only a set key
 * is checked here.
 */
void requireWorkerTokenConfig(in WorkerTokenConfig config)
{
    if (config.signingKey.length > 0 && config.signingKey.length < minimumSigningKeyLength)
        throw new Exception(format("[config] Setting 'server.workerTokens.signingKey' (or CONFECTOR_WORKER_TOKEN_SIGNING_KEY) "
            ~ "must be at least %d bytes when set, not %d: the server cannot start with a signing key that short. "
            ~ "Generate one with openssl rand -hex 32, or unset it to use the installation's key.",
            minimumSigningKeyLength, config.signingKey.length));
}

/// The fewest bytes the trusted proxy's shared secret may have.
enum size_t minimumProxySecretLength = 32;

/**
 * Throws, naming the setting and its environment variable, unless the trusted proxy is configured:
 * a secret of at least minimumProxySecretLength bytes, header names that are not empty, and no empty
 * entry in the role mapping. Without one the server has no authenticator and cannot start. The
 * secret is never in the message.
 */
void requireTrustedProxyConfig(in TrustedProxyConfig config)
{
    if (config.secret.length == 0)
        throw new Exception("[config] Required setting 'server.auth.trustedProxy.secret' is missing "
            ~ "(server.auth.trustedProxy.secret or CONFECTOR_AUTH_PROXY_SECRET): the server cannot start without "
            ~ "an authenticator, and the trusted proxy cannot check a request without the secret.");
    if (config.secret.length < minimumProxySecretLength)
        throw new Exception(format("[config] Setting 'server.auth.trustedProxy.secret' (or CONFECTOR_AUTH_PROXY_SECRET) "
            ~ "must be at least %d bytes, not %d: the server cannot start with a secret that short. "
            ~ "Generate one with openssl rand -hex 32.", minimumProxySecretLength, config.secret.length));

    requireHeaderName("server.auth.trustedProxy.secretHeader", config.secretHeader);
    requireHeaderName("server.auth.trustedProxy.headers.user", config.headers.user);
    requireHeaderName("server.auth.trustedProxy.headers.email", config.headers.email);
    requireHeaderName("server.auth.trustedProxy.headers.groups", config.headers.groups);
    foreach (identityHeader; [config.headers.user, config.headers.email, config.headers.groups])
    {
        if (sicmp(identityHeader, config.secretHeader) == 0)
            throw new Exception(format("[config] Setting 'server.auth.trustedProxy.secretHeader' names the identity header '%s' "
                ~ "(server.auth.trustedProxy.headers): the secret and the identity must arrive in different headers.",
                identityHeader));
    }
    requireNoEmptyEntry("server.auth.trustedProxy.roles.admins", config.roles.admins);
    requireNoEmptyEntry("server.auth.trustedProxy.roles.members", config.roles.members);
    requireNoEmptyEntry("server.auth.trustedProxy.roles.viewers", config.roles.viewers);
}

private void requireHeaderName(string setting, string header)
{
    if (header.length == 0)
        throw new Exception("[config] Setting '" ~ setting ~ "' is empty: the trusted proxy needs a header name to read.");
}

private void requireNoEmptyEntry(string setting, in string[] entries)
{
    foreach (entry; entries)
    {
        if (entry.length == 0)
            throw new Exception("[config] Setting '" ~ setting ~ "' holds an empty entry, which would match requests "
                ~ "that send no value for it.");
    }
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
 * Throws, naming the setting, unless executions get at least one attempt.
 */
void requireExecutionConfig(in ExecutionConfig config)
{
    if (config.maxAttempts == 0)
        throw new Exception("[config] Setting 'server.execution.maxAttempts' is 0 "
            ~ "(server.execution.maxAttempts or " ~ keyToDefaultEnvVar("server.execution.maxAttempts")
            ~ "): an execution needs at least one attempt, or it could never run.");
}

/**
 * Loads and binds ServerConfig from the ConfigRegistry.
 */
ServerConfig loadServerConfig(ConfigRegistry registry)
{
    if (registry is null)
        throw new Exception("[config] Cannot load server configuration without a configuration registry.");

    auto serverScope = registry.getScope("server");
    return serverScope.bind!ServerConfig();
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    // Without a registry there is no configuration to load, so the server must not start on defaults
    auto failure = collectException(loadServerConfig(null));
    assert(failure !is null && failure.msg.canFind("configuration registry"), "loadServerConfig(null) must throw");
    assert(collectException(registerServerConfigDefinitions(null)) !is null);
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
    assert(cfg.workerTokens.signingKey == "");
    assert(cfg.workerPool.credential == "");
    assert(cfg.artifactStore.baseDirectory == "");
    assert(cfg.execution.maxAttempts == 3, "Executions get three attempts unless the admin sets a limit");
}

unittest
{
    import std.exception : collectException;
    import std.algorithm.searching : canFind;

    import vibe.data.json : parseJsonString;

    // The attempt limit is an optional setting: three by default, set from the file or the
    // environment, and zero is refused
    auto registry = new ConfigRegistry(parseJsonString(`{"server": {"execution": {"maxAttempts": 5}}}`));
    registerServerConfigDefinitions(registry);
    assert(loadServerConfig(registry).execution.maxAttempts == 5);
    assert(keyToDefaultEnvVar("server.execution.maxAttempts") == "CONFECTOR_SERVER_EXECUTION_MAX_ATTEMPTS");

    ExecutionConfig config;
    requireExecutionConfig(config);
    config.maxAttempts = 0;
    auto message = collectException(requireExecutionConfig(config));
    assert(message !is null && message.msg.canFind("server.execution.maxAttempts"));
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown, collectException;
    import std.process : environment;
    import vibe.data.json : parseJsonString;

    // The credential is required: missing, or too short to be a secret, the server does not start
    enum credentialVar = "CONFECTOR_WORKER_POOL_CREDENTIAL";
    const saved = environment.get(credentialVar);
    scope(exit)
    {
        if (saved is null) environment.remove(credentialVar); else environment[credentialVar] = saved;
    }
    environment.remove(credentialVar);

    WorkerPoolConfig config;
    auto missing = collectException(requireWorkerPoolConfig(config));
    assert(missing !is null && missing.msg.canFind("server.workerPool.credential")
        && missing.msg.canFind("CONFECTOR_WORKER_POOL_CREDENTIAL"), missing.msg);

    // A short credential names the setting and its variable, and never repeats the credential
    config.credential = "too-short";
    auto tooShort = collectException(requireWorkerPoolConfig(config));
    assert(tooShort !is null && tooShort.msg.canFind("server.workerPool.credential")
        && tooShort.msg.canFind("CONFECTOR_WORKER_POOL_CREDENTIAL") && tooShort.msg.canFind("at least 32 bytes")
        && !tooShort.msg.canFind("too-short"), tooShort.msg);

    config.credential = "0123456789abcdef0123456789abcdef";
    requireWorkerPoolConfig(config);

    // The environment variable the messages name sets the credential
    environment[credentialVar] = "pool-credential-from-the-environment-0123";
    auto registry = new ConfigRegistry();
    registerServerConfigDefinitions(registry);
    assert(loadServerConfig(registry).workerPool.credential == "pool-credential-from-the-environment-0123");

    // The environment variable overrides the value in the configuration file
    auto fileRegistry = new ConfigRegistry(parseJsonString(`{"server": {"workerPool": {"credential": "pool-credential-from-the-file-0123"}}}`));
    registerServerConfigDefinitions(fileRegistry);
    assert(loadServerConfig(fileRegistry).workerPool.credential == "pool-credential-from-the-environment-0123",
        "CONFECTOR_WORKER_POOL_CREDENTIAL overrides the file");

    // Without the variable, the file's value is used
    environment.remove(credentialVar);
    assert(loadServerConfig(fileRegistry).workerPool.credential == "pool-credential-from-the-file-0123");
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    // A configured signing key is checked for length, naming the setting; unset, nothing is checked
    WorkerTokenConfig config;
    requireWorkerTokenConfig(config);
    config.signingKey = "0123456789abcdef0123456789abcdef";
    requireWorkerTokenConfig(config);

    config.signingKey = "short-key";
    auto tooShort = collectException(requireWorkerTokenConfig(config));
    assert(tooShort !is null && tooShort.msg.canFind("server.workerTokens.signingKey")
        && tooShort.msg.canFind("CONFECTOR_WORKER_TOKEN_SIGNING_KEY") && !tooShort.msg.canFind("short-key"), tooShort.msg);
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
    // The signing key is read from the configuration file (its length is checked where it is used)
    import vibe.data.json : parseJsonString;
    auto registry = new ConfigRegistry(parseJsonString(`{"server": {"workerTokens": {"signingKey": "from-the-file"}}}`));
    registerServerConfigDefinitions(registry);
    assert(loadServerConfig(registry).workerTokens.signingKey == "from-the-file");
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

unittest
{
    import std.process : environment;

    // The environment variable the error message names sets the signing key
    enum keyVar = "CONFECTOR_WORKER_TOKEN_SIGNING_KEY";
    const saved = environment.get(keyVar);
    scope(exit)
    {
        if (saved is null) environment.remove(keyVar); else environment[keyVar] = saved;
    }
    environment[keyVar] = "key-from-the-environment-0123456789";

    auto registry = new ConfigRegistry();
    registerServerConfigDefinitions(registry);
    assert(loadServerConfig(registry).workerTokens.signingKey == "key-from-the-environment-0123456789");
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    // The trusted proxy has the header defaults, and needs a secret of at least 32 bytes, without an empty
    // header name or role entry
    TrustedProxyConfig config;
    assert(config.secretHeader == "X-Confector-Proxy-Secret");
    assert(config.headers.user == "X-Forwarded-User" && config.headers.email == "X-Forwarded-Email"
        && config.headers.groups == "X-Forwarded-Groups");

    auto missing = collectException(requireTrustedProxyConfig(config));
    assert(missing !is null && missing.msg.canFind("server.auth.trustedProxy.secret")
        && missing.msg.canFind("CONFECTOR_AUTH_PROXY_SECRET"), missing.msg);

    config.secret = "too-short";
    auto tooShort = collectException(requireTrustedProxyConfig(config));
    assert(tooShort !is null && tooShort.msg.canFind("at least 32 bytes") && !tooShort.msg.canFind("too-short"),
        tooShort.msg);

    config.secret = "0123456789abcdef0123456789abcdef";
    requireTrustedProxyConfig(config);

    config.headers.user = "";
    assert(collectException(requireTrustedProxyConfig(config)).msg.canFind("server.auth.trustedProxy.headers.user"));
    config.headers.user = "X-Forwarded-User";

    config.roles.viewers = ["guest@example.com", ""];
    assert(collectException(requireTrustedProxyConfig(config)).msg.canFind("server.auth.trustedProxy.roles.viewers"));
    config.roles.viewers = [];

    // The secret header may not be an identity header, whatever its case
    config.secretHeader = "x-forwarded-USER";
    auto collision = collectException(requireTrustedProxyConfig(config));
    assert(collision !is null && collision.msg.canFind("server.auth.trustedProxy.secretHeader")
        && collision.msg.canFind("X-Forwarded-User") && !collision.msg.canFind(config.secret), collision.msg);
    config.secretHeader = "X-Confector-Proxy-Secret";
    requireTrustedProxyConfig(config);
}

unittest
{
    import std.process : environment;
    import vibe.data.json : parseJsonString;

    // The secret is read from the file, with the environment variable overriding it; a role mapping and a
    // partly given header section keep the defaults they do not set
    enum secretVar = "CONFECTOR_AUTH_PROXY_SECRET";
    const savedSecret = environment.get(secretVar);
    scope(exit)
    {
        if (savedSecret is null) environment.remove(secretVar); else environment[secretVar] = savedSecret;
    }
    environment.remove(secretVar);

    auto registry = new ConfigRegistry(parseJsonString(`{"server": {"auth": {"trustedProxy": {`
        ~ `"secret": "secret-from-the-file-0123456789abcdef", `
        ~ `"roles": {"admins": ["ada@example.com"], "viewers": ["readers"]}, `
        ~ `"headers": {"user": "X-User"}}}}}`));
    registerServerConfigDefinitions(registry);
    auto proxy = loadServerConfig(registry).auth.trustedProxy;
    assert(proxy.secret == "secret-from-the-file-0123456789abcdef");
    assert(proxy.roles.admins == ["ada@example.com"] && proxy.roles.members.length == 0 && proxy.roles.viewers == ["readers"]);
    assert(proxy.headers.user == "X-User" && proxy.headers.email == "X-Forwarded-Email");

    environment[secretVar] = "secret-from-the-environment-0123456789";
    assert(loadServerConfig(registry).auth.trustedProxy.secret == "secret-from-the-environment-0123456789");
}
