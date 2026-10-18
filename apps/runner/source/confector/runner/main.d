module confector.runner.main;

import confector.runner_core.worker : HttpWorkerConfig, HttpWorkerDaemon;
import confector.runner_core.steps.builtin : BuiltinStepRunner;

import std.getopt;
import std.stdio : writeln, writefln, stderr;

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
    writeln("  worker   Start an HTTP-polling worker daemon communicating with Confector server");
    writeln();
    writeln("Options:");
    writeln("  -h, --help      Display this help text");
    writeln("  -v, --version   Display version information");
    writeln();
    writeln("Worker options:");
    writeln("  --server-url=<url>       Confector server base URL (default: http://localhost:8080)");
    writeln("  --worker-id=<id>         Unique worker identifier");
    writeln("  --workspace=<dir>        Worker workspace directory (required)");
    writeln("  --poll-interval=<sec>    Queue poll interval in seconds (default: 2)");
    writeln("  --visibility-timeout=<s  Visibility timeout in seconds (default: 60)");
    writeln("  --heartbeat-interval=<s  Heartbeat renewal interval in seconds (default: 15)");
    writeln("  --max-tasks=<count>      Maximum tasks to process before exiting (0 = infinite)");
    writeln("  --verbose                Enable verbose logging to console");
}

int handleWorker(string[] args)
{
    import std.process : environment;

    string serverUrl = environment.get("CONFECTOR_SERVER_URL", "http://localhost:8080");
    string workerId = environment.get("CONFECTOR_WORKER_ID", "");
    string workspaceDir = "";
    size_t pollInterval = 2;
    size_t visibilityTimeout = 60;
    size_t heartbeatInterval = 15;
    size_t maxTasks = 0;
    bool verbose = false;

    auto helpInfo = getopt(
        args,
        "server-url", "Confector server base URL (default: http://localhost:8080)", &serverUrl,
        "worker-id", "Unique worker ID", &workerId,
        "workspace", "Worker workspace directory", &workspaceDir,
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

    printBanner();
    writefln("Starting remote worker '%s' targeting server '%s'...", workerId.length > 0 ? workerId : "auto-generated", serverUrl);

    HttpWorkerConfig config;
    config.serverUrl = serverUrl;
    config.workerId = workerId;
    config.workspaceDir = workspaceDir;
    config.pollIntervalSeconds = pollInterval;
    config.visibilityTimeoutSeconds = visibilityTimeout;
    config.heartbeatIntervalSeconds = heartbeatInterval;
    config.maxTasksToProcess = maxTasks;
    config.verbose = verbose;

    int exitCode = 0;
    try
    {
        auto runner = new HttpWorkerDaemon(config, new BuiltinStepRunner());
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
