module confector.core.git_resolver;

/**
 * The built-in git RepositoryResolver (design records: beads confector-z7z.13 and
 * confector-z7z.7): turns a repository input's ref selector into a commit SHA with
 * `git ls-remote`.
 *
 * The pinned value is the commit SHA alone, as a Json string; the ref that was selected goes
 * into `InputPin.info` for display. Imperative shell and functional core are separate:
 * `parseLsRemote` and `selectGitRef` are pure; running git is behind the `LsRemote` seam so
 * tests can run without a network or a git installation.
 *
 * Selectors:
 * - a full 40-hex (SHA-1) or 64-hex (SHA-256) object id is already pinned and is returned
 *   without contacting the repository (lowercased);
 * - `HEAD`, or a fully qualified ref (`refs/heads/main`, `refs/tags/v1`), selects exactly that;
 * - a short name (`main`, `v1`) selects the branch or the tag of that name. A name that is both
 *   a branch and a tag is ambiguous and fails; qualify it.
 * An annotated tag resolves to the commit it points at (its peeled `^{}` entry).
 */

import confector.plugin_api.input_resolver : InputPin, RepositoryResolver;
import confector.plugin_api.model : InputDecl, InputKind, RepositoryRecord;

import vibe.data.json : Json;

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind, startsWith;
import std.array : appender;
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

/// True if `s` is a complete git object id: 40 (SHA-1) or 64 (SHA-256) hex digits.
bool isFullSha(string s) pure nothrow @safe @nogc
{
    if (s.length != 40 && s.length != 64) return false;
    foreach (immutable char c; s)
    {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

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

/// The refs `selector` could name, as full ref names, and the ls-remote patterns that fetch them.
string[] candidateRefNames(string selector) pure @safe
{
    if (selector == "HEAD" || selector.startsWith("refs/")) return [selector];
    return ["refs/heads/" ~ selector, "refs/tags/" ~ selector];
}

/// The ls-remote patterns that cover `candidateRefNames(selector)` and peeled tags.
string[] lsRemotePatterns(string selector) pure @safe
{
    string[] patterns;
    foreach (name; candidateRefNames(selector))
    {
        patterns ~= name;
        patterns ~= name ~ "^{}";
    }
    return patterns;
}

/**
 * Selects the commit `selector` names from `refs`. Pure.
 *
 * Throws: GitResolutionException if the selector is empty, names no ref, or names more than one
 * (a branch and a tag of the same name).
 */
GitRef selectGitRef(string selector, const GitRef[] refs) pure @safe
{
    if (selector.length == 0)
    {
        throw new GitResolutionException("Git ref selector is empty");
    }

    GitRef[] found;
    foreach (name; candidateRefNames(selector))
    {
        const peeled = name ~ "^{}";
        string direct, peel;
        foreach (r; refs)
        {
            if (r.name == name) direct = r.sha;
            else if (r.name == peeled) peel = r.sha;
        }
        // An annotated tag is advertised twice; its peeled entry is the commit.
        if (peel.length > 0) found ~= GitRef(name, peel);
        else if (direct.length > 0) found ~= GitRef(name, direct);
    }

    if (found.length == 0)
    {
        throw new GitResolutionException(format("Git ref '%s' does not exist in the repository", selector));
    }
    if (found.length > 1)
    {
        string[] names;
        foreach (f; found) names ~= f.name;
        throw new GitResolutionException(format(
            "Git ref selector '%s' is ambiguous; it matches %-(%s, %). Use a fully qualified ref", selector, names));
    }
    return found[0];
}

/**
 * Replaces the userinfo of every URL in `text` (`https://user:token@host/...` becomes
 * `https://***@host/...`), so credentials embedded in a repository address never reach an
 * exception message or a log. Pure.
 */
string redactUserInfo(string text) pure @safe
{
    import std.ascii : isWhite;

    auto app = appender!string();
    size_t i = 0;
    while (i < text.length)
    {
        const sep = text[i .. $].indexOf("://");
        if (sep < 0)
        {
            app.put(text[i .. $]);
            break;
        }
        const authorityStart = i + sep + 3;
        app.put(text[i .. authorityStart]);

        // The authority runs to the next '/', whitespace or end; its userinfo ends at its last '@'.
        size_t end = authorityStart;
        ptrdiff_t at = -1;
        while (end < text.length && text[end] != '/' && !isWhite(text[end]))
        {
            if (text[end] == '@') at = end;
            ++end;
        }
        if (at >= 0)
        {
            app.put("***");
            app.put(text[at .. end]);
        }
        else
        {
            app.put(text[authorityStart .. end]);
        }
        i = end;
    }
    return app.data;
}

/// How long `git ls-remote` may run before it is killed. A remote that does not answer within
/// this time fails resolution; it is generous because large repositories advertise many refs.
enum Duration lsRemoteTimeout = 120.seconds;

/**
 * Runs the real `git ls-remote`, unable to wait for a person: standard input is not
 * inherited, terminal prompts are disabled (`GIT_TERMINAL_PROMPT=0`), ssh runs with
 * `BatchMode=yes` unless the environment already sets `GIT_SSH_COMMAND` or `GIT_SSH`, and git is
 * killed after `timeout`. Credentials in `address` are redacted from error messages.
 *
 * Throws: GitResolutionException if git cannot be run, exits non-zero or times out.
 */
string runGitLsRemote(string address, string[] patterns, Duration timeout = lsRemoteTimeout)
{
    import core.thread : Thread;
    import std.datetime.stopwatch : AutoStart, StopWatch;
    import std.process : Config, Redirect, environment, kill, pipeProcess, tryWait, wait;

    const shown = redactUserInfo(address);
    const command = ["git", "ls-remote", "--"] ~ address ~ patterns;

    string[string] env = ["GIT_TERMINAL_PROMPT": "0"];
    if (environment.get("GIT_SSH_COMMAND") is null && environment.get("GIT_SSH") is null)
    {
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes";
    }

    try
    {
        auto pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout, env,
            Config.suppressConsole);
        pipes.stdin.close();

        // Read on a separate thread so the deadline is enforced even while git produces no
        // output. If git is killed, a helper it spawned (ssh, git-remote-https) may keep the
        // pipe open; the daemon reader is then abandoned rather than waited for.
        string output;
        auto reader = new Thread({
            foreach (chunk; pipes.stdout.byChunk(4096)) output ~= cast(const(char)[]) chunk;
        });
        reader.isDaemon = true;
        reader.start();

        auto clock = StopWatch(AutoStart.yes);
        auto status = tryWait(pipes.pid);
        while (!status.terminated)
        {
            if (clock.peek > timeout)
            {
                kill(pipes.pid);
                wait(pipes.pid);
                throw new GitResolutionException(format("git ls-remote %s timed out after %s", shown, timeout));
            }
            Thread.sleep(20.msecs);
            status = tryWait(pipes.pid);
        }
        while (reader.isRunning)
        {
            if (clock.peek > timeout)
            {
                throw new GitResolutionException(format(
                    "git ls-remote %s exited but its output did not end within %s", shown, timeout));
            }
            Thread.sleep(5.msecs);
        }
        reader.join();

        if (status.status != 0)
        {
            throw new GitResolutionException(format(
                "git ls-remote %s failed with exit code %s: %s", shown, status.status, redactUserInfo(output.strip)));
        }
        return output;
    }
    catch (GitResolutionException e) throw e;
    catch (Exception e)
    {
        throw new GitResolutionException(format("Could not run git ls-remote %s: %s", shown, redactUserInfo(e.msg)));
    }
}

/**
 * Resolves git repository inputs: the repository's `address` is the git remote, the input's
 * ref selector selects a commit.
 */
class GitRepositoryResolver : RepositoryResolver
{
    private LsRemote lsRemote;

    /// `lsRemote` runs `git ls-remote`; defaults to the real thing. Tests inject a fake.
    this(LsRemote lsRemote = null)
    {
        this.lsRemote = lsRemote !is null ? lsRemote : (a, p) => runGitLsRemote(a, p);
    }

    InputPin resolve(in RepositoryRecord repository, in InputDecl input)
    {
        if (input.kind != InputKind.repository)
        {
            throw new GitResolutionException(format("Input of kind '%s' is not a repository input", cast(string) input.kind));
        }
        const selector = input.spec.refSelector;
        if (selector.length == 0)
        {
            throw new GitResolutionException(format("Repository '%s': git ref selector is empty", repository.name));
        }

        InputPin pin;
        if (isFullSha(selector))
        {
            pin.pinned = Json(selector.toLower);
            pin.info["ref"] = selector.toLower;
            return pin;
        }

        if (repository.address.length == 0)
        {
            throw new GitResolutionException(format("Repository '%s' has no address", repository.name));
        }
        if (repository.address.startsWith("-") || selector.startsWith("-"))
        {
            throw new GitResolutionException(format(
                "Repository '%s': address or ref selector must not start with '-'", repository.name));
        }

        string output;
        try output = lsRemote(repository.address, lsRemotePatterns(selector));
        catch (GitResolutionException e) throw new GitResolutionException(
            format("Repository '%s': %s", repository.name, e.msg));

        const chosen = selectGitRef(selector, parseLsRemote(output));
        pin.pinned = Json(chosen.sha);
        pin.info["ref"] = chosen.name;
        return pin;
    }
}

version (unittest)
{
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
}

unittest // parseLsRemote keeps refs, skips noise, lowercases
{
    const refs = parseLsRemote("warning: something\n" ~ sha1a ~ "\trefs/heads/main\r\n\nABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD\tHEAD\n");
    assert(refs.length == 2);
    assert(refs[0] == GitRef("refs/heads/main", sha1a));
    assert(refs[1].sha == "abcdefabcdefabcdefabcdefabcdefabcdefabcd");
}

unittest // branch, lightweight tag, annotated tag (peeled), HEAD, qualified
{
    const refs = parseLsRemote(fakeOutput([
        [sha1a, "HEAD"], [sha1a, "refs/heads/main"], [sha1b, "refs/tags/light"],
        [sha1b, "refs/tags/ann"], [sha1c, "refs/tags/ann^{}"],
    ]));
    assert(selectGitRef("main", refs) == GitRef("refs/heads/main", sha1a));
    assert(selectGitRef("light", refs).sha == sha1b);
    assert(selectGitRef("ann", refs).sha == sha1c);
    assert(selectGitRef("refs/tags/ann", refs).sha == sha1c);
    assert(selectGitRef("HEAD", refs).sha == sha1a);
}

unittest // missing, ambiguous and empty selectors throw
{
    import std.exception : assertThrown;

    const refs = parseLsRemote(fakeOutput([
        [sha1a, "refs/heads/dup"], [sha1b, "refs/tags/dup"], [sha1a, "refs/heads/feature/main"],
    ]));
    assertThrown!GitResolutionException(selectGitRef("nope", refs));
    assertThrown!GitResolutionException(selectGitRef("main", refs)); // only a tail match, not a ref
    assertThrown!GitResolutionException(selectGitRef("dup", refs));
    assertThrown!GitResolutionException(selectGitRef("", refs));
    assert(selectGitRef("refs/tags/dup", refs).sha == sha1b);
}

unittest // resolver: branch, tag, patterns passed to git, info
{
    string[] seen;
    auto resolver = new GitRepositoryResolver((a, p) {
        seen = [a] ~ p;
        return fakeOutput([[sha1a, "refs/heads/main"], [sha1b, "refs/tags/v1"], [sha1c, "refs/tags/v1^{}"]]);
    });
    const pin = resolver.resolve(repo(), repositoryInputFor("main"));
    assert(pin.pinned == Json(sha1a));
    assert(pin.info["ref"] == "refs/heads/main");
    assert(seen[0] == "https://example.test/r.git" && seen.canFind("refs/heads/main"));
    assert(resolver.resolve(repo(), repositoryInputFor("v1")).pinned == Json(sha1c));
}

unittest // credentials in URLs are redacted
{
    assert(redactUserInfo("https://user:t0ken@example.test/r.git") == "https://***@example.test/r.git");
    assert(redactUserInfo("git ls-remote https://x-access-token:abc@github.com/o/r failed: fatal: https://tok@github.com/o/r not found")
        == "git ls-remote https://***@github.com/o/r failed: fatal: https://***@github.com/o/r not found");
    assert(redactUserInfo("ssh://git@host:22/r.git") == "ssh://***@host:22/r.git");
    assert(redactUserInfo("https://u:p@ss@host/r") == "https://***@host/r", "Userinfo ends at the last '@'");
    assert(redactUserInfo("https://example.test/a@b") == "https://example.test/a@b", "An '@' in the path is not userinfo");
    assert(redactUserInfo("git@host:org/r.git") == "git@host:org/r.git");
    assert(redactUserInfo("") == "" && redactUserInfo("no url here") == "no url here");
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

unittest // resolver: a full SHA is pinned without calling git
{
    auto resolver = new GitRepositoryResolver((a, p) { assert(false, "must not run git"); return ""; });
    const sha256 = "AB" ~ "0".replicate(62);
    assert(resolver.resolve(repo(), repositoryInputFor(sha1a)).pinned == Json(sha1a));
    assert(resolver.resolve(repo(), repositoryInputFor(sha256)).pinned == Json(sha256.toLower));
    assert(!isFullSha("abc123"));
}

unittest // resolver fails loudly
{
    import std.exception : assertThrown;

    auto empty = new GitRepositoryResolver((a, p) => "");
    assertThrown!GitResolutionException(empty.resolve(repo(), repositoryInputFor("main")));
    assertThrown!GitResolutionException(empty.resolve(repo(""), repositoryInputFor("main")));
    assertThrown!GitResolutionException(empty.resolve(repo(), repositoryInputFor("--upload-pack=x")));
    assertThrown!GitResolutionException(empty.resolve(repo(), repositoryInputFor("")));
    assertThrown!GitResolutionException(empty.resolve(repo(), valueInputFor()));

    auto failing = new GitRepositoryResolver((string a, string[] p) { throw new GitResolutionException("boom"); return ""; });
    assertThrown!GitResolutionException(failing.resolve(repo(), repositoryInputFor("main")));
}

version (unittest)
{
    import confector.plugin_api.model : repositoryInput, valueInput;
    import std.array : replicate;

    private InputDecl repositoryInputFor(string selector) { return repositoryInput("r", selector); }
    private InputDecl valueInputFor() { return valueInput("x"); }
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
    assert(resolver.resolve(addr, repositoryInputFor("main")).pinned == Json(first));
    assert(resolver.resolve(addr, repositoryInputFor("light")).pinned == Json(first));
    assert(resolver.resolve(addr, repositoryInputFor("ann")).pinned == Json(first)); // peeled, not tag object
    assert(resolver.resolve(addr, repositoryInputFor(first)).pinned == Json(first));
    assertThrown!GitResolutionException(resolver.resolve(addr, repositoryInputFor("missing")));
    assertThrown!GitResolutionException(resolver.resolve(repo(buildPath(dir, "nonexistent")), repositoryInputFor("main")));
}
