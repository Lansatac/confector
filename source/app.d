import std.stdio;

import vibe.vibe;
import controller.repositorycontroller;
import controller.api_controller;
import controller.dashboard_controller;
import controller.executor_controller;
import controller.admin_controller;
import confector.core.plugin;
import confector.core.plugin_loader;
import confector.core.storage;
import confector.storage.mongo_repository;
import confector.queue.queue;
import confector.queue.mongo_queue;
import confector.runner.engine;
import confector.runner.coordinator;

debug static import std.stdio;

void index(HTTPServerRequest req, HTTPServerResponse res)
{
	res.render!("index.dt", req);
}

void errorPage(HTTPServerRequest req,
	HTTPServerResponse res,
	HTTPServerErrorInfo error)
{
	res.render!("error.dt", req, error);
}

string readSecretFile(string path)
{
  import std.encoding : getBOM, BOM;
  import std.file : exists, read;
  import std.string : strip;
  import std.conv : to;
  import std.encoding : transcode;
    
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

void main()
{
  import std.file;
  import std.format;
  import std.conv;
  import std.string : strip;

  // Ensure info and error logs are printed to console
  setLogLevel(vibe.core.log.LogLevel.warn);
  debug setLogLevel(vibe.core.log.LogLevel.info);

  string password = readSecretFile("/run/secrets/mongo-readwrite-password");

  auto mongoHost = "mongo:27017/confector";
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

  MongoClient client;
  BuildStateRepository stateRepo;
  WorkQueue workQueue;
  try
  {
	  client = connectMongoDB(mongoUri);
    stateRepo = new MongoBuildStateRepository(client);
    workQueue = new MongoWorkQueue(client);
  }
  catch(Exception e)
  {
    writeln("MongoDB connection failed, using in-memory state repository and queue: ", e.message);
    stateRepo = new InMemoryBuildStateRepository();
    workQueue = new InMemoryWorkQueue();
  }
  writeln("Connected to mongo.");
	
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
  import std.process : environment;
  import std.string : split, strip;
  import std.algorithm.searching : canFind;

  string confectorPluginsEnv = environment.get("CONFECTOR_PLUGINS", "");
  string[] pluginPaths;
  if (confectorPluginsEnv.length > 0)
  {
      version(Windows)
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


  // Initialize execution engine, coordinator & storage
  auto artifactStorage = new LocalArtifactStorage(".confector/artifacts");
  auto taskEngine = new TaskEngine(artifactStorage, stateRepo);
  auto buildCoordinator = new BuildCoordinator(artifactStorage, stateRepo, workQueue);
  writeln("Initialized Confector execution engine and build coordinator (stateless control plane mode).");

	auto router = new URLRouter;

  router.get("/favicon.ico", serveStaticFile("public/images/favicon.ico"));
  auto fsettings = new HTTPFileServerSettings;
	fsettings.serverPathPrefix = "/static";
  router.get("/static/*", serveStaticFiles("public/", fsettings));

  // Mount API & serverless execution endpoints
  router.any("/api/v1/*", apiRouter(taskEngine, workQueue, buildCoordinator));

  // Mount dashboard, builds, projects, executors, and admin UI
  router.any("/projects/*", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));
  router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });
  router.any("/builds/*", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));
  router.get("/builds", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/builds/"); });
  router.any("/executors/*", executorRouter(stateRepo, PluginRegistry.instance));
  router.get("/executors", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/executors/"); });
  router.any("/admin/*", adminRouter(PluginRegistry.instance, PluginLoader.instance));
  router.get("/admin", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/admin/plugins"); });
  router.get("/", dashboardRouter(taskEngine, workQueue, stateRepo, null, buildCoordinator));

  router.any("/repositories/*", repositoryRouter(client));
  router.get("/repositories", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/repositories/"); });
	
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
  settings.errorPageHandler = toDelegate(&errorPage);

  settings.options = HTTPServerOption.defaults;

  debug settings.options = HTTPServerOption.defaults | HTTPServerOption.errorStackTraces;
  //debug settings.accessLogToConsole = true;
	
	listenHTTP(settings, router);
	
  writeln("Starting server");
	runApplication();
}