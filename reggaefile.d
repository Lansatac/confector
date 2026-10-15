import reggae;
import reggae.config : options, configToDubInfo;
import reggae.rules.dub.runtime : dubTest;
import reggae.rules.dub.external : DubPath, dubPackage;

Target dubPathTarget(string path)
{
  import std.array : replace;
  import std.path : dirSeparator;

  auto opts = options.dup;
  opts.allAtOnce = true;
  // Use native separators: on Windows, dub reports subpackage paths with backslashes, and a
  // forward-slash path here makes ninja see each subpackage's dub.json as a duplicate output.
  return dubPackage(opts, DubPath(path.replace("/", dirSeparator), Configuration("default")));
}

Target serverPublicAssets()
{
  import std.file : dirEntries, SpanMode;
  import std.path : buildPath;

  // The build generator runs from the build directory, so scan the project's public/ explicitly.
  Target[] inputs = [Target("$project/public")];
  foreach (entry; dirEntries(buildPath(options.projectPath, "public"), SpanMode.depth))
  {
    if (entry.isFile)
      inputs ~= Target(entry.name);
  }

  // ninja runs commands without a shell on Windows, so the copy needs a native command there.
  version (Windows)
    enum copyCommand = `cmd /c "xcopy "$project\public" out\server\public\ /E /I /Y /Q > nul && type nul > $out"`;
  else
    enum copyCommand = "mkdir -p out/server && cp -R $project/public out/server/ && touch $out";

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
    dubPathTarget("source/confector/server"),
    serverPublicAssets(),
  );
}

Target runner()
{
  return dubPathTarget("source/confector/runner");
}

Target configLib()
{
  return dubPathTarget("source/confector/config");
}

Target pluginApiLib()
{
  return dubPathTarget("source/confector/plugin_api");
}

Target mongoHelpersLib()
{
  return dubPathTarget("source/confector/mongo_helpers");
}

Target coreLib()
{
  return dubPathTarget("source/confector/core");
}

Target runnerCoreLib()
{
  return dubPathTarget("source/confector/runner_core");
}

Target bashDef()
{
  return dubPathTarget("plugins/definition/bash");
}

Target bashRunner()
{
  return dubPathTarget("plugins/step_executor/bash");
}

Target gitDef()
{
  return dubPathTarget("plugins/definition/git");
}

Target gitRunner()
{
  return dubPathTarget("plugins/step_executor/git");
}

Target powershellDef()
{
  return dubPathTarget("plugins/definition/powershell");
}

Target powershellRunner()
{
  return dubPathTarget("plugins/step_executor/powershell");
}

Target localProcess()
{
  return dubPathTarget("plugins/worker/local_process");
}

Target localArtifact()
{
  return dubPathTarget("plugins/artifact/local");
}

Target mongoStorage()
{
  return dubPathTarget("plugins/storage/mongo");
}

Target mongoQueue()
{
  return dubPathTarget("plugins/queue/mongo");
}

Target mongoDocumentStore()
{
  return dubPathTarget("plugins/document_store/mongo");
}

Target localScheduler()
{
  return dubPathTarget("plugins/scheduler/local");
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
  configLib,
  pluginApiLib,
  mongoHelpersLib,
  coreLib,
  runnerCoreLib,
  bashDef,
  bashRunner,
  gitDef,
  gitRunner,
  powershellDef,
  powershellRunner,
  localProcess,
  localArtifact,
  mongoStorage,
  mongoQueue,
  mongoDocumentStore,
  localScheduler,
  optional!test,
);
