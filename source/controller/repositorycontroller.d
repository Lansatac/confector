module controller.repositorycontroller;
import vibe.vibe;
import vibe.utils.dictionarylist;
import std.algorithm;
import std.range;
import std.typecons;

debug import std.stdio;


URLRouter repositoryRouter(MongoClient mongoClient)
{
	auto repositoryRouter = new URLRouter("/repositories");
	repositoryRouter.registerWebInterface(new RepositoryController(mongoClient));
  return repositoryRouter;
}

class RepositoryController
{
  MongoClient mongoClient;
  MongoCollection repositoryCollection;

  public this(MongoClient mongoClient)
  {
	  repositoryCollection = mongoClient.getCollection("confector.repositories");
    this.mongoClient = mongoClient;
  }

  void index()
  {    
    import std.conv;
    auto all = repositoryCollection.find();

    auto repositories = all.map!(r=>tuple!("name", "address")(r["name"].get!string, r["address"].get!string)).array;
    render!("repositories.dt", repositories);
  }
  
  void getAddRepo()
  {
    render!("add-repo.dt");
  }

  
  void getRepoDetails(HTTPServerRequest req)
  {
    DictionaryList!(string,true,16L,false) queryParams;
    parseURLEncodedForm(req.queryString, queryParams);
    
    auto queryName = queryParams["name"];
    auto repoDetails = repositoryCollection.find(["name": queryName]).front;

    auto name = repoDetails["name"].get!string;
    auto address = repoDetails["address"].get!string;
    
    render!("repository-details.dt", name, address);
  }

  void postAddRepo(HTTPServerRequest req, HTTPServerResponse res)
  {
    debug std.stdio.writefln("Post request to add repository: " ~ req.form.to!string);

    try{
      auto name = req.form["repository-name"];
      auto address = req.form["repository-address"];

      auto existing = repositoryCollection.find(["name": name]);
      
      debug writefln("Existing entries: %s", existing);

      if(existing.empty)
      {
        Bson doc = Bson(["name": Bson(name), "address": Bson(address)]);
        repositoryCollection.insertOne(doc);
        
        redirect("/repo_details");
      }
      else
      {
        redirect("/repo_add_error");
      }
    }
    catch(Exception e)
    {
      debug writeln(e);
      return;
    }
    
    debug std.stdio.writefln("Adding succeeded?");
    
  }

}