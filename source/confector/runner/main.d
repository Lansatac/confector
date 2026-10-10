module confector.runner_app.main;

import confector.core.model;
import confector.core.plugin;
import confector.core.plugin_loader;
import confector.plugin_api.model : ArtifactStorage;
import confector.runner_core;
import confector.runner_core.http_artifact_storage;

import std.getopt;
import std.stdio : writeln, writefln, stderr, stdin, readln;
import std.file : exists, isFile, isDir, readText, mkdirRecurse;
import std.path : buildPath, dirName;
import std.array : Appender;
import std.format : format;
import vibe.data.json;

enum VERSION = "1.0.0";

void printBanner()
{
    writeln("Confector Runner v" ~ VERSION);
    writeln("Stateless compute plane & task execution engine");
}

void printUsage()
{
    printBanner();
    writeln();
    writeln("Usage: confector-runner <command> [options]");
    writeln();
    writeln("Commands:");
    writeln("  run      Execute a single task payload directly from file, argument, or stdin");
    writeln("  worker   Start an HTTP-polling worker daemon communicating with Confector server");
    writeln();
    writeln("Options:");
    writeln("  -h, --help      Display this help text");
    writeln("  -v, --version   Display version information");
    writeln();
    writeln("Run options:");
    writeln("  --payload=<path|json|->  JSON payload string, file path, or '-' for stdin");
    writeln("  --workspace=<dir>        Workspace directory path (required)");
    writeln("  --storage-dir=<dir>      Artifact storage directory (required)");
    writeln("  --plugins-dir=<dir>      Directory to load dynamic step plugins from (default: plugins)");
    writeln();
    writeln("Worker options:");
    writeln("  --server-url=<url>       Confector server base URL (default: http://localhost:8080)");
    writeln("  --worker-id=<id>         Unique worker identifier");
    writeln("  --token=<token>          Worker authorization secret token");
    writeln("  --workspace=<dir>        Worker workspace directory (required)");
    writeln("  --storage-dir=<dir>      Artifact storage directory (required)");
    writeln("  --plugins-dir=<dir>      Directory to load dynamic step plugins from (default: plugins)");
    writeln("  --poll-interval=<sec>    Queue poll interval in seconds (default: 2)");
    writeln("  --visibility-timeout=<s  Visibility timeout in seconds (default: 60)");
    writeln("  --heartbeat-interval=<s  Heartbeat renewal interval in seconds (default: 15)");
    writeln("  --max-tasks=<count>      Maximum tasks to process before exiting (0 = infinite)");
    writeln("  --verbose                Enable verbose logging to console");
}

int handleRun(string[] args)
{
    string payloadArg;
    string workspaceDir = "";
    string storageDir = "";
    string serverUrl = "";
    string pluginsDir = "plugins";

    auto helpInfo = getopt(
        args,
        "payload", "Task payload JSON file path, JSON string, or '-' for stdin", &payloadArg,
        "workspace", "Workspace directory path", &workspaceDir,
        "storage-dir", "Artifact storage directory (required for offline mode)", &storageDir,
        "server-url", "Confector server URL for HTTP artifact storage", &serverUrl,
        "plugins-dir", "Directory containing runner plugins", &pluginsDir
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Usage: confector-runner run [options]", helpInfo.options);
        return 0;
    }

    if (workspaceDir.length == 0)
    {
        stderr.writeln("Error: --workspace is required for run command.");
        return 1;
    }

    // Load execution step plugins from search paths (artifact storage is handled via HTTP or local plugin)
    string[] searchDirs = [pluginsDir, "out/plugins", "plugins"];
    foreach (dir; searchDirs)
    {
        if (exists(dir) && isDir(dir))
        {
            try
            {
                auto loaded = PluginLoader.instance.loadBundledPlugins(dir, [PluginCategory.step_executor]);
                foreach (p; loaded)
                {
                    stderr.writefln("[runner] Loaded plugin '%s' v%s (%s)", p.name, p.versionString, p.category);
                }
            }
            catch (Exception e)
            {
                stderr.writefln("[runner] Error loading plugins from '%s': %s", dir, e.msg);
            }
        }
    }

    string payloadJsonStr;
    if (payloadArg == "-" || payloadArg.length == 0)
    {
        Appender!string buf;
        while (!stdin.eof)
        {
            string line = stdin.readln();
            if (line.length > 0) buf.put(line);
        }
        payloadJsonStr = buf.data;
    }
    else if (exists(payloadArg) && isFile(payloadArg))
    {
        payloadJsonStr = readText(payloadArg);
    }
    else
    {
        payloadJsonStr = payloadArg;
    }

    if (payloadJsonStr.length == 0)
    {
        stderr.writeln("Error: Empty payload provided.");
        return 1;
    }

    Json parsed;
    try
    {
        parsed = parseJsonString(payloadJsonStr);
    }
    catch (Exception e)
    {
        stderr.writefln("Error parsing JSON payload: %s", e.msg);
        return 1;
    }

    TaskNode task;
    string buildId = "single_run";
    string[string] upstreamFingerprints;
    bool force = false;
    string[] allowedRepositories;
    string[string] repositoryMap;

    if (parsed.type == Json.Type.object && "task" in parsed)
    {
        task = deserializeJson!TaskNode(parsed["task"]);
        if ("build_id" in parsed) buildId = parsed["build_id"].get!string;
        if ("workspace_dir" in parsed && workspaceDir == ".") workspaceDir = parsed["workspace_dir"].get!string;
        if ("storage_base_dir" in parsed) storageDir = parsed["storage_base_dir"].get!string;
        if ("upstream_artifact_hashes" in parsed) upstreamFingerprints = deserializeJson!(string[string])(parsed["upstream_artifact_hashes"]);
        if ("force" in parsed) force = parsed["force"].get!bool;
        if ("allowed_repositories" in parsed) allowedRepositories = deserializeJson!(string[])(parsed["allowed_repositories"]);
        if ("repository_map" in parsed) repositoryMap = deserializeJson!(string[string])(parsed["repository_map"]);
    }
    else
    {
        task = deserializeJson!TaskNode(parsed);
    }

    if (!exists(workspaceDir))
    {
        mkdirRecurse(workspaceDir);
    }

    // Resolve artifact storage: prefer HTTP (server-mediated), fall back to local plugin
    ArtifactStorage storage;
    if (serverUrl.length > 0)
    {
        storage = new HttpArtifactStorage(serverUrl);
    }
    else
    {
        // Offline mode: load artifact storage plugins locally
        foreach (dir; searchDirs)
        {
            if (exists(dir) && isDir(dir))
            {
                try
                {
                    PluginLoader.instance.loadBundledPlugins(dir, [PluginCategory.artifact]);
                }
                catch (Exception) {}
            }
        }
        storage = PluginRegistry.instance.getDefaultArtifactStorage();
        if (storage is null)
        {
            stderr.writeln("Error: No artifact storage plugin registered and no --server-url provided.");
            stderr.writeln("Please provide --server-url or ensure an artifact plugin is loaded.");
            return 1;
        }
    }
    auto engine = new TaskEngine(storage);

    auto result = engine.executeTask(
        buildId,
        task,
        workspaceDir,
        upstreamFingerprints,
        force,
        (line) {
            stderr.writeln(line);
        },
        allowedRepositories,
        repositoryMap
    );

    writeln(serializeToJsonString(result));
    return result.status == TaskStatus.succeeded ? 0 : (result.exitCode != 0 ? result.exitCode : 1);
}

int handleWorker(string[] args)
{
    import std.process : environment;

    string serverUrl = environment.get("CONFECTOR_SERVER_URL", "http://localhost:8080");
    string workerId = environment.get("CONFECTOR_WORKER_ID", "");
    string token = environment.get("CONFECTOR_WORKER_TOKEN", environment.get("CONFECTOR_SECRET_TOKEN", ""));
    string workspaceDir = "";
    string storageDir = "";
    string pluginsDir = "plugins";
    size_t pollInterval = 2;
    size_t visibilityTimeout = 60;
    size_t heartbeatInterval = 15;
    size_t maxTasks = 0;
    bool verbose = false;

    auto helpInfo = getopt(
        args,
        "server-url", "Confector server base URL (default: http://localhost:8080)", &serverUrl,
        "worker-id", "Unique worker ID", &workerId,
        "token", "Worker authorization secret token", &token,
        "workspace", "Worker workspace directory", &workspaceDir,
        "storage-dir", "Artifact storage directory", &storageDir,
        "plugins-dir", "Directory containing runner plugins", &pluginsDir,
        "poll-interval", "Queue poll interval in seconds", &pollInterval,
        "visibility-timeout", "Visibility timeout in seconds", &visibilityTimeout,
        "heartbeat-interval", "Heartbeat renewal interval in seconds", &heartbeatInterval,
        "max-tasks", "Maximum tasks to process before exiting (0 = infinite)", &maxTasks,
        "verbose", "Enable verbose console logging", &verbose
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Usage: confector-runner worker [options]", helpInfo.options);
        return 0;
    }

    if (workspaceDir.length == 0)
    {
        stderr.writeln("Error: --workspace is required for worker command.");
        return 1;
    }
    if (storageDir.length == 0)
    {
        stderr.writeln("Error: --storage-dir is required for worker command.");
        return 1;
    }

    printBanner();
    writefln("Starting remote worker '%s' targeting server '%s'...", workerId.length > 0 ? workerId : "auto-generated", serverUrl);

    HttpWorkerConfig config;
    config.serverUrl = serverUrl;
    config.workerId = workerId;
    config.workerToken = token;
    config.workspaceDir = workspaceDir;
    config.storageDir = storageDir;
    config.pluginsDir = pluginsDir;
    config.pollIntervalSeconds = pollInterval;
    config.visibilityTimeoutSeconds = visibilityTimeout;
    config.heartbeatIntervalSeconds = heartbeatInterval;
    config.maxTasksToProcess = maxTasks;
    config.verbose = verbose;

    int exitCode = 0;
    try
    {
        auto runner = new HttpWorkerDaemon(config);
        runner.run();
    }
    catch (Throwable e)
    {
        stderr.writefln("[worker] Fatal worker error: %s", e.msg);
        exitCode = 1;
    }

    return exitCode;
}

int main(string[] args)
{
    if (args.length < 2)
    {
        printUsage();
        return 1;
    }

    string cmd = args[1];
    string[] subArgs = args[1 .. $];

    if (cmd == "-h" || cmd == "--help" || cmd == "help")
    {
        printUsage();
        return 0;
    }
    else if (cmd == "-v" || cmd == "--version" || cmd == "version")
    {
        printBanner();
        return 0;
    }
    else if (cmd == "run")
    {
        return handleRun(subArgs);
    }
    else if (cmd == "worker")
    {
        return handleWorker(subArgs);
    }
    else
    {
        stderr.writefln("Unknown command '%s'. Use --help for available commands.", cmd);
        return 1;
    }
}
