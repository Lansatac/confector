module plugins.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName, isAbsolute;
import std.algorithm.searching : canFind;
import std.json : JSONValue, JSONType, parseJSON;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.vcs;
import confector.plugin_api.system : InputResolverSystem, InputResolutionContext, BuildStepSystem, BuildStepProvider, StepExecutionContext, StepExecutionResult;
import confector.plugin_api.executor : LogDelegate;

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
class GitRepositoryPlugin : Plugin, RepositoryProvider, InputResolverSystem, BuildStepSystem, BuildStepProvider
{
    private PluginContext m_context;

    @property string name() const { return "git-provider"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control provider, input resolution, and build step plugin"; }
    @property string providerType() const { return "git"; }
    @property string systemName() const { return "git-input-resolver"; }
    @property string stepType() const { return "clone_repository"; }
    @property string displayName() const { return "Clone Git Repository"; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("GitRepositoryPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("GitRepositoryPlugin shut down");
        }
    }

    JSONValue defaultParameters() const
    {
        JSONValue p = JSONValue(["repository": JSONValue(""), "branch": JSONValue(""), "target_dir": JSONValue("")]);
        return p;
    }

    string[] validateParameters(in JSONValue parameters) const
    {
        string[] errors;
        if (parameters.type != JSONType.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }
        return errors;
    }

    string renderStepFormHtml(in JSONValue currentParameters) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;
        string repoUrl = "";
        string branch = "";
        string targetDir = "";

        if (currentParameters.type == JSONType.object)
        {
            if (auto p = "repository" in currentParameters) repoUrl = p.str;
            else if (auto p = "url" in currentParameters) repoUrl = p.str;
            else if (auto p = "address" in currentParameters) repoUrl = p.str;

            if (auto p = "branch" in currentParameters) branch = p.str;
            if (auto p = "target_dir" in currentParameters) targetDir = p.str;
            else if (auto p = "targetDirectory" in currentParameters) targetDir = p.str;
            else if (auto p = "target" in currentParameters) targetDir = p.str;
        }

        compileHTMLDietFile!("step.dt", repoUrl, branch, targetDir)(html);

        return html.data;
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
            m_context.info(format("Executing git clone via GitRepositoryPlugin for %s into %s", address, targetDirectory));
        }

        auto pipe = pipeShell(format("git clone %s", address),
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
            m_context.info("Git clone completed successfully via GitRepositoryPlugin");
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
                cloneRepository(repo, targetDir, context.logCallback);
            }
        }

        if (task.hasCustomComponent("git_source"))
        {
            auto comp = task.getCustomComponent("git_source");
            if (comp.type == JSONType.object && "url" in comp)
            {
                string url = comp["url"].str;
                string targetDir = "target_dir" in comp
                    ? buildPath(context.effectiveWorkingDir, comp["target_dir"].str)
                    : buildPath(context.effectiveWorkingDir, baseName(url));
                cloneRepository(url, targetDir, context.logCallback);
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
        if ("repository" in step.parameters) repoParam = step.parameters["repository"];
        else if ("url" in step.parameters) repoParam = step.parameters["url"];
        else if ("address" in step.parameters) repoParam = step.parameters["address"];
        else if (step.script.length > 0) repoParam = step.script;
        else if (step.properties.type == JSONType.object && "url" in step.properties) repoParam = step.properties["url"].str;
        else if (step.properties.type == JSONType.object && "repository" in step.properties) repoParam = step.properties["repository"].str;

        // Auto-infer repository if omitted
        if (repoParam.length == 0)
        {
            string[] distinctRepos;
            foreach (k, v; context.repositoryMap)
            {
                if (!distinctRepos.canFind(k)) distinctRepos ~= k;
            }
            foreach (r; context.allowedRepositories)
            {
                if (!distinctRepos.canFind(r)) distinctRepos ~= r;
            }

            // Find distinct clone URLs
            string[] distinctUrls;
            foreach (d; distinctRepos)
            {
                string u = (d in context.repositoryMap) ? context.repositoryMap[d] : d;
                if (!distinctUrls.canFind(u)) distinctUrls ~= u;
            }

            if (distinctUrls.length == 1)
            {
                repoParam = distinctUrls[0];
            }
            else if (distinctUrls.length > 1)
            {
                res.success = false;
                res.exitCode = 1;
                res.errorMessage = format("Missing repository parameter in build step and multiple linked repositories are declared: %s. Please select a repository explicitly.", distinctRepos);
                return res;
            }
            else
            {
                res.success = false;
                res.exitCode = 1;
                res.errorMessage = "Missing repository URL/address in clone repository build step and no linked repositories found in task inputs or upstream dependencies";
                return res;
            }
        }

        // Resolve repository ID / name to its actual Git clone URL / address
        string repoUrl = repoParam;
        if (repoParam in context.repositoryMap)
        {
            repoUrl = context.repositoryMap[repoParam];
        }
        else if (!canHandle(repoParam))
        {
            // If repoParam is not a valid git URL format, check if any allowed repo matches or is mapped
            if (context.allowedRepositories.length > 0)
            {
                foreach (allowed; context.allowedRepositories)
                {
                    if (allowed in context.repositoryMap)
                    {
                        repoUrl = context.repositoryMap[allowed];
                        break;
                    }
                    else if (canHandle(allowed))
                    {
                        repoUrl = allowed;
                        break;
                    }
                }
            }
        }

        // Enforce repository authorization
        if (context.allowedRepositories.length > 0 || context.repositoryMap.length > 0)
        {
            bool authorized = false;
            if (repoParam in context.repositoryMap || repoUrl in context.repositoryMap)
            {
                authorized = true;
            }
            if (!authorized)
            {
                foreach (allowed; context.allowedRepositories)
                {
                    if (isRepoMatch(repoParam, allowed, context.repositoryMap) || isRepoMatch(repoUrl, allowed, context.repositoryMap))
                    {
                        authorized = true;
                        break;
                    }
                }
            }

            if (!authorized)
            {
                res.success = false;
                res.exitCode = 1;
                res.errorMessage = format("Repository '%s' is not declared in task inputs or upstream dependencies. Authorized repositories: %s", repoParam, context.allowedRepositories);
                if (context.logCallback !is null)
                {
                    context.logCallback(format("[git] Security Error: %s", res.errorMessage));
                }
                return res;
            }
        }
        else
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = format("Repository '%s' is not authorized: no repositories are declared in task inputs or upstream dependencies", repoParam);
            if (context.logCallback !is null)
            {
                context.logCallback(format("[git] Security Error: %s", res.errorMessage));
            }
            return res;
        }

        // Validate that repoUrl is a cloneable address (URL, SSH, or local existing directory/path)
        if (!canHandle(repoUrl) && !exists(repoUrl))
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = format("Repository '%s' could not be resolved to a valid Git URL or directory path", repoParam);
            if (context.logCallback !is null)
            {
                context.logCallback(format("[git] Error: %s", res.errorMessage));
            }
            return res;
        }

        string targetDir = context.workingDirectory;
        string specifiedTarget = "";
        if ("target_dir" in step.parameters) specifiedTarget = step.parameters["target_dir"];
        else if ("targetDirectory" in step.parameters) specifiedTarget = step.parameters["targetDirectory"];
        else if ("target" in step.parameters) specifiedTarget = step.parameters["target"];
        else if (step.properties.type == JSONType.object && "target_dir" in step.properties) specifiedTarget = step.properties["target_dir"].str;

        if (specifiedTarget.length > 0 && specifiedTarget != ".")
        {
            targetDir = isAbsolute(specifiedTarget) ? specifiedTarget : buildPath(context.workingDirectory, specifiedTarget);
        }
        else
        {
            targetDir = context.workingDirectory;
        }

        string branch = "";
        if ("branch" in step.parameters) branch = step.parameters["branch"];
        else if (step.properties.type == JSONType.object && "branch" in step.properties) branch = step.properties["branch"].str;

        try
        {
            mkdirRecurse(targetDir);
            string cmd = format("git clone %s", repoUrl);
            if (branch.length > 0)
            {
                cmd ~= format(" -b %s", branch);
            }
            cmd ~= format(" \"%s\"", targetDir);

            if (context.logCallback !is null)
            {
                context.logCallback(format("[git] Executing %s", cmd));
            }

            auto pipe = pipeShell(cmd,
                Redirect.stdout | Redirect.stderrToStdout,
                null,
                Config.retainStderr,
                targetDir);

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
                res.errorMessage = format("git clone exited with code %d", res.exitCode);
            }
        }
        catch (Exception e)
        {
            res.exitCode = -1;
            res.success = false;
            res.errorMessage = e.msg;
            if (context.logCallback !is null)
            {
                context.logCallback(format("Git step error: %s", e.msg));
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
    return new GitRepositoryPlugin();
}

unittest
{
    auto plugin = new GitRepositoryPlugin();
    plugin.initialize(new NullPluginContext("git-provider"));
    assert(plugin.name == "git-provider");
    assert(plugin.providerType == "git");
    assert(plugin.systemName == "git-input-resolver");
    assert(plugin.stepType == "clone_repository");
    assert(plugin.canHandle("https://github.com/user/repo.git"));
    assert(plugin.canHandle("git@github.com:user/repo.git"));
    assert(!plugin.canHandle("ftp://unknown-protocol/repo"));

    BuildStep bStep;
    bStep.type = "clone_repository";
    assert(plugin.canExecuteStep(bStep));
    BuildStep bStepAlias;
    bStepAlias.type = "checkout_repository";
    assert(plugin.canExecuteStep(bStepAlias));

    TaskNode node;
    node.id = "git-task";
    node.inputs.repositories = ["https://github.com/example/repo.git"];
    assert(plugin.canResolve(node));

    // When task has explicit steps, canResolve returns false to avoid duplicate checkout passes
    node.steps = [bStep];
    assert(!plugin.canResolve(node));

    TaskNode nonGitNode;
    nonGitNode.id = "local-task";
    assert(!plugin.canResolve(nonGitNode));

    // BuildStepProvider testing
    assert(plugin.displayName == "Clone Git Repository");
    assert(plugin.defaultParameters()["repository"].str == "");
    auto html = plugin.renderStepFormHtml(JSONValue(string[string].init));
    assert(html.length > 0);
    assert(plugin.validateParameters(JSONValue(string[string].init)).length == 0);
    assert(plugin.validateParameters(JSONValue("invalid-not-object")).length > 0);

    JSONValue validParams = JSONValue(["repository": JSONValue("https://github.com/org/repo.git")]);
    assert(plugin.validateParameters(validParams).length == 0);

    // Test authorization enforcement
    StepExecutionContext ctx;
    ctx.workspaceDir = "test_workspace";
    ctx.workingDirectory = "test_workspace";
    ctx.allowedRepositories = ["https://github.com/org/declared-repo.git"];

    // Unauthorized repository
    BuildStep unauthStep;
    unauthStep.type = "clone_repository";
    unauthStep.parameters["repository"] = "https://github.com/org/unauthorized-repo.git";
    auto unauthRes = plugin.executeStep(unauthStep, ctx);
    assert(!unauthRes.success);
    assert(unauthRes.errorMessage.length > 0);

    // No allowed repositories configured
    BuildStep inferStep;
    inferStep.type = "clone_repository";
    StepExecutionContext emptyCtx;
    emptyCtx.workspaceDir = "test_workspace";
    emptyCtx.workingDirectory = "test_workspace";
    auto emptyRes = plugin.executeStep(inferStep, emptyCtx);
    assert(!emptyRes.success);

    // Multiple allowed repos with omitted repository
    StepExecutionContext multiCtx;
    multiCtx.workspaceDir = "test_workspace";
    multiCtx.workingDirectory = "test_workspace";
    multiCtx.allowedRepositories = ["https://github.com/org/repo1.git", "https://github.com/org/repo2.git"];
    auto multiRes = plugin.executeStep(inferStep, multiCtx);
    assert(!multiRes.success);

    // Helper functions testing
    assert(isRepoMatch("https://github.com/org/repo.git", "https://github.com/org/repo"));
    assert(isRepoMatch("git@github.com:org/repo.git", "https://github.com/org/repo.git"));
    assert(isRepoMatch("ssh://git@github.com:org/repo.git", "https://github.com/org/repo"));
    assert(!isRepoMatch("https://github.com/org/other.git", "https://github.com/org/repo.git"));

    // Test repository map resolution
    StepExecutionContext mapCtx;
    mapCtx.workspaceDir = "test_workspace";
    mapCtx.workingDirectory = "test_workspace";
    mapCtx.repositoryMap = ["confector": "https://github.com/org/confector.git"];
    mapCtx.allowedRepositories = ["confector", "https://github.com/org/confector.git"];

    assert(isRepoMatch("confector", "https://github.com/org/confector.git", mapCtx.repositoryMap));
    assert(isRepoMatch("https://github.com/org/confector.git", "confector", mapCtx.repositoryMap));

    // When repo id 'confector' is passed but git clone will try to execute it against a non-existent repo or mock
    // if 'confector' is in repositoryMap, repoUrl resolves to "https://github.com/org/confector.git"
    BuildStep namedStep;
    namedStep.type = "clone_repository";
    namedStep.parameters["repository"] = "confector";
    // Authorization passes for namedStep in mapCtx
    bool authorized = false;
    foreach (allowed; mapCtx.allowedRepositories)
    {
        if (isRepoMatch(namedStep.parameters["repository"], allowed, mapCtx.repositoryMap))
        {
            authorized = true;
            break;
        }
    }
    assert(authorized);
}
