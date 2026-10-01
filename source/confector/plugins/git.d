module confector.plugins.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import std.path : buildPath, baseName;
import vibe.core.log;
import vibe.data.json : Json;

import confector.core.model;
import confector.core.plugin;
import confector.core.vcs;
import confector.core.system : InputResolverSystem, InputResolutionContext;
import confector.core.executor : LogDelegate;

/**
 * Git repository provider and input resolution plugin.
 * Encapsulates Git-specific cloning, command operations, and input staging.
 */
class GitRepositoryPlugin : RepositoryProvider, InputResolverSystem
{
    @property string name() const { return "git-provider"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control provider and input resolution plugin"; }
    @property string providerType() const { return "git"; }
    @property string systemName() const { return "git-input-resolver"; }

    void initialize() {}
    void shutdown() {}

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
}

unittest
{
    auto plugin = new GitRepositoryPlugin();
    assert(plugin.name == "git-provider");
    assert(plugin.providerType == "git");
    assert(plugin.systemName == "git-input-resolver");
    assert(plugin.canHandle("https://github.com/user/repo.git"));
    assert(plugin.canHandle("git@github.com:user/repo.git"));
    assert(!plugin.canHandle("ftp://unknown-protocol/repo"));

    TaskNode node;
    node.id = "git-task";
    node.inputs.repositories = ["https://github.com/example/repo.git"];
    assert(plugin.canResolve(node));

    TaskNode nonGitNode;
    nonGitNode.id = "local-task";
    assert(!plugin.canResolve(nonGitNode));
}
