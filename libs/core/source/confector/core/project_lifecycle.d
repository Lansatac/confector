module confector.core.project_lifecycle;

/**
 * Project lifecycle (AGENTS.md, "Coordinating builds"): what deleting a project does to the requests
 * it has open. Its open requests can never progress once it is gone, so they settle failed, and the
 * project is removed after them. This is imperative shell: it reads and writes through the state
 * stores and keeps no state between calls.
 *
 * Deleting is resumable. A crash between settling and removing leaves the project in place, and
 * deleting it again finishes. Each settlement is a compare-and-set (BuildRequestStore.replaceState):
 * one that loses reads the request again, so a settlement another write made first is kept.
 */

import confector.core.request_state : withFailure;
import confector.core.state_stores : StateStores;
import confector.api.document_store : DocumentConflictException;
import confector.api.model : RequestOutcome;

import std.format : format;

/// How many times settling one request reads again after losing its compare-and-set before deleting
/// the project fails.
enum size_t maxSettleAttempts = 100;

/**
 * Deletes project `projectId`: settles each of its open requests failed, with an error saying the
 * project was deleted, one page of open requests at a time, and then removes the project. Returns
 * false, and writes nothing, if the project does not exist.
 *
 * A settled request keeps what it asked for and the tasks its last evaluation cached. A request
 * recorded while the project is deleted may be left open and unlisted. Executions of the project
 * that are running are not cancelled.
 *
 * Throws: whatever the stores throw, which leaves the project in place; Exception if a listed request
 * no longer exists, or if other writes overtake a request maxSettleAttempts times.
 */
bool deleteProject(StateStores stores, string projectId)
{
    if (stores.projects.get(projectId).isNull) return false;
    const error = format("Project '%s' was deleted", projectId);
    string cursor;
    while (true)
    {
        auto page = stores.requests.listOpenPage(projectId, cursor);
        foreach (item; page.items) settleDeleted(stores, item.value.id, error);
        if (page.nextCursor.length == 0) break;
        cursor = page.nextCursor;
    }
    return stores.projects.remove(projectId);
}

/// Settles request `requestId` failed with `error`, unless it is settled already. A write that another
/// write overtook reads the request again and settles it on what it then holds.
private void settleDeleted(StateStores stores, string requestId, string error)
{
    foreach (attempt; 0 .. maxSettleAttempts)
    {
        auto found = stores.requests.get(requestId);
        if (found.isNull) throw new Exception(format("Request '%s' does not exist, so it cannot be settled", requestId));
        auto read = found.get;
        if (read.state.outcome != RequestOutcome.open) return;
        try
        {
            stores.requests.replaceState(read, withFailure(read.value, error));
            return;
        }
        catch (DocumentConflictException)
        {
            // Another write changed the request since it was read: read it again
        }
    }
    throw new Exception(format("Request '%s' was not settled: %s writes in a row overtook it", requestId, maxSettleAttempts));
}

version (unittest)
{
    import confector.core.request_fixtures;
    import confector.core.build_stores : buildRequestsCollection, defaultPageSize;
    import confector.api.document_store : Document, DocumentStore;
    import confector.api.model : ProjectRecord, RequestState, RequestTaskState, RequestTaskStatus;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import vibe.data.json : Json;

    import std.algorithm.searching : canFind;

    /// Stores over `documents`, paged by `pageSize`, with project "game" registered so that a deletion finds it.
    private StateStores gameStores(DocumentStore documents, size_t pageSize = defaultPageSize)
    {
        auto stores = new StateStores(documents, pageSize);
        ProjectRecord game;
        game.id = "game";
        game.name = "game";
        stores.projects.put(game);
        return stores;
    }
}

unittest
{
    // Deleting a project settles its open requests failed over several pages, keeping what they asked
    // for and their cached tasks, then removes it; deleting it again finds no project
    auto stores = gameStores(new InMemoryDocumentStore(), 2);
    createChain(stores, "c1");
    foreach (i; 0 .. 3) intake(stores, "c1", format("r%s", i), ["lint"], format("2026-10-20T10:00:0%sZ", i));
    reconcilerOf(stores).reconcile("r0");

    assert(deleteProject(stores, "game"));
    foreach (i; 0 .. 3)
    {
        auto request = stores.requests.get(format("r%s", i)).get.value;
        assert(request.state.outcome == RequestOutcome.failed && request.state.error == "Project 'game' was deleted", request.state.error);
    }
    assert(stores.requests.get("r0").get.state.tasks.length == 1, "The tasks cached by the last evaluation are kept");
    assert(stores.requests.listOpen("game").length == 0, "Every settled request leaves the open index");
    assert(stores.projects.get("game").isNull, "The project is removed");
    assert(!deleteProject(stores, "game"), "A project that is gone is not removed again");
}

unittest
{
    // A project that does not exist is not removed, and nothing is written: its open requests stay open
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = new StateStores(interleaving);
    createChain(stores, "c1");
    intake(stores, "c1", "r0", ["lint"], "2026-10-20T10:00:00Z");

    beforeWrite(interleaving, 1, () { throw new Exception("A write was attempted"); });
    assert(!deleteProject(stores, "game"), "A project that does not exist is not removed");
    assert(interleaving.beforeNextWrite !is null, "Nothing was written");
    assert(stores.requests.listOpen("game").length == 1, "The request stays open");
}

unittest
{
    // A failure while the open requests are settled leaves the project in place, with the requests
    // settled before it settled; deleting it again finishes
    auto interleaving = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto stores = gameStores(interleaving, 2);
    createChain(stores, "c1");
    foreach (i; 0 .. 3) intake(stores, "c1", format("r%s", i), ["lint"], format("2026-10-20T10:00:0%sZ", i));

    // Writes 1 and 2 settle r0 and r1; write 3 settles r2 and fails
    beforeWrite(interleaving, 3, () { throw new Exception("The store is unavailable"); });
    bool failed = false;
    try deleteProject(stores, "game");
    catch (Exception e)
    {
        failed = true;
        assert(e.msg.canFind("unavailable"), e.msg);
    }
    assert(failed, "A failed settle must be reported");
    assert(!stores.projects.get("game").isNull, "The project is left in place");
    assert(stores.requests.get("r0").get.state.outcome == RequestOutcome.failed && stores.requests.get("r1").get.state.outcome == RequestOutcome.failed);
    assert(stores.requests.listOpen("game").length == 1 && stores.requests.listOpen("game")[0].id == "r2");

    assert(deleteProject(stores, "game"), "Deleting it again finishes");
    assert(stores.projects.get("game").isNull && stores.requests.listOpen("game").length == 0);
    assert(stores.requests.get("r2").get.state.error == "Project 'game' was deleted");
}

unittest
{
    // A request another write changed since it was read is read again and settled on what it then
    // holds; a request another write settled first keeps that settlement
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = gameStores(interleaving);
    createChain(stores, "c1");
    intake(stores, "c1", "r0", ["lint"], "2026-10-20T10:00:00Z");
    intake(stores, "c1", "r1", ["lint"], "2026-10-20T10:00:01Z");
    const r0 = stores.requests.get("r0").get;
    const r1 = stores.requests.get("r1").get;

    // Before the first settle, another writer records a state for r0 and settles r1
    RequestState queued;
    queued.tasks = [RequestTaskState("lint", "fp-lint", RequestTaskStatus.queued)];
    beforeWrite(interleaving, 1, () {
        stores.requests.replaceState(r0, queued);
        stores.requests.replaceState(r1, withFailure(r1.value, "The build was cancelled"));
    });
    assert(deleteProject(stores, "game"));

    const kept = stores.requests.get("r0").get.value;
    assert(kept.state.outcome == RequestOutcome.failed && kept.state.error == "Project 'game' was deleted");
    assert(kept.state.tasks == queued.tasks, "The state the other writer recorded is the one settled");
    assert(stores.requests.get("r1").get.state.error == "The build was cancelled", "A settlement made first is kept");
}

unittest
{
    // A request that another write overtakes on every attempt is not settled: deleting the project
    // throws once the attempts run out, and the project stays
    static final class OvertakingStore : InMemoryDocumentStore
    {
        override Document replace(string collection, string id, Json content, ulong expectedVersion)
        {
            if (collection == buildRequestsCollection.name)
            {
                // Another writer's write, between the read and this one
                auto current = get(collection, id).get;
                super.replace(collection, id, current.content, current.version_);
            }
            return super.replace(collection, id, content, expectedVersion);
        }
    }

    auto stores = gameStores(new OvertakingStore());
    createChain(stores, "c1");
    intake(stores, "c1", "r0", ["lint"], "2026-10-20T10:00:00Z");

    bool exhausted = false;
    try deleteProject(stores, "game");
    catch (Exception e)
    {
        exhausted = e.msg.canFind("overtook");
    }
    assert(exhausted, "Deleting must give up after its attempts");
    assert(!stores.projects.get("game").isNull, "The project is left in place");
    assert(stores.requests.get("r0").get.state.outcome == RequestOutcome.open, "The request is left open");
}

unittest
{
    // A request that the open index lists but whose document is gone when it is settled makes deleting
    // throw, and the project stays. (Within one store the index and the document change together, so
    // the removal here comes after the listing: the reachable case.)
    auto documents = new InMemoryDocumentStore();
    auto interleaving = new InterleavingDocumentStore(documents);
    auto stores = gameStores(interleaving);
    createChain(stores, "c1");
    intake(stores, "c1", "r0", ["lint"], "2026-10-20T10:00:00Z");
    intake(stores, "c1", "r1", ["lint"], "2026-10-20T10:00:01Z");

    beforeWrite(interleaving, 1, () {
        documents.remove(buildRequestsCollection.name, "r1", documents.get(buildRequestsCollection.name, "r1").get.version_);
    });
    bool missing = false;
    try deleteProject(stores, "game");
    catch (Exception e)
    {
        missing = e.msg.canFind("does not exist");
    }
    assert(missing, "A listed request that is gone must be reported");
    assert(!stores.projects.get("game").isNull, "The project is left in place");
    assert(stores.requests.get("r0").get.state.outcome == RequestOutcome.failed);
}
