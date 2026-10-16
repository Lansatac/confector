import reggae;
import reggae.config : options, configToDubInfo;
import reggae.rules.dub.runtime : dubTest;
import reggae.rules.dub.external : DubPath, dubPackage;

Target dubPathTarget(string path)
{
  import std.array : replace;
  import std.path : buildPath, dirSeparator, isAbsolute;

  auto opts = options.dup;
  opts.allAtOnce = true;
  // Use native separators: on Windows, dub reports subpackage paths with backslashes, and a
  // forward-slash path here makes ninja see each subpackage's dub.json as a duplicate output.
  // Anchor outputs at $builddir: reggae otherwise moves the relative outputs of a target nested
  // in a phony (server, plugins) into that phony's .reggae/objs directory.
  return dubPackage(opts, DubPath(path.replace("/", dirSeparator), Configuration("default")))
    .mapOutputs((string o) => o.isAbsolute ? o : buildPath("$builddir", o));
}

Target serverPublicAssets()
{
  import std.file : dirEntries, SpanMode;
  import std.path : buildPath;

  // The build generator runs from the build directory, so scan the server's public/ explicitly.
  Target[] inputs = [Target("$project/apps/server/public")];
  foreach (entry; dirEntries(buildPath(options.projectPath, "apps", "server", "public"), SpanMode.depth))
  {
    if (entry.isFile)
      inputs ~= Target(entry.name);
  }

  // ninja runs commands without a shell on Windows, so the copy needs a native command there.
  version (Windows)
    enum copyCommand = `cmd /c "xcopy "$project\apps\server\public" out\server\public\ /E /I /Y /Q > nul && type nul > $out"`;
  else
    enum copyCommand = "mkdir -p out/server && cp -R $project/apps/server/public out/server/ && touch $out";

  return Target(
    "$builddir/out/server/public/.reggae-copy.stamp",
    copyCommand,
    inputs,
  );
}

Target server()
{
  return Target.phony(
    "server",
    "",
    dubPathTarget("apps/server"),
    serverPublicAssets(),
  );
}

Target runner()
{
  return dubPathTarget("apps/runner");
}

// Libraries are not top-level targets: the executables and plugins that use them build them.
Target plugins()
{
  return Target.phony(
    "plugins",
    "",
    [
      dubPathTarget("plugins/definition/bash"),
      dubPathTarget("plugins/definition/git"),
      dubPathTarget("plugins/definition/powershell"),
      dubPathTarget("plugins/step_executor/bash"),
      dubPathTarget("plugins/step_executor/git"),
      dubPathTarget("plugins/step_executor/powershell"),
      dubPathTarget("plugins/worker/local_process"),
      dubPathTarget("plugins/artifact/local"),
      dubPathTarget("plugins/queue/mongo"),
      dubPathTarget("plugins/scheduler/local"),
    ],
  );
}

// Optional unit test target
Target test()
{
  auto opts = options.dup;
  if (opts.dubObjsDir == "")
    opts.dubObjsDir = "objs";
  return dubTest(opts, configToDubInfo, CompilationMode.all);
}

mixin build!(
  server,
  runner,
  plugins,
  optional!test,
);
