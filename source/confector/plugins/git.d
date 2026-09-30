module confector.plugins.git;

import std.format;
import std.process;
import std.stdio;
import std.file;
import vibe.core.log;

import confector.core.plugin;
import confector.core.vcs;
import confector.core.executor : LogDelegate;

/**
 * Git repository provider plugin.
 * Encapsulates all Git-specific cloning and command operations.
 */
class GitRepositoryPlugin : RepositoryProvider
{
    @property string name() const { return "git-provider"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git version control provider plugin"; }
    @property string providerType() const { return "git"; }

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
}

unittest
{
    auto plugin = new GitRepositoryPlugin();
    assert(plugin.name == "git-provider");
    assert(plugin.providerType == "git");
    assert(plugin.canHandle("https://github.com/user/repo.git"));
    assert(plugin.canHandle("git@github.com:user/repo.git"));
    assert(!plugin.canHandle("ftp://unknown-protocol/repo"));
}
