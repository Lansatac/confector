module confector.core.state_stores;

/**
 * Every state store the core keeps in the DocumentStore (design record: bead confector-z7z.4),
 * built over one store at startup and passed explicitly to what needs it. Constructing it
 * declares every collection and index, so a misconfigured store fails at startup rather than on
 * first use.
 */

import confector.core.api_token_store : ApiTokenStore;
import confector.core.build_stores : ArtifactRecordStore, BuildRequestStore, ChainStore, ExecutionStore, FingerprintClaimStore;
import confector.core.counters : CounterStore;
import confector.core.legacy_stores : BuildLogStore, LegacyBuildStore, ResultCacheStore, TriggerRuleStore, VcsStateStore, WorkerStore;
import confector.core.project_stores : ProjectStore, RepositoryStore, TrackedBranchStore;
import confector.core.rerun_generations : RerunGenerationStore;
import confector.plugin_api.document_store : DocumentStore;

/**
 * The core's state stores over one DocumentStore.
 */
final class StateStores
{
    // The build model
    ChainStore chains;
    BuildRequestStore requests;
    ExecutionStore executions;
    FingerprintClaimStore claims;
    RerunGenerationStore rerunGenerations;
    ArtifactRecordStore artifacts;
    CounterStore counters;

    // What builds are made from, and who may make them
    ProjectStore projects;
    RepositoryStore repositories;
    TrackedBranchStore trackedBranches;
    ApiTokenStore apiTokens;

    // The BuildCoordinator's records; see confector.core.legacy_stores for when each goes
    LegacyBuildStore legacyBuilds;
    ResultCacheStore resultCache;
    BuildLogStore logs;
    TriggerRuleStore triggerRules;
    WorkerStore workers;
    VcsStateStore vcsStates;

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
        claims = new FingerprintClaimStore(store);
        rerunGenerations = new RerunGenerationStore(store);
        artifacts = new ArtifactRecordStore(store);
        counters = new CounterStore(store);
        projects = new ProjectStore(store);
        repositories = new RepositoryStore(store);
        trackedBranches = new TrackedBranchStore(store);
        apiTokens = new ApiTokenStore(store);
        legacyBuilds = new LegacyBuildStore(store);
        resultCache = new ResultCacheStore(store);
        logs = new BuildLogStore(store);
        triggerRules = new TriggerRuleStore(store);
        workers = new WorkerStore(store);
        vcsStates = new VcsStateStore(store);
    }

    /// The DocumentStore the stores are kept in.
    @property DocumentStore documentStore() { return m_store; }
}

unittest
{
    import confector.core.memory_document_store : InMemoryDocumentStore;
    import confector.core.model : ProjectRecord;

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
