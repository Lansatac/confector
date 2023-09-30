import std.stdio;
import vibe.vibe;

void index(HTTPServerRequest req, HTTPServerResponse res)
{
	res.render!("index.dt", req);
}

void main()
{
	auto router = new URLRouter;
	router.get("/", &index);
	
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	
	listenHTTP(settings, router);
	
	runApplication();
}