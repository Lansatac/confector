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

void main()
{
  import std.file;
  import std.format;
  import std.conv;
  

  auto password = readText!wstring("/run/secrets/mongo-readwrite-password").to!string;

  auto mongoAddress = "mongo:27017/confector";

  writefln("Connecting to mongo at %s...", mongoAddress);
  MongoClient client;
  BuildStateRepository stateRepo;
  WorkQueue workQueue;
  try
  {
	  client = connectMongoDB("mongodb://%s".format(mongoAddress));
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
	
  // Automatically load bundled plugins from ./plugins directory
  auto bundledPlugins = PluginLoader.instance.loadBundledPlugins("./plugins");
  if (bundledPlugins.length > 0)
  {
      foreach (p; bundledPlugins)
      {
          writefln("[plugins] Loaded bundled plugin '%s' v%s", p.name, p.versionString);
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
                  auto p = PluginLoader.instance.loadPlugin(trimmed, false);
                  writefln("[plugins] Dynamically loaded plugin '%s' v%s from %s", p.name, p.versionString, trimmed);
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

  // Initialize execution engine & storage
  auto artifactStorage = new LocalArtifactStorage(".confector/artifacts");
  auto taskEngine = new TaskEngine(artifactStorage, stateRepo);
  writeln("Initialized Confector execution engine.");

	auto router = new URLRouter;

  router.get("/favicon.ico", serveStaticFile("public/images/favicon.ico"));
  auto fsettings = new HTTPFileServerSettings;
	fsettings.serverPathPrefix = "/static";
  router.get("/static/*", serveStaticFiles("public/", fsettings));

  // Mount API & serverless execution endpoints
  router.any("/api/v1/*", apiRouter(taskEngine, workQueue));

  // Mount dashboard, builds, projects, executors, and admin UI
  router.any("/projects/*", dashboardRouter(taskEngine, workQueue, stateRepo));
  router.get("/projects", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/projects/"); });
  router.any("/builds/*", dashboardRouter(taskEngine, workQueue, stateRepo));
  router.get("/builds", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/builds/"); });
  router.any("/executors/*", executorRouter(stateRepo, PluginRegistry.instance));
  router.get("/executors", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/executors/"); });
  router.any("/admin/*", adminRouter(PluginRegistry.instance, PluginLoader.instance));
  router.get("/admin", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/admin/plugins"); });
  router.get("/", dashboardRouter(taskEngine, workQueue, stateRepo));

  router.any("/repositories/*", repositoryRouter(client));
  router.get("/repositories", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/repositories/"); });
	
	auto settings = new HTTPServerSettings;
	//settings.port = 8080;
  settings.errorPageHandler = toDelegate(&errorPage);

  settings.options = HTTPServerOption.defaults;

  debug settings.options = HTTPServerOption.defaults | HTTPServerOption.errorStackTraces;
  //debug settings.accessLogToConsole = true;
  debug setLogLevel(vibe.core.log.LogLevel.info);
	
	listenHTTP(settings, router);
	
  writeln("Starting server");
	runApplication();
}