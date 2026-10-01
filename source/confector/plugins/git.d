module confector.plugins.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName, isAbsolute;
import vibe.core.log;
import vibe.data.json : Json;

import confector.core.model;
import confector.core.plugin;
import confector.core.vcs;
import confector.core.system : InputResolverSystem, InputResolutionContext, BuildStepSystem, BuildStepProvider, StepExecutionContext, StepExecutionResult;
import confector.core.executor : LogDelegate;

/**
 * Git repository provider, input resolution, and build step execution plugin.
 * Encapsulates Git-specific cloning, command operations, and input staging.
 */
class GitRepositoryPlugin : Plugin, RepositoryProvider, InputResolverSystem, BuildStepSystem, BuildStepProvider
{
    @property string name() const { return "git-provider"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control provider, input resolution, and build step plugin"; }
    @property string providerType() const { return "git"; }
    @property string systemName() const { return "git-input-resolver"; }
    @property string stepType() const { return "clone_repository"; }
    @property string displayName() const { return "Clone Git Repository"; }

    void initialize() {}
    void shutdown() {}

    Json defaultParameters() const
    {
        Json p = Json.emptyObject;
        p["repository"] = "";
        p["branch"] = "";
        p["target_dir"] = "";
        return p;
    }

    string[] validateParameters(in Json parameters) const
    {
        string[] errors;
        if (parameters.type != Json.Type.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }
        auto pRepo = "repository" in parameters;
        auto pUrl = "url" in parameters;
        auto pAddress = "address" in parameters;
        if ((pRepo is null || pRepo.get!string.length == 0) &&
            (pUrl is null || pUrl.get!string.length == 0) &&
            (pAddress is null || pAddress.get!string.length == 0))
        {
            errors ~= "Repository URL or address cannot be empty";
        }
        return errors;
    }

    string renderStepFormHtml(in Json currentParameters) const
    {
        import std.array : appender;
        import vibe.textfilter.html : htmlEscape;

        auto html = appender!string;
        string repoUrl = "";
        string branch = "";
        string targetDir = "";

        if (currentParameters.type == Json.Type.object)
        {
            if (auto p = "repository" in currentParameters) repoUrl = p.get!string;
            else if (auto p = "url" in currentParameters) repoUrl = p.get!string;
            else if (auto p = "address" in currentParameters) repoUrl = p.get!string;

            if (auto p = "branch" in currentParameters) branch = p.get!string;
            if (auto p = "target_dir" in currentParameters) targetDir = p.get!string;
            else if (auto p = "targetDirectory" in currentParameters) targetDir = p.get!string;
            else if (auto p = "target" in currentParameters) targetDir = p.get!string;
        }

        html.put("<div class=\"step-subform step-subform-git\">\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label>Repository URL / Address</label>\n");
        html.put("    <input type=\"text\" name=\"step_param_repository\" class=\"form-control step-field-repository\" placeholder=\"e.g. https://github.com/org/repo.git or git@github.com:...\" value=\"");
        html.put(htmlEscape(repoUrl));
        html.put("\" required />\n");
        html.put("    <small class=\"form-help-text\">Git clone URL for HTTPS, SSH, or local repository path.</small>\n");
        html.put("  </div>\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label>Branch / Tag / Ref (Optional)</label>\n");
        html.put("    <input type=\"text\" name=\"step_param_branch\" class=\"form-control step-field-branch\" placeholder=\"e.g. main, master, v1.0.0 (default branch if empty)\" value=\"");
        html.put(htmlEscape(branch));
        html.put("\" />\n");
        html.put("  </div>\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label>Target Subdirectory (Optional)</label>\n");
        html.put("    <input type=\"text\" name=\"step_param_target_dir\" class=\"form-control step-field-target-dir\" placeholder=\"Subdirectory inside workspace (defaults to repository name)\" value=\"");
        html.put(htmlEscape(targetDir));
        html.put("\" />\n");
        html.put("  </div>\n");
        html.put("</div>\n");

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

        logInfo("Executing git clone via GitRepositoryPlugin for %s into %s", address, targetDirectory);
        auto pipe = pipeShell(format("git clone %s", address),
            Redirect.stdout | Redirect.stderrToStdout,
            null,
            Config.retainStderr,
            targetDirectory);

        scope(exit) wait(pipe.pid);

        foreach (line; pipe.stdout.byLineCopy)
        {
            logInfo(line);
            if (logCallback !is null)
            {
                logCallback(line);
            }
        }
        logInfo("Git clone completed successfully via GitRepositoryPlugin");
    }

    bool canResolve(in TaskNode task) const
    {
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
            if (comp.type == Json.Type.object && "url" in comp)
            {
                string url = comp["url"].get!string;
                string targetDir = "target_dir" in comp
                    ? buildPath(context.effectiveWorkingDir, comp["target_dir"].get!string)
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
        string repoUrl = "";
        if ("repository" in step.parameters) repoUrl = step.parameters["repository"];
        else if ("url" in step.parameters) repoUrl = step.parameters["url"];
        else if ("address" in step.parameters) repoUrl = step.parameters["address"];
        else if (step.script.length > 0) repoUrl = step.script;
        else if (step.properties.type == Json.Type.object && "url" in step.properties) repoUrl = step.properties["url"].get!string;
        else if (step.properties.type == Json.Type.object && "repository" in step.properties) repoUrl = step.properties["repository"].get!string;

        if (repoUrl.length == 0)
        {
            res.success = false;
            res.exitCode = 1;
            res.errorMessage = "Missing repository URL/address in clone repository build step";
            return res;
        }

        string targetDir = context.workingDirectory;
        if ("target_dir" in step.parameters)
        {
            string td = step.parameters["target_dir"];
            targetDir = isAbsolute(td) ? td : buildPath(context.workingDirectory, td);
        }
        else if ("targetDirectory" in step.parameters)
        {
            string td = step.parameters["targetDirectory"];
            targetDir = isAbsolute(td) ? td : buildPath(context.workingDirectory, td);
        }
        else if ("target" in step.parameters)
        {
            string td = step.parameters["target"];
            targetDir = isAbsolute(td) ? td : buildPath(context.workingDirectory, td);
        }
        else if (step.properties.type == Json.Type.object && "target_dir" in step.properties)
        {
            string td = step.properties["target_dir"].get!string;
            targetDir = isAbsolute(td) ? td : buildPath(context.workingDirectory, td);
        }
        else
        {
            targetDir = buildPath(context.workingDirectory, baseName(repoUrl));
        }

        string branch = "";
        if ("branch" in step.parameters) branch = step.parameters["branch"];
        else if (step.properties.type == Json.Type.object && "branch" in step.properties) branch = step.properties["branch"].get!string;

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

unittest
{
    auto plugin = new GitRepositoryPlugin();
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

    TaskNode nonGitNode;
    nonGitNode.id = "local-task";
    assert(!plugin.canResolve(nonGitNode));

    // BuildStepProvider testing
    assert(plugin.displayName == "Clone Git Repository");
    assert(plugin.defaultParameters()["repository"].get!string == "");
    auto html = plugin.renderStepFormHtml(Json.emptyObject);
    assert(html.length > 0);
    assert(plugin.validateParameters(Json.emptyObject).length > 0);

    Json validParams = Json.emptyObject;
    validParams["repository"] = "https://github.com/org/repo.git";
    assert(plugin.validateParameters(validParams).length == 0);
}
