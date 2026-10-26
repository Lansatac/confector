module confector.core.intake;

/**
 * Request intake (AGENTS.md, "What a build is" and "Branches"): how a manual request, from the API
 * or the dashboard, becomes a recorded BuildRequest on a build chain, with its state created and
 * reconciled. The decisions are pure (`chooseRefs`, `headlineChoice`, `repositoryDefaults`); the
 * shell (`RequestIntake`) does the I/O, with the repository resolver injected.
 *
 * Intake reads the project's current definition once and stores it (`DefinitionStore.put`), and
 * binds each repository input to a ref: the request's ref for the input's repository, else the
 * input's default (a fixed ref, or `same` against the chain's headline), else the request is
 * refused naming the task and the input.
 *
 * - **A new chain is a snapshot.** Every repository input of the whole definition is bound the same
 *   way, each distinct (repository, ref) is resolved once, and all are pinned on the new chain. If
 *   any cannot be bound or resolved the request is refused and no chain (and no number) is created.
 *   The chain's headline is the ref of the first repository, by id, that the request or a fixed
 *   default gives a ref for.
 * - **A chain records the ref each repository input was first bound to** (`BuildChain.bindings`): all
 *   inputs of the definition at creation, and later any input first bound by a request. On an
 *   existing chain an input binds to the request's ref for its repository, else the chain's
 *   binding, else the input's default. A rebinding adds a pin and leaves the chain's binding.
 * - **An existing chain** (named by id or number) keeps its pins. Only the (repository, ref) pairs
 *   the request needs and the chain lacks are resolved, and added with `ChainStore.addPins`.
 *   Binding an input to another ref than it was built at is allowed: it adds a pin.
 * - **Each pin comes from**, in order: the pins supplied with the request, the chain's pin, or
 *   resolution now. Chain pins are written first; the request is then recorded with the pins of
 *   exactly the refs its bindings use, taken from the chain.
 *
 * A ref named without a kind (`main`, `v1.0`) takes its kind from a supplied or chain pin of that
 * name, or else from the resolver (`RepositoryResolver.resolveName`); a name pinned as both a branch
 * and a tag is ambiguous and refused.
 *
 * Binding choices are made from the chain as first read and are not recomputed when the pin write
 * retries: concurrent requests stay individually consistent but may differ from running one after
 * the other.
 *
 * Every write is safe to retry or race. The definition is stored idempotently, `addPins` and the
 * chain number counter are compare-and-set, and a pin another request wins the race for is
 * taken from the chain instead of the one resolved here. A failure after the chain was created
 * leaves a chain without requests and a gap in the numbers, which is harmless; a rerun bumps the
 * target's generation before the request is recorded, so repeating a failed rerun bumps it again,
 * which only means the earlier generation is not used either.
 */

import confector.api.input_resolver : RepositoryResolver, ResolvedRef;
import confector.api.model;
import confector.core.chain_pins;
import confector.core.dag : TaskGraph;
import confector.core.document_collection : Versioned;
import confector.core.definition_store : InvalidDefinitionException, currentDefinition;
import confector.core.input_resolution : InputResolutionException, requireRepositorySpec, requiredPins;
import confector.core.project_stores : RepositoryStore;
import confector.core.request_evaluator : closureGraph, requestDemands;
import confector.core.request_reconciler : RequestReconciler;
import confector.core.rerun_generations : readGraphResolution;
import confector.core.state_stores : StateStores;
import confector.core.work_orders : utcNow;

import std.algorithm.iteration : map;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array;
import std.format : format;
import std.typecons : Nullable, nullable;
import std.uuid : randomUUID;

/// Why intake refused or failed a request; the API maps each to a status.
enum IntakeFailure
{
    /// The project or chain does not exist.
    notFound,
    /// The request is malformed on its own: no target, a chain named twice, a retry or rerun
    /// without a chain.
    invalid,
    /// The request cannot be bound or resolved: an input without a ref, a ref that does not
    /// exist, an unreachable repository, a target the definition lacks.
    refused,
    /// A supplied pin disagrees with the chain's pin of the same ref.
    conflict,
    /// The request was recorded, but reconciling it failed; the sweep reconciles it again.
    reconcileFailed
}

/// What a recorded request is, for the caller to show.
struct IntakeResult
{
    string requestId;
    string chainId;
    ulong chainNumber;
    /// Whether this request created the chain.
    bool createdChain;
}

/// A request that intake refused or could not finish. `recorded` is set only for `reconcileFailed`.
class IntakeException : Exception
{
    IntakeFailure failure;
    IntakeResult recorded;

    this(IntakeFailure failure, string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line, cause);
        this.failure = failure;
    }
}

/**
 * What a manual request asks for. `chainId` or `chainNumber` (at most one) names an existing chain
 * of the project; neither creates a new chain. `refs` maps a repository id to the ref name to use
 * for every input of that repository; a repository it does not name uses the inputs' defaults.
 * `pins` are supplied revisions, taken as given instead of resolving.
 */
struct IntakeRequest
{
    string projectId;
    string[] targets;
    BuildIntent intent;
    string chainId;
    ulong chainNumber;
    string[string] refs;
    RepositoryPin[] pins;
    string requestedBy;
}

/// A ref as chosen for an input. `kind` is null when it was named without one.
struct RefChoice
{
    string name;
    Nullable!RefKind kind;
}

/// The ref a new chain's headline is taken from: `name` in repository `repositoryId`.
struct HeadlineChoice
{
    string repositoryId;
    string name;
}

/// The ref a repository's inputs agree to default to, for prefilling a request form; empty when
/// the inputs have no fixed default or disagree.
struct RepositoryDefault
{
    string repositoryId;
    string defaultRef;
}

/// The ref kind `kind` of a headline names, null for the headline `default`.
Nullable!RefKind refKindOf(HeadlineKind kind) pure nothrow @safe
{
    final switch (kind)
    {
        case HeadlineKind.branch: return nullable(RefKind.branch);
        case HeadlineKind.tag: return nullable(RefKind.tag);
        case HeadlineKind.changeRequest: return nullable(RefKind.changeRequest);
        case HeadlineKind.revision: return nullable(RefKind.revision);
        case HeadlineKind.default_: return Nullable!RefKind.init;
    }
}

/// Returns the ids of the repositories `graph`'s repository inputs name, sorted.
string[] repositoriesOf(const TaskGraph graph) @trusted
{
    bool[string] distinct;
    foreach (taskId; graph.allTaskIds())
    {
        foreach (decl; graph.getTask(taskId).inputs.byValue)
        {
            if (decl.kind == InputKind.repository) distinct[decl.spec.repository] = true;
        }
    }
    return distinct.keys.sort().release;
}

/**
 * Returns the ref each repository input of `graph` is bound to, keyed by input: the ref of
 * `requestRefs` for the input's repository, else the ref the chain recorded for the input
 * (`chainBindings`, used only when `chainPins` pins it in the input's repository now; none for a
 * new chain), else the input's default ref spec (a fixed ref, or
 * `same` as `headline`'s ref). Pure.
 *
 * Throws: InputResolutionException naming the task and input if an input is malformed or has no
 * ref (the request names none for its repository and it has no default), or its default is `same`
 * and `headline` is null or the headline `default`, or `same` with a fallback, which intake does not
 * support.
 */
RefChoice[InputKey] chooseRefs(const TaskGraph graph, in string[string] requestRefs, in InputBinding[] chainBindings,
    in RepositoryPin[] chainPins, in Nullable!HeadlineRef headline) @trusted
{
    const bound = bindingMap(chainBindings);
    const pinned = pinMap(chainPins);
    RefChoice[InputKey] choices;
    foreach (taskId; graph.allTaskIds())
    {
        const task = graph.getTask(taskId);
        foreach (name; task.inputs.keys.sort().release)
        {
            const decl = task.inputs[name];
            if (decl.kind != InputKind.repository) continue;
            requireRepositorySpec(taskId, name, decl);
            choices[InputKey(taskId, name)] = chooseRef(taskId, name, decl, requestRefs, bound, pinned, headline);
        }
    }
    return choices;
}

private RefChoice chooseRef(string taskId, string name, in InputDecl decl, in string[string] requestRefs,
    in RepositoryRef[InputKey] chainBindings, in RepositoryPin[RepositoryAt] chainPins, in Nullable!HeadlineRef headline) @trusted
{
    const repository = decl.spec.repository;
    if (auto requested = repository in requestRefs) return RefChoice(*requested);
    // The chain's binding counts only for the repository it was made for: an input the definition
    // has pointed at another repository since falls back to its default
    if (auto recorded = InputKey(taskId, name) in chainBindings)
    {
        if (RepositoryAt(repository, *recorded) in chainPins) return RefChoice(recorded.name, nullable(cast(RefKind) recorded.kind));
    }

    const spec = decl.spec.defaultRef;
    final switch (spec.kind)
    {
        case RefSpecKind.none:
        case RefSpecKind.event:
            throw new InputResolutionException(format(
                "Task '%s' input '%s' (repository '%s') has no ref: the request names none for the repository and the input has no default ref",
                taskId, name, repository), taskId, name);
        case RefSpecKind.fixed:
            return RefChoice(spec.refName);
        case RefSpecKind.same:
            if (spec.fallback != RefFallback.none)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s') defaults to '%s', whose fallback intake does not support; name a ref for the repository in the request",
                    taskId, name, repository, spec.toString()), taskId, name);
            }
            if (headline.isNull || refKindOf(headline.get.kind).isNull)
            {
                throw new InputResolutionException(format(
                    "Task '%s' input '%s' (repository '%s') defaults to 'same', but the build has no headline ref to take the name from; name a ref for the repository in the request",
                    taskId, name, repository), taskId, name);
            }
            return RefChoice(headline.get.name, refKindOf(headline.get.kind));
    }
}

/**
 * Returns the ref a new chain's headline is taken from: the first repository (by id) of `graph`
 * that `requestRefs` or a fixed default gives a ref for. Null when `graph` has no repository
 * inputs (the chain's headline is `default`). Pure.
 *
 * Throws: InputResolutionException if `graph` has repository inputs and none has a ref to take a
 * headline from; it names the first input without a ref, as `chooseRefs` does.
 */
Nullable!HeadlineChoice headlineChoice(const TaskGraph graph, in string[string] requestRefs) @trusted
{
    string[string] fixedDefault;
    foreach (taskId; graph.allTaskIds())
    {
        const task = graph.getTask(taskId);
        foreach (name; task.inputs.keys.sort().release)
        {
            const decl = task.inputs[name];
            if (decl.kind != InputKind.repository) continue;
            if (decl.spec.defaultRef.kind == RefSpecKind.fixed && decl.spec.repository !in fixedDefault)
            {
                fixedDefault[decl.spec.repository] = decl.spec.defaultRef.refName;
            }
        }
    }

    const repositories = repositoriesOf(graph);
    if (repositories.length == 0) return Nullable!HeadlineChoice.init;
    foreach (repository; repositories)
    {
        if (auto requested = repository in requestRefs) return nullable(HeadlineChoice(repository, *requested));
        if (auto fixed = repository in fixedDefault) return nullable(HeadlineChoice(repository, *fixed));
    }
    // No repository has a ref to take the headline from: report the first input that has none
    chooseRefs(graph, requestRefs, null, null, Nullable!HeadlineRef.init);
    throw new InputResolutionException(format(
        "Cannot choose the headline ref of a new build: none of the repositories [%-(%s, %)] has a ref in the request or a fixed default; name a ref for one",
        repositories));
}

/**
 * Returns, for each repository `definition` uses (sorted by id), the ref all its inputs default
 * to when they agree on a fixed ref, else empty: what a request form prefills.
 */
RepositoryDefault[] repositoryDefaults(in ProjectDefinition definition) @trusted
{
    string[string] defaults;
    foreach (ref task; definition.tasks)
    {
        foreach (decl; task.inputs.byValue)
        {
            if (decl.kind != InputKind.repository) continue;
            const spec = decl.spec.defaultRef;
            const text = spec.kind == RefSpecKind.fixed ? spec.refName : "";
            auto known = decl.spec.repository in defaults;
            if (known is null) defaults[decl.spec.repository] = text;
            else if (*known != text) *known = "";
        }
    }
    RepositoryDefault[] result;
    foreach (repository; defaults.keys.sort().release) result ~= RepositoryDefault(repository, defaults[repository]);
    return result;
}

/// A name in a repository, as a request or an input default writes it, without a kind.
private struct NameKey
{
    string repositoryId;
    string name;
}

/**
 * The revisions one intake works with and the resolver that supplies the missing ones. Resolves each
 * (repository, ref) at most once, and takes each pin from the supplied pins, else the chain's, else
 * the resolver.
 */
private final class PinSource
{
    private RepositoryStore m_repositories;
    private RepositoryResolver m_resolver;
    private RepositoryPin[] m_supplied;
    private RepositoryPin[] m_chainPins;
    private InputPin[RepositoryAt] m_resolved;
    private RepositoryRef[NameKey] m_named;

    this(RepositoryStore repositories, RepositoryResolver resolver, RepositoryPin[] supplied)
    {
        m_repositories = repositories;
        m_resolver = resolver;
        m_supplied = supplied;
    }

    /// Sets the chain's pins as last read.
    void chainPins(RepositoryPin[] pins)
    {
        m_chainPins = pins;
    }

    /// Whether the request supplied a pin of `at`.
    bool supplied(in RepositoryAt at)
    {
        foreach (ref pin; m_supplied)
        {
            if (repositoryAt(pin) == at) return true;
        }
        return false;
    }

    /**
     * Returns the ref `choice` names in repository `repositoryId`: its kind if it has one, else the
     * kind of a supplied or chain pin of that name, else the one the resolver finds.
     *
     * Throws: IntakeException (refused) if the name is ambiguous or cannot be resolved.
     */
    RepositoryRef concretize(string repositoryId, in RefChoice choice)
    {
        if (!choice.kind.isNull) return RepositoryRef(choice.kind.get, choice.name);

        RepositoryRef[] known;
        foreach (ref pin; m_supplied ~ m_chainPins)
        {
            if (pin.repositoryId == repositoryId && pin.ref_.name == choice.name && !known.canFind(pin.ref_)) known ~= pin.ref_;
        }
        if (known.length > 1)
        {
            throw new IntakeException(IntakeFailure.refused, format(
                "Repository '%s' has %-(%s and %) named '%s'; the build cannot choose between them",
                repositoryId, known.map!(r => format("a %s", cast(string) r.kind)).array, choice.name));
        }
        if (known.length == 1) return known[0];

        const key = NameKey(repositoryId, choice.name);
        if (auto resolved = key in m_named) return *resolved;
        const record = repositoryRecord(repositoryId);
        ResolvedRef found;
        try found = m_resolver.resolveName(record, choice.name);
        catch (Exception e)
        {
            throw new IntakeException(IntakeFailure.refused, format("Cannot resolve repository '%s' at '%s': %s",
                repositoryId, choice.name, e.msg), e);
        }
        requireUsable(repositoryId, found);
        m_resolved[RepositoryAt(repositoryId, found.ref_)] = found.pin;
        m_named[key] = found.ref_;
        return found.ref_;
    }

    /**
     * Returns the revision of each of `refs` (sorted), resolving those that no supplied pin, no
     * chain pin and no earlier resolution covers.
     *
     * Throws: IntakeException (refused) if a repository is unknown or a ref cannot be resolved.
     */
    InputPin[RepositoryAt] revisionsOf(in RepositoryAt[] refs)
    {
        foreach (at; refs)
        {
            if (supplied(at) || chainPinned(at) || at in m_resolved) continue;
            const record = repositoryRecord(at.repositoryId);
            ResolvedRef found;
            try found = m_resolver.resolve(record, at.ref_);
            catch (Exception e)
            {
                throw new IntakeException(IntakeFailure.refused, format("Cannot resolve %s: %s", describeRepositoryAt(at), e.msg), e);
            }
            requireUsable(at.repositoryId, found);
            if (found.ref_ != at.ref_)
            {
                throw new IntakeException(IntakeFailure.refused, format("Resolving %s found %s '%s' instead", describeRepositoryAt(at),
                    cast(string) found.ref_.kind, found.ref_.name));
            }
            m_resolved[at] = found.pin;
        }

        InputPin[RepositoryAt] revisions;
        foreach (at, pin; m_resolved) revisions[at] = pin;
        foreach (ref pin; m_chainPins) revisions[repositoryAt(pin)] = pin.pin;
        foreach (ref pin; m_supplied) revisions[repositoryAt(pin)] = pin.pin;
        return revisions;
    }

    private bool chainPinned(in RepositoryAt at)
    {
        foreach (ref pin; m_chainPins)
        {
            if (repositoryAt(pin) == at) return true;
        }
        return false;
    }

    private RepositoryRecord repositoryRecord(string repositoryId)
    {
        auto record = m_repositories.get(repositoryId);
        if (record.isNull)
        {
            throw new IntakeException(IntakeFailure.refused, format("Repository '%s' is not registered", repositoryId));
        }
        return record.get.value;
    }

    private static void requireUsable(string repositoryId, in ResolvedRef found)
    {
        if (found.ref_.name.length == 0 || isEmptyPinned(found.pin.pinned))
        {
            throw new IntakeException(IntakeFailure.refused, format("The resolver returned no ref or no revision for repository '%s'", repositoryId));
        }
    }
}

/**
 * Turns manual requests into recorded, reconciled BuildRequests. See the module documentation.
 */
final class RequestIntake
{
    /// How many times a request on an existing chain reads the chain again after another request
    /// pinned a ref first. Each retry follows a pin that landed, and pins never change, so a pin
    /// is lost at most once.
    enum maxPinAttempts = 10;

    private StateStores m_stores;
    private RepositoryResolver m_resolver;
    private string delegate() m_now;
    private string delegate(string) m_newId;
    private RequestReconciler m_reconciler;

    /// Intake over `stores`, resolving refs with `resolver`. `now` (default `utcNow`) is the clock
    /// and `newId` (default a random UUID after the prefix) makes request and chain ids.
    this(StateStores stores, RepositoryResolver resolver, string delegate() now = null, string delegate(string prefix) newId = null)
    {
        if (stores is null) throw new Exception("Request intake requires the state stores");
        if (resolver is null) throw new Exception("Request intake requires a repository resolver");
        m_stores = stores;
        m_resolver = resolver;
        m_now = now !is null ? now : () => utcNow();
        m_newId = newId !is null ? newId : (string prefix) => prefix ~ "_" ~ randomUUID().toString();
        m_reconciler = new RequestReconciler(stores, m_now);
    }

    /**
     * Records `request`, creates its state and reconciles it. See the module documentation.
     *
     * Throws: IntakeException: notFound for an unknown project or chain, invalid for a malformed
     * request, refused when a ref cannot be bound or resolved, conflict when a supplied pin
     * disagrees with the chain, reconcileFailed when the request was recorded but reconciling it
     * failed; whatever the stores throw.
     */
    IntakeResult intake(in IntakeRequest request)
    {
        requireWellFormed(request);
        auto project = m_stores.projects.get(request.projectId);
        if (project.isNull) throw new IntakeException(IntakeFailure.notFound, format("Project '%s' does not exist", request.projectId));

        auto existing = findChain(request);
        const definition = currentDefinition(project.get.value);
        string definitionId;
        try definitionId = m_stores.definitions.put(definition);
        catch (InvalidDefinitionException e)
        {
            throw new IntakeException(IntakeFailure.refused, format("The definition of project '%s' is invalid: %s", request.projectId, e.msg), e);
        }
        foreach (target; request.targets)
        {
            if (!definition.tasks.canFind!(t => t.id == target))
            {
                throw new IntakeException(IntakeFailure.refused, format("Target '%s' is not a task of project '%s'", target, request.projectId));
            }
        }

        try return record(request, project.get.value.id, definition, definitionId, existing);
        catch (InputResolutionException e) throw new IntakeException(IntakeFailure.refused, e.msg, e);
    }

    private IntakeResult record(in IntakeRequest request, string projectId, in ProjectDefinition definition, string definitionId,
        Nullable!(Versioned!BuildChain) existing)
    {
        auto full = new TaskGraph(definition.tasks);
        auto closure = closureGraph(definition, request.targets);
        const known = repositoriesOf(full);
        foreach (repository; request.refs.keys.sort().release)
        {
            if (!known.canFind(repository))
            {
                throw new IntakeException(IntakeFailure.refused, format(
                    "The request names a ref for repository '%s', which no input of project '%s' uses", repository, projectId));
            }
        }

        RepositoryPin[] supplied;
        try supplied = sortPins(request.pins);
        catch (InvalidPinsException e) throw new IntakeException(IntakeFailure.invalid, e.msg, e);
        auto source = new PinSource(m_stores.repositories, m_resolver, supplied);
        if (!existing.isNull) source.chainPins(existing.get.pins);

        // Bind every input the chain's pins must cover: the whole definition for a new chain
        // (its snapshot), the request's closure on an existing one
        Nullable!HeadlineRef headline;
        const snapshot = existing.isNull;
        HeadlineRef newHeadline;
        if (snapshot)
        {
            auto choice = headlineChoice(full, request.refs);
            if (choice.isNull) newHeadline = defaultHeadline();
            else newHeadline = headlineOf(choice.get.repositoryId, source.concretize(choice.get.repositoryId, RefChoice(choice.get.name)));
            headline = newHeadline;
        }
        else
        {
            headline = existing.get.headline;
        }
        const bound = snapshot ? full : closure;
        auto choices = chooseRefs(bound, request.refs, snapshot ? null : existing.get.bindings, snapshot ? null : existing.get.pins, headline);
        InputBinding[] allBindings;
        foreach (key; choices.keys.sort!((a, b) => inputKeyLess(a, b)))
        {
            const repository = bound.getTask(key.taskId).inputs[key.input].spec.repository;
            allBindings ~= InputBinding(key.taskId, key.input, source.concretize(repository, choices[key]));
        }

        const chainRefs = refsOf(requiredPins(bound, bindingMap(allBindings)));
        InputBinding[] bindings;
        const covered = closure.allTaskIds();
        foreach (ref binding; allBindings)
        {
            if (covered.canFind(binding.taskId)) bindings ~= binding;
        }
        const requestRefs = refsOf(requiredPins(closure, bindingMap(bindings)));
        foreach (ref pin; supplied)
        {
            if (!chainRefs.canFind(repositoryAt(pin)))
            {
                throw new IntakeException(IntakeFailure.refused, format(
                    "The request supplies a pin of %s, which none of the inputs it binds uses", describeRepositoryAt(repositoryAt(pin))));
            }
        }

        BuildChain chain;
        bool created = false;
        if (snapshot)
        {
            auto revisions = source.revisionsOf(chainRefs);
            auto pins = pinsForRefs(chainRefs, revisions);
            chain.id = m_newId("chain");
            chain.projectId = projectId;
            chain.number = m_stores.chains.nextNumber(projectId);
            chain.headline = newHeadline;
            chain.pins = pins;
            chain.bindings = allBindings;
            chain.createdAt = m_now();
            chain = m_stores.chains.create(chain).value;
            created = true;
        }
        else
        {
            chain = pinChain(existing.get.id, chainRefs, bindings, source);
        }

        auto requestPins = selectPins(chain.pins, requestRefs);
        auto resolution = readGraphResolution(projectId, closure, bindingMap(bindings), pinMap(requestPins), (in string[] bases) => m_stores.rerunGenerations.read(bases));
        if (request.intent == BuildIntent.rerun)
        {
            m_stores.rerunGenerations.bump(resolution.bases[request.targets[0]]);
            resolution = readGraphResolution(projectId, closure, bindingMap(bindings), pinMap(requestPins), (in string[] bases) => m_stores.rerunGenerations.read(bases));
        }
        ulong[string] stopSeqs;
        foreach (fingerprint; resolution.fingerprints.byValue)
        {
            auto settled = m_stores.ledgers.settle(fingerprint);
            stopSeqs[fingerprint] = settled.isNull ? 0 : settled.get.stopSeq;
        }

        BuildRequest recorded;
        recorded.id = m_newId("req");
        recorded.projectId = projectId;
        recorded.chainId = chain.id;
        recorded.targets = request.targets.dup;
        recorded.intent = request.intent;
        recorded.trigger.type = TriggerType.manual;
        recorded.pins = requestPins;
        recorded.bindings = bindings;
        recorded.definitionId = definitionId;
        recorded.definitionSource = DefinitionSource(DefinitionLocation.confector);
        recorded.demands = requestDemands(resolution, stopSeqs);
        recorded.requestedBy = request.requestedBy;
        recorded.requestedAt = m_now();
        m_stores.requests.create(recorded);
        m_stores.requestStates.createFor(recorded);

        const result = IntakeResult(recorded.id, chain.id, chain.number, created);
        try m_reconciler.reconcile(recorded.id);
        catch (Exception e)
        {
            auto failure = new IntakeException(IntakeFailure.reconcileFailed, format(
                "Request '%s' of build #%s was recorded, but reconciling it failed (the sweep will try again): %s",
                recorded.id, chain.number, e.msg), e);
            failure.recorded = result;
            throw failure;
        }
        return result;
    }

    /// Adds the pins of `refs` and the first bindings of `bindings` to chain `chainId` in one write
    /// and returns the chain as stored. A pin another
    /// request added first is taken from the chain instead of the one resolved here; a supplied
    /// pin that disagrees with the chain is a conflict.
    private BuildChain pinChain(string chainId, in RepositoryAt[] refs, in InputBinding[] bindings, PinSource source)
    {
        foreach (attempt; 0 .. maxPinAttempts)
        {
            auto chain = m_stores.chains.get(chainId);
            if (chain.isNull) throw new IntakeException(IntakeFailure.notFound, format("Chain '%s' does not exist", chainId));
            source.chainPins(chain.get.pins);
            auto pins = pinsForRefs(refs, source.revisionsOf(refs));
            if (chain.get.headline.kind == HeadlineKind.default_ && pins.length > 0)
            {
                throw new IntakeException(IntakeFailure.refused, format(
                    "Chain '%s' (build #%s) has no repositories, so it cannot pin repository '%s'; start a new build",
                    chainId, chain.get.number, pins[0].repositoryId));
            }
            try return m_stores.chains.addPins(chainId, pins, bindings).value;
            catch (PinConflictException e)
            {
                if (source.supplied(e.key)) throw new IntakeException(IntakeFailure.conflict, e.msg, e);
                // Another request pinned the ref first; the next read takes its pin
            }
        }
        throw new IntakeException(IntakeFailure.conflict, format(
            "Could not add pins to chain '%s': other requests pinned its refs first %s times in a row", chainId, maxPinAttempts));
    }

    private Nullable!(Versioned!BuildChain) findChain(in IntakeRequest request)
    {
        if (request.chainId.length == 0 && request.chainNumber == 0) return Nullable!(Versioned!BuildChain).init;
        auto found = request.chainId.length > 0
            ? m_stores.chains.get(request.chainId) : m_stores.chains.findByNumber(request.projectId, request.chainNumber);
        const named = request.chainId.length > 0 ? format("Chain '%s'", request.chainId) : format("Build #%s", request.chainNumber);
        if (found.isNull || found.get.projectId != request.projectId)
        {
            throw new IntakeException(IntakeFailure.notFound, format("%s does not exist in project '%s'", named, request.projectId));
        }
        return found;
    }

    private static void requireWellFormed(in IntakeRequest request)
    {
        void invalid(string message) { throw new IntakeException(IntakeFailure.invalid, message); }

        if (request.projectId.length == 0) invalid("The request names no project");
        if (request.requestedBy.length == 0) invalid("The request names no identity that made it");
        if (request.targets.length == 0) invalid("The request names no target");
        foreach (i, target; request.targets)
        {
            if (target.length == 0) invalid("The request has an empty target");
            if (request.targets[0 .. i].canFind(target)) invalid(format("The request targets task '%s' twice", target));
        }
        if (request.chainId.length > 0 && request.chainNumber != 0) invalid("The request names its chain by id and by number; name one");
        const named = request.chainId.length > 0 || request.chainNumber != 0;
        if (request.intent != BuildIntent.build && !named)
        {
            invalid(format("A %s runs in an existing chain; name its chain", cast(string) request.intent));
        }
        if (request.intent == BuildIntent.rerun && request.targets.length != 1) invalid("A rerun names exactly the one task to rerun");
        foreach (repository, name; request.refs)
        {
            if (repository.length == 0 || name.length == 0) invalid("The request has a ref without a repository or without a name");
        }
    }
}

version (unittest)
{
    import confector.core.git_resolver : GitRepositoryResolver;
    import confector.testing.fake_repository_resolver : FakeRepositoryResolver;
    import vibe.data.json : Json;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;

    private struct World
    {
        StateStores stores;
        FakeRepositoryResolver resolver;
        RequestIntake intake;
        InterleavingDocumentStore documents;
    }

    /// Stores with repositories game, docs and assets, a project "game" (compile and test over
    /// repository game at main, docs over repository docs at main), and a resolver that knows
    /// their main branches and game's release branch.
    private World world()
    {
        World w;
        w.documents = new InterleavingDocumentStore(new InMemoryDocumentStore());
        w.stores = new StateStores(w.documents);
        foreach (name; ["game", "docs", "assets"])
        {
            RepositoryRecord record;
            record.name = name;
            record.address = "https://example.test/" ~ name ~ ".git";
            w.stores.repositories.put(record);
        }
        setTasks(w, gameTasks());
        w.resolver = new FakeRepositoryResolver();
        w.resolver.add("game", "main", "aaa111");
        w.resolver.add("game", "release", "rel111");
        w.resolver.add("docs", "main", "ddd111");
        w.resolver.add("assets", "main", "sss111");
        w.intake = intakeOf(w.stores, w.resolver);
        return w;
    }

    private RequestIntake intakeOf(StateStores stores, RepositoryResolver resolver)
    {
        auto counter = new size_t[1];
        return new RequestIntake(stores, resolver, () => "2026-10-20T10:00:00Z", (string prefix) => format("%s_%s", prefix, ++counter[0]));
    }

    private TaskNode taskOf(string id, string[string] repositories, string[] upstream = null, string defaultRef = "main")
    {
        TaskNode task;
        task.id = id;
        foreach (name, repository; repositories)
        {
            task.inputs[name] = repositoryInput(repository, defaultRef.length > 0 ? RefSpec.fromString(defaultRef) : RefSpec.init);
        }
        foreach (dependency; upstream) task.inputs[dependency] = taskOutputInput(dependency);
        task.steps = [BuildStep("Run", "bash", Json(["script": Json("make " ~ id)]))];
        return task;
    }

    private TaskNode[] gameTasks()
    {
        return [taskOf("compile", ["src": "game"]), taskOf("test", null, ["compile"]), taskOf("docs", ["pages": "docs"])];
    }

    private void setTasks(ref World w, TaskNode[] tasks)
    {
        ProjectRecord project;
        project.id = "game";
        project.tasks = tasks;
        w.stores.projects.put(project);
    }

    private IntakeRequest build(string[] targets, ulong chainNumber = 0)
    {
        IntakeRequest request;
        request.projectId = "game";
        request.targets = targets;
        request.chainNumber = chainNumber;
        request.requestedBy = "jason";
        return request;
    }

    private RepositoryPin pinOf(string repository, string name, string sha, RefKind kind = RefKind.branch)
    {
        return RepositoryPin(repository, RepositoryRef(kind, name), InputPin(Json(sha)));
    }

    /// The failure `action` raises, or fails the test if it raises none.
    private IntakeException refusedBy(scope void delegate() action)
    {
        try action();
        catch (IntakeException e) return e;
        assert(false, "Intake accepted the request");
    }

    private TaskDemand demandOf(in BuildRequest request, string taskId)
    {
        foreach (ref demand; request.demands)
        {
            if (demand.taskId == taskId) return cast(TaskDemand) demand;
        }
        assert(false, "no demand for " ~ taskId);
    }
}

unittest
{
    // A new chain is a snapshot: it pins the refs of tasks the request does not run, each once; the
    // request's own pins are those of its closure; its state is open and the needed fingerprint is
    // claimed by the reconcile that follows
    auto w = world();
    const result = w.intake.intake(build(["test"]));
    assert(result.createdChain && result.chainNumber == 1 && result.chainId == "chain_1" && result.requestId == "req_2");

    const chain = w.stores.chains.get(result.chainId).get.value;
    assert(chain.number == 1 && chain.projectId == "game" && chain.createdAt == "2026-10-20T10:00:00Z");
    assert(chain.headline == HeadlineRef(HeadlineKind.branch, "main"));
    assert(chain.pins == [pinOf("docs", "main", "ddd111"), pinOf("game", "main", "aaa111")], "Pins of tasks the request does not run");
    assert(w.resolver.log == ["docs/main", "game/main"], "Each distinct ref is resolved once");

    const request = w.stores.requests.get(result.requestId).get.value;
    assert(request.chainId == chain.id && request.targets == ["test"] && request.intent == BuildIntent.build);
    assert(request.trigger.type == TriggerType.manual && request.requestedBy == "jason");
    assert(request.pins == [pinOf("game", "main", "aaa111")], "The request holds the pins of its own bindings");
    assert(request.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "main"))]);
    assert(request.definitionSource.location == DefinitionLocation.confector);
    assert(!w.stores.definitions.get(request.definitionId).isNull);
    assert(request.demands.length == 2);

    auto state = w.stores.requestStates.get(result.requestId).get.value;
    assert(state.outcome == RequestOutcome.open && state.tasks.length == 2, "The request was reconciled");
    const compile = w.stores.ledgers.get(demandOf(request, "compile").fingerprint);
    assert(!compile.isNull && !compile.get.active.isNull, "An execution is claimed for the needed fingerprint");
    assert(w.stores.ledgers.get(demandOf(request, "test").fingerprint).isNull, "Downstream waits for compile");
}

unittest
{
    // A later request on a named chain reuses the chain's pins and resolves nothing; a task added
    // to the definition later gets the chain's revision; an input the chain lacks is resolved and
    // added
    auto w = world();
    const first = w.intake.intake(build(["test"]));
    const firstRequest = w.stores.requests.get(first.requestId).get.value;
    w.resolver.add("game", "main", "bbb222");
    const resolved = w.resolver.log.length;

    const second = w.intake.intake(build(["test"], 1));
    assert(!second.createdChain && second.chainId == first.chainId && second.chainNumber == 1);
    const secondRequest = w.stores.requests.get(second.requestId).get.value;
    assert(secondRequest.pins == [pinOf("game", "main", "aaa111")], "The chain's revision, not what main is now");
    assert(demandOf(secondRequest, "compile").fingerprint == demandOf(firstRequest, "compile").fingerprint);
    assert(w.resolver.log.length == resolved, "Nothing the chain pins is resolved again");
    assert(w.stores.chains.get(first.chainId).get.pins.length == 2);

    setTasks(w, gameTasks() ~ taskOf("lint", ["src": "game"]) ~ taskOf("package", ["files": "assets"]));
    const lint = w.intake.intake(build(["lint"], 1));
    const lintRequest = w.stores.requests.get(lint.requestId).get.value;
    assert(lintRequest.pins == [pinOf("game", "main", "aaa111")], "A task added later builds the chain's revision");
    assert(w.resolver.log.length == resolved);

    const added = w.intake.intake(build(["package"], 1));
    assert(w.resolver.log[resolved .. $] == ["assets/main"], "Only the missing ref is resolved");
    assert(w.stores.chains.get(added.chainId).get.pins == [pinOf("assets", "main", "sss111"), pinOf("docs", "main", "ddd111"), pinOf("game", "main", "aaa111")]);
    assert(w.stores.requests.get(added.requestId).get.pins == [pinOf("assets", "main", "sss111")]);
}

unittest
{
    // Binding an input to another ref than the chain built it at adds a pin for that ref
    auto w = world();
    w.intake.intake(build(["test"]));
    auto request = build(["test"], 1);
    request.refs["game"] = "release";
    const result = w.intake.intake(request);

    assert(w.stores.chains.get(result.chainId).get.pins == [pinOf("docs", "main", "ddd111"), pinOf("game", "main", "aaa111"), pinOf("game", "release", "rel111")]);
    const recorded = w.stores.requests.get(result.requestId).get.value;
    assert(recorded.pins == [pinOf("game", "release", "rel111")]);
    assert(recorded.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release"))]);
}

unittest
{
    // A new chain binds the request's refs
    auto w = world();
    auto request = build(["test"]);
    request.refs["game"] = "release";
    const result = w.intake.intake(request);
    const chain = w.stores.chains.get(result.chainId).get.value;
    assert(chain.pins == [pinOf("docs", "main", "ddd111"), pinOf("game", "release", "rel111")]);
    assert(chain.headline == HeadlineRef(HeadlineKind.branch, "main"), "docs sorts first and defaults to main");

    // A tag named by the request is a tag; a supplied pin is used instead of resolving
    auto tagged = world();
    tagged.resolver.add("game", "v1", "ttt111", RefKind.tag);
    auto byTag = build(["test"]);
    byTag.refs["game"] = "v1";
    byTag.pins = [pinOf("docs", "main", "supplied")];
    const tagResult = tagged.intake.intake(byTag);
    const tagChain = tagged.stores.chains.get(tagResult.chainId).get.value;
    assert(tagChain.pins == [pinOf("docs", "main", "supplied"), pinOf("game", "v1", "ttt111", RefKind.tag)]);
    assert(tagged.resolver.log == ["game/v1"], "A supplied pin is never resolved");
}

unittest
{
    // A ref of a task the request does not run that cannot be resolved fails the request: no
    // chain, no number, no request
    auto w = world();
    w.resolver.failing["docs/main"] = true;
    auto failure = refusedBy({ w.intake.intake(build(["test"])); });
    assert(failure.failure == IntakeFailure.refused && failure.msg.canFind("'docs'") && failure.msg.canFind("main"), failure.msg);
    assert(w.stores.chains.listForProject("game", 10).length == 0 && w.stores.requests.listForProject("game", 10).length == 0);
    assert(w.stores.chains.nextNumber("game") == 1, "No number was allocated");

    // So does a ref that does not exist, and an unregistered repository
    auto missing = world();
    missing.resolver.remove("game", "main");
    assert(refusedBy({ missing.intake.intake(build(["test"])); }).msg.canFind("game/main"));
    auto unregistered = world();
    unregistered.stores.repositories.remove("docs");
    assert(refusedBy({ unregistered.intake.intake(build(["test"])); }).msg.canFind("Repository 'docs' is not registered"));
    assert(unregistered.stores.chains.listForProject("game", 10).length == 0);
}

unittest
{
    // A rerun bumps the target's rerun generation before the request is recorded, so it and its
    // downstream tasks get new fingerprints
    auto w = world();
    const first = w.intake.intake(build(["test"]));
    const firstRequest = w.stores.requests.get(first.requestId).get.value;
    const base = demandOf(firstRequest, "compile").base;
    assert(w.stores.rerunGenerations.read([base])[base] == 0);

    auto rerun = build(["compile"], 1);
    rerun.intent = BuildIntent.rerun;
    const result = w.intake.intake(rerun);
    assert(w.stores.rerunGenerations.read([base])[base] == 1);
    const recorded = w.stores.requests.get(result.requestId).get.value;
    assert(recorded.intent == BuildIntent.rerun && demandOf(recorded, "compile").generation == 1);
    assert(demandOf(recorded, "compile").fingerprint != demandOf(firstRequest, "compile").fingerprint);

    // A retry in the chain keeps the fingerprints
    auto retry = build(["test"], 1);
    retry.intent = BuildIntent.retry;
    const retried = w.stores.requests.get(w.intake.intake(retry).requestId).get.value;
    assert(demandOf(retried, "compile").generation == 1 && demandOf(retried, "compile").fingerprint == demandOf(recorded, "compile").fingerprint);
}

unittest
{
    // A supplied pin that disagrees with the chain's is a conflict; one that no binding uses is refused
    auto w = world();
    w.intake.intake(build(["test"]));
    auto conflicting = build(["test"], 1);
    conflicting.pins = [pinOf("game", "main", "zzz999")];
    auto conflict = refusedBy({ w.intake.intake(conflicting); });
    assert(conflict.failure == IntakeFailure.conflict && conflict.msg.canFind("zzz999") && conflict.msg.canFind("aaa111"), conflict.msg);

    auto unused = build(["test"], 1);
    unused.pins = [pinOf("game", "dev", "ddd999")];
    assert(refusedBy({ w.intake.intake(unused); }).failure == IntakeFailure.refused);

    auto malformed = build(["test"], 1);
    malformed.pins = [pinOf("game", "main", "aaa111"), pinOf("game", "main", "bbb222")];
    assert(refusedBy({ w.intake.intake(malformed); }).failure == IntakeFailure.invalid);
}

unittest
{
    // Another request pinning a ref first is not an error: its pin is taken from the chain
    auto w = world();
    const first = w.intake.intake(build(["test"]));
    auto request = build(["test"], 1);
    request.refs["game"] = "release";
    w.documents.beforeNextWrite = () {
        w.stores.chains.addPins(first.chainId, [pinOf("game", "release", "rival11")]);
    };
    const result = w.intake.intake(request);
    assert(w.stores.requests.get(result.requestId).get.pins == [pinOf("game", "release", "rival11")]);
    assert(w.stores.chains.get(first.chainId).get.pins.length == 3);
}

unittest
{
    // Requests that cannot be taken, with the failure each is
    auto w = world();
    w.intake.intake(build(["test"]));
    IntakeFailure failureOf(IntakeRequest request)
    {
        return refusedBy({ w.intake.intake(request); }).failure;
    }

    auto unknownProject = build(["test"]);
    unknownProject.projectId = "nope";
    assert(failureOf(unknownProject) == IntakeFailure.notFound);
    assert(failureOf(build(["test"], 7)) == IntakeFailure.notFound);
    auto unknownChain = build(["test"]);
    unknownChain.chainId = "chain_nope";
    assert(failureOf(unknownChain) == IntakeFailure.notFound);

    assert(failureOf(build(null)) == IntakeFailure.invalid);
    assert(failureOf(build(["test", "test"])) == IntakeFailure.invalid);
    auto both = build(["test"], 1);
    both.chainId = "chain_1";
    assert(failureOf(both) == IntakeFailure.invalid);
    auto retryWithoutChain = build(["test"]);
    retryWithoutChain.intent = BuildIntent.retry;
    assert(failureOf(retryWithoutChain) == IntakeFailure.invalid);
    auto rerunTwo = build(["test", "docs"], 1);
    rerunTwo.intent = BuildIntent.rerun;
    assert(failureOf(rerunTwo) == IntakeFailure.invalid);

    assert(failureOf(build(["nope"], 1)) == IntakeFailure.refused);
    auto unknownRepository = build(["test"]);
    unknownRepository.refs["nope"] = "main";
    assert(failureOf(unknownRepository) == IntakeFailure.refused);

    // A chain of another project does not exist for this one
    ProjectRecord other;
    other.id = "other";
    other.tasks = [taskOf("a", null)];
    w.stores.projects.put(other);
    auto otherRequest = build(["a"]);
    otherRequest.projectId = "other";
    const otherChain = w.intake.intake(otherRequest);
    auto crossed = build(["test"]);
    crossed.chainId = otherChain.chainId;
    assert(failureOf(crossed) == IntakeFailure.notFound);
}

unittest
{
    // An input with no default and no ref in the request fails loudly, naming the task and input
    auto w = world();
    setTasks(w, [taskOf("compile", ["src": "game"], null, "")]);
    auto failure = refusedBy({ w.intake.intake(build(["compile"])); });
    assert(failure.failure == IntakeFailure.refused && failure.msg.canFind("'compile'") && failure.msg.canFind("'src'"), failure.msg);
    assert(w.stores.chains.listForProject("game", 10).length == 0);

    // The request's ref for the repository supplies it
    auto named = build(["compile"]);
    named.refs["game"] = "main";
    assert(w.intake.intake(named).createdChain);

    // An input that defaults to `same` takes the chain's headline; a new chain has none for it
    // unless another input or the request names a ref
    auto same = world();
    setTasks(same, [taskOf("compile", ["src": "game"]), taskOf("docs", ["pages": "docs"], null, "same")]);
    const sameResult = same.intake.intake(build(["docs"]));
    assert(same.stores.chains.get(sameResult.chainId).get.pins == [pinOf("docs", "main", "ddd111"), pinOf("game", "main", "aaa111")],
        "docs follows the headline, taken from game");
    setTasks(same, [taskOf("docs", ["pages": "docs"], null, "same")]);
    assert(refusedBy({ same.intake.intake(build(["docs"])); }).msg.canFind("headline"));
    setTasks(same, [taskOf("compile", ["src": "game"]), taskOf("docs", ["pages": "docs"], null, "same"), taskOf("docs2", ["pages": "docs"], null, "same else main")]);
    assert(refusedBy({ same.intake.intake(build(["docs2"], 1)); }).msg.canFind("fallback"));
}

unittest
{
    // A project without repositories has one history and no pins
    auto w = world();
    setTasks(w, [taskOf("clean", null)]);
    const result = w.intake.intake(build(["clean"]));
    const chain = w.stores.chains.get(result.chainId).get.value;
    assert(chain.headline == defaultHeadline() && chain.pins.length == 0);
    assert(w.stores.requests.get(result.requestId).get.pins.length == 0);
    assert(w.intake.intake(build(["clean"], 1)).chainNumber == 1);
    assert(w.resolver.log.length == 0);
}

unittest
{
    // With the git resolver and a fake git, one ls-remote for each repository
    auto w = world();
    string[] asked;
    auto intake = intakeOf(w.stores, new GitRepositoryResolver((string address, string[] patterns) {
        asked ~= address;
        const sha = address.canFind("game") ? "1111111111111111111111111111111111111111" : "2222222222222222222222222222222222222222";
        return sha ~ "\trefs/heads/main\n";
    }));
    const result = intake.intake(build(["test"]));
    assert(asked.length == 2);
    const pins = w.stores.chains.get(result.chainId).get.pins;
    assert(pins.length == 2 && pins[0].pin.pinned == Json("2222222222222222222222222222222222222222")
        && pins[1].pin.pinned == Json("1111111111111111111111111111111111111111") && pins[1].ref_ == RepositoryRef(RefKind.branch, "main"));
}

unittest
{
    // The pure parts: ref choice, headline choice and form defaults
    auto definition = ProjectDefinition([
        taskOf("compile", ["src": "game"]),
        taskOf("tools", ["scripts": "tools"], null, "stable"),
        taskOf("docs", ["pages": "docs", "extra": "game"], null, "same"),
    ]);
    auto graph = new TaskGraph(definition.tasks);
    assert(repositoriesOf(graph) == ["docs", "game", "tools"]);
    assert(repositoryDefaults(definition) == [RepositoryDefault("docs", ""), RepositoryDefault("game", ""), RepositoryDefault("tools", "stable")],
        "Only repositories whose inputs agree on a fixed default are prefilled");

    string[string] none;
    const choices = chooseRefs(graph, ["docs": "feature"], null, null, nullable(HeadlineRef(HeadlineKind.tag, "v1")));
    assert(choices[InputKey("compile", "src")] == RefChoice("main"));
    assert(choices[InputKey("docs", "pages")] == RefChoice("feature"), "The request's ref wins over the default");
    assert(choices[InputKey("docs", "extra")] == RefChoice("v1", nullable(RefKind.tag)), "same takes the headline's name and kind");
    assert(choices[InputKey("tools", "scripts")] == RefChoice("stable"));

    bool threw = false;
    try chooseRefs(graph, none, null, null, Nullable!HeadlineRef.init);
    catch (InputResolutionException e) threw = e.taskId == "docs" && e.inputName == "extra";
    assert(threw, "same needs a headline");

    assert(headlineChoice(graph, none).get == HeadlineChoice("game", "main"), "docs has only same, so game is the first with a ref");
    assert(headlineChoice(graph, ["docs": "feature"]).get == HeadlineChoice("docs", "feature"));
    assert(headlineChoice(new TaskGraph([taskOf("a", null)]), none).isNull);
    auto onlySame = new TaskGraph([taskOf("docs", ["pages": "docs"], null, "same")]);
    threw = false;
    try headlineChoice(onlySame, none);
    catch (InputResolutionException) threw = true;
    assert(threw);
}

unittest
{
    // A chain of a project that had no repositories cannot pin one: refused, naming chain and repository
    auto w = world();
    setTasks(w, [taskOf("clean", null)]);
    w.intake.intake(build(["clean"]));
    setTasks(w, [taskOf("clean", null), taskOf("pkg", ["src": "game"])]);
    auto failure = refusedBy({ w.intake.intake(build(["pkg"], 1)); });
    assert(failure.failure == IntakeFailure.refused && failure.msg.canFind("chain_1") && failure.msg.canFind("'game'"), failure.msg);
    assert(w.stores.requests.listForProject("game", 10).length == 1);
}

unittest
{
    // A request whose reconcile fails stays recorded, and the failure says so and carries its ids
    import confector.core.request_fixtures : beforeWrite;

    auto w = world();
    w.intake.intake(build(["test"]));
    beforeWrite(w.documents, 3, () { throw new Exception("store unavailable"); });
    auto failure = refusedBy({ w.intake.intake(build(["test"], 1)); });
    assert(failure.failure == IntakeFailure.reconcileFailed && failure.msg.canFind("store unavailable"), failure.msg);
    assert(failure.recorded.chainNumber == 1 && !w.stores.requests.get(failure.recorded.requestId).isNull);
    assert(!w.stores.requestStates.get(failure.recorded.requestId).isNull);
}

unittest
{
    // A chain remembers how its inputs were bound. Created with game at release, it binds every input
    // of the definition; a later request that names no ref builds the chain's ref and pins nothing new
    auto w = world();
    auto creation = build(["test"]);
    creation.refs["game"] = "release";
    const created = w.intake.intake(creation);
    const chain = w.stores.chains.get(created.chainId).get.value;
    assert(chain.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release")),
        InputBinding("docs", "pages", RepositoryRef(RefKind.branch, "main"))], "The snapshot binds every repository input");
    assert(chain.pins == [pinOf("docs", "main", "ddd111"), pinOf("game", "release", "rel111")]);

    w.resolver.add("game", "main", "bbb222");
    const resolved = w.resolver.log.length;
    const later = w.intake.intake(build(["test"], 1));
    const laterRequest = w.stores.requests.get(later.requestId).get.value;
    assert(laterRequest.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release"))], "The chain's ref, not the default");
    assert(laterRequest.pins == [pinOf("game", "release", "rel111")]);
    assert(w.stores.chains.get(created.chainId).get.pins == chain.pins, "No main pin was added");
    assert(w.resolver.log.length == resolved);

    // A rebinding with an explicit ref adds a pin and leaves the chain's binding as it was
    auto rebind = build(["test"], 1);
    rebind.refs["game"] = "main";
    const rebound = w.intake.intake(rebind);
    assert(w.stores.requests.get(rebound.requestId).get.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "main"))]);
    assert(w.stores.chains.get(created.chainId).get.bindings == chain.bindings, "The first binding wins");
    assert(w.stores.chains.get(created.chainId).get.pins.length == 3, "Another ref is another pin");
    // A task added later, with an input the chain never bound, falls back to the input's default,
    // and the chain records that binding
    setTasks(w, gameTasks() ~ taskOf("lint", ["src": "game"]));
    const lint = w.intake.intake(build(["lint"], 1));
    assert(w.stores.requests.get(lint.requestId).get.pins == [pinOf("game", "main", "bbb222")], "main of game was pinned by the rebinding");
    const afterLint = w.stores.chains.get(created.chainId).get.value;
    assert(afterLint.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release")),
        InputBinding("docs", "pages", RepositoryRef(RefKind.branch, "main")),
        InputBinding("lint", "src", RepositoryRef(RefKind.branch, "main"))]);
    assert(afterLint.pins.length == 3, "Nothing new to pin");

    const again = w.stores.requests.get(w.intake.intake(build(["test"], 1)).requestId).get.value;
    assert(again.bindings[0].ref_.name == "release", "Later requests still bind the chain's ref");
}

unittest
{
    // Pins and bindings are written in one compare-and-set: one new version of the chain holds both
    auto w = world();
    const created = w.intake.intake(build(["test"]));
    const before = w.stores.chains.get(created.chainId).get.version_;
    auto both = w.stores.chains.addPins(created.chainId, [pinOf("assets", "main", "sss111")],
        [InputBinding("package", "files", RepositoryRef(RefKind.branch, "main"))]);
    assert(both.version_ == before + 1 && both.pins.length == 3 && both.bindings.length == 3);

    // Binding an input the chain has bound keeps its binding; nothing new means no write
    const same = w.stores.chains.addPins(created.chainId, null, [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release"))]);
    assert(same.version_ == both.version_ && same.bindings == both.bindings);

    // A concurrent writer between the read and the write forces a merge of both, never a divergence
    w.documents.beforeNextWrite = () {
        w.stores.chains.addPins(created.chainId, [pinOf("tools", "main", "ttt111")], [InputBinding("tool", "bin", RepositoryRef(RefKind.branch, "main"))]);
    };
    const merged = w.stores.chains.addPins(created.chainId, [pinOf("game", "release", "rel111")],
        [InputBinding("other", "src", RepositoryRef(RefKind.branch, "release")), InputBinding("tool", "bin", RepositoryRef(RefKind.branch, "dev"))]);
    assert(merged.pins.length == 5 && merged.bindings.length == 5);
    foreach (binding; merged.bindings)
    {
        if (binding.taskId == "tool") assert(binding.ref_.name == "main", "The first binding wins in a race too");
    }

    // The store refuses a chain whose bindings are not well formed
    bool refused = false;
    try w.stores.chains.addPins(created.chainId, null, [InputBinding("a", "b", RepositoryRef(RefKind.branch, ""))]);
    catch (InvalidPinsException) refused = true;
    assert(refused);
}

unittest
{
    // A chain's binding counts only for the repository it was made for: when the definition points
    // compile/src at another repository, a request that names no ref binds the new one's default
    auto w = world();
    auto creation = build(["test"]);
    creation.refs["game"] = "release";
    w.intake.intake(creation);

    RepositoryRecord engine;
    engine.name = "engine";
    engine.address = "https://example.test/engine.git";
    w.stores.repositories.put(engine);
    w.resolver.add("engine", "main", "eee111");
    setTasks(w, [taskOf("compile", ["src": "engine"]), taskOf("test", null, ["compile"]), taskOf("docs", ["pages": "docs"])]);
    const result = w.intake.intake(build(["test"], 1));
    const recorded = w.stores.requests.get(result.requestId).get.value;
    assert(recorded.bindings == [InputBinding("compile", "src", RepositoryRef(RefKind.branch, "main"))], "The default, not release on engine");
    assert(recorded.pins == [pinOf("engine", "main", "eee111")]);
    assert(w.stores.chains.get(result.chainId).get.bindings[0] == InputBinding("compile", "src", RepositoryRef(RefKind.branch, "release")),
        "The chain's first binding is kept");
}
