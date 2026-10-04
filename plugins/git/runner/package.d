module plugins.git.runner;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName, isAbsolute, buildNormalizedPath, absolutePath, relativePath, dirSeparator;
import std.algorithm.searching : canFind, startsWith, endsWith;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, NullPluginContext, PluginCategory, StepExecutionPlugin;
import confector.plugin_api.vcs;
import confector.plugin_api.system : InputResolverSystem, InputResolutionContext, BuildStepSystem, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : LogDelegate;

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
class GitRunnerPlugin : StepExecutionPlugin, RepositoryProvider, InputResolverSystem, BuildStepSystem
{
    private PluginContext m_context;

    @property string name() const { return "git-runner"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control execution, input resolution, and build step runner plugin"; }
    @property PluginCategory category() const { return PluginCategory.runner; }
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
        cloneArgs ~= repoParam;
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
    assert(plugin.category == PluginCategory.runner);
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

    // Security escape boundary test
    StepExecutionContext escCtx;
    escCtx.workspaceDir = "sub/workspace";
    escCtx.workingDirectory = "sub/workspace";

    BuildStep escStep;
    escStep.type = "clone_repository";
    escStep.parameters["repository"] = "https://github.com/allowed/repo.git";
    escStep.parameters["target_dir"] = "../../escape_attempt";

    auto escRes = plugin.executeStep(escStep, escCtx);
    assert(!escRes.success);
    assert(escRes.exitCode != 0);
}
