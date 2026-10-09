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

/// View model for repository listing.
struct RepositoryViewModel
{
    string name;
    string address;
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

/**
 * Creates the URL router for the /repositories endpoints.
 */
URLRouter repositoryRouter(BuildStateRepository stateRepo)
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

        if (name.length == 0 || address.length == 0)
        {
            res.redirect("/repositories/add?error=Name+and+address+are+required");
            return;
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
            record.createdAt = Clock.currTime.toISOString();
            stateRepo.saveRepository(record);
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/add", &handleAddSubmit);
    router.post("/repositories/add_repo", &handleAddSubmit);

    // 4. Repository details view
    void handleDetails(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.query.get("name", req.query.get("repo_name", ""));
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
        }

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

        res.render!("repository/repository-details.dt", repo, repoName, repoAddress, repoCreatedAt, connectedProjects);
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