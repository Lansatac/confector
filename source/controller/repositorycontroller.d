module controller.repositorycontroller;
import vibe.vibe;
import vibe.utils.dictionarylist;
import std.algorithm;
import std.range;
import std.typecons;

import clonestatus;

import std.stdio;
import vibe.core.process;

URLRouter repositoryRouter(MongoClient mongoClient)
{
	auto repositoryRouter = new URLRouter("/repositories");
	repositoryRouter.registerWebInterface(new RepositoryController(mongoClient));

  return repositoryRouter;
}

final class RepositoryController
{
  private MongoClient mongoClient;
  private MongoCollection repositoryCollection;

	private CloneStatus[string] clonestatuses;

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
    auto queryName = req.query["name"];

    try{
      auto repoQuery = repositoryCollection.findOne(["name": queryName], FindOptions.init);
      auto repoDetails = repoQuery;
      
      auto name = repoDetails["name"].get!string;
      auto address = repoDetails["address"].get!string;
      auto status = getOrCreateCloneStatus(name);
      auto logLines = status.logLines;
      
      render!("repository/repository-details.dt", name, address, logLines);
    }
    catch (Exception e) {
      logError(e.message);
      redirect("/error");
    }
  }
  
  @safe
  void postCloneRepo(HTTPServerRequest req)
  {
    import std.string : format;
    import std.file;
    import std.process;


    try{
      auto name = req.form["name"];

      auto repoDir = "/home/dev/repositories/%s".format(name); // TODO: harden, validate name
      mkdirRecurse(repoDir);

      auto repoQuery = repositoryCollection.findOne(["name": name], FindOptions.init);
      auto repoDetails = repoQuery;
      
      //auto name = repoDetails["name"].get!string;
      auto address = repoDetails["address"].get!string;
      auto cloneTask = runTask(() nothrow  @trusted {
        try{
        auto status = getOrCreateCloneStatus(name);
        
        auto logFile = File("%s/clone.log".format(repoDir), "w");
        auto inFile = File("/dev/null", "r");
        
        logInfo("spawning git command");
        auto pipe = pipeShell("git clone %s".format(address), Redirect.stdout | Redirect.stderrToStdout, null, Config.none, repoDir);
        
        scope(exit) wait(pipe.pid);
        
        //auto logReader = File("%s/clone.log".format(repoDir), "r");
        foreach (line; pipe.stdout.byLineCopy)
        {
          logInfo(line);
          status.addLogLine(line);
        }
        logInfo("git command complete");


        } catch (Exception e) {
          logError(e.message);
        }
      });

      auto status = getOrCreateCloneStatus(name);
      auto logLines = status.logLines;
      
      redirect("repo_details?name=%s".format(name));
      cloneTask.join();
    }
    catch (Exception e) {
      logError(e.message);
      redirect("/error");
    }
  }

  @safe
  void getWS(HTTPServerRequest req, scope WebSocket socket)
  {
    auto status = getOrCreateCloneStatus(req.query["repo_name"]);

    auto writer = runTask(() nothrow {
      auto next_message = status.logLines.length;
      try{
        while (socket.connected) {
          while (next_message < status.logLines.length)
          {
            socket.send(status.logLines[next_message++]);
          }
            
          status.waitForMessage(next_message);
        }
      }
      catch (Exception e) {
        logError(e.message);
      }
    });

    while (socket.connected) {
      sleep(dur!"msecs"(100));
    }
    // while (socket.waitForData) {
    //   auto message = socket.receiveText();
    //   if (message.length) status.addLogLine(message);
    // }

    writer.join(); // wait for writer task to finish
  }
  
  @safe
	private nothrow CloneStatus getOrCreateCloneStatus(string id)
	{
    CloneStatus cs;
    try{
      if (auto pcs = id in clonestatuses) return *pcs;
      cs = new CloneStatus;
      clonestatuses[id] = cs;
    }
    catch(Exception){}
    return cs;
	}

  void getRepoAddError()
  {
    render!("repository/add-error.dt");
  }

  void postAddRepo(HTTPServerRequest req)
  {
    import std.string : format;

    auto name = req.form["repository-name"];
    auto address = req.form["repository-address"];

    auto noExisting = repositoryCollection.find(["name": name]).empty;

    if(noExisting)
    {
      Bson doc = Bson(["name": Bson(name), "address": Bson(address)]);
      repositoryCollection.insertOne(doc);
      
      redirect("repo_details?name=%s".format(name), HTTPStatus.seeOther);
    }
    else
    {
      redirect("add_error");
    } 
  }
}