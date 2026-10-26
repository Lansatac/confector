module confector.testing.fake_repository_resolver;

/**
 * A RepositoryResolver over a fixed set of refs, for tests that must never run version control.
 * It logs every ref it is asked to resolve as "repository/name", and can be made to fail for one.
 */

import confector.api.input_resolver : RepositoryResolver, ResolvedRef;
import confector.api.model : InputPin, RefKind, RepositoryRecord, RepositoryRef;

import vibe.data.json : Json;

/// Resolves the refs added with `add`; any other ref fails, as does one in `failing`.
final class FakeRepositoryResolver : RepositoryResolver
{
    private struct Known
    {
        RefKind kind;
        string sha;
    }

    private Known[string] m_refs;

    /// What was asked to be resolved, as "repository/name", in order.
    string[] log;
    /// Refs ("repository/name") whose resolution fails even though they were added.
    bool[string] failing;

    /// Makes `name` of `repository` exist, as a ref of `kind` at revision `sha`.
    void add(string repository, string name, string sha, RefKind kind = RefKind.branch)
    {
        m_refs[repository ~ "/" ~ name] = Known(kind, sha);
    }

    /// Makes `name` of `repository` stop existing.
    void remove(string repository, string name)
    {
        m_refs.remove(repository ~ "/" ~ name);
    }

    ResolvedRef resolve(in RepositoryRecord repository, in RepositoryRef ref_)
    {
        const key = repository.name ~ "/" ~ ref_.name;
        log ~= key;
        auto known = key in m_refs;
        if (key in failing || known is null || known.kind != ref_.kind) throw new Exception("no such ref " ~ key);
        return ResolvedRef(ref_, InputPin(Json(known.sha)));
    }

    ResolvedRef resolveName(in RepositoryRecord repository, string name)
    {
        const key = repository.name ~ "/" ~ name;
        log ~= key;
        auto known = key in m_refs;
        if (key in failing || known is null) throw new Exception("no such ref " ~ key);
        return ResolvedRef(RepositoryRef(known.kind, name), InputPin(Json(known.sha)));
    }
}
