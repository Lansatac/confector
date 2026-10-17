module confector.server.controller.repositorycontroller;

import vibe.vibe;
import std.algorithm : canFind, count, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.format : format;
import std.string : replace, strip;
import std.typecons : Tuple, tuple;
import std.uri : encodeComponent;

import confector.core.model : ProjectRecord, RepositoryRecord, projectUsesRepository, repositoryIds;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;
import confector.server.controller.api_controller : buildsNotImplemented;
import confector.server.scheduler_callback : schedulerCallback;
import confector.plugin_api.scheduler : Scheduler, ScheduleEntry;

/// Refresh policy options for repository change detection.
enum RefreshPolicy : string
{
    webhook = "webhook",
    polling = "polling",
    both = "both"
}

/// View model for repository listing.
struct RepositoryViewModel
{
    string name;
    string address;
    string refreshPolicy;
    string createdAt;
    ulong projectCount;
}

/// View model for a project referencing a repository.
struct ConnectedProjectViewModel
{
    string id;
    string name;
    string description;
    string[] matchingTasks;
}

/// The VCS poll callback route. repositoryRouter serves it, and vcsPollPath fills in its parameter,
/// so the scheduled poll URL and the route are built from the same pattern and cannot drift apart.
enum string vcsPollRoutePattern = "/repositories/:repoName/poll";

/// The path a scheduled poll of this repository is sent to.
string vcsPollPath(string repositoryName)
{
    return vcsPollRoutePattern.replace(":repoName", encodeComponent(repositoryName));
}

/// The absolute URL the scheduler calls to poll this repository on the local server.
string vcsPollUrl(ushort serverPort, string repositoryName)
{
    return format("http://127.0.0.1:%d%s", serverPort, vcsPollPath(repositoryName));
}

/// Registers or unregisters a VCS polling schedule entry for a repository.
void updateVcsPollingSchedule(Scheduler scheduler, ushort serverPort, string repositoryName, string repositoryAddress, string refreshPolicy)
{
    if (scheduler is null) return;
    string entryId = "vcs-poll-" ~ repositoryName;
    string policy = refreshPolicy.length > 0 ? refreshPolicy : "webhook";

    if (policy == "polling" || policy == "both")
    {
        ScheduleEntry entry;
        entry.id = entryId;
        entry.name = format("VCS Poll: %s", repositoryName);
        entry.uri = vcsPollUrl(serverPort, repositoryName);
        entry.httpMethod = "POST";
        entry.cronExpression = "*/5 * * * *";  // Every 5 minutes
        entry.recurring = true;
        scheduler.schedule(entry);
    }
    else
    {
        scheduler.unschedule(entryId);
    }
}

/**
 * Creates the URL router for the /repositories endpoints.
 */
URLRouter repositoryRouter(StateStores stores, string schedulerCallbackSecret,
    Scheduler scheduler = null, ushort serverPort = 8080)
{
    auto router = new URLRouter();

    // 1. Repositories list view
    void handleIndex(HTTPServerRequest req, HTTPServerResponse res)
    {
        auto repos = stores !is null ? stores.repositories.list() : [];
        auto projects = stores !is null ? stores.projects.list() : [];

        RepositoryViewModel[] repoViews;
        ulong totalConnectedProjects = 0;

        foreach (r; repos)
        {
            RepositoryViewModel rvm;
            rvm.name = r.name;
            rvm.address = r.address;
            rvm.refreshPolicy = r.refreshPolicy.length > 0 ? r.refreshPolicy : "webhook";
            rvm.createdAt = r.createdAt;

            ulong count = 0;
            foreach (p; projects)
            {
                if (projectUsesRepository(p, r))
                {
                    count++;
                }
            }
            rvm.projectCount = count;
            totalConnectedProjects += count;
            repoViews ~= rvm;
        }

        res.render!("repository/repositories.dt", repoViews, repos, totalConnectedProjects);
    }

    router.get("/repositories/", &handleIndex);
    router.get("/repositories", &handleIndex);

    // 2. Add repository view
    void handleAddForm(HTTPServerRequest req, HTTPServerResponse res)
    {
        string errorMessage = req.query.get("error", "");
        res.render!("repository/add-repo.dt", errorMessage);
    }

    router.get("/repositories/add", &handleAddForm);
    router.get("/repositories/add_repo", &handleAddForm);

    // 3. Post add repository
    void handleAddSubmit(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.form.get("name", req.form.get("repository-name", "")).strip;
        string address = req.form.get("address", req.form.get("repository-address", "")).strip;
        string refreshPolicy = req.form.get("refresh-policy", "webhook").strip;

        if (name.length == 0 || address.length == 0)
        {
            res.redirect("/repositories/add?error=Name+and+address+are+required");
            return;
        }

        if (refreshPolicy != "webhook" && refreshPolicy != "polling" && refreshPolicy != "both")
        {
            refreshPolicy = "webhook";
        }

        if (stores !is null)
        {
            RepositoryRecord existing;
            if (stores.repositories.get(name).tryValue(existing))
            {
                res.redirect("/repositories/add?error=Repository+with+this+name+already+exists");
                return;
            }

            RepositoryRecord record;
            record.name = name;
            record.address = address;
            record.refreshPolicy = refreshPolicy;
            record.createdAt = Clock.currTime.toISOString();
            stores.repositories.put(record);

            // Register VCS polling schedule entry if needed
            updateVcsPollingSchedule(scheduler, serverPort, name, address, refreshPolicy);
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/add", &handleAddSubmit);
    router.post("/repositories/add_repo", &handleAddSubmit);

    // 3.5. Post edit repository
    void handleEditSubmit(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.form.get("name", "").strip;
        string address = req.form.get("address", "").strip;
        string refreshPolicy = req.form.get("refresh-policy", "webhook").strip;

        if (name.length == 0 || address.length == 0)
        {
            res.redirect("/repositories/details?name=" ~ encodeComponent(name) ~ "&error=Name+and+address+are+required");
            return;
        }

        if (refreshPolicy != "webhook" && refreshPolicy != "polling" && refreshPolicy != "both")
        {
            refreshPolicy = "webhook";
        }

        if (stores !is null)
        {
            RepositoryRecord record;
            if (stores.repositories.get(name).tryValue(record))
            {
                // Unschedule the old entry if the address is changing
                if (record.address != address)
                {
                    updateVcsPollingSchedule(scheduler, serverPort, name, record.address, "webhook");
                }
                else
                {
                    // Same address, just update the policy
                    updateVcsPollingSchedule(scheduler, serverPort, name, address, refreshPolicy);
                }
                record.address = address;
                record.refreshPolicy = refreshPolicy;
                stores.repositories.put(record);
            }
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/edit", &handleEditSubmit);

    // 4. Per-repository VCS polling endpoint (called by scheduler)
    if (stores !is null)
    {
        router.post(vcsPollRoutePattern, schedulerCallback(schedulerCallbackSecret, (HTTPServerRequest req, HTTPServerResponse res) {
            try
            {
                import confector.core.plugin : PluginRegistry;
                import confector.plugin_api.vcs : VcsStateResolver;
                import confector.plugin_api.model : VcsRepositoryState, VcsChangeRecord;
                import std.uuid : randomUUID;

                string repoName = req.params.get("repoName", "");
                if (repoName.length == 0)
                {
                    res.statusCode = HTTPStatus.badRequest;
                    Json err = Json.emptyObject;
                    err["error"] = Json("repoName path parameter is required");
                    res.writeJsonBody(err);
                    return;
                }

                // Look up the repository record to get the address
                RepositoryRecord repoRecord;
                if (!stores.repositories.get(repoName).tryValue(repoRecord))
                {
                    res.statusCode = HTTPStatus.notFound;
                    Json err = Json.emptyObject;
                    err["error"] = Json(format("Repository not found: %s", repoName));
                    res.writeJsonBody(err);
                    return;
                }

                string repoUrl = repoRecord.address;
                auto resolver = PluginRegistry.instance.findVcsResolver(repoUrl);
                if (resolver is null)
                {
                    res.statusCode = HTTPStatus.badRequest;
                    Json err = Json.emptyObject;
                    err["error"] = Json(format("No VCS resolver found for repository: %s", repoUrl));
                    res.writeJsonBody(err);
                    return;
                }

                auto newState = resolver.fetchLatestState(repoUrl);

                VcsRepositoryState previousState;
                bool changed = false;
                string fromRevision = "";

                if (stores.vcsStates.getState(newState.repositoryUrl, newState.targetRef, previousState))
                {
                    fromRevision = previousState.revision;
                    if (previousState.revision != newState.revision)
                    {
                        changed = true;
                    }
                }
                else
                {
                    changed = true;
                }

                newState.updatedAt = Clock.currTime.toISOString();
                stores.vcsStates.saveState(newState);

                if (changed)
                {
                    VcsChangeRecord change;
                    change.id = "change_" ~ randomUUID().toString();
                    change.repositoryUrl = newState.repositoryUrl;
                    change.providerType = newState.providerType;
                    change.targetRef = newState.targetRef;
                    change.fromRevision = fromRevision;
                    change.toRevision = newState.revision;
                    change.detectedAt = Clock.currTime.toISOString();
                    change.triggerSource = "polling";
                    stores.vcsStates.recordChange(change);

                    // The change is recorded, but building the projects that use the repository
                    // fails loudly until request intake lands (see buildsNotImplemented)
                    string[] affected;
                    foreach (proj; stores.projects.list())
                    {
                        if (projectUsesRepository(proj, repoRecord)) affected ~= proj.id;
                    }
                    if (affected.length > 0)
                    {
                        res.statusCode = HTTPStatus.notImplemented;
                        Json err = Json.emptyObject;
                        err["error"] = Json(format("Repository '%s' changed to revision %s, but projects %s were not built: %s",
                            repoName, newState.revision, affected, buildsNotImplemented));
                        res.writeJsonBody(err);
                        return;
                    }
                }

                Json resp = Json.emptyObject;
                resp["status"] = Json("ok");
                resp["repository"] = Json(repoUrl);
                resp["changed"] = Json(changed);
                resp["revision"] = Json(newState.revision);
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                res.statusCode = HTTPStatus.internalServerError;
                Json err = Json.emptyObject;
                err["error"] = Json(e.msg);
                res.writeJsonBody(err);
            }
        }));
    }

    // 5. Repository details view
    void handleDetails(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.query.get("name", req.query.get("repo_name", ""));
        string errorMessage = req.query.get("error", "");
        if (name.length == 0)
        {
            res.redirect("/repositories/");
            return;
        }

        RepositoryRecord repo;
        bool found = false;
        if (stores !is null)
        {
            found = stores.repositories.get(name).tryValue(repo);
        }

        if (!found)
        {
            repo.name = name;
            repo.address = "";
            repo.refreshPolicy = "webhook";
        }

        string repoRefreshPolicy = repo.refreshPolicy.length > 0 ? repo.refreshPolicy : "webhook";

        auto allProjects = stores !is null ? stores.projects.list() : [];
        ConnectedProjectViewModel[] connectedProjects;

        foreach (p; allProjects)
        {
            string[] matchingTasks;

            foreach (t; p.tasks)
            {
                if (repositoryIds(t).canFind(repo.name))
                {
                    matchingTasks ~= (t.name.length > 0 ? t.name : t.id);
                }
            }

            if (matchingTasks.length > 0)
            {
                ConnectedProjectViewModel cpvm;
                cpvm.id = p.id;
                cpvm.name = p.name.length > 0 ? p.name : p.id;
                cpvm.description = p.description;
                cpvm.matchingTasks = matchingTasks;
                connectedProjects ~= cpvm;
            }
        }

        string repoName = repo.name;
        string repoAddress = repo.address;
        string repoCreatedAt = repo.createdAt;

        res.render!("repository/repository-details.dt", repo, repoName, repoAddress, repoCreatedAt, repoRefreshPolicy, errorMessage, connectedProjects);
    }

    router.get("/repositories/details", &handleDetails);
    router.get("/repositories/repo_details", &handleDetails);

    return router;
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    auto stores = new StateStores(new InMemoryDocumentStore());

    RepositoryRecord r1;
    r1.name = "confector-core";
    r1.address = "https://github.com/example/confector.git";
    r1.refreshPolicy = "polling";
    r1.createdAt = "2026-10-04T12:00:00Z";
    stores.repositories.put(r1);

    ProjectRecord p1;
    p1.id = "proj-1";
    p1.name = "Confector";
    stores.projects.put(p1);

    auto router = repositoryRouter(stores, "test-scheduler-secret");
    assert(router !is null);
    assert(stores.repositories.list().length == 1);

    // The VCS poll callback is a scheduler callback: refused without the scheduler secret
    auto pollReq = createTestHTTPServerRequest(URL("http://localhost/repositories/Confector/poll"), HTTPMethod.POST);
    auto pollRes = createTestHTTPServerResponse();
    router.handleRequest(pollReq, pollRes);
    assert(pollRes.statusCode == HTTPStatus.unauthorized);

    pollReq = createTestHTTPServerRequest(URL("http://localhost/repositories/Confector/poll"), HTTPMethod.POST);
    pollReq.headers["X-Confector-Scheduler-Secret"] = "wrong-secret";
    pollRes = createTestHTTPServerResponse();
    router.handleRequest(pollReq, pollRes);
    assert(pollRes.statusCode == HTTPStatus.unauthorized);

    // The URL a scheduled poll is sent to reaches the protected handler (401), not an unserved path (404)
    assert(vcsPollPath("Confector") == "/repositories/Confector/poll");
    auto scheduledReq = createTestHTTPServerRequest(URL(vcsPollUrl(8080, "Confector")), HTTPMethod.POST);
    auto scheduledRes = createTestHTTPServerResponse();
    router.handleRequest(scheduledReq, scheduledRes);
    assert(scheduledRes.statusCode == HTTPStatus.unauthorized);

    // A name that needs encoding is encoded in the scheduled path and still reaches the protected handler
    assert(vcsPollPath("a b") == "/repositories/a%20b/poll");
    auto encodedReq = createTestHTTPServerRequest(URL(vcsPollUrl(8080, "a b")), HTTPMethod.POST);
    auto encodedRes = createTestHTTPServerResponse();
    router.handleRequest(encodedReq, encodedRes);
    assert(encodedRes.statusCode == HTTPStatus.unauthorized);
}

unittest
{
    // A poll that finds a new revision records it, then fails loudly when a project uses the
    // repository: starting builds waits for request intake. A poll that finds nothing new, or a
    // change no project uses, succeeds
    import confector.core.plugin : PluginRegistry;
    import confector.plugin_api.model : TaskNode, VcsRepositoryState, repositoryInput;
    import confector.plugin_api.plugin : BasePlugin, PluginCategory;
    import confector.plugin_api.vcs : VcsStateResolver;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.json : JSONValue;
    import vibe.stream.memory : createMemoryOutputStream;

    static class PollTestResolver : BasePlugin, VcsStateResolver
    {
        string revision = "rev1";
        @property string name() const { return "poll-test-vcs"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Poll test VCS"; }
        @property PluginCategory category() const { return PluginCategory.definition; }
        @property string providerType() const { return "poll-test"; }
        bool canHandle(string repositoryUrl) const { import std.algorithm.searching : startsWith; return repositoryUrl.startsWith("polltest://"); }
        VcsRepositoryState fetchLatestState(string repositoryUrl, string targetRef = null)
        {
            VcsRepositoryState state;
            state.repositoryUrl = repositoryUrl;
            state.providerType = "poll-test";
            state.targetRef = "main";
            state.revision = revision;
            return state;
        }
        bool canHandleWebhook(in string[string] headers, in JSONValue payload) const { return false; }
        bool parseWebhookPayload(in string[string] headers, in JSONValue payload, out VcsRepositoryState resolvedState) { return false; }
    }

    auto resolver = new PollTestResolver();
    PluginRegistry.instance.registerPlugin(resolver);
    scope(exit) PluginRegistry.instance.unregisterPlugin(resolver.name);
    auto stores = new StateStores(new InMemoryDocumentStore());
    foreach (name; ["game", "unused"])
    {
        RepositoryRecord repo;
        repo.name = name;
        repo.address = "polltest://" ~ name;
        stores.repositories.put(repo);
    }
    ProjectRecord project;
    project.id = "game-project";
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", "main");
    project.tasks = [compile];
    stores.projects.put(project);
    auto router = repositoryRouter(stores, "test-scheduler-secret");

    int poll(string repository, out string error)
    {
        auto req = createTestHTTPServerRequest(URL(vcsPollUrl(8080, repository)), HTTPMethod.POST);
        req.headers["X-Confector-Scheduler-Secret"] = "test-scheduler-secret";
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        router.handleRequest(req, res);
        auto body = cast(string) sink.data;
        if (body.length > 0)
        {
            auto json = parseJsonString(body);
            if ("error" in json) error = json["error"].get!string;
        }
        return res.statusCode;
    }

    string error;
    assert(poll("game", error) == HTTPStatus.notImplemented);
    assert(error.canFind("game-project") && error.canFind(buildsNotImplemented), error);
    assert(stores.vcsStates.listChanges("polltest://game").length == 1, "The change is recorded first");

    assert(poll("game", error) == HTTPStatus.ok, "Nothing new");
    resolver.revision = "rev2";
    assert(poll("game", error) == HTTPStatus.notImplemented);
    assert(stores.vcsStates.listChanges("polltest://game").length == 2);

    assert(poll("unused", error) == HTTPStatus.ok, "No project uses it");
    assert(stores.vcsStates.listChanges("polltest://unused").length == 1);
}