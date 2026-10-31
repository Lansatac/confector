module confector.core.git_resolver;

/**
 * The built-in git RepositoryResolver: turns a ref of a repository into a commit SHA with
 * `git ls-remote`.
 *
 * The pinned value is the commit SHA alone, as a Json string; the full ref that was selected goes
 * into `InputPin.info` for display. Imperative shell and functional core are separate:
 * `parseLsRemote`, `selectGitRef` and `selectNamedRef` are pure; running git is behind the
 * `LsRemote` seam so tests can run without a network or a git installation.
 *
 * Refs (confector.api.input_resolver):
 * - names are short names (`main`, `release/1.2`, `v1`); full ref names (`refs/heads/main`) and
 *   `HEAD` are refused (`requireShortRefName`);
 * - a branch or tag is resolved as exactly that kind (`refs/heads/<name>` or `refs/tags/<name>`);
 *   another kind of the same name is never substituted;
 * - a name without a kind (`resolveName`) is the branch or the tag of that name, whichever
 *   exists; a name that is both is ambiguous and fails;
 * - a full 40-hex (SHA-1) or 64-hex (SHA-256) object id is a revision, already pinned, returned
 *   lowercased without contacting the repository.
 * An annotated tag resolves to the commit it points at (its peeled `^{}` entry).
 */

import confector.api.input_resolver : RepositoryResolver, ResolvedRef;
import confector.api.model : InputPin, RefKind, RepositoryRecord, RepositoryRef;
import confector.core.git : isFullSha, redactUserInfo;

import vibe.data.json : Json;

import core.time : Duration, seconds;
import std.algorithm.searching : canFind, startsWith;
import std.array : appender, join;
import std.ascii : isHexDigit;
import std.format : format;
import std.string : lineSplitter, indexOf, strip, toLower;

/// A git ref (or peeled ref) advertised by a remote, as listed by `git ls-remote`.
struct GitRef
{
    /// Full ref name, e.g. `refs/heads/main`; a peeled tag keeps its `^{}` suffix.
    string name;
    /// Object id the ref points at.
    string sha;
}

/// A repository input could not be resolved to a git commit.
class GitResolutionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Runs `git ls-remote` against `address`, restricted to `patterns` (git matches each pattern
 * against the end of the ref name), and returns its standard output. Throws if git fails.
 */
alias LsRemote = string delegate(string address, string[] patterns);

/**
 * Parses `git ls-remote` output (`<sha>\t<ref>` per line). Lines of any other shape are
 * skipped; they are diagnostics, not refs.
 */
GitRef[] parseLsRemote(string output) pure @safe
{
    GitRef[] refs;
    foreach (line; output.lineSplitter)
    {
        const tab = line.indexOf('\t');
        if (tab < 0) continue;
        const sha = line[0 .. tab].strip;
        const name = line[tab + 1 .. $].strip;
        if (!isFullSha(sha) || name.length == 0) continue;
        refs ~= GitRef(name.idup, sha.toLower);
    }
    return refs;
}

/**
 * Throws GitResolutionException unless `name` is a short ref name (AGENTS.md, "Version control
 * providers"; confector.api.input_resolver): not empty, without whitespace, not starting with
 * `-`, and not a full ref name (`refs/...`) or `HEAD`. Full names are refused rather than
 * normalized, so one ref has one spelling and pins made from it agree.
 */
void requireShortRefName(string name) pure @safe
{
    import std.algorithm.searching : any;
    import std.ascii : isWhite;

    if (name.length == 0) throw new GitResolutionException("Git ref name is empty");
    if (name.any!isWhite) throw new GitResolutionException(format("Git ref name '%s' contains whitespace", name));
    if (name.startsWith("-")) throw new GitResolutionException(format("Git ref name '%s' must not start with '-'", name));
    if (name == "HEAD" || name.startsWith("refs/"))
    {
        throw new GitResolutionException(format(
            "Git ref name '%s' is not a short name; name the branch or tag itself (for example 'main', not 'refs/heads/main')", name));
    }
}

/// The full git ref name of branch or tag `name`: `refs/heads/<name>` or `refs/tags/<name>`.
string fullRefName(RefKind kind, string name) pure @safe
{
    switch (kind)
    {
        case RefKind.branch: return "refs/heads/" ~ name;
        case RefKind.tag: return "refs/tags/" ~ name;
        default:
            throw new GitResolutionException(format("A git %s has no ref name of its own", cast(string) kind));
    }
}

/// The ls-remote patterns that fetch the full ref names `names` and their peeled tags.
string[] lsRemotePatterns(in string[] names) pure @safe
{
    string[] patterns;
    foreach (name; names)
    {
        patterns ~= name;
        patterns ~= name ~ "^{}";
    }
    return patterns;
}

/// The commit full ref name `name` points at in `refs` (an annotated tag's peeled entry), or null.
private string commitOf(string name, const GitRef[] refs) pure @safe
{
    const peeled = name ~ "^{}";
    string direct, peel;
    foreach (r; refs)
    {
        if (r.name == name) direct = r.sha;
        else if (r.name == peeled) peel = r.sha;
    }
    // An annotated tag is advertised twice; its peeled entry is the commit.
    return peel.length > 0 ? peel : direct;
}

/**
 * Selects the commit of branch or tag `ref_` from `refs`: exactly that kind. Pure.
 *
 * Throws: GitResolutionException if the name is not a short name, the kind is not a branch or
 * tag, or no ref of that kind has the name, even when a ref of the other kind does: another kind
 * is never substituted.
 */
GitRef selectGitRef(in RepositoryRef ref_, const GitRef[] refs) pure @safe
{
    requireShortRefName(ref_.name);
    const name = fullRefName(ref_.kind, ref_.name);
    const sha = commitOf(name, refs);
    if (sha.length > 0) return GitRef(name, sha);

    const other = ref_.kind == RefKind.branch ? RefKind.tag : RefKind.branch;
    const hint = commitOf(fullRefName(other, ref_.name), refs).length > 0
        ? format(" (a %s of that name does; ask for the %s)", cast(string) other, cast(string) other) : "";
    throw new GitResolutionException(format("Git %s '%s' does not exist in the repository%s", cast(string) ref_.kind, ref_.name, hint));
}

/**
 * Selects the branch or tag named `name` from `refs`, whichever exists, and returns it with its
 * kind. Pure.
 *
 * Throws: GitResolutionException if the name is not a short name, names no branch or tag, or
 * names both (ambiguous: ask for the kind).
 */
GitRef selectNamedRef(string name, const GitRef[] refs, out RefKind kind) pure @safe
{
    requireShortRefName(name);
    GitRef[] found;
    RefKind[] kinds;
    foreach (candidate; [RefKind.branch, RefKind.tag])
    {
        const full = fullRefName(candidate, name);
        const sha = commitOf(full, refs);
        if (sha.length == 0) continue;
        found ~= GitRef(full, sha);
        kinds ~= candidate;
    }
    if (found.length == 0)
    {
        throw new GitResolutionException(format("Git ref '%s' is neither a branch nor a tag of the repository", name));
    }
    if (found.length > 1)
    {
        throw new GitResolutionException(format(
            "Git ref '%s' is ambiguous: the repository has a branch and a tag of that name; ask for the kind", name));
    }
    kind = kinds[0];
    return found[0];
}

/// How long `git ls-remote` may run before it is stopped. A remote that does not answer within
/// this time fails resolution; it is generous because large repositories advertise many refs.
enum Duration lsRemoteTimeout = 120.seconds;

/**
 * Runs the real `git ls-remote`, unable to wait for a person: standard input is not inherited,
 * terminal prompts are disabled (`GIT_TERMINAL_PROMPT=0`), ssh runs with `BatchMode=yes` unless
 * the environment already sets `GIT_SSH_COMMAND` or `GIT_SSH`, and git is stopped after
 * `timeout` (see `runProcess`). Credentials in `address` are redacted from error messages.
 *
 * Throws: GitResolutionException if git cannot be run, exits non-zero or times out.
 */
string runGitLsRemote(string address, string[] patterns, Duration timeout = lsRemoteTimeout)
{
    import confector.core.process : DeadlineException, ProcessResult, runProcess, StopLimits;
    import core.time : MonoTime;
    import std.process : environment;

    const shown = redactUserInfo(address);
    auto command = ["git", "ls-remote", "--"] ~ address ~ patterns;

    string[string] env = environment.toAA;
    env["GIT_TERMINAL_PROMPT"] = "0";
    if (environment.get("GIT_SSH_COMMAND") is null && environment.get("GIT_SSH") is null)
    {
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes";
    }

    // Server resolution must not stall far past its timeout; git exits promptly on a stop
    const limits = StopLimits(2.seconds, 5.seconds, 5.seconds);
    auto lines = appender!(string[]);
    ProcessResult result;
    try
    {
        result = runProcess(command, null, env, MonoTime.currTime + timeout, limits,
            (string line) { lines.put(line); });
    }
    catch (DeadlineException e)
    {
        throw new GitResolutionException(format("git ls-remote %s timed out after %s", shown, timeout));
    }
    catch (Exception e)
    {
        throw new GitResolutionException(format("Could not run git ls-remote %s: %s", shown, redactUserInfo(e.msg)));
    }

    // Truncated output could resolve to a wrong commit, so it is an error, not a partial answer
    if (result.outputAbandoned)
    {
        throw new GitResolutionException(format(
            "git ls-remote %s: its output did not end within %s of git exiting", shown, limits.drainLimit));
    }
    const output = lines.data.join("\n");
    if (result.exitCode != 0)
    {
        throw new GitResolutionException(format(
            "git ls-remote %s failed with exit code %s: %s", shown, result.exitCode, redactUserInfo(output.strip)));
    }
    return output;
}

/**
 * Resolves refs of git repositories: the repository's `address` is the git remote. Branches and
 * tags are resolved with `git ls-remote`; a revision (a full commit SHA) is already pinned and is
 * returned lowercased without contacting the repository. Change requests are not resolved by the
 * plain git resolver: which refs a hosting service gives them (GitHub `refs/pull/N/head`, GitLab
 * `refs/merge-requests/N/head`) belongs to that service's integration, so asking for one fails.
 */
class GitRepositoryResolver : RepositoryResolver
{
    private LsRemote lsRemote;

    /// `lsRemote` runs `git ls-remote`; defaults to the real thing. Tests inject a fake.
    this(LsRemote lsRemote = null)
    {
        this.lsRemote = lsRemote !is null ? lsRemote : (a, p) => runGitLsRemote(a, p);
    }

    ResolvedRef resolve(in RepositoryRecord repository, in RepositoryRef ref_)
    {
        final switch (ref_.kind)
        {
            case RefKind.revision:
                return revision(repository, ref_.name);
            case RefKind.changeRequest:
                throw new GitResolutionException(format(
                    "Repository '%s': change request '%s' cannot be resolved by the plain git resolver; it needs the hosting service's integration",
                    repository.name, ref_.name));
            case RefKind.branch:
            case RefKind.tag:
            {
                const chosen = selectGitRef(ref_, listRefs(repository, [fullRefName(ref_.kind, ref_.name)], ref_.name));
                return ResolvedRef(RepositoryRef(ref_.kind, ref_.name), pinOf(chosen));
            }
        }
    }

    ResolvedRef resolveName(in RepositoryRecord repository, string name)
    {
        if (isFullSha(name)) return revision(repository, name);
        requireShortRefName(name);
        RefKind kind;
        const chosen = selectNamedRef(name,
            listRefs(repository, [fullRefName(RefKind.branch, name), fullRefName(RefKind.tag, name)], name), kind);
        return ResolvedRef(RepositoryRef(kind, name), pinOf(chosen));
    }

    private static ResolvedRef revision(in RepositoryRecord repository, string name)
    {
        if (!isFullSha(name))
        {
            throw new GitResolutionException(format("Repository '%s': revision '%s' is not a full commit SHA", repository.name, name));
        }
        InputPin pin;
        pin.pinned = Json(name.toLower);
        pin.info["ref"] = name.toLower;
        return ResolvedRef(RepositoryRef(RefKind.revision, name.toLower), pin);
    }

    private static InputPin pinOf(in GitRef chosen)
    {
        InputPin pin;
        pin.pinned = Json(chosen.sha);
        pin.info["ref"] = chosen.name;
        return pin;
    }

    /// The refs `git ls-remote` lists for the full ref names `names` (and their peeled tags).
    private GitRef[] listRefs(in RepositoryRecord repository, string[] names, string shortName)
    {
        requireShortRefName(shortName);
        if (repository.address.length == 0)
        {
            throw new GitResolutionException(format("Repository '%s' has no address", repository.name));
        }
        if (repository.address.startsWith("-"))
        {
            throw new GitResolutionException(format("Repository '%s': the address must not start with '-'", repository.name));
        }
        try return parseLsRemote(lsRemote(repository.address, lsRemotePatterns(names)));
        catch (GitResolutionException e) throw new GitResolutionException(format("Repository '%s': %s", repository.name, e.msg));
    }
}

version (unittest)
{
    import std.array : replicate;

    private enum sha1a = "1111111111111111111111111111111111111111";
    private enum sha1b = "2222222222222222222222222222222222222222";
    private enum sha1c = "3333333333333333333333333333333333333333";

    private string fakeOutput(string[2][] entries)
    {
        string s;
        foreach (e; entries) s ~= e[0] ~ "\t" ~ e[1] ~ "\n";
        return s;
    }

    private RepositoryRecord repo(string address = "https://example.test/r.git")
    {
        RepositoryRecord r;
        r.name = "r";
        r.address = address;
        return r;
    }

    private RepositoryRef branch(string name) { return RepositoryRef(RefKind.branch, name); }
    private RepositoryRef tag(string name) { return RepositoryRef(RefKind.tag, name); }
}

unittest // parseLsRemote keeps refs, skips noise, lowercases
{
    const refs = parseLsRemote("warning: something\n" ~ sha1a ~ "\trefs/heads/main\r\n\nABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD\tHEAD\n");
    assert(refs.length == 2);
    assert(refs[0] == GitRef("refs/heads/main", sha1a));
    assert(refs[1].sha == "abcdefabcdefabcdefabcdefabcdefabcdefabcd");
}

unittest // by kind: branch, lightweight tag, annotated tag (peeled); a fixed name finds its kind
{
    const refs = parseLsRemote(fakeOutput([
        [sha1a, "HEAD"], [sha1a, "refs/heads/main"], [sha1b, "refs/tags/light"],
        [sha1b, "refs/tags/ann"], [sha1c, "refs/tags/ann^{}"],
    ]));
    assert(selectGitRef(branch("main"), refs) == GitRef("refs/heads/main", sha1a));
    assert(selectGitRef(tag("light"), refs).sha == sha1b);
    assert(selectGitRef(tag("ann"), refs).sha == sha1c);

    RefKind kind;
    assert(selectNamedRef("main", refs, kind).sha == sha1a && kind == RefKind.branch);
    assert(selectNamedRef("ann", refs, kind).sha == sha1c && kind == RefKind.tag);
}

unittest // a kind is never substituted; missing, ambiguous and non-short names throw
{
    import std.exception : assertThrown, collectExceptionMsg;

    const refs = parseLsRemote(fakeOutput([
        [sha1a, "refs/heads/dup"], [sha1b, "refs/tags/dup"], [sha1a, "refs/heads/feature/main"], [sha1c, "refs/tags/v1"],
    ]));
    // Branch v1 is asked for while only tag v1 exists: it fails, saying the tag exists
    auto msg = collectExceptionMsg!GitResolutionException(selectGitRef(branch("v1"), refs));
    assert(msg !is null && msg.canFind("branch 'v1' does not exist") && msg.canFind("a tag of that name does"), msg);
    assertThrown!GitResolutionException(selectGitRef(tag("main"), refs));
    assertThrown!GitResolutionException(selectGitRef(branch("main"), refs)); // only a tail match, not a ref
    assert(selectGitRef(branch("dup"), refs).sha == sha1a && selectGitRef(tag("dup"), refs).sha == sha1b, "Kinds are distinguished");

    RefKind kind;
    assertThrown!GitResolutionException(selectNamedRef("nope", refs, kind));
    assert(collectExceptionMsg!GitResolutionException(selectNamedRef("dup", refs, kind)).canFind("ambiguous"));

    // Only short names: full ref names and HEAD are refused, not normalized
    foreach (bad; ["", "refs/heads/dup", "refs/tags/v1", "HEAD", "-x", "a b"])
    {
        assertThrown!GitResolutionException(selectGitRef(branch(bad), refs), bad);
        assertThrown!GitResolutionException(selectNamedRef(bad, refs, kind), bad);
    }
    assertThrown!GitResolutionException(selectGitRef(RepositoryRef(RefKind.changeRequest, "pull/1"), refs));
}

unittest // resolver: branch, tag, patterns passed to git, info, the ref resolved
{
    string[] seen;
    auto resolver = new GitRepositoryResolver((a, p) {
        seen = [a] ~ p;
        return fakeOutput([[sha1a, "refs/heads/main"], [sha1b, "refs/tags/v1"], [sha1c, "refs/tags/v1^{}"]]);
    });
    const resolved = resolver.resolve(repo(), branch("main"));
    assert(resolved.ref_ == branch("main") && resolved.pin.pinned == Json(sha1a));
    assert(resolved.pin.info["ref"] == "refs/heads/main");
    assert(seen == ["https://example.test/r.git", "refs/heads/main", "refs/heads/main^{}"], "Only the asked-for kind is listed");
    assert(resolver.resolve(repo(), tag("v1")).pin.pinned == Json(sha1c));

    // A fixed name: the resolver discovers its kind
    const named = resolver.resolveName(repo(), "v1");
    assert(named.ref_ == tag("v1") && named.pin.pinned == Json(sha1c));
    assert(seen.canFind("refs/heads/v1") && seen.canFind("refs/tags/v1"));
    assert(resolver.resolveName(repo(), "main").ref_ == branch("main"));
}

unittest // resolver: branch v1 requested while only tag v1 exists fails loudly
{
    import std.exception : collectExceptionMsg;

    auto resolver = new GitRepositoryResolver((a, p) => fakeOutput([[sha1c, "refs/tags/v1"]]));
    auto msg = collectExceptionMsg!GitResolutionException(resolver.resolve(repo(), branch("v1")));
    assert(msg !is null && msg.canFind("branch 'v1'"), msg);
    assert(resolver.resolve(repo(), tag("v1")).ref_ == tag("v1"));
}

unittest // a failing remote's address is redacted in the error, and nothing prompts
{
    import std.process : execute;

    try
    {
        if (execute(["git", "--version"]).status != 0) return;
    }
    catch (Exception) return;

    bool redacted = false;
    try runGitLsRemote("https://user:s3cret@127.0.0.1:1/none.git", ["refs/heads/main"], 30.seconds);
    catch (GitResolutionException e) redacted = !e.msg.canFind("s3cret") && e.msg.canFind("***@127.0.0.1");
    assert(redacted, "The token must not appear in the error");
}

unittest // resolver: a full SHA is a revision, pinned without calling git
{
    import std.exception : assertThrown;

    auto resolver = new GitRepositoryResolver((a, p) { assert(false, "must not run git"); return ""; });
    const sha256 = "AB" ~ "0".replicate(62);
    assert(resolver.resolveName(repo(), sha1a) == ResolvedRef(RepositoryRef(RefKind.revision, sha1a), InputPin(Json(sha1a), ["ref": sha1a])));
    const upper = resolver.resolve(repo(), RepositoryRef(RefKind.revision, sha256));
    assert(upper.ref_ == RepositoryRef(RefKind.revision, sha256.toLower) && upper.pin.pinned == Json(sha256.toLower), "Normalized to lowercase");
    assertThrown!GitResolutionException(resolver.resolve(repo(), RepositoryRef(RefKind.revision, "abc123")));
    assert(!isFullSha("abc123"));
}

unittest // resolver fails loudly
{
    import std.exception : assertThrown;

    auto empty = new GitRepositoryResolver((a, p) => "");
    assertThrown!GitResolutionException(empty.resolve(repo(), branch("main")));
    assertThrown!GitResolutionException(empty.resolve(repo(""), branch("main")));
    assertThrown!GitResolutionException(empty.resolve(repo("-x"), branch("main")));
    assertThrown!GitResolutionException(empty.resolve(repo(), branch("--upload-pack=x")));
    assertThrown!GitResolutionException(empty.resolve(repo(), branch("")));
    assertThrown!GitResolutionException(empty.resolveName(repo(), ""));
    assertThrown!GitResolutionException(empty.resolveName(repo(), "refs/heads/main"));
    assertThrown!GitResolutionException(empty.resolve(repo(), RepositoryRef(RefKind.changeRequest, "pull/12")));

    auto failing = new GitRepositoryResolver((string a, string[] p) { throw new GitResolutionException("boom"); return ""; });
    assertThrown!GitResolutionException(failing.resolve(repo(), branch("main")));
    assertThrown!GitResolutionException(failing.resolveName(repo(), "main"));
}

unittest // real git against a local repository (skipped when git is unavailable)
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : Config, execute;

    // Skip when git is not installed: execute throws if the program cannot be started.
    try
    {
        if (execute(["git", "--version"]).status != 0) return;
    }
    catch (Exception) return;

    // Git object files are read-only on Windows, which rmdirRecurse cannot delete.
    static void removeTree(string path)
    {
        import std.file : SpanMode, attrIsDir, dirEntries, getAttributes, setAttributes;
        if (!exists(path)) return;
        foreach (e; dirEntries(path, SpanMode.breadth))
        {
            if (!attrIsDir(getAttributes(e.name))) setAttributes(e.name, 0x80 /* FILE_ATTRIBUTE_NORMAL */);
        }
        rmdirRecurse(path);
    }

    const dir = buildPath(tempDir, "cfr_git_test");
    removeTree(dir);
    mkdirRecurse(dir);
    scope(exit) removeTree(dir);

    string git(string[] args...)
    {
        auto r = execute(["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.test",
            "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] ~ args, null, Config.suppressConsole);
        assert(r.status == 0, r.output);
        return r.output.strip;
    }

    git("init", "-q");
    write(buildPath(dir, "f"), "1");
    git("add", "f");
    git("commit", "-q", "-m", "one");
    const first = git("rev-parse", "HEAD");
    git("branch", "-M", "main");
    git("tag", "light");
    git("tag", "-a", "-m", "annotated", "ann");

    auto resolver = new GitRepositoryResolver();
    const addr = repo(dir);
    assert(resolver.resolve(addr, branch("main")).pin.pinned == Json(first));
    assert(resolver.resolve(addr, tag("light")).pin.pinned == Json(first));
    assert(resolver.resolve(addr, tag("ann")).pin.pinned == Json(first)); // peeled, not tag object
    assert(resolver.resolveName(addr, "ann").ref_ == tag("ann"));
    assert(resolver.resolveName(addr, first).pin.pinned == Json(first));
    assertThrown!GitResolutionException(resolver.resolve(addr, branch("light")), "A tag is not a branch");
    assertThrown!GitResolutionException(resolver.resolve(addr, branch("missing")));
    assertThrown!GitResolutionException(resolver.resolve(repo(buildPath(dir, "nonexistent")), branch("main")));

    // The output is the advertised lines in git's order, joined by newlines, with none at the end
    assert(runGitLsRemote(dir, ["refs/heads/main", "refs/tags/light"]) == first ~ "\trefs/heads/main\n" ~ first ~ "\trefs/tags/light",
        "Unexpected ls-remote output");
}
