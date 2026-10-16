module confector.plugins.step_executor.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName, isAbsolute, buildNormalizedPath, absolutePath, relativePath, dirSeparator;
import std.algorithm.searching : canFind, startsWith, endsWith;
import std.algorithm.sorting : sort;
import std.array : split;
import std.conv : to;
import std.string : strip, toLower, indexOf;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.vcs;
import confector.plugin_api.system : BuildStepSystem, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : LogDelegate;
import std.json : parseJSON;
import std.datetime : Clock;
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

/**
 * Parameters of the checkout step. A checkout step names a declared repository input by its
 * name (`input`) and checks out exactly that input's pinned commit; it never takes a URL, a
 * repository or a ref. Options:
 *
 * - `target_dir`: directory to check out into, relative to the step's working directory
 *   (default: the working directory itself); must stay inside the workspace.
 * - `depth`: fetch depth, a positive integer (default: full history).
 * - `submodules`: `true` or `false` (default: `true`, recursive).
 *
 * The git program is always `git` from the runner's PATH; a task cannot choose it.
 */
private immutable string[] checkoutParameters = ["input", "target_dir", "depth", "submodules"];

/// The null device, used as git's global configuration so no user-level configuration applies.
version (Windows) private enum nullDevice = "NUL";
else private enum nullDevice = "/dev/null";

/**
 * Returns the environment checkout runs git with: `inherited` (the runner's own environment
 * with the task's and step's on top) without any variable that changes how git behaves, plus
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
 * Git version control plugin: the built-in checkout step, plus webhook parsing and remote
 * state queries for the control plane.
 *
 * The checkout step checks out a repository input by name at its pinned commit SHA. The
 * repository's address comes from the work order and is used only here: it is passed to git on
 * the command line, never written to `.git/config` or anywhere else in the workspace, and
 * redacted from everything logged.
 */
class GitRunnerPlugin : StepExecutionPlugin, BuildStepSystem, VcsStateResolver
{
    private PluginContext m_context;

    @property string name() const { return "git-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git checkout step and repository state plugin"; }
    @property PluginCategory category() const { return PluginCategory.step_executor; }

    ConfigDefinition[] configDefinitions() const { return null; }
    @property string providerType() const { return "git"; }
    @property string systemName() const { return "git-checkout"; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("GitRunnerPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("GitRunnerPlugin shut down");
        }
    }

    bool canHandle(string repositoryAddress) const
    {
        import std.algorithm.searching : startsWith, endsWith;
        return repositoryAddress.startsWith("git@")
            || repositoryAddress.startsWith("http://")
            || repositoryAddress.startsWith("https://")
            || repositoryAddress.startsWith("ssh://")
            || repositoryAddress.endsWith(".git");
    }

    bool canExecuteStep(in BuildStep step) const
    {
        return step.type == "clone_repository"
            || step.type == "git_clone"
            || step.type == "checkout_repository"
            || step.type == "git:clone"
            || step.type == "git";
    }

    /**
     * Checks out the repository input the step names at its pinned commit. Fails, without
     * running git, if the step names no input, names an input the task does not declare or
     * that is not a repository input, carries any parameter other than those in
     * `checkoutParameters`, or the input's pinned value is not a full commit SHA.
     */
    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
    {
        StepExecutionResult res;

        StepExecutionResult fail(string message)
        {
            res.success = false;
            res.exitCode = res.exitCode != 0 ? res.exitCode : 1;
            res.errorMessage = message;
            if (context.logCallback !is null)
            {
                context.logCallback(format("[git] Error: %s", message));
            }
            return res;
        }

        string[] keys = step.parameters.keys;
        keys.sort();
        foreach (key; keys)
        {
            if (!checkoutParameters.canFind(key))
            {
                return fail(format("Checkout step parameter '%s' is not supported. A checkout step names a declared repository input with 'input' and checks out its pinned commit; supported parameters: %-(%s, %)",
                    key, checkoutParameters));
            }
        }
        if (step.command.length > 0 || step.script.length > 0)
        {
            return fail("A checkout step takes no command or script; name a declared repository input with the 'input' parameter");
        }

        string inputName = step.parameters.get("input", "");
        if (inputName.length == 0)
        {
            return fail("Checkout step has no 'input' parameter naming the repository input to check out");
        }
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

        string targetDirParam = step.parameters.get("target_dir", "");
        string checkoutDir = targetDirParam.length == 0
            ? context.workingDirectory
            : (isAbsolute(targetDirParam) ? targetDirParam : buildPath(context.workingDirectory, targetDirParam));
        if (!isWithinDirectory(checkoutDir, context.workspaceDir))
        {
            return fail(format("Target directory '%s' escapes workspace boundary '%s'", checkoutDir, context.workspaceDir));
        }

        string depth = step.parameters.get("depth", "");
        if (depth.length > 0)
        {
            uint parsed;
            try parsed = depth.to!uint;
            catch (Exception) parsed = 0;
            if (parsed == 0)
            {
                return fail(format("Checkout step 'depth' must be a positive integer, not '%s'", depth));
            }
        }

        bool submodules = true;
        if (auto p = "submodules" in step.parameters)
        {
            if (*p == "true") submodules = true;
            else if (*p == "false") submodules = false;
            else return fail(format("Checkout step 'submodules' must be 'true' or 'false', not '%s'", *p));
        }

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
        foreach (k, v; step.environment) inherited[k] = v;
        string[string] gitEnv = checkoutEnvironment(inherited, checkoutDir);

        if (context.logCallback !is null)
        {
            context.logCallback(format("[git] Checking out input '%s' at commit %s", inputName, sha));
        }

        try
        {
            int run(string[] args)
            {
                return runGit(["git"] ~ hermeticGitOptions ~ args, checkoutDir, gitEnv, res, context.logCallback);
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
                if (context.logCallback !is null)
                {
                    context.logCallback("[git] The repository did not serve the commit directly; fetching its branches and tags");
                }
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
        catch (Exception e)
        {
            res.exitCode = -1;
            return fail(format("Could not run git: %s", redactUserInfo(e.msg)));
        }

        res.success = true;
        res.exitCode = 0;
        return res;
    }

    /// Runs one git command in `dir` with standard input closed, appending its output, with any
    /// credentials in URLs redacted, to `res` and the log. Returns its exit code.
    private static int runGit(string[] args, string dir, string[string] env, ref StepExecutionResult res, LogDelegate log)
    {
        // newEnv: git sees exactly nv, never the runner's unfiltered environment
        auto pipe = pipeProcess(args, Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout, env,
            Config.newEnv, dir);
        pipe.stdin.close();
        foreach (line; pipe.stdout.byLineCopy)
        {
            string shown = redactUserInfo(line);
            res.outputLines ~= shown;
            if (log !is null)
            {
                log(shown);
            }
        }
        return wait(pipe.pid);
    }

    // ===================== VcsStateResolver implementation =====================

    VcsRepositoryState fetchLatestState(string repositoryUrl, string targetRef = null)
    {
        VcsRepositoryState state;
        state.repositoryUrl = repositoryUrl;
        state.providerType = "git";
        state.targetRef = targetRef !is null ? targetRef : "";
        state.updatedAt = Clock.currTime().toString();

        string[] args;
        args ~= ["git", "ls-remote", repositoryUrl];

        try
        {
            auto pipe = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr);
            scope(exit) wait(pipe.pid);

            foreach (line; pipe.stdout.byLineCopy)
            {
                auto trimmedLine = strip(line);
                if (trimmedLine.length == 0) continue;

                // Format: <SHA>\t<ref> (e.g., abc123\trefs/heads/main or abc123\tHEAD)
                auto tabPos = trimmedLine.indexOf('\t');
                if (tabPos < 0) continue;

                string sha = strip(trimmedLine[0 .. tabPos]);
                string refName = strip(trimmedLine[tabPos + 1 .. $]);

                if (sha.length == 0) continue;

                // If no target ref specified, prefer HEAD, then refs/heads/master, then refs/heads/main
                if (state.revision.length == 0)
                {
                    if (refName == "HEAD" || refName == "refs/heads/master" || refName == "refs/heads/main")
                    {
                        state.revision = sha;
                        if (refName == "HEAD")
                        {
                            // Try to resolve HEAD to a branch name
                            auto symref = line[0 .. tabPos]; // already have sha
                            state.targetRef = "HEAD";
                        }
                        else if (refName.startsWith("refs/heads/"))
                        {
                            state.targetRef = refName["refs/heads/".length .. $];
                        }
                    }
                }

                // If targetRef is specified, match it
                if (targetRef !is null && targetRef.length > 0)
                {
                    string expectedRef = "refs/heads/" ~ targetRef;
                    if (refName == expectedRef || refName == targetRef)
                    {
                        state.revision = sha;
                        state.targetRef = targetRef;
                    }
                }
            }

            // If we found HEAD but need to resolve the actual branch, do a second pass
            if (state.revision.length > 0 && state.targetRef == "HEAD" && targetRef is null)
            {
                // Try to get the symbolic ref
                string[] symArgs = ["git", "ls-remote", "--symref", repositoryUrl, "HEAD"];
                try
                {
                    auto symPipe = pipeProcess(symArgs, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr);
                    scope(exit) wait(symPipe.pid);

                    foreach (line; symPipe.stdout.byLineCopy)
                    {
                        auto trimmedLine2 = strip(line);
                        if (trimmedLine2.startsWith("ref:"))
                        {
                            // Format: ref: refs/heads/main\tHEAD
                            auto parts = split(trimmedLine2, '\t');
                            if (parts.length >= 1)
                            {
                                auto refPart = strip(parts[0]);
                                if (refPart.startsWith("ref: refs/heads/"))
                                {
                                    state.targetRef = refPart["ref: refs/heads/".length .. $];
                                }
                            }
                        }
                    }
                }
                catch (Throwable)
                {
                    // Ignore errors resolving symbolic ref
                }
            }

            if (m_context !is null && state.revision.length > 0)
            {
                m_context.info(format("[git] Fetched latest state for %s: %s (%s)", repositoryUrl, state.revision, state.targetRef));
            }
        }
        catch (Exception e)
        {
            if (m_context !is null)
            {
                m_context.error(format("[git] Failed to fetch latest state for %s: %s", repositoryUrl, e.msg));
            }
            // Return empty state on error; caller should handle missing revision
        }

        return state;
    }

    bool canHandleWebhook(in string[string] headers, in JSONValue payload) const
    {
        // Detect GitHub webhooks by X-GitHub-Event header
        foreach (header, value; headers)
        {
            if (toLower(header) == "x-github-event") return true;
            if (toLower(header) == "x-gitlab-event") return true;
            if (toLower(header) == "x-gitlab-token") return true;
        }

        // Detect by payload structure: look for common Git webhook fields
        if (payload.type == JSONType.object)
        {
            // GitHub push webhook has "ref" and "repository"
            if ("ref" in payload && "repository" in payload) return true;
            // GitLab push webhook has "ref" and "project"
            if ("ref" in payload && "project" in payload) return true;
            // Generic Git webhook with "commits" array
            if ("commits" in payload) return true;
        }

        return false;
    }

    bool parseWebhookPayload(
        in string[string] headers,
        in JSONValue payload,
        out VcsRepositoryState resolvedState
    )
    {
        resolvedState = VcsRepositoryState();
        resolvedState.providerType = "git";
        resolvedState.updatedAt = Clock.currTime().toString();

        try
        {
            if (payload.type != JSONType.object) return false;

            bool isGitHub = false;
            bool isGitLab = false;

            // Detect provider by headers
            foreach (header, value; headers)
            {
                auto h = header.toLower();
                if (h == "x-github-event") isGitHub = true;
                if (h == "x-gitlab-event" || h == "x-gitlab-token") isGitLab = true;
            }

            if (isGitHub)
            {
                // Parse GitHub webhook payload
                if ("repository" in payload && payload["repository"].type == JSONType.object)
                {
                    auto repo = payload["repository"];
                    if ("html_url" in repo) resolvedState.repositoryUrl = repo["html_url"].str;
                    else if ("clone_url" in repo) resolvedState.repositoryUrl = repo["clone_url"].str;
                    else if ("url" in repo) resolvedState.repositoryUrl = repo["url"].str;
                }

                if ("ref" in payload)
                {
                    string refValue = payload["ref"].str;
                    if (refValue.startsWith("refs/heads/"))
                    {
                        resolvedState.targetRef = refValue["refs/heads/".length .. $];
                    }
                    else
                    {
                        resolvedState.targetRef = refValue;
                    }
                }

                // After a push, "after" contains the new HEAD SHA
                if ("after" in payload)
                {
                    string after = payload["after"].str;
                    // GitHub sends 0000...0000 for deleted refs
                    if (after != "0000000000000000000000000000000000000000")
                    {
                        resolvedState.revision = after;
                    }
                }

                if ("head_commit" in payload && payload["head_commit"].type == JSONType.object)
                {
                    auto commit = payload["head_commit"];
                    if ("id" in commit) resolvedState.revision = commit["id"].str;
                    if ("message" in commit) resolvedState.message = commit["message"].str;
                    if ("author" in commit && commit["author"].type == JSONType.object)
                    {
                        auto author = commit["author"];
                        if ("name" in author) resolvedState.author = author["name"].str;
                    }
                }

                // For tag pushes, extract tag name
                if ("ref" in payload)
                {
                    string refValue = payload["ref"].str;
                    if (refValue.startsWith("refs/tags/"))
                    {
                        resolvedState.targetRef = refValue["refs/tags/".length .. $];
                        if ("pusher" in payload && payload["pusher"].type == JSONType.object)
                        {
                            auto pusher = payload["pusher"];
                            if ("name" in pusher) resolvedState.author = pusher["name"].str;
                        }
                    }
                }
            }
            else if (isGitLab)
            {
                // Parse GitLab webhook payload
                if ("project" in payload && payload["project"].type == JSONType.object)
                {
                    auto project = payload["project"];
                    if ("http_url_to_repo" in project) resolvedState.repositoryUrl = project["http_url_to_repo"].str;
                    else if ("git_http_url" in project) resolvedState.repositoryUrl = project["git_http_url"].str;
                    else if ("web_url" in project) resolvedState.repositoryUrl = project["web_url"].str;
                }

                if ("ref" in payload)
                {
                    string refValue = payload["ref"].str;
                    if (refValue.startsWith("refs/heads/"))
                    {
                        resolvedState.targetRef = refValue["refs/heads/".length .. $];
                    }
                    else
                    {
                        resolvedState.targetRef = refValue;
                    }
                }

                if ("after" in payload)
                {
                    string after = payload["after"].str;
                    if (after != "0000000000000000000000000000000000000000")
                    {
                        resolvedState.revision = after;
                    }
                }

                if ("commits" in payload && payload["commits"].type == JSONType.array)
                {
                    auto commits = payload["commits"].array;
                    if (commits.length > 0)
                    {
                        auto lastCommit = commits[$ - 1];
                        if (lastCommit.type == JSONType.object)
                        {
                            if ("id" in lastCommit) resolvedState.revision = lastCommit["id"].str;
                            if ("message" in lastCommit) resolvedState.message = lastCommit["message"].str;
                            if ("author_name" in lastCommit) resolvedState.author = lastCommit["author_name"].str;
                        }
                    }
                }
            }
            else
            {
                // Generic Git webhook parsing
                if ("repository" in payload)
                {
                    auto repo = payload["repository"];
                    if (repo.type == JSONType.object)
                    {
                        if ("url" in repo) resolvedState.repositoryUrl = repo["url"].str;
                        else if ("clone_url" in repo) resolvedState.repositoryUrl = repo["clone_url"].str;
                    }
                    else
                    {
                        resolvedState.repositoryUrl = repo.str;
                    }
                }

                if ("ref" in payload)
                {
                    string refValue = payload["ref"].str;
                    if (refValue.startsWith("refs/heads/"))
                    {
                        resolvedState.targetRef = refValue["refs/heads/".length .. $];
                    }
                    else
                    {
                        resolvedState.targetRef = refValue;
                    }
                }

                if ("commit" in payload)
                {
                    resolvedState.revision = payload["commit"].str;
                }
                else if ("sha" in payload)
                {
                    resolvedState.revision = payload["sha"].str;
                }

                if ("message" in payload) resolvedState.message = payload["message"].str;
                if ("author" in payload)
                {
                    auto author = payload["author"];
                    if (author.type == JSONType.object && "name" in author)
                    {
                        resolvedState.author = author["name"].str;
                    }
                    else
                    {
                        resolvedState.author = author.str;
                    }
                }
            }

            if (m_context !is null)
            {
                m_context.info(format("[git] Parsed webhook: %s @ %s (%s)", resolvedState.repositoryUrl, resolvedState.revision, resolvedState.targetRef));
            }

            return resolvedState.repositoryUrl.length > 0 && resolvedState.revision.length > 0;
        }
        catch (Exception e)
        {
            if (m_context !is null)
            {
                m_context.error(format("[git] Failed to parse webhook payload: %s", e.msg));
            }
            return false;
        }
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new GitRunnerPlugin();
}

version (unittest)
{
    private enum testSha = "1111111111111111111111111111111111111111";

    /// A step context for a task declaring repository input `src`, value input `flavor` and
    /// task_output input `bin`, with `src` pinned to `sha` at `address`.
    private StepExecutionContext checkoutContext(string workspace, string sha = testSha, string address = "https://example.test/game.git")
    {
        StepExecutionContext ctx;
        ctx.taskId = "compile";
        ctx.workspaceDir = workspace;
        ctx.workingDirectory = workspace;
        ctx.inputs["src"] = ResolvedInput("src", InputKind.repository, Json(sha));
        ctx.inputs["flavor"] = ResolvedInput("flavor", InputKind.value, Json("internal"));
        ctx.inputs["bin"] = ResolvedInput("bin", InputKind.taskOutput, Json("fp_upstream"));
        ctx.repositoryAddresses["src"] = address;
        return ctx;
    }

    private BuildStep checkoutStep(string[string] parameters)
    {
        BuildStep step;
        step.type = "clone_repository";
        step.parameters = parameters;
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
    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));
    assert(plugin.name == "git-runner");
    assert(plugin.category == PluginCategory.step_executor);
    assert(plugin.providerType == "git");
    assert(plugin.systemName == "git-checkout");

    assert(plugin.canHandle("https://github.com/dlang/dmd.git"));
    assert(plugin.canHandle("git@github.com:dlang/druntime.git"));
    assert(!plugin.canHandle("svn://svn.example.com/repo"));

    assert(plugin.canExecuteStep(checkoutStep(["input": "src"])));
    BuildStep bashStep;
    bashStep.type = "bash";
    assert(!plugin.canExecuteStep(bashStep));
}

unittest
{
    // A checkout step can only name a declared repository input; anything else fails before
    // git runs (none of these cases needs git)
    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));

    bool failsWith(StepExecutionContext ctx, BuildStep step, string expected)
    {
        auto res = plugin.executeStep(step, ctx);
        return !res.success && res.exitCode != 0 && res.errorMessage.canFind(expected);
    }

    auto ctx = checkoutContext(".");

    assert(failsWith(ctx, checkoutStep(null), "no 'input' parameter"));
    assert(failsWith(ctx, checkoutStep(["input": "tools"]), "'tools', which task 'compile' does not declare"));
    assert(failsWith(ctx, checkoutStep(["input": "flavor"]), "value input, not a repository input"));
    assert(failsWith(ctx, checkoutStep(["input": "bin"]), "task_output input, not a repository input"));

    // No URL, repository, address, ref or commit parameter: only the input's pinned commit
    foreach (param; ["repository", "url", "address", "repo", "branch", "ref", "commit", "sha", "executable"])
    {
        assert(failsWith(ctx, checkoutStep(["input": "src", param: "https://example.test/other.git"]),
            format("parameter '%s' is not supported", param)), param);
    }
    BuildStep withCommand = checkoutStep(["input": "src"]);
    withCommand.command = "https://example.test/other.git";
    assert(failsWith(ctx, withCommand, "takes no command"));

    // The pinned value must be a full commit SHA, and the work order must say where to fetch it
    assert(failsWith(checkoutContext(".", "main"), checkoutStep(["input": "src"]), "not pinned to a git commit SHA"));
    auto noAddress = checkoutContext(".");
    noAddress.repositoryAddresses = null;
    assert(failsWith(noAddress, checkoutStep(["input": "src"]), "no repository address for input 'src'"));
    assert(failsWith(checkoutContext(".", testSha, "--upload-pack=evil"), checkoutStep(["input": "src"]), "must not start with '-'"));

    // Options are validated, and the checkout stays inside the workspace
    assert(failsWith(ctx, checkoutStep(["input": "src", "target_dir": "../escape"]), "escapes workspace"));
    assert(failsWith(ctx, checkoutStep(["input": "src", "depth": "0"]), "positive integer"));
    assert(failsWith(ctx, checkoutStep(["input": "src", "submodules": "maybe"]), "'true' or 'false'"));
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

    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));

    string[] logged;
    auto ctx = checkoutContext(workspace, first, origin);
    ctx.logCallback = (string line) { logged ~= line; };
    auto res = plugin.executeStep(checkoutStep(["input": "src", "target_dir": "src"]), ctx);
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
    auto plantedRes = plugin.executeStep(checkoutStep(["input": "src", "target_dir": "planted"]), plantedCtx);
    assert(!plantedRes.success && plantedRes.errorMessage.canFind("already contains .git"), plantedRes.errorMessage);

    // The task's environment cannot change how git runs: a redirecting GIT_CONFIG_*, a foreign
    // GIT_DIR, a global config file and tracing are all ignored
    string elsewhere = buildPath(root, "e");
    mkdirRecurse(elsewhere);
    string globalConfig = buildPath(root, "gc");
    std.file.write(globalConfig, "[url \"" ~ buildPath(root, "nowhere").replace("\\", "/") ~ "\"]\n\tinsteadOf = " ~ origin.replace("\\", "\\\\") ~ "\n");
    auto hostile = checkoutContext(workspace, first, origin);
    hostile.environment = [
        "GIT_DIR": buildPath(elsewhere, ".git"),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url." ~ buildPath(root, "nowhere").replace("\\", "/") ~ ".insteadOf",
        "GIT_CONFIG_VALUE_0": origin,
        "GIT_CONFIG_GLOBAL": globalConfig,
        "GIT_TRACE": "1",
        "GIT_TRACE_CURL": "1",
    ];
    auto hostileRes = plugin.executeStep(checkoutStep(["input": "src", "target_dir": "h"]), hostile);
    assert(hostileRes.success, hostileRes.errorMessage);
    assert(gitIn(buildPath(workspace, "h"), ["rev-parse", "HEAD"]) == first);
    assert(!exists(buildPath(elsewhere, ".git")), "GIT_DIR from the task must not be honoured");
    foreach (line; hostileRes.outputLines) assert(!line.canFind("trace"), "GIT_TRACE from the task must not be honoured: " ~ line);

    // A pinned commit the repository does not have fails loudly, naming the input
    auto missing = checkoutContext(workspace, "0123456789abcdef0123456789abcdef01234567", origin);
    auto missingRes = plugin.executeStep(checkoutStep(["input": "src", "target_dir": "gone"]), missing);
    assert(!missingRes.success);
    assert(missingRes.errorMessage.canFind("no longer exists") && missingRes.errorMessage.canFind("'src'"), missingRes.errorMessage);
}

unittest
{
    // Test VcsStateResolver interface methods
    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));

    // Test canHandleWebhook with GitHub headers
    {
        string[string] githubHeaders = ["X-GitHub-Event": "push"];
        auto payload = parseJSON(`{"ref": "refs/heads/main", "repository": {"html_url": "https://github.com/example/repo"}}`);
        assert(plugin.canHandleWebhook(githubHeaders, payload));
    }

    // Test canHandleWebhook with GitLab headers
    {
        string[string] gitlabHeaders = ["X-GitLab-Event": "push"];
        auto payload = parseJSON(`{"ref": "refs/heads/main", "project": {"http_url_to_repo": "https://gitlab.com/example/repo"}}`);
        assert(plugin.canHandleWebhook(gitlabHeaders, payload));
    }

    // Test canHandleWebhook with payload structure (no headers)
    {
        string[string] emptyHeaders;
        auto payload = parseJSON(`{"ref": "refs/heads/main", "repository": {"url": "https://github.com/example/repo"}}`);
        assert(plugin.canHandleWebhook(emptyHeaders, payload));
    }

    // Test canHandleWebhook returns false for non-Git payloads
    {
        string[string] emptyHeaders;
        auto payload = parseJSON(`{"event": "deploy", "status": "success"}`);
        assert(!plugin.canHandleWebhook(emptyHeaders, payload));
    }

    // Test parseWebhookPayload for GitHub push
    {
        string[string] githubHeaders = ["X-GitHub-Event": "push"];
        auto payload = parseJSON(`{
            "ref": "refs/heads/main",
            "after": "abc123def456789012345678901234567890abcd",
            "repository": {
                "html_url": "https://github.com/example/repo"
            },
            "head_commit": {
                "id": "abc123def456789012345678901234567890abcd",
                "message": "Fix bug",
                "author": {"name": "Dev User"}
            }
        }`);
        VcsRepositoryState state;
        assert(plugin.parseWebhookPayload(githubHeaders, payload, state));
        assert(state.repositoryUrl == "https://github.com/example/repo");
        assert(state.targetRef == "main");
        assert(state.revision == "abc123def456789012345678901234567890abcd");
        assert(state.providerType == "git");
        assert(state.message == "Fix bug");
        assert(state.author == "Dev User");
    }

    // Test parseWebhookPayload for GitLab push
    {
        string[string] gitlabHeaders = ["X-GitLab-Event": "push"];
        auto payload = parseJSON(`{
            "ref": "refs/heads/develop",
            "after": "1234567890abcdef1234567890abcdef12345678",
            "project": {
                "http_url_to_repo": "https://gitlab.com/example/project"
            },
            "commits": [{
                "id": "1234567890abcdef1234567890abcdef12345678",
                "message": "Update feature",
                "author_name": "GitLab User"
            }]
        }`);
        VcsRepositoryState state;
        assert(plugin.parseWebhookPayload(gitlabHeaders, payload, state));
        assert(state.repositoryUrl == "https://gitlab.com/example/project");
        assert(state.targetRef == "develop");
        assert(state.revision == "1234567890abcdef1234567890abcdef12345678");
        assert(state.providerType == "git");
    }

    // Test parseWebhookPayload for generic webhook
    {
        string[string] emptyHeaders;
        auto payload = parseJSON(`{
            "repository": "https://github.com/example/repo",
            "ref": "refs/heads/main",
            "commit": "deadbeef1234567890abcdef1234567890abcdef",
            "message": "Generic commit"
        }`);
        VcsRepositoryState state;
        assert(plugin.parseWebhookPayload(emptyHeaders, payload, state));
        assert(state.repositoryUrl == "https://github.com/example/repo");
        assert(state.targetRef == "main");
        assert(state.revision == "deadbeef1234567890abcdef1234567890abcdef");
    }

    // Test parseWebhookPayload returns false for invalid payload
    {
        string[string] emptyHeaders;
        auto payload = parseJSON(`{"event": "unknown"}`);
        VcsRepositoryState state;
        assert(!plugin.parseWebhookPayload(emptyHeaders, payload, state));
    }

    // Test parseWebhookPayload for GitHub tag push
    {
        string[string] githubHeaders = ["X-GitHub-Event": "push"];
        auto payload = parseJSON(`{
            "ref": "refs/tags/v1.0.0",
            "after": "tagsha123456789012345678901234567890123456",
            "repository": {
                "html_url": "https://github.com/example/repo"
            },
            "pusher": {"name": "Tag Pusher"}
        }`);
        VcsRepositoryState state;
        assert(plugin.parseWebhookPayload(githubHeaders, payload, state));
        assert(state.targetRef == "v1.0.0");
        assert(state.author == "Tag Pusher");
    }

    // Test parseWebhookPayload ignores deleted refs (all zeros)
    {
        string[string] githubHeaders = ["X-GitHub-Event": "push"];
        auto payload = parseJSON(`{
            "ref": "refs/heads/deleted-branch",
            "after": "0000000000000000000000000000000000000000",
            "repository": {
                "html_url": "https://github.com/example/repo"
            }
        }`);
        VcsRepositoryState state;
        // Should return false because revision is empty (deleted ref)
        assert(!plugin.parseWebhookPayload(githubHeaders, payload, state));
    }
}
