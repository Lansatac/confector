module confector.plugin_api.input_resolver;

/**
 * The repository resolver contract: how a version control provider turns a declared repository
 * input into a pinned value (design records: beads confector-z7z.13 and confector-z7z.7).
 *
 * Resolution is split along the functional-core/imperative-shell line. The pure core
 * (confector.core.input_resolution) lists the distinct repository inputs of a whole DAG that are
 * not already pinned; the shell calls a RepositoryResolver once for each and hands the results
 * back to the core, which builds every task's resolved inputs. Resolvers do the I/O; the core
 * never does.
 */

import confector.plugin_api.model : InputDecl, InputPin, RepositoryRecord;

/**
 * Resolves repository inputs for one version control provider. How the shell selects the
 * resolver for a repository is left to the provider wiring (z7z.20.6). Supersedes the
 * revision-fetching `VcsStateResolver` for fingerprinting.
 */
interface RepositoryResolver
{
    /**
     * Resolves `input`, a repository input declaring `repository` (its `spec.repository` is
     * `repository.name`), to the provider's canonical pinned value at the ref its
     * `spec.refSelector` selects, now. The provider alone defines what the pinned value is.
     *
     * Throws on any failure, including a ref that does not exist; never returns an undefined
     * or null pin.
     */
    InputPin resolve(in RepositoryRecord repository, in InputDecl input);
}
