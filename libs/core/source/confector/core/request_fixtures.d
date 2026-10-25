module confector.core.request_fixtures;

/**
 * Test fixtures shared by the unittests of the request components (request_state,
 * execution_dispatcher, request_reconciler): a small project, chains, request intake, finishing
 * executions, and the real dispatcher and reconciler. Compiled only for unittests.
 */

version (unittest):

import confector.core.request_evaluator;
import confector.core.chain_pins : pinMap;
import confector.core.request_reconciler : RequestReconciler;
import confector.core.document_collection : Versioned;
import confector.core.execution_dispatcher : Dispatched, ExecutionDispatcher;
import confector.core.fingerprint_ledger : ClaimOutcome;
import confector.core.input_resolution : GraphResolution;
import confector.core.rerun_generations : RerunGenerationReader, readGraphResolution;
import confector.core.state_stores : StateStores;
import confector.api.model;
import confector.testing.memory_document_store : InterleavingDocumentStore;

import std.format : format;
import vibe.data.json : Json;

/// The address the fixtures register for repository "game".
enum string gameAddress = "https://example.test/game.git";

/// The clock the fixtures' dispatchers use.
string fixedNow() { return "2026-10-20T10:00:00Z"; }

/// compile -> test -> report, and lint; compile and lint build repository game.
ProjectDefinition sampleDefinition()
{
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game");
    compile.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
    TaskNode test; test.id = "test"; test.inputs["bin"] = taskOutputInput("compile");
    TaskNode report; report.id = "report"; report.inputs["results"] = taskOutputInput("test");
    TaskNode lint; lint.id = "lint"; lint.inputs["src"] = repositoryInput("game");
    return ProjectDefinition([compile, test, report, lint]);
}

BuildChain sampleChain(string id)
{
    BuildChain chain;
    chain.id = id;
    chain.projectId = "game";
    chain.number = 1;
    chain.headline = HeadlineRef(HeadlineKind.branch, "main");
    foreach (task; ["compile", "lint"])
    {
        chain.pins ~= PinnedInput(task, "src", "game", RepositoryRef(RefKind.branch, "main"), InputPin(Json("aaa111")));
    }
    chain.createdAt = "2026-10-20T10:00:00Z";
    return chain;
}

/// Creates chain `id` and registers repository game if it is not yet.
BuildChain createChain(StateStores stores, string id)
{
    if (stores.repositories.get("game").isNull)
    {
        RepositoryRecord game;
        game.name = "game";
        game.address = gameAddress;
        stores.repositories.put(game);
    }
    return stores.chains.create(sampleChain(id)).value;
}

RerunGenerationReader readerOf(StateStores stores)
{
    return (in string[] bases) => stores.rerunGenerations.read(bases);
}

/// The fingerprints, now, of the tasks a request for `targets` covers.
GraphResolution closureNow(StateStores stores, in BuildChain chain, in string[] targets,
    ProjectDefinition definition = sampleDefinition())
{
    return readGraphResolution(chain.projectId, closureGraph(definition, targets), pinMap(chain.pins), readerOf(stores));
}

/// The fingerprint, now, of task `taskId` of chain `chainId`.
string fingerprintNow(StateStores stores, string chainId, string taskId)
{
    return closureNow(stores, stores.chains.get(chainId).get.value, [taskId]).fingerprints[taskId];
}

/// Records request `id` as an intake does: its demands from the settled ledgers, then the
/// request. Its state is not yet created (`intake` does both).
BuildRequest recordRequest(StateStores stores, string chainId, string id, string[] targets, string requestedAt,
    ProjectDefinition definition = sampleDefinition())
{
    const chain = stores.chains.get(chainId).get.value;
    auto closure = closureNow(stores, chain, targets, definition);
    ulong[string] stopSeqs;
    foreach (fingerprint; closure.fingerprints.byValue)
    {
        auto settled = stores.ledgers.settle(fingerprint);
        stopSeqs[fingerprint] = settled.ledger.isNull ? 0 : settled.ledger.get.stopSeq;
    }
    BuildRequest request;
    request.id = id;
    request.projectId = chain.projectId;
    request.chainId = chain.id;
    request.targets = targets;
    request.intent = BuildIntent.build;
    request.trigger.type = TriggerType.manual;
    request.definitionId = stores.definitions.put(definition);
    request.definitionSource = DefinitionSource(DefinitionLocation.confector);
    request.demands = requestDemands(closure, stopSeqs);
    request.requestedBy = "jason";
    request.requestedAt = requestedAt;
    return stores.requests.create(request).value;
}

/// Records request `id` and creates its open state.
BuildRequest intake(StateStores stores, string chainId, string id, string[] targets, string requestedAt,
    ProjectDefinition definition = sampleDefinition())
{
    auto request = recordRequest(stores, chainId, id, targets, requestedAt, definition);
    stores.requestStates.createFor(request);
    return request;
}

/// Request `id` with its definition, read by id.
DefinedRequest definedRequest(StateStores stores, string id)
{
    auto request = stores.requests.get(id).get.value;
    return DefinedRequest(request, stores.definitions.get(request.definitionId).get);
}

/// Evaluates request `requestId` from what the stores hold, all read by id.
RequestEvaluation evaluateFrom(StateStores stores, string requestId)
{
    auto entry = definedRequest(stores, requestId);
    const chain = stores.chains.get(entry.request.chainId).get.value;
    auto generations = readRequestGenerations(chain, entry, readerOf(stores));
    LedgerSummary[string] summaries;
    foreach (fingerprint; requestFingerprints(chain, entry, generations))
    {
        summaries[fingerprint] = readLedgerSummary(stores.ledgers, stores.executions, fingerprint);
    }
    return evaluateRequest(chain, entry, generations, summaries);
}

/// A dispatcher over `stores`, on the fixed clock.
ExecutionDispatcher dispatcherOf(StateStores stores)
{
    return new ExecutionDispatcher(stores, () => fixedNow());
}

/// A reconciler over `stores`.
RequestReconciler reconcilerOf(StateStores stores)
{
    return new RequestReconciler(stores, dispatcherOf(stores));
}

/// Dispatches the execution `needed` asks for with the real dispatcher; its claim must win.
Dispatched dispatch(StateStores stores, in NeededExecution needed, string requestId)
{
    auto dispatched = dispatcherOf(stores).dispatch(needed, definedRequest(stores, requestId));
    assert(dispatched.claim == ClaimOutcome.won, "The test dispatch's claim must win");
    return dispatched;
}

/// Reconciles request `requestId` with the real reconciler and returns its state.
Versioned!RequestState reconcile(StateStores stores, string requestId)
{
    return reconcilerOf(stores).reconcile(requestId).state;
}

/// Ends the active execution of `taskId`'s current fingerprint in chain `chain` with `status`:
/// the terminal compare-and-set and the fold.
void finish(StateStores stores, in BuildChain chain, string taskId, ExecutionStatus status)
{
    const fingerprint = closureNow(stores, chain, [taskId]).fingerprints[taskId];
    auto ledger = stores.ledgers.get(fingerprint).get;
    auto current = stores.executions.get(ledger.activeExecutionId).get;
    TaskExecution ended = current.value;
    ended.status = status;
    ended.finishedAt = "2026-10-20T11:00:00Z";
    stores.executions.update(current, ended);
    stores.ledgers.fold(ended);
}

RequestTaskState taskOf(in RequestState state, string taskId)
{
    foreach (ref task; state.tasks)
    {
        if (task.taskId == taskId) return cast(RequestTaskState) task;
    }
    assert(false, format("task '%s' has no state", taskId));
}

bool throwsA(E)(scope void delegate() action)
{
    try action();
    catch (E) return true;
    return false;
}

/// Runs `action` just before the `n`th write (1 for the next one) through `store`.
void beforeWrite(InterleavingDocumentStore store, size_t n, void delegate() action)
{
    assert(n >= 1);
    if (n == 1)
    {
        store.beforeNextWrite = action;
        return;
    }
    store.beforeNextWrite = () { beforeWrite(store, n - 1, action); };
}
