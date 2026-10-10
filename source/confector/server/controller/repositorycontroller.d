module controller.repositorycontroller;

import vibe.vibe;
import std.algorithm : canFind, count, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.format : format;
import std.string : strip;
import std.typecons : Tuple, tuple;
import std.uri : encodeComponent;

import confector.core.model : ProjectRecord, RepositoryRecord;
import confector.core.storage : BuildStateRepository;
import confector.orchestrator.coordinator : BuildCoordinator;
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
    string repositoryUrl;
    string[] matchingTasks;
    bool isProjectDefault;
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
        entry.uri = format("http://127.0.0.1:%d/api/v1/repositories/%s/poll", serverPort, encodeComponent(repositoryName));
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
URLRouter repositoryRouter(BuildStateRepository stateRepo, BuildCoordinator coordinator = null,
    Scheduler scheduler = null, ushort serverPort = 8080)
{
    auto router = new URLRouter();

    // 1. Repositories list view
    void handleIndex(HTTPServerRequest req, HTTPServerResponse res)
    {
        auto repos = stateRepo !is null ? stateRepo.listRepositories() : [];
        auto projects = stateRepo !is null ? stateRepo.listProjects() : [];

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
                bool usesRepo = (p.repositoryUrl.length > 0 && (p.repositoryUrl == r.address || p.repositoryUrl == r.name));
                if (!usesRepo)
                {
                    foreach (t; p.tasks)
                    {
                        if (t.inputs.repositories.canFind(r.name) || (r.address.length > 0 && t.inputs.repositories.canFind(r.address)))
                        {
                            usesRepo = true;
                            break;
                        }
                    }
                }
                if (usesRepo)
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

        if (stateRepo !is null)
        {
            RepositoryRecord existing;
            if (stateRepo.getRepository(name, existing))
            {
                res.redirect("/repositories/add?error=Repository+with+this+name+already+exists");
                return;
            }

            RepositoryRecord record;
            record.name = name;
            record.address = address;
            record.refreshPolicy = refreshPolicy;
            record.createdAt = Clock.currTime.toISOString();
            stateRepo.saveRepository(record);

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

        if (stateRepo !is null)
        {
            RepositoryRecord record;
            if (stateRepo.getRepository(name, record))
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
                stateRepo.saveRepository(record);
            }
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/edit", &handleEditSubmit);

    // 4. Per-repository VCS polling endpoint (called by scheduler)
    if (stateRepo !is null)
    {
        router.post("/repositories/:repoName/poll", (HTTPServerRequest req, HTTPServerResponse res) {
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
                if (!stateRepo.getRepository(repoName, repoRecord))
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

                if (stateRepo.getRepositoryState(newState.repositoryUrl, newState.targetRef, previousState))
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
                stateRepo.saveRepositoryState(newState);

                if (changed && coordinator !is null)
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
                    stateRepo.recordRepositoryChange(change);

                    // Find projects that use this repository and start builds
                    foreach (proj; stateRepo.listProjects())
                    {
                        if (proj.repositoryUrl == repoUrl)
                        {
                            coordinator.startBuild(proj, null, false, "polling");
                        }
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
        });
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
        if (stateRepo !is null)
        {
            found = stateRepo.getRepository(name, repo);
        }

        if (!found)
        {
            repo.name = name;
            repo.address = "";
            repo.refreshPolicy = "webhook";
        }

        string repoRefreshPolicy = repo.refreshPolicy.length > 0 ? repo.refreshPolicy : "webhook";

        auto allProjects = stateRepo !is null ? stateRepo.listProjects() : [];
        ConnectedProjectViewModel[] connectedProjects;

        foreach (p; allProjects)
        {
            bool isDefault = (p.repositoryUrl.length > 0 && (p.repositoryUrl == repo.address || p.repositoryUrl == repo.name));
            string[] matchingTasks;

            foreach (t; p.tasks)
            {
                if (t.inputs.repositories.canFind(repo.name) || (repo.address.length > 0 && t.inputs.repositories.canFind(repo.address)))
                {
                    matchingTasks ~= (t.name.length > 0 ? t.name : t.id);
                }
            }

            if (isDefault || matchingTasks.length > 0)
            {
                ConnectedProjectViewModel cpvm;
                cpvm.id = p.id;
                cpvm.name = p.name.length > 0 ? p.name : p.id;
                cpvm.description = p.description;
                cpvm.repositoryUrl = p.repositoryUrl;
                cpvm.matchingTasks = matchingTasks;
                cpvm.isProjectDefault = isDefault;
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
    import confector.core.test_storage : InMemoryBuildStateRepository;
    auto stateRepo = new InMemoryBuildStateRepository();

    RepositoryRecord r1;
    r1.name = "confector-core";
    r1.address = "https://github.com/example/confector.git";
    r1.refreshPolicy = "polling";
    r1.createdAt = "2026-10-04T12:00:00Z";
    stateRepo.saveRepository(r1);

    ProjectRecord p1;
    p1.id = "proj-1";
    p1.name = "Confector";
    p1.repositoryUrl = "https://github.com/example/confector.git";
    stateRepo.saveProject(p1);

    auto router = repositoryRouter(stateRepo);
    assert(router !is null);
    assert(stateRepo.listRepositories().length == 1);
}