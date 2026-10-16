module confector.core.project_stores;

/**
 * State stores for what builds are made from (design records: beads confector-z7z.4 and
 * confector-z7z.19): projects, repositories and tracked branches, each a typed collection in the
 * DocumentStore.
 *
 * Projects and repositories are configuration that people edit: they are written whole, and the
 * last edit wins (`put`). Tracked branches are written by webhooks and polling with
 * compare-and-set. Listing is discovery and may lag behind writes.
 */

import confector.core.build_stores : InvalidStateTransitionException;
import confector.core.document_collection;
import confector.core.model;
import confector.plugin_api.document_store;

import std.format : format;
import std.typecons : Nullable;

/// Projects, by project id; indexed for listing.
enum CollectionSpec projectsCollection = CollectionSpec("projects", [IndexSpec("all", "listing", "id")]);

/// Repositories, by repository id (`RepositoryRecord.name`); indexed for listing.
enum CollectionSpec repositoriesCollection = CollectionSpec("repositories", [IndexSpec("all", "listing", "name")]);

/// Tracked branches, by `trackedBranchId`; indexed by repository.
enum CollectionSpec trackedBranchesCollection = CollectionSpec("tracked_branches",
    [IndexSpec("by_repository", "repository_id", "ref_key")]);

/// The partition key value of the listing indexes, which hold every document of a collection.
private enum string everything = "all";

/// Page size of the queries that list everything they find.
private enum size_t pageSize = 100;

/**
 * Projects (`ProjectRecord`).
 */
final class ProjectStore
{
    private DocumentCollection!ProjectRecord m_projects;

    /// Declares `projectsCollection` on `store`.
    this(DocumentStore store)
    {
        m_projects = new DocumentCollection!ProjectRecord(store, projectsCollection, ["listing"],
            (in ProjectRecord project) => ["listing": everything]);
    }

    /// Reads a project by id. Null if it does not exist.
    Nullable!(Versioned!ProjectRecord) get(string id)
    {
        return m_projects.get(id);
    }

    /// Writes `project`, creating it or replacing its latest version (last edit wins). Throws if
    /// it has no id, or DocumentConflictException if another write races this one.
    Versioned!ProjectRecord put(ProjectRecord project)
    {
        if (project.id.length == 0) throw new Exception("A project needs an id");
        return m_projects.put(project.id, project);
    }

    /// Removes project `id`. Returns false if it did not exist.
    bool remove(string id)
    {
        return m_projects.removeLatest(id);
    }

    /// Lists every project, by id. Discovery: may lag behind writes.
    ProjectRecord[] list()
    {
        return listAll(m_projects);
    }
}

/**
 * Repositories (`RepositoryRecord`), identified by their name, which is the repository id that
 * inputs name.
 */
final class RepositoryStore
{
    private DocumentCollection!RepositoryRecord m_repositories;

    /// Declares `repositoriesCollection` on `store`.
    this(DocumentStore store)
    {
        m_repositories = new DocumentCollection!RepositoryRecord(store, repositoriesCollection, ["listing"],
            (in RepositoryRecord repository) => ["listing": everything]);
    }

    /// Reads a repository by id. Null if it does not exist.
    Nullable!(Versioned!RepositoryRecord) get(string name)
    {
        return m_repositories.get(name);
    }

    /// Writes `repository`, creating it or replacing its latest version (last edit wins). Throws
    /// if it has no name, or DocumentConflictException if another write races this one.
    Versioned!RepositoryRecord put(RepositoryRecord repository)
    {
        if (repository.name.length == 0) throw new Exception("A repository needs a name");
        return m_repositories.put(repository.name, repository);
    }

    /// Removes repository `name`. Returns false if it did not exist.
    bool remove(string name)
    {
        return m_repositories.removeLatest(name);
    }

    /// Lists every repository, by name. Discovery: may lag behind writes.
    RepositoryRecord[] list()
    {
        return listAll(m_repositories);
    }
}

/// The id of the tracked branch of repository `repositoryId` of kind `kind` named `refName`.
string trackedBranchId(string repositoryId, RefKind kind, string refName) @safe
{
    return hashedId(repositoryId, kind, refName);
}

/**
 * Tracked branches. A branch's repository, kind and name never change; webhooks and polling
 * update its head, status and last-seen time by compare-and-set.
 */
final class TrackedBranchStore
{
    private DocumentCollection!TrackedBranch m_branches;

    /// Declares `trackedBranchesCollection` on `store`.
    this(DocumentStore store)
    {
        m_branches = new DocumentCollection!TrackedBranch(store, trackedBranchesCollection, ["ref_key"],
            (in TrackedBranch branch) => ["ref_key": compositeKey(branch.kind, branch.refName)]);
    }

    /// Reads a tracked branch. Null if it is not tracked.
    Nullable!(Versioned!TrackedBranch) get(string repositoryId, RefKind kind, string refName)
    {
        return m_branches.get(trackedBranchId(repositoryId, kind, refName));
    }

    /**
     * Starts tracking `branch`.
     *
     * Throws: DocumentConflictException if it is already tracked; InvalidStateTransitionException
     * if it has no repository, name or head; Exception if `lastSeenAt` is not an ISO 8601
     * timestamp.
     */
    Versioned!TrackedBranch create(TrackedBranch branch)
    {
        validate(branch);
        return m_branches.create(trackedBranchId(branch.repositoryId, branch.kind, branch.refName), branch);
    }

    /**
     * Replaces the branch `current` with `next`, which must name the same ref.
     *
     * Throws: DocumentConflictException if the branch changed since `current` was read;
     * InvalidStateTransitionException if `next` names another ref or has no head.
     */
    Versioned!TrackedBranch update(in Versioned!TrackedBranch current, TrackedBranch next)
    {
        const was = current.value;
        if (next.repositoryId != was.repositoryId || next.kind != was.kind || next.refName != was.refName)
        {
            throw new InvalidStateTransitionException(format("Tracked branch '%s' %s '%s' cannot become another ref",
                was.repositoryId, was.kind, was.refName));
        }
        validate(next);
        return m_branches.replace(trackedBranchId(was.repositoryId, was.kind, was.refName), next, current.version_);
    }

    /// Lists repository `repositoryId`'s tracked branches, deleted ones included, by kind and
    /// name. Discovery: may lag behind writes.
    TrackedBranch[] listForRepository(string repositoryId)
    {
        IndexQuery lookup;
        lookup.index = "by_repository";
        lookup.partitionKey = repositoryId;
        lookup.limit = pageSize;
        TrackedBranch[] result;
        foreach (item; m_branches.queryAll(lookup)) result ~= item.value;
        return result;
    }

    private static void validate(in TrackedBranch branch)
    {
        import vibe.data.json : Json;

        if (branch.repositoryId.length == 0 || branch.refName.length == 0)
        {
            throw new InvalidStateTransitionException("A tracked branch needs a repository id and a ref name");
        }
        if (branch.head.pinned.type == Json.Type.undefined || branch.head.pinned.type == Json.Type.null_)
        {
            throw new InvalidStateTransitionException(format("Tracked branch '%s' %s '%s' needs a head",
                branch.repositoryId, branch.kind, branch.refName));
        }
        sortableTimestamp(branch.lastSeenAt);
    }
}

/// Every value in a collection's "all" listing index.
private T[] listAll(T)(DocumentCollection!T collection)
{
    IndexQuery lookup;
    lookup.index = "all";
    lookup.partitionKey = everything;
    lookup.limit = pageSize;
    T[] result;
    foreach (item; collection.queryAll(lookup)) result ~= item.value;
    return result;
}

version (unittest)
{
    import confector.core.memory_document_store : InMemoryDocumentStore;
    import vibe.data.json : Json;

    private bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }
}

unittest
{
    // Projects: written whole, last edit wins, listed and removed
    auto documents = new InMemoryDocumentStore();
    auto projects = new ProjectStore(documents);
    ProjectRecord project;
    project.id = "game";
    project.name = "Game";
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", "main");
    project.tasks = [compile];
    assert(projects.put(project).version_ == 1);

    ProjectRecord read;
    assert(projects.get("game").tryValue(read) && read == project);
    project.name = "Game (renamed)";
    assert(projects.put(project).version_ == 2);
    assert(projects.get("game").get.name == "Game (renamed)");

    ProjectRecord tools;
    tools.id = "tools";
    projects.put(tools);
    auto listed = projects.list();
    assert(listed.length == 2 && listed[0].id == "game" && listed[1].id == "tools");
    assert(new ProjectStore(documents.restart()).list().length == 2);

    assert(projects.remove("tools"));
    assert(!projects.remove("tools"));
    assert(projects.list().length == 1);
    assert(throwsA!Exception({ projects.put(ProjectRecord.init); }), "A project needs an id");
}

unittest
{
    // Repositories: identified by name, listed and removed
    auto repositories = new RepositoryStore(new InMemoryDocumentStore());
    RepositoryRecord repository;
    repository.name = "game";
    repository.address = "https://example.com/game.git";
    repositories.put(repository);
    repository.refreshPolicy = "polling";
    repositories.put(repository);

    RepositoryRecord read;
    assert(repositories.get("game").tryValue(read) && read.refreshPolicy == "polling");
    assert(repositories.get("other").isNull);
    assert(repositories.list() == [repository]);
    assert(repositories.remove("game") && repositories.list().length == 0);
    assert(throwsA!Exception({ repositories.put(RepositoryRecord.init); }));
}

unittest
{
    // Tracked branches: one per repository, kind and name; head moves by compare-and-set
    auto branches = new TrackedBranchStore(new InMemoryDocumentStore());
    TrackedBranch main;
    main.repositoryId = "game";
    main.kind = RefKind.branch;
    main.refName = "main";
    main.head = InputPin(Json("aaa111"), ["subject": "Initial commit"]);
    main.status = BranchStatus.active;
    main.lastSeenAt = "2026-10-15T14:02:00Z";
    auto v1 = branches.create(main);

    auto tag = main;
    tag.kind = RefKind.tag;
    tag.refName = "main"; // a tag with a branch's name is another ref
    branches.create(tag);
    auto pr = main;
    pr.kind = RefKind.changeRequest;
    pr.refName = "pull/12";
    branches.create(pr);
    auto otherRepo = main;
    otherRepo.repositoryId = "tools";
    branches.create(otherRepo);

    assert(branches.get("game", RefKind.branch, "main").get.value == main);
    assert(branches.get("game", RefKind.branch, "dev").isNull);
    auto listed = branches.listForRepository("game");
    assert(listed.length == 3 && listed[0].kind == RefKind.branch && listed[1].kind == RefKind.changeRequest && listed[2].kind == RefKind.tag);

    // A push moves the head; a stale writer loses; a deletion keeps the record
    auto pushed = main;
    pushed.head = InputPin(Json("bbb222"));
    pushed.lastSeenAt = "2026-10-15T15:00:00Z";
    auto v2 = branches.update(v1, pushed);
    assert(throwsA!DocumentConflictException({ branches.update(v1, pushed); }));
    auto deleted = v2.value;
    deleted.status = BranchStatus.deleted;
    branches.update(v2, deleted);
    assert(branches.get("game", RefKind.branch, "main").get.status == BranchStatus.deleted);

    auto renamed = branches.get("game", RefKind.branch, "main").get;
    auto renamedValue = renamed.value;
    renamedValue.refName = "trunk";
    assert(throwsA!InvalidStateTransitionException({ branches.update(renamed, renamedValue); }));
    auto headless = main;
    headless.refName = "dev";
    headless.head = InputPin.init;
    assert(throwsA!InvalidStateTransitionException({ branches.create(headless); }));
    assert(throwsA!DocumentConflictException({ branches.create(main); }));
}
