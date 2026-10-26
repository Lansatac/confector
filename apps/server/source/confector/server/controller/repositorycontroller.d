module confector.server.controller.repositorycontroller;

import vibe.vibe;
import std.algorithm : canFind, count, filter;
import std.array : array;
import std.datetime.systime : Clock;
import std.string : strip;
import std.uri : encodeComponent;

import confector.api.model : ProjectRecord, RepositoryRecord, Role, projectUsesRepository, repositoryIds;
import confector.core.document_collection : tryValue, DocumentCollection;
import confector.core.git : addressCarriesCredentials, redactAddress;
import confector.core.project_stores : InvalidRepositoryAddressException, repositoriesCollection;
import confector.core.state_stores : StateStores;
import confector.server.authenticator : Authenticator;
import confector.server.route_access : AuthorizedRoutes;

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
 * Creates the routes for the /repositories pages. Viewing them needs the viewer role; adding and
 * editing repositories needs admin, as repository records are configuration.
 */
AuthorizedRoutes repositoryRouter(Authenticator authenticator, StateStores stores)
{
    auto router = new AuthorizedRoutes(authenticator);

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
            rvm.address = redactAddress(r.address);
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

    router.get("/repositories/", Role.viewer, &handleIndex);

    // 2. Add repository view
    void handleAddForm(HTTPServerRequest req, HTTPServerResponse res)
    {
        string errorMessage = req.query.get("error", "");
        res.render!("repository/add-repo.dt", errorMessage);
    }

    router.get("/repositories/add", Role.admin, &handleAddForm);

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
            try
            {
                stores.repositories.put(record);
            }
            catch (InvalidRepositoryAddressException e)
            {
                res.redirect("/repositories/add?error=" ~ encodeComponent(e.msg));
                return;
            }
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/add", Role.admin, &handleAddSubmit);

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
                try
                {
                    stores.repositories.put(record);
                }
                catch (InvalidRepositoryAddressException e)
                {
                    res.redirect("/repositories/details?name=" ~ encodeComponent(name) ~ "&error=" ~ encodeComponent(e.msg));
                    return;
                }
            }
        }

        res.redirect("/repositories/details?name=" ~ encodeComponent(name));
    }

    router.post("/repositories/edit", Role.admin, &handleEditSubmit);

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
        // An address with credentials is not shown at all, not even redacted: the field is left empty
        // for the address to be entered again, so a saved form never stores a redacted address
        const addressWithheld = addressCarriesCredentials(repo.address);
        string repoAddress = addressWithheld ? "" : repo.address;
        string repoCreatedAt = repo.createdAt;

        res.render!("repository/repository-details.dt", repoName, repoAddress, addressWithheld, repoCreatedAt, errorMessage,
            connectedProjects);
    }

    router.get("/repositories/details", Role.viewer, &handleDetails);

    return router;
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import vibe.stream.memory : createMemoryOutputStream;
    auto stores = new StateStores(new InMemoryDocumentStore());

    RepositoryRecord r1;
    r1.name = "confector-core";
    r1.address = "https://github.com/example/confector.git";
    r1.createdAt = "2026-10-04T12:00:00Z";
    stores.repositories.put(r1);

    import confector.server.authenticator : FixedAuthenticator, testIdentity;
    auto router = repositoryRouter(new FixedAuthenticator(testIdentity(Role.admin)), stores);
    assert(router !is null);

    // A registration without a name and address is redirected back to the form and stores nothing
    auto addReq = createTestHTTPServerRequest(URL("http://localhost/repositories/add"), HTTPMethod.POST);
    auto addRes = createTestHTTPServerResponse();
    router.handleRequest(addReq, addRes);
    assert(addRes.statusCode == HTTPStatus.found);
    assert(stores.repositories.list().length == 1);

    // An address with credentials is refused with the reason, and nothing is stored
    auto leakReq = createTestHTTPServerRequest(URL("http://localhost/repositories/add"), HTTPMethod.POST);
    leakReq.form["name"] = "secret-repo";
    leakReq.form["address"] = "https://token@example.com/secret.git";
    auto leakRes = createTestHTTPServerResponse();
    router.handleRequest(leakReq, leakRes);
    assert(leakRes.statusCode == HTTPStatus.found);
    assert(leakRes.headers["Location"].canFind("error="), leakRes.headers["Location"]);
    assert(stores.repositories.list().length == 1);

    // A record written without the store's check still shows without its credentials
    auto legacy = new DocumentCollection!RepositoryRecord(stores.documentStore, repositoriesCollection, ["listing"],
        (in RepositoryRecord record) => ["listing": "all"]);
    RepositoryRecord leaked;
    leaked.name = "leaked";
    leaked.address = "https://token@example.com/leaked.git";
    legacy.put(leaked.name, leaked);

    // Answers a request to a route of this router: its status, its Location and its body
    struct Answer { int status; string location; string body; }
    Answer send(HTTPMethod method, string path, string[2][] fields = null)
    {
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method);
        foreach (field; fields) req.form[field[0]] = field[1];
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        router.handleRequest(req, res);
        res.finalize();
        return Answer(res.statusCode, res.headers.get("Location", ""), cast(string) sink.data.idup);
    }

    // The list shows the stored address with its credentials redacted
    auto listed = send(HTTPMethod.GET, "/repositories/");
    assert(listed.body.canFind("https://***@example.com/leaked.git"), listed.body);
    assert(!listed.body.canFind("token@"), listed.body);

    // The details page shows no address for it, so a saved form cannot store a redacted one
    auto leakedPage = send(HTTPMethod.GET, "/repositories/details?name=leaked");
    assert(leakedPage.body.canFind("carries credentials") && !leakedPage.body.canFind("example.com"), leakedPage.body);
    assert(!leakedPage.body.canFind("token@"), leakedPage.body);

    // Editing it with credentials is refused with the reason, and the stored address is kept
    auto editLeak = send(HTTPMethod.POST, "/repositories/edit",
        [["name", "leaked"], ["address", "https://token@example.com/new.git"]]);
    assert(editLeak.status == HTTPStatus.found && editLeak.location.canFind("error="), editLeak.location);
    assert(stores.repositories.get("leaked").get.value.address == "https://token@example.com/leaked.git");

    // An edit that keeps a login-only address saves it as it is, for both ssh forms
    foreach (address; ["git@github.com:org/repo.git", "ssh://git@github.com/org/repo.git"])
    {
        RepositoryRecord login;
        login.name = "login";
        login.address = address;
        stores.repositories.put(login);
        auto page = send(HTTPMethod.GET, "/repositories/details?name=login");
        assert(page.body.canFind(address) && !page.body.canFind("carries credentials"), page.body);
        auto saved = send(HTTPMethod.POST, "/repositories/edit", [["name", "login"], ["address", address]]);
        assert(saved.status == HTTPStatus.found && !saved.location.canFind("error="), saved.location);
        assert(stores.repositories.get("login").get.value.address == address);
    }
}