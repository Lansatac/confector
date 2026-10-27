module confector.runner_core.steps.checkout;

import std.format;
import std.process;
import std.file;
import std.path : buildPath, baseName, isAbsolute, buildNormalizedPath, absolutePath, relativePath, dirSeparator;
import std.algorithm.searching : canFind, startsWith;
import std.string : strip, toLower;
import core.time : MonoTime, minutes, seconds;

import confector.api.model : BuildStep, InputKind, ResolvedInput;
import confector.core.git : isFullSha, redactUserInfo;
import confector.core.builtin_steps : checkoutConfig, checkoutConfigIssues, checkoutStepType;
import confector.runner_core.logging : LogDelegate;
import confector.runner_core.steps.process : runProcess;
import confector.runner_core.steps.step : StepContext, StepResult, StepTimeoutException, StopLimits;
import vibe.data.json : Json;

private bool isWithinDirectory(string targetPath, string baseDir) pure @safe
{
    if (baseDir.length == 0 || targetPath.length == 0)
        return false;

    string normBase = buildNormalizedPath(absolutePath(baseDir));
    string normTarget = buildNormalizedPath(absolutePath(targetPath));

    string rel = relativePath(normTarget, normBase);

    // If target is the same directory, relativePath returns "." or empty
    if (rel == "." || rel.length == 0)
        return true;

    // If target escapes baseDir, rel will start with ".." or be an absolute path (e.g. on different Windows drives)
    if (isAbsolute(rel) || rel == ".." || rel.startsWith(".." ~ dirSeparator) || rel.startsWith("../") || rel.startsWith("..\\"))
        return false;

    return true;
}

// The checkout step's config (`BuildStep.config`) is a JSON object with the keys
// `checkoutConfigKeys`, validated by `checkoutConfigIssues` (confector.core.builtin_steps). A checkout step names a declared repository input by its name (`input`,
// a string, required) and checks out exactly that input's pinned commit; it never takes a URL, a
// repository or a ref. Options:
//
// - `target_dir`: directory to check out into (a string), relative to the step's working
//   directory (default: the working directory itself); must stay inside the workspace.
// - `depth`: fetch depth, a positive integer (default: full history).
// - `submodules`: `true` or `false` (default: `true`, recursive).
//
// The git program is always `git` from the runner's PATH; a task cannot choose it.

/// The null device, used as git's global configuration so no user-level configuration applies.
version (Windows) private enum nullDevice = "NUL";
else private enum nullDevice = "/dev/null";

/**
 * Returns the environment checkout runs git with: `inherited` (the runner's own environment
 * with the task's on top) without any variable that changes how git behaves, plus
 * Confector's own settings.
 *
 * Every `GIT_*` variable is dropped (GIT_DIR, GIT_WORK_TREE, GIT_CONFIG_*, GIT_SSH*, GIT_TRACE*,
 * GIT_EXEC_PATH, GIT_ASKPASS, ...), as are `SSH_ASKPASS` and `XDG_CONFIG_HOME`. Then:
 * system and global configuration are disabled, nothing may prompt, ssh runs in batch mode,
 * and repository discovery stops at `checkoutDir`'s parent, so only the fresh repository in
 * `checkoutDir` is ever used.
 */
string[string] checkoutEnvironment(in string[string] inherited, string checkoutDir) @safe
{
    import std.path : dirName;
    import std.uni : toUpper;

    string[string] env;
    foreach (key, value; inherited)
    {
        const upper = key.toUpper;
        if (upper.startsWith("GIT_") || upper == "SSH_ASKPASS" || upper == "XDG_CONFIG_HOME") continue;
        env[key] = value;
    }
    env["GIT_CONFIG_NOSYSTEM"] = "1";
    env["GIT_CONFIG_GLOBAL"] = nullDevice;
    env["GIT_TERMINAL_PROMPT"] = "0";
    env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes";
    env["GIT_CEILING_DIRECTORIES"] = dirName(buildNormalizedPath(absolutePath(checkoutDir)));
    return env;
}

/// Configuration every checkout git command runs with, overriding anything that could hand
/// credentials to a helper or run code: no credential helpers, no fsmonitor, no `ext::` remotes.
private immutable string[] hermeticGitOptions = [
    "-c", "credential.helper=",
    "-c", "core.fsmonitor=false",
    "-c", "protocol.ext.allow=never",
    "-c", "advice.detachedHead=false",
];

unittest
{
    auto env = checkoutEnvironment([
        "PATH": "/usr/bin", "GIT_DIR": "/elsewhere", "git_work_tree": "/x", "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url.x.insteadOf", "GIT_TRACE_CURL": "1", "GIT_SSH": "evil", "GIT_EXEC_PATH": "/evil",
        "SSH_ASKPASS": "evil", "XDG_CONFIG_HOME": "/evil", "GIT_TERMINAL_PROMPT": "1",
    ], "/ws/src");
    assert(env["PATH"] == "/usr/bin");
    foreach (dropped; ["GIT_DIR", "git_work_tree", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_TRACE_CURL", "GIT_SSH",
        "GIT_EXEC_PATH", "SSH_ASKPASS", "XDG_CONFIG_HOME"])
    {
        assert(dropped !in env, dropped);
    }
    assert(env["GIT_TERMINAL_PROMPT"] == "0" && env["GIT_CONFIG_NOSYSTEM"] == "1" && env["GIT_CONFIG_GLOBAL"] == nullDevice);
}

/**
 * The built-in checkout step: checks out the repository input the step names at its pinned
 * commit SHA. The repository's address comes from the work order and is used only here: it is
 * passed to git on the command line, never written to `.git/config` or anywhere else in the
 * workspace, and redacted from everything logged.
 *
 * Fails, without running git, if the step's config has any problem `checkoutConfigIssues` finds
 * (not a JSON object, a key other than those in `checkoutConfigKeys`, a value of the wrong type,
 * no input), names an input the task does not declare or that is not a repository input, or
 * the input's pinned value is not a full commit SHA.
 *
 * Throws: Exception if `context.log` is null: a step's output always has somewhere to go.
 */
StepResult runCheckout(in BuildStep step, ref StepContext context)
{
    if (context.log is null) throw new Exception("The checkout step needs a log for its output (StepContext.log is null)");
    StepResult res;

    StepResult fail(string message)
    {
        res.success = false;
        res.exitCode = res.exitCode != 0 ? res.exitCode : 1;
        res.errorMessage = message;
        context.log(format("[git] Error: %s", message));
        return res;
    }

    // The config's keys and value types are checked as the task editor checks them on save
    const issues = checkoutConfigIssues(step.config);
    if (issues.length > 0)
    {
        return fail(format("Invalid checkout step config: %-(%s; %)", issues));
    }
    const settings = checkoutConfig(step.config);
    const inputName = settings.input;
    auto input = inputName in context.inputs;
    if (input is null)
    {
        return fail(format("Checkout step names input '%s', which task '%s' does not declare", inputName, context.taskId));
    }
    if (input.kind != InputKind.repository)
    {
        return fail(format("Checkout step names input '%s', which is a %s input, not a repository input",
            inputName, cast(string) input.kind));
    }
    if (input.pinned.type != Json.Type.string || !isFullSha(input.pinned.get!string))
    {
        return fail(format("Repository input '%s' is not pinned to a git commit SHA", inputName));
    }
    string sha = input.pinned.get!string.toLower;

    auto addressPtr = inputName in context.repositoryAddresses;
    if (addressPtr is null || addressPtr.length == 0)
    {
        return fail(format("The work order gives no repository address for input '%s'", inputName));
    }
    string address = *addressPtr;
    if (address.startsWith("-"))
    {
        return fail(format("The repository address of input '%s' must not start with '-'", inputName));
    }

    const targetDirParam = settings.targetDir;
    string checkoutDir = targetDirParam.length == 0
        ? context.workingDirectory
        : (isAbsolute(targetDirParam) ? targetDirParam : buildPath(context.workingDirectory, targetDirParam));
    if (!isWithinDirectory(checkoutDir, context.workspaceDir))
    {
        return fail(format("Target directory '%s' escapes workspace boundary '%s'", checkoutDir, context.workspaceDir));
    }

    const string depth = settings.depth > 0 ? format("%d", settings.depth) : "";
    const bool submodules = settings.submodules;

    // Checkout must start from a fresh repository: an existing .git (from an upstream
    // artifact or an earlier step) could carry configuration that redirects the fetch or
    // captures credentials.
    if (exists(buildPath(checkoutDir, ".git")))
    {
        return fail(format("Checkout directory '%s' already contains .git; check input '%s' out into a fresh directory (set target_dir)",
            checkoutDir, inputName));
    }

    if (!exists(checkoutDir))
    {
        mkdirRecurse(checkoutDir);
    }

    string[string] inherited = environment.toAA();
    foreach (k, v; context.environment) inherited[k] = v;
    string[string] gitEnv = checkoutEnvironment(inherited, checkoutDir);

    context.log(format("[git] Checking out input '%s' at commit %s", inputName, sha));

    try
    {
        int run(string[] args)
        {
            return runGit(["git"] ~ hermeticGitOptions ~ args, checkoutDir, gitEnv, context.deadline, context.stopLimits, context.log);
        }

        // No templates: the fresh repository has no hooks
        int code = run(["init", "--quiet", "--template="]);
        if (code != 0)
        {
            res.exitCode = code;
            return fail(format("git init failed with exit code %d", code));
        }

        // Fetch exactly the pinned commit, straight from the address: no remote is
        // configured, so the address never lands in .git/config.
        string[] fetchSha = ["fetch", "--no-tags", "--quiet"];
        if (depth.length > 0) fetchSha ~= "--depth=" ~ depth;
        fetchSha ~= ["--", address, sha];
        if (run(fetchSha) != 0)
        {
            // The server refuses to serve an unadvertised commit: fetch its branches and
            // tags, then require the commit to be among what they reach.
            context.log("[git] The repository did not serve the commit directly; fetching its branches and tags");
            code = run(["fetch", "--no-tags", "--quiet", "--", address,
                "+refs/heads/*:refs/confector/heads/*", "+refs/tags/*:refs/confector/tags/*"]);
            if (code != 0)
            {
                res.exitCode = code;
                return fail(format("git fetch for input '%s' failed with exit code %d", inputName, code));
            }
            if (run(["cat-file", "-e", sha ~ "^{commit}"]) != 0)
            {
                res.exitCode = 1;
                return fail(format("Commit %s of input '%s' no longer exists in its repository (force-pushed?). The build chain pins that commit, so a rerun cannot help; start a new build",
                    sha, inputName));
            }
        }

        code = run(["checkout", "--quiet", "--detach", sha, "--"]);
        if (code != 0)
        {
            res.exitCode = code;
            return fail(format("git checkout of commit %s failed with exit code %d", sha, code));
        }

        if (submodules)
        {
            code = run(["submodule", "update", "--init", "--recursive"]);
            if (code != 0)
            {
                res.exitCode = code;
                return fail(format("git submodule update failed with exit code %d", code));
            }
        }
    }
    catch (StepTimeoutException e)
    {
        // The task's deadline is reported by the executor, not as a git failure
        throw e;
    }
    catch (Exception e)
    {
        res.exitCode = -1;
        return fail(format("Could not run git: %s", redactUserInfo(e.msg)));
    }

    res.success = true;
    res.exitCode = 0;
    return res;
}

/// Runs one git command in `dir` with standard input closed, sending its output, with any
/// credentials in URLs redacted, to `log`. Returns its exit code. Stops it at `deadline`.
private int runGit(string[] args, string dir, string[string] env, MonoTime deadline, StopLimits limits, LogDelegate log)
{
    return runProcess(args, dir, env, deadline, limits, (string line) { log(redactUserInfo(line)); });
}

version (unittest)
{
    private enum testSha = "1111111111111111111111111111111111111111";

    /// A step context for a task declaring repository input `src`, value input `flavor` and
    /// task_output input `bin`, with `src` pinned to `sha` at `address`. Its log drops lines.
    private StepContext checkoutContext(string workspace, string sha = testSha, string address = "https://example.test/game.git")
    {
        StepContext ctx;
        ctx.executionId = "exe_checkout";
        ctx.taskId = "compile";
        ctx.log = (string line) {};
        ctx.workspaceDir = workspace;
        ctx.workingDirectory = workspace;
        ctx.inputs["src"] = ResolvedInput("src", InputKind.repository, Json(sha));
        ctx.inputs["flavor"] = ResolvedInput("flavor", InputKind.value, Json("internal"));
        ctx.inputs["bin"] = ResolvedInput("bin", InputKind.taskOutput, Json("fp_upstream"));
        ctx.repositoryAddresses["src"] = address;
        ctx.deadline = MonoTime.currTime + 10.minutes;
        return ctx;
    }

    /// A checkout step whose config holds the string settings `settings`.
    private BuildStep checkoutStep(string[string] settings)
    {
        Json config = Json.emptyObject;
        foreach (key, value; settings) config[key] = value;
        return BuildStep(null, checkoutStepType, config);
    }

    /// A checkout step of input `src` whose config also holds `key: value`.
    private BuildStep checkoutStepWith(string key, Json value)
    {
        BuildStep step = checkoutStep(["input": "src"]);
        step.config[key] = value;
        return step;
    }

    /// Removes a directory tree that may contain git's read-only object files.
    private void removeTree(string dir)
    {
        version (Windows)
        {
            enum uint readOnly = 0x1; // FILE_ATTRIBUTE_READONLY
            foreach (DirEntry entry; dirEntries(dir, SpanMode.depth, false))
            {
                if (entry.isFile && (entry.attributes & readOnly)) setAttributes(entry.name, entry.attributes & ~readOnly);
            }
        }
        rmdirRecurse(dir);
    }

    /// Runs git in `dir`, asserting success, and returns its trimmed output.
    private string gitIn(string dir, string[] args)
    {
        auto r = execute(["git", "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"] ~ args,
            null, Config.none, size_t.max, dir);
        assert(r.status == 0, format("git %s failed: %s", args, r.output));
        return r.output.strip;
    }
}

unittest
{
    // A checkout step can only name a declared repository input; anything else fails before
    // git runs (none of these cases needs git)
    bool failsWith(StepContext ctx, BuildStep step, string expected)
    {
        auto res = runCheckout(step, ctx);
        return !res.success && res.exitCode != 0 && res.errorMessage.canFind(expected);
    }

    auto ctx = checkoutContext(".");

    assert(failsWith(ctx, checkoutStep(null), "no 'input'"));
    assert(failsWith(ctx, BuildStep(null, "checkout"), "no 'input'"), "A step without config names no input");
    assert(failsWith(ctx, BuildStep(null, "checkout", Json("src")), "must be a JSON object"));
    assert(failsWith(ctx, BuildStep(null, "checkout", Json([Json("src")])), "must be a JSON object"));
    assert(failsWith(ctx, BuildStep(null, "checkout", Json(["input": Json(1)])), "'input' must be a string"));
    assert(failsWith(ctx, checkoutStep(["input": "tools"]), "'tools', which task 'compile' does not declare"));
    assert(failsWith(ctx, checkoutStep(["input": "flavor"]), "value input, not a repository input"));
    assert(failsWith(ctx, checkoutStep(["input": "bin"]), "task_output input, not a repository input"));

    // No URL, repository, address, ref, commit, command or script setting: only the input's
    // pinned commit. Nor a step environment or working directory: git's environment is fixed
    foreach (key; ["repository", "url", "address", "repo", "branch", "ref", "commit", "sha", "executable", "command", "script",
        "environment", "working_directory"])
    {
        assert(failsWith(ctx, checkoutStep(["input": "src", key: "https://example.test/other.git"]),
            format("key '%s' is not supported", key)), key);
    }

    // The pinned value must be a full commit SHA, and the work order must say where to fetch it
    assert(failsWith(checkoutContext(".", "main"), checkoutStep(["input": "src"]), "not pinned to a git commit SHA"));
    auto noAddress = checkoutContext(".");
    noAddress.repositoryAddresses = null;
    assert(failsWith(noAddress, checkoutStep(["input": "src"]), "no repository address for input 'src'"));
    assert(failsWith(checkoutContext(".", testSha, "--upload-pack=evil"), checkoutStep(["input": "src"]), "must not start with '-'"));

    // Options are validated, and the checkout stays inside the workspace
    assert(failsWith(ctx, checkoutStep(["input": "src", "target_dir": "../escape"]), "escapes workspace"));
    assert(failsWith(ctx, checkoutStepWith("target_dir", Json(3)), "'target_dir' must be a string"));
    foreach (depth; [Json(0), Json(-1), Json(1.5), Json("1"), Json(5_000_000_000L)])
    {
        assert(failsWith(ctx, checkoutStepWith("depth", depth), "positive integer"), depth.toString());
    }
    assert(failsWith(ctx, checkoutStepWith("submodules", Json("maybe")), "true or false"));
    assert(failsWith(ctx, checkoutStepWith("submodules", Json("false")), "true or false"), "A string is not a boolean");

    // A context without a log is refused outright, not given a silent default
    auto noLog = checkoutContext(".");
    noLog.log = null;
    bool refused = false;
    try runCheckout(checkoutStep(["input": "src"]), noLog);
    catch (Exception e) refused = e.msg.canFind("StepContext.log is null");
    assert(refused);
}

unittest
{
    // A checkout whose task has run out of time throws StepTimeoutException, not a failed result
    import std.uuid : randomUUID;

    string workspace = buildPath(tempDir(), "cfx" ~ randomUUID().toString()[0 .. 6]);
    mkdirRecurse(workspace);
    scope(exit) if (exists(workspace)) removeTree(workspace);

    auto ctx = checkoutContext(workspace);
    ctx.deadline = MonoTime.currTime - 1.seconds;
    bool timedOut = false;
    try runCheckout(checkoutStep(["input": "src", "target_dir": "late"]), ctx);
    catch (StepTimeoutException e) timedOut = true;
    assert(timedOut, "A checkout past its deadline did not throw StepTimeoutException");
}

unittest
{
    // Checkout by input name against a local repository: exactly the pinned commit, not the
    // branch tip, and the address is not written into the workspace
    import std.uuid : randomUUID;

    try
    {
        if (execute(["git", "--version"]).status != 0) return;
    }
    catch (Exception) return;

    string root = buildPath(tempDir(), "cfx" ~ randomUUID().toString()[0 .. 6]);
    string origin = buildPath(root, "o");
    string workspace = buildPath(root, "w");
    mkdirRecurse(origin);
    mkdirRecurse(workspace);
    scope(exit) if (exists(root)) removeTree(root);

    gitIn(origin, ["init", "--quiet"]);
    std.file.write(buildPath(origin, "version.txt"), "one");
    gitIn(origin, ["add", "version.txt"]);
    gitIn(origin, ["commit", "--quiet", "-m", "one"]);
    string first = gitIn(origin, ["rev-parse", "HEAD"]);
    std.file.write(buildPath(origin, "version.txt"), "two");
    gitIn(origin, ["commit", "--quiet", "-am", "two"]);
    string tip = gitIn(origin, ["rev-parse", "HEAD"]);
    assert(first != tip);

    string[] logged;
    auto ctx = checkoutContext(workspace, first, origin);
    ctx.log = (string line) { logged ~= line; };
    auto res = runCheckout(checkoutStep(["input": "src", "target_dir": "src"]), ctx);
    assert(res.success, res.errorMessage);

    string checkout = buildPath(workspace, "src");
    assert(readText(buildPath(checkout, "version.txt")) == "one", "The pinned commit is checked out, not the branch tip");
    assert(gitIn(checkout, ["rev-parse", "HEAD"]) == first);
    assert(!readText(buildPath(checkout, ".git", "config")).canFind(baseName(root)),
        "The repository address must not be written into the workspace");

    import std.array : replace;

    // A pre-existing .git (here one whose config would redirect the fetch) is refused, not reused
    string planted = buildPath(workspace, "planted");
    mkdirRecurse(buildPath(planted, ".git"));
    std.file.write(buildPath(planted, ".git", "config"), "[url \"" ~ buildPath(root, "nowhere").replace("\\", "/") ~ "\"]\n\tinsteadOf = " ~ origin.replace("\\", "\\\\") ~ "\n");
    auto plantedCtx = checkoutContext(workspace, first, origin);
    auto plantedRes = runCheckout(checkoutStep(["input": "src", "target_dir": "planted"]), plantedCtx);
    assert(!plantedRes.success && plantedRes.errorMessage.canFind("already contains .git"), plantedRes.errorMessage);

    // The task's environment cannot change how git runs: a redirecting GIT_CONFIG_*, a foreign
    // GIT_DIR, a global config file and tracing are all ignored
    string elsewhere = buildPath(root, "e");
    mkdirRecurse(elsewhere);
    string globalConfig = buildPath(root, "gc");
    std.file.write(globalConfig, "[url \"" ~ buildPath(root, "nowhere").replace("\\", "/") ~ "\"]\n\tinsteadOf = " ~ origin.replace("\\", "\\\\") ~ "\n");
    string[] hostileLogged;
    auto hostile = checkoutContext(workspace, first, origin);
    hostile.log = (string line) { hostileLogged ~= line; };
    hostile.environment = [
        "GIT_DIR": buildPath(elsewhere, ".git"),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url." ~ buildPath(root, "nowhere").replace("\\", "/") ~ ".insteadOf",
        "GIT_CONFIG_VALUE_0": origin,
        "GIT_CONFIG_GLOBAL": globalConfig,
        "GIT_TRACE": "1",
        "GIT_TRACE_CURL": "1",
    ];
    auto hostileRes = runCheckout(checkoutStep(["input": "src", "target_dir": "h"]), hostile);
    assert(hostileRes.success, hostileRes.errorMessage);
    assert(gitIn(buildPath(workspace, "h"), ["rev-parse", "HEAD"]) == first);
    assert(!exists(buildPath(elsewhere, ".git")), "GIT_DIR from the task must not be honoured");
    foreach (line; hostileLogged) assert(!line.canFind("trace"), "GIT_TRACE from the task must not be honoured: " ~ line);

    // A pinned commit the repository does not have fails loudly, naming the input
    auto missing = checkoutContext(workspace, "0123456789abcdef0123456789abcdef01234567", origin);
    auto missingRes = runCheckout(checkoutStep(["input": "src", "target_dir": "gone"]), missing);
    assert(!missingRes.success);
    assert(missingRes.errorMessage.canFind("no longer exists") && missingRes.errorMessage.canFind("'src'"), missingRes.errorMessage);

    // Credentials in a repository address never reach the log or the error, even when git
    // fails and reports the address. Port 0 cannot be connected to, so the fetch fails at once
    // without depending on the network or on what listens locally.
    string[] credentialLogged;
    auto withCredentials = checkoutContext(workspace, first, "https://x-access-token:s3cr3t@127.0.0.1:0/nothing.git");
    withCredentials.log = (string line) { credentialLogged ~= line; };
    auto credentialRes = runCheckout(checkoutStep(["input": "src", "target_dir": "creds"]), withCredentials);
    assert(!credentialRes.success);
    assert(!credentialRes.errorMessage.canFind("s3cr3t"), credentialRes.errorMessage);
    assert(credentialLogged.canFind!(line => line.canFind("127.0.0.1")), "git's report of the address reaches the log");
    foreach (line; credentialLogged) assert(!line.canFind("s3cr3t"), "A credential reached the log: " ~ line);
}
