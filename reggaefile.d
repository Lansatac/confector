/+
    Reggae build description for Confector.

    This file coordinates the full build of the Confector project:
      - Compiles all DUB subpackages (server, runner, plugins)
      - Copies Diet-NG view templates into the out/ artifact directory
      - Copies public web assets into the out/ artifact directory

    Usage (create a build subfolder per environment to isolate ninja files):

        # Host development
        mkdir build-host
        cd build-host
        reggae -b ninja ..
        ninja

        # Docker dev container
        mkdir build-docker
        cd build-docker
        reggae -b ninja ..
        ninja

    The `out/` output directory lives at the project root and is shared
    across build configurations.
+/

module reggaefile;

import reggae;
import reggae.rules.dubBuild;

// ---------------------------------------------------------------------------
// DUB build targets – these delegate to dub.json for all source paths,
// dependencies, compiler flags, and library settings.
// ---------------------------------------------------------------------------

// The server executable (out/server/confector-server)
alias server = dubBuild!(
    SubPackage("server")
);

// The runner executable (out/runner/confector-runner)
alias runner = dubBuild!(
    SubPackage("runner")
);

// Core library (out/lib/confector_core)
alias coreLib = dubBuild!(
    SubPackage("core")
);

// Runner core library (out/lib/confector_runner_core)
alias runnerCoreLib = dubBuild!(
    SubPackage("runner_core")
);

// Plugin API library (out/lib/confector_plugin_api)
alias pluginApiLib = dubBuild!(
    SubPackage("plugin_api")
);

// Config library (out/lib/confector_config)
alias configLib = dubBuild!(
    SubPackage("config")
);

// Plugin dynamic libraries (out/plugins/*.dll or *.so)
alias bashDefPlugin = dubBuild!(
    SubPackage("bash_def")
);

alias bashRunnerPlugin = dubBuild!(
    SubPackage("bash_runner")
);

alias gitDefPlugin = dubBuild!(
    SubPackage("git_def")
);

alias gitRunnerPlugin = dubBuild!(
    SubPackage("git_runner")
);

alias powershellDefPlugin = dubBuild!(
    SubPackage("powershell_def")
);

alias powershellRunnerPlugin = dubBuild!(
    SubPackage("powershell_runner")
);

alias localProcessPlugin = dubBuild!(
    SubPackage("local_process")
);

// ---------------------------------------------------------------------------
// Asset copy targets – sync views and public assets into out/
// ---------------------------------------------------------------------------

// Copy Diet-NG view templates from views/ to out/views/
alias copyViews = Target(
    "out/views",
    "if not exist out\\views mkdir out\\views & xcopy /E /I /Y views\\* out\\views\\",
    globFiles!("views/**/*")
);

// Copy public web assets from public/ to out/public/
alias copyPublic = Target(
    "out/public",
    "if not exist out\\public mkdir out\\public & xcopy /E /I /Y public\\* out\\public\\",
    globFiles!("public/**/*")
);

// ---------------------------------------------------------------------------
// Aggregate target – builds everything
// ---------------------------------------------------------------------------

alias allLibraries = Target(
    "libraries",
    "",
    [configLib, pluginApiLib, coreLib, runnerCoreLib]
);

alias allPlugins = Target(
    "plugins",
    "",
    [
        bashDefPlugin,
        bashRunnerPlugin,
        gitDefPlugin,
        gitRunnerPlugin,
        powershellDefPlugin,
        powershellRunnerPlugin,
        localProcessPlugin
    ]
);

alias allAssets = Target(
    "assets",
    "",
    [copyViews, copyPublic]
);

alias all = Target(
    "all",
    "",
    [server, runner, allLibraries, allPlugins, allAssets]
);

// ---------------------------------------------------------------------------
// Build definition
// ---------------------------------------------------------------------------

mixin build!(all);
