import std.stdio;

import vibe.vibe;
import controller.repositorycontroller;
import controller.api_controller;
import controller.dashboard_controller;
import controller.executor_controller;
import confector.core.plugin;
import confector.core.storage;
import confector.storage.mongo_repository;
import confector.queue.queue;
import confector.queue.mongo_queue;
import confector.runner.engine;
import plugins.git;
import plugins.bash;
import plugins.powershell;
import plugins.local_executor;

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
	
  // Initialize and register core default plugins
  PluginRegistry.instance.registerPlugin(new GitRepositoryPlugin());
  PluginRegistry.instance.registerPlugin(new BashPlugin());
  PluginRegistry.instance.registerPlugin(new PowerShellPlugin());
  PluginRegistry.instance.registerPlugin(new LocalExecutorPlugin());
  writeln("Initialized modular plugins.");

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

  // Mount dashboard, builds, projects, and executors UI
  router.any("/projects/*", dashboardRouter(taskEngine, workQueue, stateRepo));
  router.any("/builds/*", dashboardRouter(taskEngine, workQueue, stateRepo));
  router.any("/executors/*", executorRouter(stateRepo, PluginRegistry.instance));
  router.get("/executors", (HTTPServerRequest req, HTTPServerResponse res) { res.redirect("/executors/"); });
  router.get("/", dashboardRouter(taskEngine, workQueue, stateRepo));

  router.any("/repositories/*", repositoryRouter(client));
	
	auto settings = new HTTPServerSettings;
	//settings.port = 8080;
  settings.errorPageHandler = toDelegate(&errorPage);

  settings.options = HTTPServerOption.defaults;

  debug settings.options = HTTPServerOption.defaults | HTTPServerOption.errorStackTraces;
  //debug settings.accessLogToConsole = true;
  //debug setLogLevel(LogLevel.debugV);
	
	listenHTTP(settings, router);
	
  writeln("Starting server");
	runApplication();
}