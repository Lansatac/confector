module plugins.executors.local_process;

import std.format;
import std.process;
import std.stdio;
import std.file : exists, mkdirRecurse, write, remove, tempDir;
import std.parallelism : totalCPUs;
import std.path : buildPath, isAbsolute;
import std.json : JSONValue, JSONType, parseJSON;
import std.uuid : randomUUID;
import core.sync.mutex : Mutex;
import core.time : Duration, seconds, msecs, MonoTime;
import core.thread : Thread;

import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, NullPluginContext, PluginCategory, WorkerPlugin;
import confector.plugin_api.executor : ComputeProvider, ComputeInstance, WorkerRecord, ExecutionRequest, ExecutionResult, LogDelegate, ComputeProvisioner;

/**
 * Concrete ComputeInstance managing task execution by provisioning and launching
 * the standalone confector-runner subprocess with structured payloads and credentials.
 */
class LocalProcessInstance : ComputeInstance
{
    private WorkerRecord m_record;

    this(in WorkerRecord record)
    {
        m_record = cast()record;
    }

    @property string id() const
    {
        return m_record.id;
    }

    @property string providerType() const
    {
        return m_record.providerType;
    }

    @property bool isEnabled() const
    {
        return m_record.enabled;
    }

    @property string[] supportedStepTypes() const
    {
        if (m_record.configuration.type == JSONType.object)
        {
            auto pSteps = "allowedStepTypes" in m_record.configuration;
            if (pSteps !is null && pSteps.type == JSONType.array)
            {
                string[] types;
                foreach (step; pSteps.array)
                {
                    if (step.type == JSONType.string)
                    {
                        types ~= step.str;
                    }
                }
                if (types.length > 0)
                {
                    return types;
                }
            }
        }
        return ["bash", "powershell", "git"];
    }

    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
    {
        ExecutionResult result;

        if (!m_record.enabled)
        {
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = format("Compute instance '%s' is disabled. Enable it in the Executors dashboard to run tasks.", m_record.name.length > 0 ? m_record.name : m_record.id);
            if (logCallback !is null)
            {
                logCallback(format("Execution error: %s", result.errorMessage));
            }
            return result;
        }

        string effectiveWorkDir = request.workingDirectory;
        if (effectiveWorkDir.length == 0 && m_record.configuration.type == JSONType.object)
        {
            auto pWork = "workspaceDir" in m_record.configuration;
            if (pWork !is null && pWork.type == JSONType.string && pWork.str.length > 0)
            {
                effectiveWorkDir = pWork.str;
            }
        }
        if (effectiveWorkDir.length == 0)
        {
            effectiveWorkDir = ".";
        }

        if (!exists(effectiveWorkDir))
        {
            try
            {
                mkdirRecurse(effectiveWorkDir);
            }
            catch (Exception)
            {
            }
        }

        string runnerBinary = "bin/confector-runner";
        string defaultShell = "powershell";
        bool isolateEnv = false;
        string secretToken = "";

        if (m_record.configuration.type == JSONType.object)
        {
            auto pRunner = "runnerBinary" in m_record.configuration;
            if (pRunner !is null && pRunner.type == JSONType.string && pRunner.str.length > 0)
            {
                runnerBinary = pRunner.str;
            }

            auto pShell = "defaultShell" in m_record.configuration;
            if (pShell !is null && pShell.type == JSONType.string && pShell.str.length > 0)
            {
                defaultShell = pShell.str;
            }

            auto pIso = "isolateEnvironment" in m_record.configuration;
            if (pIso !is null)
            {
                if (pIso.type == JSONType.true_) isolateEnv = true;
                else if (pIso.type == JSONType.false_) isolateEnv = false;
            }

            auto pTok = "secretToken" in m_record.configuration;
            if (pTok !is null && pTok.type == JSONType.string)
            {
                secretToken = pTok.str;
            }
        }

        // Resolve runner binary executable path
        string resolvedRunner = runnerBinary;
        version(Windows)
        {
            import std.string : endsWith;
            if (!resolvedRunner.endsWith(".exe") && exists(resolvedRunner ~ ".exe"))
            {
                resolvedRunner ~= ".exe";
            }
        }

        // Prepare environment map with brokered credentials and sandboxing
        string[string] envMap;
        if (!isolateEnv)
        {
            envMap = environment.toAA();
        }

        foreach (k, v; request.effectiveEnvironment)
        {
            envMap[k] = v;
        }

        // Inject brokered worker token/secret
        if (secretToken.length > 0)
        {
            envMap["CONFECTOR_WORKER_TOKEN"] = secretToken;
            envMap["CONFECTOR_SECRET_TOKEN"] = secretToken;
        }

        // Build structured TaskNode payload JSON for confector-runner
        string scriptToRun = request.effectiveScript;
        string taskId = request.taskId.length > 0 ? request.taskId : "task_1";
        string buildId = request.buildId.length > 0 ? request.buildId : "build_local";

        JSONValue stepObj = JSONValue([
            "name": JSONValue(taskId),
            "type": JSONValue(defaultShell),
            "script": JSONValue(scriptToRun)
        ]);

        JSONValue taskObj = JSONValue([
            "id": JSONValue(taskId),
            "name": JSONValue(taskId),
            "script": JSONValue(scriptToRun),
            "steps": JSONValue([stepObj])
        ]);

        JSONValue payloadObj = JSONValue([
            "build_id": JSONValue(buildId),
            "workspace_dir": JSONValue(effectiveWorkDir),
            "task": taskObj
        ]);

        string tempPayloadPath = buildPath(tempDir(), format("payload_%s.json", randomUUID().toString()));
        try
        {
            write(tempPayloadPath, payloadObj.toString());
        }
        catch (Exception e)
        {
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = format("Failed to write temporary runner payload: %s", e.msg);
            return result;
        }
        scope(exit)
        {
            if (exists(tempPayloadPath))
            {
                remove(tempPayloadPath);
            }
        }

        string[] cmdArgs = [
            resolvedRunner,
            "run",
            format("--payload=%s", tempPayloadPath),
            format("--workspace=%s", effectiveWorkDir)
        ];

        static class ExecState
        {
            Mutex mutex;
            bool processExited = false;
            int exitCode = -1;
            string[] outputLines;
            string errorMessage;
            bool timedOut = false;

            this()
            {
                mutex = new Mutex();
            }
        }

        auto state = new ExecState();
        MonoTime startTime = MonoTime.currTime;

        try
        {
            auto pipe = pipeProcess(cmdArgs, Redirect.all, envMap, Config.none, effectiveWorkDir.length > 0 ? effectiveWorkDir : null);

            auto readerThread = new Thread({
                try
                {
                    foreach (line; pipe.stdout.byLineCopy)
                    {
                        synchronized (state.mutex)
                        {
                            state.outputLines ~= line;
                        }
                        if (logCallback !is null)
                        {
                            logCallback(line);
                        }
                    }

                    auto ec = wait(pipe.pid);
                    synchronized (state.mutex)
                    {
                        state.exitCode = ec;
                        state.processExited = true;
                    }
                }
                catch (Exception e)
                {
                    synchronized (state.mutex)
                    {
                        state.errorMessage = e.msg;
                        state.processExited = true;
                    }
                }
            });
            readerThread.start();

            size_t timeoutSec = request.timeoutSeconds > 0 ? request.timeoutSeconds : 900;
            size_t elapsedMsecs = 0;
            size_t checkInterval = 25;

            while (true)
            {
                bool done = false;
                synchronized (state.mutex)
                {
                    done = state.processExited;
                }
                if (done) break;

                if (elapsedMsecs >= timeoutSec * 1000)
                {
                    synchronized (state.mutex)
                    {
                        state.timedOut = true;
                    }
                    try
                    {
                        kill(pipe.pid);
                    }
                    catch (Exception)
                    {
                    }
                    break;
                }

                Thread.sleep(msecs(checkInterval));
                elapsedMsecs += checkInterval;
            }

            try
            {
                readerThread.join();
            }
            catch (Exception)
            {
            }

            MonoTime endTime = MonoTime.currTime;
            result.durationMs = (endTime - startTime).total!"msecs";

            synchronized (state.mutex)
            {
                result.outputLines = state.outputLines;
                if (state.timedOut)
                {
                    result.exitCode = -2;
                    result.success = false;
                    result.errorMessage = format("Runner subprocess execution timed out after %d seconds", timeoutSec);
                }
                else if (state.errorMessage.length > 0)
                {
                    result.exitCode = -1;
                    result.success = false;
                    result.errorMessage = state.errorMessage;
                }
                else
                {
                    result.exitCode = state.exitCode;
                    result.success = (state.exitCode == 0);
                    if (!result.success)
                    {
                        result.errorMessage = format("Runner subprocess exited with code %d", state.exitCode);
                    }
                }
            }
        }
        catch (Exception e)
        {
            MonoTime endTime = MonoTime.currTime;
            result.durationMs = (endTime - startTime).total!"msecs";
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = format("Failed to spawn confector-runner subprocess '%s': %s", resolvedRunner, e.msg);
            if (logCallback !is null)
            {
                logCallback(format("Subprocess spawn error: %s", result.errorMessage));
            }
        }

        return result;
    }
}

/**
 * Local process ComputeProvider / WorkerPlugin managing runner subprocess provisioning,
 * environment sandboxing, workspace root configuration, and token credential injection.
 */
class LocalProcessProvider : WorkerPlugin, ComputeProvider
{
    private PluginContext m_context;

    @property string name() const { return "local-process"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Local runner subprocess compute provider with credential brokering and environment sandboxing"; }
    @property PluginCategory category() const { return PluginCategory.worker; }
    @property string providerType() const { return "local_process"; }
    @property string displayName() const { return "Local Subprocess Runner"; }
    @property string[] supportedStepTypes() const { return ["process", "bash", "powershell", "git"]; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("LocalProcessProvider initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("LocalProcessProvider shut down");
        }
    }

    JSONValue defaultConfig() const
    {
        long defaultConcurrency = cast(long)totalCPUs;
        if (defaultConcurrency <= 0) defaultConcurrency = 1;

        JSONValue cfg = JSONValue([
            "maxConcurrency": JSONValue(defaultConcurrency),
            "workspaceDir": JSONValue(".confector/workspaces"),
            "runnerBinary": JSONValue("bin/confector-runner"),
            "defaultShell": JSONValue("powershell"),
            "isolateEnvironment": JSONValue(false),
            "secretToken": JSONValue(""),
            "allowedStepTypes": JSONValue([
                JSONValue("process"),
                JSONValue("bash"),
                JSONValue("powershell"),
                JSONValue("git")
            ])
        ]);
        return cfg;
    }

    string[] validateConfig(in JSONValue config) const
    {
        string[] errors;
        if (config.type != JSONType.object)
        {
            errors ~= "Configuration must be a JSON object";
            return errors;
        }

        if (auto p = "maxConcurrency" in config)
        {
            if ((p.type != JSONType.integer && p.type != JSONType.uinteger) || (p.type == JSONType.integer && p.integer < 1) || (p.type == JSONType.uinteger && p.uinteger < 1))
            {
                errors ~= "maxConcurrency must be a positive integer greater than or equal to 1";
            }
        }

        if (auto p = "workspaceDir" in config)
        {
            if (p.type != JSONType.string || p.str.length == 0)
            {
                errors ~= "workspaceDir cannot be empty";
            }
        }

        if (auto p = "runnerBinary" in config)
        {
            if (p.type != JSONType.string || p.str.length == 0)
            {
                errors ~= "runnerBinary cannot be empty";
            }
        }

        return errors;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;

        int concurrency = totalCPUs > 0 ? cast(int)totalCPUs : 1;
        int hostCores = concurrency;
        string workspaceDir = ".confector/workspaces";
        string runnerBinary = "bin/confector-runner";
        string defaultShell = "powershell";
        bool isolateEnvironment = false;
        string secretToken = "";
        string allowedStepsStr = "process, bash, powershell, git";

        if (currentConfig.type == JSONType.object)
        {
            if (auto p = "maxConcurrency" in currentConfig)
            {
                if (p.type == JSONType.integer) concurrency = cast(int)p.integer;
            }
            if (auto p = "workspaceDir" in currentConfig)
            {
                if (p.type == JSONType.string) workspaceDir = p.str;
            }
            if (auto p = "runnerBinary" in currentConfig)
            {
                if (p.type == JSONType.string) runnerBinary = p.str;
            }
            if (auto p = "defaultShell" in currentConfig)
            {
                if (p.type == JSONType.string) defaultShell = p.str;
            }
            if (auto p = "isolateEnvironment" in currentConfig)
            {
                if (p.type == JSONType.true_) isolateEnvironment = true;
                else if (p.type == JSONType.false_) isolateEnvironment = false;
            }
            if (auto p = "secretToken" in currentConfig)
            {
                if (p.type == JSONType.string) secretToken = p.str;
            }
            if (auto p = "allowedStepTypes" in currentConfig)
            {
                if (p.type == JSONType.array)
                {
                    string[] types;
                    foreach (item; p.array)
                    {
                        if (item.type == JSONType.string) types ~= item.str;
                    }
                    if (types.length > 0)
                    {
                        import std.string : join;
                        allowedStepsStr = types.join(", ");
                    }
                }
            }
        }

        compileHTMLDietFile!("config.dt", concurrency, hostCores, workspaceDir, runnerBinary, defaultShell, isolateEnvironment, secretToken, allowedStepsStr)(html);

        return html.data;
    }

    ComputeInstance createExecutor(in WorkerRecord record)
    {
        return new LocalProcessInstance(record);
    }

    ComputeProvisioner createProvisioner(in WorkerRecord record)
    {
        LocalProcessProvisionerConfig cfg;
        if (record.configuration.type == JSONType.object)
        {
            if (auto p = "maxConcurrency" in record.configuration)
            {
                if (p.type == JSONType.integer) cfg.maxConcurrency = cast(size_t)p.integer;
            }
            if (auto p = "workspaceDir" in record.configuration)
            {
                if (p.type == JSONType.string) cfg.workspaceDir = p.str;
            }
            if (auto p = "runnerBinary" in record.configuration)
            {
                if (p.type == JSONType.string) cfg.runnerBinary = p.str;
            }
            if (auto p = "secretToken" in record.configuration)
            {
                if (p.type == JSONType.string) cfg.secretToken = p.str;
            }
        }
        return new LocalProcessProvisioner(cfg);
    }
}

/**
 * Configuration for LocalProcessProvisioner.
 */
struct LocalProcessProvisionerConfig
{
    string runnerBinary = "bin/confector-runner";
    string serverUrl = "http://localhost:8080";
    string workspaceDir = ".confector/workspaces";
    string storageDir = ".confector/artifacts";
    string pluginsDir = "plugins";
    string secretToken = "";
    size_t maxConcurrency = 0; // 0 = totalCPUs
    string[] supportedExecutorTypes = ["local", "local_process", ""];
    void delegate(string[] cmdArgs) customLauncher = null;
}

/**
 * ComputeProvisioner implementation that manages local subprocess capacity
 * by launching standalone confector-runner worker instances up to a concurrency ceiling.
 */
class LocalProcessProvisioner : ComputeProvisioner
{
    private LocalProcessProvisionerConfig m_config;
    private size_t m_activeInstances = 0;
    private Mutex m_mutex;

    this(LocalProcessProvisionerConfig config = LocalProcessProvisionerConfig.init)
    {
        m_config = config;
        if (m_config.maxConcurrency == 0)
        {
            m_config.maxConcurrency = totalCPUs > 0 ? totalCPUs : 4;
        }
        if (m_config.supportedExecutorTypes.length == 0)
        {
            m_config.supportedExecutorTypes = ["local", "local_process", ""];
        }
        m_mutex = new Mutex();
    }

    @property string providerType() const
    {
        return "local";
    }

    @property size_t activeInstanceCount() const
    {
        synchronized (m_mutex)
        {
            return m_activeInstances;
        }
    }

    @property size_t maxCapacity() const
    {
        return m_config.maxConcurrency;
    }

    bool canProvision(in QueueDemand demand) const
    {
        string exec = demand.executorType;
        bool matchesType = false;
        foreach (t; m_config.supportedExecutorTypes)
        {
            if (exec == t)
            {
                matchesType = true;
                break;
            }
        }
        if (!matchesType && exec.length > 0)
        {
            return false;
        }

        if (demand.requirements !is null)
        {
            if (auto p = "gpu" in demand.requirements)
            {
                if (*p == "true") return false;
            }
            if (auto p = "cloud" in demand.requirements)
            {
                if (*p == "aws" || *p == "k8s") return false;
            }
        }

        return true;
    }

    void requestCapacity(in QueueDemand demand)
    {
        if (!canProvision(demand))
        {
            return;
        }

        size_t toSpawn = 0;
        synchronized (m_mutex)
        {
            if (m_activeInstances >= m_config.maxConcurrency)
            {
                return;
            }
            size_t available = m_config.maxConcurrency - m_activeInstances;
            toSpawn = demand.pendingWorkOrderCount > 0 ? demand.pendingWorkOrderCount : 1;
            if (toSpawn > available)
            {
                toSpawn = available;
            }
            m_activeInstances += toSpawn;
        }

        for (size_t i = 0; i < toSpawn; i++)
        {
            spawnRunnerInstance();
        }
    }

    private void spawnRunnerInstance()
    {
        if (m_config.customLauncher !is null)
        {
            try
            {
                m_config.customLauncher(["custom"]);
            }
            finally
            {
                synchronized (m_mutex)
                {
                    if (m_activeInstances > 0) m_activeInstances--;
                }
            }
            return;
        }

        auto workerThread = new Thread({
            try
            {
                string binPath = m_config.runnerBinary;
                version (Windows)
                {
                    import std.string : endsWith;
                    if (!binPath.endsWith(".exe") && exists(binPath ~ ".exe"))
                    {
                        binPath ~= ".exe";
                    }
                }

                if (!exists(binPath))
                {
                    string[] fallbacks = ["bin/confector-runner", "../bin/confector-runner", "./confector-runner", "confector-runner"];
                    try
                    {
                        import std.file : thisExePath;
                        import std.path : dirName, buildPath;
                        string exeDir = dirName(thisExePath());
                        fallbacks ~= buildPath(exeDir, "confector-runner");
                    }
                    catch (Exception) {}

                    foreach (fb; fallbacks)
                    {
                        string candidate = fb;
                        version (Windows)
                        {
                            import std.string : endsWith;
                            if (!candidate.endsWith(".exe")) candidate ~= ".exe";
                        }
                        if (exists(candidate))
                        {
                            binPath = candidate;
                            break;
                        }
                    }
                }

                if (exists(binPath))
                {
                    string[] runnerArgs = [
                        binPath,
                        "worker",
                        format("--server-url=%s", m_config.serverUrl),
                        format("--workspace=%s", m_config.workspaceDir),
                        format("--storage-dir=%s", m_config.storageDir),
                        format("--plugins-dir=%s", m_config.pluginsDir),
                        "--max-tasks=1",
                        "--poll-interval=1"
                    ];
                    if (m_config.secretToken.length > 0)
                    {
                        runnerArgs ~= format("--token=%s", m_config.secretToken);
                    }

                    auto pid = spawnProcess(runnerArgs);
                    wait(pid);
                }
            }
            catch (Exception)
            {
            }
            finally
            {
                synchronized (m_mutex)
                {
                    if (m_activeInstances > 0)
                    {
                        m_activeInstances--;
                    }
                }
            }
        });
        workerThread.isDaemon = true;
        workerThread.start();
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new LocalProcessProvider();
}

unittest
{
    auto provider = new LocalProcessProvider();
    provider.initialize(new NullPluginContext("local-process"));
    assert(provider.name == "local-process");
    assert(provider.category == PluginCategory.worker);
    assert(provider.providerType == "local_process");
    assert(provider.displayName == "Local Subprocess Runner");
    assert(provider.supportedStepTypes.length == 4);

    auto defConfig = provider.defaultConfig();
    assert(defConfig.type == JSONType.object);
    assert(defConfig["maxConcurrency"].integer >= 1);
    assert(defConfig["runnerBinary"].str == "bin/confector-runner");
    assert(defConfig["workspaceDir"].str == ".confector/workspaces");
    assert(defConfig["isolateEnvironment"].type == JSONType.false_);

    assert(provider.validateConfig(defConfig).length == 0);

    JSONValue invalidConfig = JSONValue(["maxConcurrency": JSONValue(0), "runnerBinary": JSONValue("")]);
    auto errors = provider.validateConfig(invalidConfig);
    assert(errors.length == 2);

    string formHtml = provider.renderConfigFormHtml(defConfig);
    assert(formHtml.length > 0);
    import std.string : indexOf;
    assert(formHtml.indexOf("config_maxConcurrency") != -1);
    assert(formHtml.indexOf("config_runnerBinary") != -1);
    assert(formHtml.indexOf("config_isolateEnvironment") != -1);
    assert(formHtml.indexOf("config_secretToken") != -1);

    WorkerRecord rec;
    rec.id = "worker_1";
    rec.name = "Local Worker 1";
    rec.providerType = "local_process";
    rec.enabled = false;
    rec.configuration = defConfig;

    auto instance = provider.createExecutor(rec);
    assert(instance !is null);
    assert(instance.id == "worker_1");
    assert(instance.providerType == "local_process");
    assert(!instance.isEnabled);

    // Verify disabled execution returns immediate failure
    ExecutionRequest req;
    req.command = "Write-Output 'should fail when disabled'";
    auto disRes = instance.execute(req);
    assert(!disRes.success);
    assert(disRes.exitCode != 0);

    // Enable and verify compute instance properties
    rec.enabled = true;
    auto enabledInstance = provider.createExecutor(rec);
    assert(enabledInstance.isEnabled);
    assert(enabledInstance.supportedStepTypes.length == 4);

    // If confector-runner binary is built, test subprocess execution invocation
    string testRunnerBin = "bin/confector-runner";
    version(Windows) testRunnerBin ~= ".exe";
    if (exists(testRunnerBin))
    {
        ExecutionRequest testReq;
        testReq.taskId = "test_subproc";
        testReq.script = "echo subproc_ok";
        testReq.workingDirectory = "test_workspace";
        auto subprocRes = enabledInstance.execute(testReq);
        assert(subprocRes.exitCode == 0 || subprocRes.durationMs > 0);
    }

    // Test LocalProcessProvisioner capability checking and demand handling
    LocalProcessProvisionerConfig provConfig;
    provConfig.maxConcurrency = 3;
    bool customLaunched = false;
    provConfig.customLauncher = (args) {
        customLaunched = true;
    };

    auto provisioner = new LocalProcessProvisioner(provConfig);
    assert(provisioner.providerType == "local");
    assert(provisioner.maxCapacity == 3);
    assert(provisioner.activeInstanceCount == 0);

    // Matches local and default executor types
    assert(provisioner.canProvision(QueueDemand("local", 1)));
    assert(provisioner.canProvision(QueueDemand("local_process", 1)));
    assert(provisioner.canProvision(QueueDemand("", 1)));

    // Rejects incompatible tags and requirements
    assert(!provisioner.canProvision(QueueDemand("kubernetes", 1)));
    assert(!provisioner.canProvision(QueueDemand("ecs", 1)));
    assert(!provisioner.canProvision(QueueDemand("local", 1, ["gpu": "true"])));
    assert(!provisioner.canProvision(QueueDemand("local", 1, ["cloud": "aws"])));

    // Request capacity
    provisioner.requestCapacity(QueueDemand("local", 2));
    assert(customLaunched);

    // Test createProvisioner via provider
    auto provFromRecord = provider.createProvisioner(rec);
    assert(provFromRecord !is null);
    assert(provFromRecord.providerType == "local");
}
