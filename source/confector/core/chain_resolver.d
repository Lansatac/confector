module confector.core.chain_resolver;

/**
 * The imperative shell of input resolution (design records: beads confector-z7z.13,
 * confector-z7z.14 and confector-z7z.20.7): turns a project's task graph into a build chain's
 * frozen tasks by resolving every distinct repository input of the whole DAG exactly once.
 *
 * The decisions are pure (confector.core.input_resolution); this module only performs the I/O
 * between them, through injected seams, so tests run without a network or a store.
 *
 * Resolution happens only here, when a chain is created. Building any task of an existing
 * chain uses the chain's frozen tasks (`chainFingerprints`) and never calls a resolver.
 */

import confector.core.dag : TaskGraph;
import confector.core.input_resolution;
import confector.core.model;
import confector.plugin_api.input_resolver : InputPin, RepositoryResolver;

import vibe.data.json : Json;

import std.format : format;

/**
 * Looks up a repository record by id (`RepositoryRecord.name`). Throws if no such repository
 * is registered.
 */
alias RepositoryLookup = RepositoryRecord delegate(string repositoryId);

/**
 * Chooses the resolver for a repository. Git is the only built-in provider, so today every
 * repository resolves through one resolver; when repositories record their provider, this
 * selects by it (bead confector-z7z.7).
 */
alias ResolverSelector = RepositoryResolver delegate(in RepositoryRecord repository);

/**
 * Resolves every input of every task in `graph` and freezes the result into a chain's tasks.
 *
 * Repository inputs pinned by `knownPins` (trigger payload, user pins) are taken as given; each
 * other distinct repository input is looked up with `lookup` and resolved once with the
 * resolver `selectResolver` returns for it.
 *
 * Throws: InputResolutionException, naming the repository and ref, if a repository input is
 * incomplete, its repository is unknown, no resolver is available for it, or its resolver
 * fails or returns an empty pin. Nothing is partially resolved: any failure fails the whole
 * chain.
 */
ChainTask[] resolveChain(
    string projectId,
    const TaskGraph graph,
    in InputPin[InputDecl] knownPins,
    RepositoryLookup lookup,
    ResolverSelector selectResolver
)
{
    InputPin[InputDecl] resolved;
    foreach (key; unpinnedRepositoryInputs(graph, knownPins))
    {
        const where = format("repository '%s' at ref '%s'", key.spec.repository, key.spec.refSelector);

        RepositoryRecord repository;
        try repository = lookup(key.spec.repository);
        catch (Exception e)
        {
            throw new InputResolutionException(format("Cannot resolve %s: %s", where, e.msg));
        }

        RepositoryResolver resolver = selectResolver is null ? null : selectResolver(repository);
        if (resolver is null)
        {
            throw new InputResolutionException(format("Cannot resolve %s: no repository resolver is configured for it", where));
        }

        InputPin pin;
        try pin = resolver.resolve(repository, key);
        catch (Exception e)
        {
            throw new InputResolutionException(format("Cannot resolve %s: %s", where, e.msg));
        }
        resolved[key] = pin;
    }

    return freezeChain(graph, resolveGraphInputs(projectId, graph, knownPins, resolved));
}

version (unittest)
{
    import std.algorithm.searching : canFind;

    /// A resolver that answers from a table and counts its calls.
    class CountingResolver : RepositoryResolver
    {
        string[string] shaByRef; // "repository@ref" -> sha
        size_t calls;

        InputPin resolve(in RepositoryRecord repository, in InputDecl input)
        {
            ++calls;
            auto sha = (repository.name ~ "@" ~ input.spec.refSelector) in shaByRef;
            if (sha is null) throw new Exception("no such ref");
            return InputPin(Json(*sha), ["ref": input.spec.refSelector]);
        }
    }

    /// Selects `resolver` for every repository.
    ResolverSelector always(RepositoryResolver resolver)
    {
        return (in RepositoryRecord repository) => resolver;
    }

    RepositoryRecord knownRepository(string id)
    {
        if (id != "game" && id != "engine") throw new Exception(format("repository '%s' is not registered", id));
        RepositoryRecord r;
        r.name = id;
        r.address = "https://example.test/" ~ id ~ ".git";
        return r;
    }
}

unittest
{
    // Each distinct repository input is resolved once for the whole DAG, and every task of the
    // chain, requested or not, carries its resolved inputs
    TaskNode compile; compile.id = "compile"; compile.inputs["src"] = repositoryInput("game", "main");
    compile.inputs["engine"] = repositoryInput("engine", "stable");
    TaskNode test; test.id = "test"; test.inputs["src"] = repositoryInput("game", "main");
    test.inputs["bin"] = taskOutputInput("compile");
    TaskNode release; release.id = "release"; release.inputs["code"] = repositoryInput("game", "main");
    auto graph = new TaskGraph([compile, test, release]);

    auto resolver = new CountingResolver();
    resolver.shaByRef = ["game@main": "aaa111", "engine@stable": "eee555"];
    InputPin[InputDecl] none;
    auto chain = resolveChain("p", graph, none, (id) => knownRepository(id), always(resolver));

    assert(resolver.calls == 2, "game@main and engine@stable must each be resolved exactly once");
    assert(chain.length == 3);
    foreach (ref t; chain)
    {
        foreach (ref input; t.resolvedInputs)
        {
            if (input.name == "src" || input.name == "code") assert(input.pinned == Json("aaa111"));
        }
    }
    assert(chain[1].id == "release" && chain[1].resolvedInputs.length == 1);

    // Pre-supplied pins are not resolved again
    InputPin[InputDecl] known = [repositoryInput("game", "main"): InputPin(Json("from-trigger"))];
    auto pinned = resolveChain("p", graph, known, (id) => knownRepository(id), always(resolver));
    assert(resolver.calls == 3, "Only engine@stable may be resolved");
    assert(pinned[1].resolvedInputs[0].pinned == Json("from-trigger"));
}

unittest
{
    // Any failure fails chain creation loudly, naming the repository and ref
    TaskNode a; a.id = "a"; a.inputs["src"] = repositoryInput("game", "main");
    auto graph = new TaskGraph([a]);
    InputPin[InputDecl] none;
    auto resolver = new CountingResolver();

    string failure(RepositoryLookup lookup, ResolverSelector select)
    {
        try resolveChain("p", graph, none, lookup, select);
        catch (InputResolutionException ex) return ex.msg;
        assert(false, "expected InputResolutionException");
    }

    // The resolver throws (the ref does not exist)
    auto msg = failure((id) => knownRepository(id), always(resolver));
    assert(msg.canFind("'game'") && msg.canFind("'main'") && msg.canFind("no such ref"));

    // No resolver for the repository
    msg = failure((id) => knownRepository(id), always(null));
    assert(msg.canFind("no repository resolver"));
    msg = failure((id) => knownRepository(id), null);
    assert(msg.canFind("no repository resolver"));

    // The repository is not registered
    TaskNode b; b.id = "b"; b.inputs["src"] = repositoryInput("tools", "main");
    bool threw = false;
    try resolveChain("p", new TaskGraph([b]), none, (id) => knownRepository(id), always(resolver));
    catch (InputResolutionException ex) threw = ex.msg.canFind("'tools'") && ex.msg.canFind("not registered");
    assert(threw);

    // An empty pin from a misbehaving resolver
    class NullResolver : RepositoryResolver
    {
        InputPin resolve(in RepositoryRecord repository, in InputDecl input) { return InputPin(Json(null)); }
    }
    auto nullResolver = new NullResolver();
    threw = false;
    try resolveChain("p", graph, none, (id) => knownRepository(id), always(nullResolver));
    catch (InputResolutionException ex) threw = ex.taskId == "a";
    assert(threw);

    // An empty ref selector fails before any resolver is called
    TaskNode c; c.id = "c"; c.inputs["src"] = repositoryInput("game", "");
    auto counting = new CountingResolver();
    threw = false;
    try resolveChain("p", new TaskGraph([c]), none, (id) => knownRepository(id), always(counting));
    catch (InputResolutionException ex) threw = ex.taskId == "c" && ex.msg.canFind("no ref selector");
    assert(threw && counting.calls == 0);
}
