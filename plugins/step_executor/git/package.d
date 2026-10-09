module plugins.step_executor.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName, isAbsolute, buildNormalizedPath, absolutePath, relativePath, dirSeparator;
import std.algorithm.searching : canFind, startsWith, endsWith;
import std.array : split;
import std.string : strip, toLower, indexOf;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.vcs;
import confector.plugin_api.system : InputResolverSystem, InputResolutionContext, BuildStepSystem, StepExecutionContext, StepExecutionResult, FingerprintContributionSystem, FingerprintContributionContext;
import confector.plugin_api.executor : LogDelegate;
import std.json : parseJSON;
import std.datetime : Clock;

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

private string normalizeRepoUrl(string url) pure @safe
{
    import std.string : toLower, strip;
    import std.algorithm.searching : endsWith;
    string u = url.strip().toLower();
    while (u.endsWith("/")) u = u[0 .. $ - 1];
    if (u.endsWith(".git")) u = u[0 .. $ - 4];
    return u;
}

private bool isRepoMatch(string candidate, string target, in string[string] repoMap = null) pure @safe
{
    if (candidate == target) return true;
    if (repoMap !is null)
    {
        if (auto p = candidate in repoMap)
        {
            if (*p == target || isRepoMatch(*p, target)) return true;
        }
        if (auto p = target in repoMap)
        {
            if (candidate == *p || isRepoMatch(candidate, *p)) return true;
        }
    }
    string nCandidate = normalizeRepoUrl(candidate);
    string nTarget = normalizeRepoUrl(target);
    if (nCandidate.length > 0 && nCandidate == nTarget) return true;

    // Check if one is SSH format and other is HTTPS format for same repo
    // e.g. git@github.com:org/repo and https://github.com/org/repo
    import std.algorithm.searching : startsWith;
    import std.string : indexOf;

    string getHostAndPath(string url)
    {
        string norm = normalizeRepoUrl(url);
        if (norm.startsWith("https://")) norm = norm[8 .. $];
        else if (norm.startsWith("http://")) norm = norm[7 .. $];
        else if (norm.startsWith("ssh://git@"))
        {
            norm = norm[10 .. $];
            auto colonIdx = norm.indexOf(':');
            if (colonIdx != -1) norm = norm[0 .. colonIdx] ~ "/" ~ norm[colonIdx + 1 .. $];
        }
        else if (norm.startsWith("git@"))
        {
            norm = norm[4 .. $];
            auto colonIdx = norm.indexOf(':');
            if (colonIdx != -1) norm = norm[0 .. colonIdx] ~ "/" ~ norm[colonIdx + 1 .. $];
        }
        return norm;
    }

    auto hCandidate = getHostAndPath(candidate);
    auto hTarget = getHostAndPath(target);
    if (hCandidate.length > 0 && hCandidate == hTarget)
    {
        return true;
    }

    return false;
}

/**
 * Git repository provider, input resolution, and build step execution plugin.
 * Encapsulates Git-specific cloning, command operations, and input staging.
 */
class GitRunnerPlugin : StepExecutionPlugin, RepositoryProvider, InputResolverSystem, BuildStepSystem, VcsStateResolver, FingerprintContributionSystem
{
    private PluginContext m_context;

    @property string name() const { return "git-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control execution, input resolution, and build step runner plugin"; }
    @property PluginCategory category() const { return PluginCategory.step_executor; }

    ConfigDefinition[] configDefinitions() const { return null; }
    @property string providerType() const { return "git"; }
    @property string systemName() const { return "git-input-resolver"; }

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

    void cloneRepository(string address, string targetDirectory, LogDelegate logCallback = null)
    {
        mkdirRecurse(targetDirectory);

        if (m_context !is null)
        {
            m_context.info(format("Executing git clone via GitRunnerPlugin for %s into %s", address, targetDirectory));
        }

        auto pipe = pipeShell(format("git clone %s .", address),
            Redirect.stdout | Redirect.stderrToStdout,
            null,
            Config.retainStderr,
            targetDirectory);

        scope(exit) wait(pipe.pid);

        foreach (line; pipe.stdout.byLineCopy)
        {
            if (m_context !is null)
            {
                m_context.debug_(line);
            }
            if (logCallback !is null)
            {
                logCallback(line);
            }
        }
        if (m_context !is null)
        {
            m_context.info("Git clone completed successfully via GitRunnerPlugin");
        }
    }

    bool canResolve(in TaskNode task) const
    {
        // When task has explicit build steps, bypass InputResolver pass so step execution manages checkout
        if (task.steps.length > 0)
        {
            return false;
        }
        if (task.inputs.repositories.length > 0)
        {
            foreach (repo; task.inputs.repositories)
            {
                if (canHandle(repo)) return true;
            }
        }
        if (task.hasCustomComponent("git_source"))
        {
            return true;
        }
        return false;
    }

    void resolveInputs(in TaskNode task, ref InputResolutionContext context)
    {
        foreach (repo; task.inputs.repositories)
        {
            if (canHandle(repo))
            {
                string targetDir = buildPath(context.effectiveWorkingDir, baseName(repo));
                if (isWithinDirectory(targetDir, context.effectiveWorkingDir))
                {
                    cloneRepository(repo, targetDir, context.logCallback);
                }
                else if (context.logCallback !is null)
                {
                    context.logCallback(format("[git] Security Error: Clone target '%s' escapes effective working directory '%s'", targetDir, context.effectiveWorkingDir));
                }
            }
        }

        if (task.hasCustomComponent("git_source"))
        {
            auto comp = task.getCustomComponent("git_source");
            if (comp.type == JSONType.object && "url" in comp)
            {
                string url = comp["url"].str;
                string targetDir = "target_dir" in comp
                    ? (isAbsolute(comp["target_dir"].str) ? comp["target_dir"].str : buildPath(context.effectiveWorkingDir, comp["target_dir"].str))
                    : buildPath(context.effectiveWorkingDir, baseName(url));
                if (isWithinDirectory(targetDir, context.effectiveWorkingDir))
                {
                    cloneRepository(url, targetDir, context.logCallback);
                }
                else if (context.logCallback !is null)
                {
                    context.logCallback(format("[git] Security Error: Clone target '%s' escapes effective working directory '%s'", targetDir, context.effectiveWorkingDir));
                }
            }
        }
    }

    bool canExecuteStep(in BuildStep step) const
    {
        return step.type == "clone_repository"
            || step.type == "git_clone"
            || step.type == "checkout_repository"
            || step.type == "git:clone"
            || step.type == "git";
    }

    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
    {
        StepExecutionResult res;
        string repoParam = "";
        string branchParam = "";
        string targetDirParam = "";
        string commitParam = "";
        string depthParam = "";
        bool submodules = true;

        if ("repository" in step.parameters) repoParam = step.parameters["repository"];
        else if ("url" in step.parameters) repoParam = step.parameters["url"];
        else if ("address" in step.parameters) repoParam = step.parameters["address"];
        else if ("repo" in step.parameters) repoParam = step.parameters["repo"];

        if ("branch" in step.parameters) branchParam = step.parameters["branch"];
        else if ("ref" in step.parameters) branchParam = step.parameters["ref"];
        else if ("tag" in step.parameters) branchParam = step.parameters["tag"];

        if ("target_dir" in step.parameters) targetDirParam = step.parameters["target_dir"];
        else if ("targetDirectory" in step.parameters) targetDirParam = step.parameters["targetDirectory"];
        else if ("target" in step.parameters) targetDirParam = step.parameters["target"];

        if ("commit" in step.parameters) commitParam = step.parameters["commit"];
        else if ("sha" in step.parameters) commitParam = step.parameters["sha"];

        if ("depth" in step.parameters) depthParam = step.parameters["depth"];
        if ("submodules" in step.parameters)
        {
            string sVal = step.parameters["submodules"];
            submodules = (sVal != "false" && sVal != "0" && sVal != "no");
        }

        if (repoParam.length == 0 && step.command.length > 0)
        {
            repoParam = step.command;
        }

        if (repoParam.length == 0)
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = "No repository address specified for git clone step";
            return res;
        }

        // Repository authorization check
        if (context.allowedRepositories.length > 0)
        {
            bool isAllowed = false;
            foreach (allowed; context.allowedRepositories)
            {
                if (isRepoMatch(repoParam, allowed, context.repositoryMap))
                {
                    isAllowed = true;
                    break;
                }
            }

            if (!isAllowed)
            {
                res.success = false;
                res.exitCode = 403;
                res.errorMessage = format("Repository '%s' is not in the project's allowed repositories whitelist", repoParam);
                if (context.logCallback !is null)
                {
                    context.logCallback(format("[git] Security Error: %s", res.errorMessage));
                }
                return res;
            }
        }

        string cloneTargetDir;
        if (targetDirParam.length > 0)
        {
            cloneTargetDir = isAbsolute(targetDirParam) ? targetDirParam : buildPath(context.workingDirectory, targetDirParam);
        }
        else
        {
            cloneTargetDir = context.workingDirectory;
        }

        // Enforce workspace jail boundary security
        if (!isWithinDirectory(cloneTargetDir, context.workspaceDir))
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = format("Security Error: Target directory '%s' escapes workspace boundary '%s'", cloneTargetDir, context.workspaceDir);
            if (context.logCallback !is null)
            {
                context.logCallback(res.errorMessage);
            }
            return res;
        }

        if (!exists(cloneTargetDir))
        {
            mkdirRecurse(cloneTargetDir);
        }

        string effectiveRepoUrl = repoParam;
        if (context.repositoryMap !is null)
        {
            int maxHops = 10;
            while (maxHops-- > 0 && (effectiveRepoUrl in context.repositoryMap))
            {
                effectiveRepoUrl = context.repositoryMap[effectiveRepoUrl];
            }
        }

        string gitExecutable = "git";
        if ("executable" in step.parameters && step.parameters["executable"].length > 0)
        {
            gitExecutable = step.parameters["executable"];
        }

        string[] cloneArgs = [gitExecutable, "clone"];
        if (depthParam.length > 0)
        {
            cloneArgs ~= ["--depth", depthParam];
        }
        if (branchParam.length > 0 && commitParam.length == 0)
        {
            cloneArgs ~= ["--branch", branchParam];
        }
        if (submodules)
        {
            cloneArgs ~= "--recurse-submodules";
        }
        cloneArgs ~= effectiveRepoUrl;
        cloneArgs ~= ".";

        if (context.logCallback !is null)
        {
            string logMsg = format("[git] Cloning repository '%s'", repoParam);
            if (branchParam.length > 0) logMsg ~= format(" (branch: %s)", branchParam);
            if (targetDirParam.length > 0) logMsg ~= format(" into '%s'", targetDirParam);
            context.logCallback(logMsg);
        }

        try
        {
            string[string] stepEnv;
            foreach (k, v; context.environment) stepEnv[k] = v;
            foreach (k, v; step.environment) stepEnv[k] = v;

            auto pipe = pipeProcess(cloneArgs,
                Redirect.stdout | Redirect.stderrToStdout,
                stepEnv.length > 0 ? stepEnv : null,
                Config.retainStderr,
                cloneTargetDir);

            foreach (line; pipe.stdout.byLineCopy)
            {
                res.outputLines ~= line;
                if (context.logCallback !is null)
                {
                    context.logCallback(line);
                }
            }

            res.exitCode = wait(pipe.pid);
            res.success = (res.exitCode == 0);

            if (!res.success)
            {
                res.errorMessage = format("Git clone failed with exit code %d", res.exitCode);
                return res;
            }

            // If a specific commit SHA was requested, checkout that commit explicitly
            if (commitParam.length > 0)
            {
                if (context.logCallback !is null)
                {
                    context.logCallback(format("[git] Checking out commit '%s'", commitParam));
                }

                string[] checkoutArgs = [gitExecutable, "checkout", commitParam];
                auto coPipe = pipeProcess(checkoutArgs,
                    Redirect.stdout | Redirect.stderrToStdout,
                    stepEnv.length > 0 ? stepEnv : null,
                    Config.retainStderr,
                    cloneTargetDir);

                foreach (line; coPipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (context.logCallback !is null)
                    {
                        context.logCallback(line);
                    }
                }

                int coExit = wait(coPipe.pid);
                if (coExit != 0)
                {
                    res.success = false;
                    res.exitCode = coExit;
                    res.errorMessage = format("Git checkout commit '%s' failed with exit code %d", commitParam, coExit);
                    return res;
                }
            }
        }
        catch (Exception e)
        {
            res.exitCode = -1;
            res.success = false;
            res.errorMessage = e.msg;
            if (context.logCallback !is null)
            {
                context.logCallback(format("[git] Execution error: %s", e.msg));
            }
        }

        return res;
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

    // ===================== FingerprintContributionSystem implementation =====================

    bool canContribute(in TaskNode task) const
    {
        // Contribute if the task has repository inputs or git-related build steps
        if (task.inputs.repositories.length > 0) return true;
        if (task.hasCustomComponent("git_source")) return true;
        foreach (step; task.steps)
        {
            if (canExecuteStep(step)) return true;
        }
        return false;
    }

    string contributeFingerprint(in TaskNode task, in FingerprintContributionContext context) const
    {
        import std.array : appender;

        auto ap = appender!string();

        // Collect all repository URLs from the task
        string[] repoUrls;

        // From repository inputs
        foreach (repo; task.inputs.repositories)
        {
            if (canHandle(repo)) repoUrls ~= repo;
        }

        // From git_source component
        if (task.hasCustomComponent("git_source"))
        {
            auto comp = task.getCustomComponent("git_source");
            if (comp.type == JSONType.object && "url" in comp)
            {
                repoUrls ~= comp["url"].str;
            }
        }

        // From build steps
        foreach (step; task.steps)
        {
            if (canExecuteStep(step))
            {
                string repoParam;
                foreach (key; ["repository", "url", "address", "repo"])
                {
                    if (key in step.parameters)
                    {
                        repoParam = step.parameters[key];
                        break;
                    }
                }
                if (repoParam.length > 0 && canHandle(repoParam))
                {
                    repoUrls ~= repoParam;
                }
            }
        }

        if (repoUrls.length == 0) return "";

        // Sort for determinism
        import std.algorithm.sorting : sort;
        repoUrls.sort();

        foreach (repoUrl; repoUrls)
        {
            ap.put("repo:");
            ap.put(normalizeRepoUrl(repoUrl));
            ap.put(':');

            // Try to get the resolved VCS state from context
            if (context.vcsRepositoryStates !is null)
            {
                bool found = false;
                foreach (key, state; context.vcsRepositoryStates)
                {
                    if (isRepoMatch(key, repoUrl))
                    {
                        ap.put(state.revision);
                        ap.put('|');
                        ap.put(state.targetRef);
                        found = true;
                        break;
                    }
                }
                if (!found)
                {
                    // No resolved state available; use empty revision marker
                    ap.put("unknown|");
                }
            }
            else
            {
                // No VCS state map provided; use empty revision marker
                ap.put("unknown|");
            }

            ap.put('\n');
        }

        return ap.data;
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new GitRunnerPlugin();
}

unittest
{
    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));
    assert(plugin.name == "git-runner");
    assert(plugin.category == PluginCategory.step_executor);
    assert(plugin.providerType == "git");
    assert(plugin.systemName == "git-input-resolver");

    assert(plugin.canHandle("https://github.com/dlang/dmd.git"));
    assert(plugin.canHandle("git@github.com:dlang/druntime.git"));
    assert(!plugin.canHandle("svn://svn.example.com/repo"));

    BuildStep bStep;
    bStep.type = "clone_repository";
    bStep.parameters["repository"] = "https://github.com/dlang/dub.git";
    assert(plugin.canExecuteStep(bStep));

    BuildStep gitStep;
    gitStep.type = "git";
    assert(plugin.canExecuteStep(gitStep));

    BuildStep bashStep;
    bashStep.type = "bash";
    assert(!plugin.canExecuteStep(bashStep));

    // Security whitelist check test
    StepExecutionContext sCtx;
    sCtx.workspaceDir = ".";
    sCtx.workingDirectory = ".";
    sCtx.allowedRepositories = ["https://github.com/allowed/repo.git"];

    BuildStep unauthStep;
    unauthStep.type = "clone_repository";
    unauthStep.parameters["repository"] = "https://github.com/unauthorized/repo.git";

    auto unauthRes = plugin.executeStep(unauthStep, sCtx);
    assert(!unauthRes.success);
    assert(unauthRes.exitCode == 403);

    // Repository map alias resolution check
    StepExecutionContext mapCtx;
    mapCtx.workspaceDir = ".";
    mapCtx.workingDirectory = ".";
    mapCtx.allowedRepositories = ["https://github.com/allowed/repo.git"];
    mapCtx.repositoryMap = ["confector": "https://github.com/allowed/repo.git"];

    BuildStep aliasStep;
    aliasStep.type = "clone_repository";
    aliasStep.parameters["repository"] = "confector";
    // Target invalid directory to avoid running actual git clone during unit test while testing pre-clone resolution
    aliasStep.parameters["target_dir"] = "../escape";

    auto aliasRes = plugin.executeStep(aliasStep, mapCtx);
    // Should pass whitelist auth check (not 403) and fail on boundary escape (code 1)
    assert(aliasRes.exitCode != 403);
    assert(!aliasRes.success);
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

unittest
{
    // Test FingerprintContributionSystem interface methods
    auto plugin = new GitRunnerPlugin();
    plugin.initialize(new NullPluginContext("git-runner"));

    // Test canContribute with repository inputs
    {
        TaskNode task;
        task.id = "build";
        task.inputs.repositories = ["https://github.com/example/repo.git"];
        assert(plugin.canContribute(task));
    }

    // Test canContribute with git_source component
    {
        TaskNode task;
        task.id = "build";
        task.setCustomComponent("git_source", JSONValue([
            "url": JSONValue("https://github.com/example/repo.git"),
            "branch": JSONValue("main")
        ]));
        assert(plugin.canContribute(task));
    }

    // Test canContribute with git build step
    {
        TaskNode task;
        task.id = "build";
        task.steps = [BuildStep("Clone", "clone_repository", ["repository": "https://github.com/example/repo.git"])];
        assert(plugin.canContribute(task));
    }

    // Test canContribute returns false for non-git task
    {
        TaskNode task;
        task.id = "build";
        task.steps = [BuildStep("Build", "bash", null, "dub build")];
        assert(!plugin.canContribute(task));
    }

    // Test contributeFingerprint with repository inputs and VCS state
    {
        TaskNode task;
        task.id = "build";
        task.inputs.repositories = ["https://github.com/example/repo.git"];

        FingerprintContributionContext ctx;
        ctx.vcsRepositoryStates = [
            "https://github.com/example/repo.git": VcsRepositoryState(
                "https://github.com/example/repo.git",
                "git",
                "main",
                "abc123def456"
            )
        ];

        auto contribution = plugin.contributeFingerprint(task, ctx);
        assert(contribution.length > 0);
        assert(contribution.canFind("abc123def456"));
        assert(contribution.canFind("main"));
    }

    // Test contributeFingerprint with different revisions produces different output
    {
        TaskNode task;
        task.id = "build";
        task.inputs.repositories = ["https://github.com/example/repo.git"];

        FingerprintContributionContext ctx1;
        ctx1.vcsRepositoryStates = [
            "https://github.com/example/repo.git": VcsRepositoryState(
                "https://github.com/example/repo.git",
                "git",
                "main",
                "abc123def456"
            )
        ];

        FingerprintContributionContext ctx2;
        ctx2.vcsRepositoryStates = [
            "https://github.com/example/repo.git": VcsRepositoryState(
                "https://github.com/example/repo.git",
                "git",
                "main",
                "789xyz000000"
            )
        ];

        auto contrib1 = plugin.contributeFingerprint(task, ctx1);
        auto contrib2 = plugin.contributeFingerprint(task, ctx2);
        assert(contrib1 != contrib2, "Different revisions should produce different fingerprint contributions");
    }

    // Test contributeFingerprint with no VCS state
    {
        TaskNode task;
        task.id = "build";
        task.inputs.repositories = ["https://github.com/example/repo.git"];

        FingerprintContributionContext ctx;

        auto contribution = plugin.contributeFingerprint(task, ctx);
        assert(contribution.canFind("unknown|"));
    }

    // Test contributeFingerprint returns empty for non-git task
    {
        TaskNode task;
        task.id = "build";
        task.steps = [BuildStep("Build", "bash", null, "dub build")];

        FingerprintContributionContext ctx;
        auto contribution = plugin.contributeFingerprint(task, ctx);
        assert(contribution.length == 0);
    }

    // Test contributeFingerprint with build step repository
    {
        TaskNode task;
        task.id = "build";
        task.steps = [BuildStep("Clone", "git:clone", ["url": "https://github.com/example/repo.git"])];

        FingerprintContributionContext ctx;
        ctx.vcsRepositoryStates = [
            "https://github.com/example/repo.git": VcsRepositoryState(
                "https://github.com/example/repo.git",
                "git",
                "main",
                "deadbeef1234"
            )
        ];

        auto contribution = plugin.contributeFingerprint(task, ctx);
        assert(contribution.canFind("deadbeef1234"));
    }
}
