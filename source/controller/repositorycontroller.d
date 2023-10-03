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
    render!("repository/repositories.dt", repositories);
  }
  
  void getAddRepo()
  {
    render!("repository/add-repo.dt");
  }

  
  void getRepoDetails(HTTPServerRequest req)
  {
    DictionaryList!(string,true,16L,false) queryParams;
    parseURLEncodedForm(req.queryString, queryParams);
    
    auto queryName = queryParams["name"];
    auto repoDetails = repositoryCollection.find(["name": queryName]).front;

    auto name = repoDetails["name"].get!string;
    auto address = repoDetails["address"].get!string;
    
    render!("repository/repository-details.dt", name, address);
  }

  void getRepoAddError()
  {
    render!("repository/add-error.dt");
  }

  void postAddRepo(HTTPServerRequest req, HTTPServerResponse res)
  {
    import std.string : format;

    auto name = req.form["repository-name"];
    auto address = req.form["repository-address"];

    auto noExisting = repositoryCollection.find(["name": name]).empty;

    if(noExisting)
    {
      Bson doc = Bson(["name": Bson(name), "address": Bson(address)]);
      repositoryCollection.insertOne(doc);
      
      redirect("repo_details?name=%s".format(name));
    }
    else
    {
      redirect("/repo_add_error");
    }
    
  }

}