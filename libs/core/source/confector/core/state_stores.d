module confector.core.state_stores;

/**
 * Every state store the core keeps in the DocumentStore (design record: bead confector-z7z.4),
 * built over one store at startup and passed explicitly to what needs it. Constructing it
 * declares every collection and index, so a misconfigured store fails at startup rather than on
 * first use.
 */

import confector.core.api_token_store : ApiTokenStore;
import confector.core.build_stores : BuildRequestStore, ChainStore, ExecutionStore;
import confector.core.counters : CounterStore;
import confector.core.fingerprint_ledger : LedgerStore;
import confector.core.project_stores : ProjectStore, RepositoryStore, TrackedBranchStore;
import confector.core.rerun_generations : RerunGenerationStore;
import confector.api.document_store : DocumentStore;

/**
 * The core's state stores over one DocumentStore.
 */
final class StateStores
{
    // The build model
    ChainStore chains;
    BuildRequestStore requests;
    ExecutionStore executions;
    LedgerStore ledgers;
    RerunGenerationStore rerunGenerations;
    CounterStore counters;

    // What builds are made from, and who may make them
    ProjectStore projects;
    RepositoryStore repositories;
    TrackedBranchStore trackedBranches;
    ApiTokenStore apiTokens;

    private DocumentStore m_store;

    /// Builds every store over `store`, declaring their collections.
    this(DocumentStore store)
    {
        if (store is null)
        {
            throw new Exception("The state stores require a document store");
        }
        m_store = store;
        chains = new ChainStore(store);
        requests = new BuildRequestStore(store);
        executions = new ExecutionStore(store);
        ledgers = new LedgerStore(store, executions);
        rerunGenerations = new RerunGenerationStore(store);
        counters = new CounterStore(store);
        projects = new ProjectStore(store);
        repositories = new RepositoryStore(store);
        trackedBranches = new TrackedBranchStore(store);
        apiTokens = new ApiTokenStore(store);
    }

    /// The DocumentStore the stores are kept in.
    @property DocumentStore documentStore() { return m_store; }
}

unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.api.model : ProjectRecord;

    // Every store is declared over one document store; a restarted process redeclares the same
    // collections and sees the same data
    auto documents = new InMemoryDocumentStore();
    auto stores = new StateStores(documents);
    ProjectRecord project;
    project.id = "game";
    stores.projects.put(project);
    assert(stores.counters.next("n") == 1);
    assert(stores.documentStore is documents);

    auto restarted = new StateStores(documents.restart());
    assert(!restarted.projects.get("game").isNull);
    assert(restarted.counters.next("n") == 2);

    bool threw = false;
    try new StateStores(null);
    catch (Exception) threw = true;
    assert(threw);
}
