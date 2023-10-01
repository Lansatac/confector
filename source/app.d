import std.stdio;
import vibe.vibe;
import controller.repositorycontroller;

void index(HTTPServerRequest req, HTTPServerResponse res)
{
	res.render!("index.dt", req);
}

void main()
{
	MongoClient client = connectMongoDB("mongodb://root:example@127.0.0.1");

	// auto coll = client.getCollection("test.collection");
	
	// foreach (doc; coll.find(["name": "Peter"]))
	// 	logInfo("Found entry: %s", doc.toJson());

	auto dbs = client.getDatabases();
	writeln("Current databases are: ", dbs);
	
	auto repositories = client.getCollection("core.repositories");

	auto all = repositories.find();
	writeln(all);
	auto router = new URLRouter;
  router.get("/*", serveStaticFiles("public/"));
	router.get("/", &index); 
	router.any("*", repositoryRouter()); 
	
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	
	listenHTTP(settings, router);
	
	runApplication();
}