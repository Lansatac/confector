import std.stdio;

import vibe.vibe;
import controller.repositorycontroller;

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
  try
  {
	  client = connectMongoDB("mongodb://%s".format(mongoAddress));
  }
  catch(MongoAuthException e)
  {
    writeln(e.message);
    return;
  }
  writeln("Connected to mongo.");
	
	auto router = new URLRouter;
	router.get("/", &index);
  router.any("*", repositoryRouter(client));


  router.get("/favicon.ico", serveStaticFile("public/images/favicon.ico"));
  auto fsettings = new HTTPFileServerSettings;
	fsettings.serverPathPrefix = "/static";
  router.get("/static/*", serveStaticFiles("public/", fsettings));
	
	auto settings = new HTTPServerSettings;
	//settings.port = 8080;
  settings.errorPageHandler = toDelegate(&errorPage);

  settings.options = HTTPServerOption.defaults;

  debug settings.options = HTTPServerOption.defaults | HTTPServerOption.errorStackTraces;
  //debug settings.accessLogToConsole = true;
  debug setLogLevel(LogLevel.verbose1);
	
	listenHTTP(settings, router);
	
  writeln("Starting server");
	runApplication();
}