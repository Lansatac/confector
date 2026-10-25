module confector.api.input_resolver;

/**
 * The repository resolver contract: how a version control provider turns a ref of a repository
 * into a pinned value (design records: beads confector-z7z.13, confector-z7z.7 and
 * confector-z7z.56).
 *
 * Resolution is split along the functional-core/imperative-shell line. A request binds each
 * repository input it needs to a ref (from the trigger's or request's ref spec, else the input's
 * default); the pure core lists the distinct (repository, ref) pairs the
 * chain does not pin yet (confector.core.chain_pins.refsToResolve); the shell calls a
 * RepositoryResolver once for each and hands the results back to the core
 * (confector.core.chain_pins.pinsForRefs), which pins each (repository, ref) once, so every input
 * bound to that ref sees the same revision. Resolvers do the I/O; the core never does.
 */

import confector.api.model : InputPin, RepositoryRecord, RepositoryRef;

/**
 * A ref as a resolver resolved it: the concrete ref (kind and normalized name) and its revision
 * now. `ref_` is the ref actually resolved, which callers pin (`RepositoryPin.ref_`), never the ref
 * they asked for.
 */
struct ResolvedRef
{
    RepositoryRef ref_;
    InputPin pin;
}

/**
 * Resolves refs of repositories for one version control provider. How the shell selects the
 * resolver for a repository is left to the provider wiring (z7z.20.6).
 *
 * Ref names are the provider's short names, as tracked branches and events report them: for git
 * `main`, `release/1.2` or `v1.0`, never `refs/heads/main`, `refs/tags/v1.0` or `HEAD`. A resolver
 * refuses a full ref name rather than guessing what it means, so one ref has one spelling and
 * pins made from the same ref agree. A revision (kind `revision`) is named by the provider's full
 * revision id (git: a 40- or 64-hex commit SHA); the resolver returns it normalized (git:
 * lowercase).
 *
 * Every method throws on any failure, including a ref that does not exist, and never returns an
 * undefined or null pin.
 */
interface RepositoryResolver
{
    /**
     * Resolves `ref_` of `repository`: exactly that kind and name. The result's ref is `ref_`
     * (its name normalized). If no ref of that kind has that name it throws, even when a ref of
     * another kind does (asking for branch `v1` while only tag `v1` exists fails): it never
     * substitutes another kind.
     */
    ResolvedRef resolve(in RepositoryRecord repository, in RepositoryRef ref_);

    /**
     * Resolves a ref named without a kind, as a fixed ref spec names it (`main`, `v1.0`, or a
     * revision id), discovering its kind: the result's ref is the one that exists. A name that
     * several kinds of ref have (a branch and a tag) is ambiguous and throws.
     */
    ResolvedRef resolveName(in RepositoryRecord repository, string name);
}
