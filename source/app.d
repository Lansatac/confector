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
	MongoClient client = connectMongoDB("mongodb://root:example@127.0.0.1");
	
	auto router = new URLRouter;
	router.get("/", &index);
	router.any("*", repositoryRouter(client));

  router.get("/favicon.ico", serveStaticFile("public/images/favicon.ico"));
  auto fsettings = new HTTPFileServerSettings;
	fsettings.serverPathPrefix = "/static";
  router.get("/static/*", serveStaticFiles("public/", fsettings));
	
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
  settings.errorPageHandler = toDelegate(&errorPage);

  //debug settings.accessLogToConsole = true;
  debug settings.options = HTTPServerOption.defaults;
	
	listenHTTP(settings, router);
	
	runApplication();
}