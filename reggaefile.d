import reggae;
import reggae.config : options, configToDubInfo;
import reggae.rules.dub.runtime : dubTest;
import reggae.rules.dub.external : DubPath, dubPackage;

Target dubPathTarget(string path)
{
  auto opts = options.dup;
  opts.allAtOnce = true;
  return dubPackage(opts, DubPath(path, Configuration("default")));
}

Target serverPublicAssets()
{
  import std.file : dirEntries, SpanMode;

  Target[] inputs = [Target("$project/public")];
  foreach (entry; dirEntries("public", SpanMode.depth))
  {
    if (entry.isFile)
      inputs ~= Target("$project/" ~ entry.name);
  }

  return Target(
    "$builddir/out/server/public/.reggae-copy.stamp",
    "mkdir -p out/server && cp -R $project/public out/server/ && touch $out",
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
  return dubPathTarget("source/confector/runner_app");
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
  localScheduler,
  optional!test,
);
