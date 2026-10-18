module confector.server.controller.repositorycontroller;

import vibe.vibe;
import std.algorithm : canFind, count, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.string : strip;
import std.uri : encodeComponent;

import confector.plugin_api.model : ProjectRecord, RepositoryRecord, projectUsesRepository, repositoryIds;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;

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
    string[] matchingTasks;
}

/**
 * Creates the URL router for the /repositories endpoints.
 */
URLRouter repositoryRouter(StateStores stores)
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

    // 2. Add repository view
    void handleAddForm(HTTPServerRequest req, HTTPServerResponse res)
    {
        string errorMessage = req.query.get("error", "");
        res.render!("repository/add-repo.dt", errorMessage);
    }

    router.get("/repositories/add", &handleAddForm);

    // 3. Post add repository
    void handleAddSubmit(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.form.get("name", "").strip;
        string address = req.form.get("address", "").strip;

        if (name.length == 0 || address.length == 0)
        {
            res.redirect("/repositories/add?error=Name+and+address+are+required");
            return;
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
            record.createdAt = Clock.currTime.toISOString();
            stores.repositories.put(record);
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/add", &handleAddSubmit);

    // 3.5. Post edit repository
    void handleEditSubmit(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.form.get("name", "").strip;
        string address = req.form.get("address", "").strip;

        if (name.length == 0 || address.length == 0)
        {
            res.redirect("/repositories/details?name=" ~ encodeComponent(name) ~ "&error=Name+and+address+are+required");
            return;
        }

        if (stores !is null)
        {
            RepositoryRecord record;
            if (stores.repositories.get(name).tryValue(record))
            {
                record.address = address;
                stores.repositories.put(record);
            }
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/edit", &handleEditSubmit);

    // 4. Repository details view
    void handleDetails(HTTPServerRequest req, HTTPServerResponse res)
    {
        string name = req.query.get("name", "");
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
        }

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

        res.render!("repository/repository-details.dt", repo, repoName, repoAddress, repoCreatedAt, errorMessage, connectedProjects);
    }

    router.get("/repositories/details", &handleDetails);

    return router;
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    auto stores = new StateStores(new InMemoryDocumentStore());

    RepositoryRecord r1;
    r1.name = "confector-core";
    r1.address = "https://github.com/example/confector.git";
    r1.createdAt = "2026-10-04T12:00:00Z";
    stores.repositories.put(r1);

    auto router = repositoryRouter(stores);
    assert(router !is null);

    // A registration without a name and address is redirected back to the form and stores nothing
    auto addReq = createTestHTTPServerRequest(URL("http://localhost/repositories/add"), HTTPMethod.POST);
    auto addRes = createTestHTTPServerResponse();
    router.handleRequest(addReq, addRes);
    assert(addRes.statusCode == HTTPStatus.found);
    assert(stores.repositories.list().length == 1);
}