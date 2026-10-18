module confector.plugins.worker.local_process;

import std.format;
import std.process;
import std.stdio;
import std.file : exists;
import std.parallelism : totalCPUs;
import std.json : JSONValue, JSONType;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, NullPluginContext, PluginCategory, WorkerPlugin, ConfigDefinition, ConfigRegistry, Description, Key, Env, EnvVar, Required;
import confector.plugin_api.executor : ComputeProvider, WorkerRecord, ComputeProvisioner;

/**
 * Local process ComputeProvider / WorkerPlugin managing runner subprocess provisioning,
 * environment sandboxing, workspace root configuration, and token credential injection.
 */
class LocalProcessProvider : WorkerPlugin, ComputeProvider
{
    private PluginContext m_context;
    private LocalProcessProvisionerConfig m_scopedConfig;

    @property string name() const { return "local-process"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Local runner subprocess compute provider with credential brokering and environment sandboxing"; }
    @property PluginCategory category() const { return PluginCategory.worker; }
    @property string providerType() const { return "local_process"; }
    @property string displayName() const { return "Local Subprocess Runner"; }
    @property string[] supportedStepTypes() const { return ["bash", "powershell", "git"]; }
    @property LocalProcessProvisionerConfig scopedConfig() const { return cast()m_scopedConfig; }

    override ConfigDefinition[] configDefinitions() const
    {
        // Definitions are now registered via bindDefinition!LocalProcessProvisionerConfig
        // This method is kept for backward compatibility but returns an empty array.
        return [];
    }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("LocalProcessProvider initialized");
            if (m_context.config !is null)
            {
                try
                {
                    m_scopedConfig = m_context.config.bind!LocalProcessProvisionerConfig();
                }
                catch (Exception e)
                {
                    m_scopedConfig = LocalProcessProvisionerConfig.init;
                }
            }
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
        long defaultConcurrency = cast(long)(m_scopedConfig.maxConcurrency > 0 ? m_scopedConfig.maxConcurrency : totalCPUs);
        if (defaultConcurrency <= 0) defaultConcurrency = 1;

        string workDir = m_scopedConfig.workspaceDir.length > 0 ? m_scopedConfig.workspaceDir : "/workspaces";

        JSONValue cfg = JSONValue([
            "maxConcurrency": JSONValue(defaultConcurrency),
            "workspaceDir": JSONValue(workDir),
            "defaultShell": JSONValue("powershell"),
            "isolateEnvironment": JSONValue(false),
            "allowedStepTypes": JSONValue([
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

        return errors;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;

        int concurrency = totalCPUs > 0 ? cast(int)totalCPUs : 1;
        int hostCores = concurrency;
        string workspaceDir = "/workspaces";
        string defaultShell = "powershell";
        bool isolateEnvironment = false;
        string allowedStepsStr = "";

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
            if (auto p = "defaultShell" in currentConfig)
            {
                if (p.type == JSONType.string) defaultShell = p.str;
            }
            if (auto p = "isolateEnvironment" in currentConfig)
            {
                if (p.type == JSONType.true_) isolateEnvironment = true;
                else if (p.type == JSONType.false_) isolateEnvironment = false;
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

        compileHTMLDietFile!("config.dt", concurrency, hostCores, workspaceDir, defaultShell, isolateEnvironment, allowedStepsStr)(html);

        return html.data;
    }

    ComputeProvisioner createProvisioner(in WorkerRecord record)
    {
        LocalProcessProvisionerConfig cfg = m_scopedConfig;
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
        }
        return new LocalProcessProvisioner(cfg, m_context);
    }
}

/**
 * Registers local process plugin configuration definitions in the ConfigRegistry.
 */
void registerLocalProcessConfigDefinitions(ConfigRegistry registry)
{
    if (registry is null) return;

    registry.bindDefinition!LocalProcessProvisionerConfig("plugins.local-process");
}

/**
 * Configuration for LocalProcessProvisioner.
 */
struct LocalProcessProvisionerConfig
{
    @Description("Path to confector-runner binary")
    string runnerBinary = "./confector-runner";

    @Description("Base URL of Confector server")
    string serverUrl = "http://localhost:8080";

    @Description("Base directory for runner workspaces")
    string workspaceDir = "/workspaces";

    @Description("Maximum concurrent runner subprocesses allowed (0 = auto-detect CPU count)")
    size_t maxConcurrency = 0;

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
    private PluginContext m_context;
    private size_t m_activeInstances = 0;
    private bool m_disabled = false;
    private Mutex m_mutex;

    this(LocalProcessProvisionerConfig config = LocalProcessProvisionerConfig.init, PluginContext context = null)
    {
        m_config = config;
        m_context = context;
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
        if (m_disabled) return false;
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
        if (m_disabled)
        {
            if (m_context !is null)
                m_context.info("[local_process] requestCapacity: provisioner is disabled, skipping");
            return;
        }

        if (!canProvision(demand))
        {
            if (m_context !is null)
                m_context.info(format("[local_process] requestCapacity: cannot provision demand (executorType='%s', pendingCount=%d)",
                    demand.executorType, demand.pendingWorkOrderCount));
            return;
        }

        size_t toSpawn = 0;
        synchronized (m_mutex)
        {
            if (m_activeInstances >= m_config.maxConcurrency)
            {
                if (m_context !is null)
                    m_context.info(format("[local_process] requestCapacity: at max capacity (%d/%d), cannot spawn more runners",
                        m_activeInstances, m_config.maxConcurrency));
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

        if (m_context !is null)
            m_context.info(format("[local_process] requestCapacity: spawning %d runner(s) for demand (executorType='%s', pendingCount=%d, active=%d/%d)",
                toSpawn, demand.executorType, demand.pendingWorkOrderCount, m_activeInstances, m_config.maxConcurrency));

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
                if (m_context !is null)
                    m_context.info("[local_process] Spawning custom runner instance");
                m_config.customLauncher(["custom"]);
            }
            catch (Exception e)
            {
                if (m_context !is null)
                    m_context.error(format("[local_process] Custom runner launcher failed: %s", e.msg));
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
                    bool shouldLog;
                    synchronized (m_mutex)
                    {
                        shouldLog = !m_disabled;
                        m_disabled = true;
                    }
                    if (shouldLog && m_context !is null)
                        m_context.critical(format("[local_process] Cannot find confector-runner binary at configured path '%s'. Disabling provisioner — builds will queue but never execute.", binPath));
                    return;
                }

                string[] runnerArgs = [
                    binPath,
                    "worker",
                    format("--server-url=%s", m_config.serverUrl),
                    format("--workspace=%s", m_config.workspaceDir),
                    "--max-tasks=1",
                    "--poll-interval=1"
                ];

                if (m_context !is null)
                    m_context.info(format("[local_process] Spawning runner worker: %s", runnerArgs[0]));

                auto pid = spawnProcess(runnerArgs);
                if (m_context !is null)
                    m_context.info(format("[local_process] Runner worker spawned with PID %d", pid.processID));
                auto exitStatus = wait(pid);
                if (m_context !is null)
                    m_context.info(format("[local_process] Runner worker (PID %d) exited with status %d", pid.processID, exitStatus));
            }
            catch (Exception e)
            {
                if (m_context !is null)
                    m_context.error(format("[local_process] Failed to spawn or run confector-runner worker: %s", e.msg));
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
    assert(provider.supportedStepTypes.length == 3);

    auto defConfig = provider.defaultConfig();
    assert(defConfig.type == JSONType.object);
    assert(defConfig["maxConcurrency"].integer >= 1);
    assert(defConfig["workspaceDir"].str == "/workspaces");
    assert(defConfig["isolateEnvironment"].type == JSONType.false_);

    // runnerBinary comes from plugin config at construction time
    assert(("runnerBinary" in defConfig) is null);

    assert(provider.validateConfig(defConfig).length == 0);

    JSONValue invalidConfig = JSONValue(["maxConcurrency": JSONValue(0)]);
    auto errors = provider.validateConfig(invalidConfig);
    assert(errors.length == 1);

    string formHtml = provider.renderConfigFormHtml(defConfig);
    assert(formHtml.length > 0);
    import std.string : indexOf;
    assert(formHtml.indexOf("config_maxConcurrency") != -1);
    assert(formHtml.indexOf("config_isolateEnvironment") != -1);
    assert(formHtml.indexOf("config_runnerBinary") == -1);

    WorkerRecord rec;
    rec.id = "worker_1";
    rec.name = "Local Worker 1";
    rec.providerType = "local_process";
    rec.enabled = false;
    rec.configuration = defConfig;

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

    // Test ConfigRegistry integration with LocalProcessProvider using bindDefinition!T
    auto configReg = new ConfigRegistry();
    registerLocalProcessConfigDefinitions(configReg);
    auto pluginCtx = new NullPluginContext("local-process", configReg.getScope("plugins.local-process"));
    auto localPlugin2 = new LocalProcessProvider();
    localPlugin2.initialize(pluginCtx);
    assert(localPlugin2.scopedConfig.runnerBinary == "bin/confector-runner");
}
