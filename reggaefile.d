import reggae;
import std.file;
import std.path;
import std.algorithm;
import std.array;

// Main application executable built via dub
alias app = dubBuild!();

// Cross-platform file copy and shell invocation commands
version(Windows) {
    enum copyCmd = "cmd /c copy /Y $in $out";
    enum ext = ".dll";
    string dubCmd(string subPkg) {
        return "cmd /c dub build confector:" ~ subPkg;
    }
} else {
    enum copyCmd = "cp $in $out";
    enum ext = ".so";
    string dubCmd(string subPkg) {
        return "dub build confector:" ~ subPkg;
    }
}

Target copyRule(string src, string dest) {
    return Target(dest, copyCmd, [Target(src)]);
}

Target[] copyDirectoryFiles(string srcDir, string destDir) {
    Target[] targets;
    if (!exists(srcDir)) return targets;
    string normSrcDir = srcDir.replace("\\", "/");
    foreach (DirEntry entry; dirEntries(srcDir, SpanMode.depth)) {
        if (entry.isFile) {
            string normPath = entry.name.replace("\\", "/");
            string rel = normPath;
            if (rel.startsWith(normSrcDir)) {
                rel = rel[normSrcDir.length .. $];
                if (rel.startsWith("/")) rel = rel[1 .. $];
            }
            targets ~= copyRule(entry.name, buildPath(destDir, rel));
        }
    }
    return targets;
}

Target pluginTarget(string name, string relPath = "") {
    string pluginDir = buildPath("plugins", relPath.length > 0 ? relPath : name);
    Target[] srcTargets;
    if (exists(pluginDir)) {
        foreach (DirEntry entry; dirEntries(pluginDir, SpanMode.depth)) {
            if (entry.isFile) {
                srcTargets ~= Target(entry.name);
            }
        }
    }
    return Target.phony("plugin-" ~ name, dubCmd(name), srcTargets);
}

Target runnerTarget() {
    string runnerDir = buildPath("source", "confector", "runner_app");
    Target[] srcTargets;
    if (exists(runnerDir)) {
        foreach (DirEntry entry; dirEntries(runnerDir, SpanMode.depth)) {
            if (entry.isFile) {
                srcTargets ~= Target(entry.name);
            }
        }
    }
    return Target.phony("runner", dubCmd("runner"), srcTargets);
}

Build reggaeBuild() {
    Target appTarget = app();
    Target runnerBinary = runnerTarget();
    
    // Plugin Targets (output to bin/plugins/)
    auto bashDef = pluginTarget("bash_def", "bash/def");
    auto bashRunner = pluginTarget("bash_runner", "bash/runner");
    auto gitDef = pluginTarget("git_def", "git/def");
    auto gitRunner = pluginTarget("git_runner", "git/runner");
    auto powershellDef = pluginTarget("powershell_def", "powershell/def");
    auto powershellRunner = pluginTarget("powershell_runner", "powershell/runner");
    auto localProcess = pluginTarget("local_process", "executors/local_process");
    
    auto plugins = Target.phony("plugins", "", [bashDef, bashRunner, gitDef, gitRunner, powershellDef, powershellRunner, localProcess]);

    // Static assets & view templates copied to bin/
    auto staticFiles = copyDirectoryFiles("public", "bin/public");
    auto viewFiles = copyDirectoryFiles("views", "bin/views");
    auto staticAssets = Target.phony("static_assets", "", staticFiles ~ viewFiles);

    // Default 'all' target grouping application, runner, plugins, and static/view assets
    auto all = Target.phony("all", "", [appTarget, runnerBinary, plugins, staticAssets]);

    Target[] allTargets = [all, appTarget, runnerBinary, plugins, bashDef, bashRunner, gitDef, gitRunner, powershellDef, powershellRunner, localProcess, staticAssets] ~ staticFiles ~ viewFiles;

    return Build(allTargets);
}

mixin BuildgenMain;
