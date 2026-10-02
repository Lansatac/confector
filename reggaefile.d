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

Target pluginTarget(string name) {
    string pluginDir = buildPath("plugins", name);
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

Build reggaeBuild() {
    Target appTarget = app();
    
    // Plugin Targets (output to bin/plugins/)
    auto bash = pluginTarget("bash");
    auto git = pluginTarget("git");
    auto localExec = pluginTarget("local_executor");
    auto powershell = pluginTarget("powershell");
    
    auto plugins = Target.phony("plugins", "", [bash, git, localExec, powershell]);

    // Assets & Views copied to output bin directory
    Target[] assetTargets = copyDirectoryFiles("public", "bin/public") ~ copyDirectoryFiles("views", "bin/views");

    // Default 'all' target grouping application, plugins, and static/view assets
    auto all = Target.phony("all", "", [appTarget, plugins] ~ assetTargets);

    Target[] allTargets = [all, appTarget, plugins, bash, git, localExec, powershell] ~ assetTargets;

    return Build(allTargets);
}

mixin BuildgenMain;
