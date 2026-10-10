module confector.core.plugin;

public import confector.plugin_api.logging;
public import confector.plugin_api.plugin;
public import confector.plugin_api.model;
public import confector.plugin_api.executor;
public import confector.plugin_api.system;
public import confector.plugin_api.vcs;
public import confector.plugin_api.scheduler;
public import confector.config;
public import confector.core.storage;
public import confector.core.queue;

import vibe.core.log : logDebug, logInfo, logWarn, logError;
import vibe.data.json : Json;

/**
 * Concrete PluginContext provided by the Confector host.
 * Routes plugin logging to custom sinks or host logs and provides scoped configuration access.
 */
class HostPluginContext : PluginContext
{
    private string m_pluginName;
    private PluginLogCallback m_logSink;
    private ConfigAccessor m_config;

    this(string pluginName, PluginLogCallback logSink = null, ConfigAccessor configAccessor = null)
    {
        m_pluginName = pluginName;
        m_logSink = logSink;
        if (configAccessor !is null)
        {
            m_config = configAccessor;
        }
        else
        {
            m_config = new ScopedConfigAccessor(new ResolutionEngine(Json.emptyObject), "plugins." ~ pluginName);
        }
    }

    this(string pluginName, ConfigRegistry registry, PluginLogCallback logSink = null)
    {
        m_pluginName = pluginName;
        m_logSink = logSink;
        if (registry !is null)
        {
            m_config = registry.getScope("plugins." ~ pluginName);
        }
        else
        {
            m_config = new ScopedConfigAccessor(new ResolutionEngine(Json.emptyObject), "plugins." ~ pluginName);
        }
    }

    @property string pluginName() const
    {
        return m_pluginName;
    }

    @property ConfigAccessor config()
    {
        return m_config;
    }

    void log(LogLevel level, string message, string context = null)
    {
        if (m_logSink !is null)
        {
            LogEntry entry;
            entry.level = level;
            entry.message = message;
            entry.pluginName = m_pluginName;
            entry.context = context;
            m_logSink(entry);
        }
        else
        {
            final switch (level)
            {
                case LogLevel.trace:
                case LogLevel.debug_:
                    logDebug("[plugin:%s] %s", m_pluginName, message);
                    break;
                case LogLevel.info:
                    logInfo("[plugin:%s] %s", m_pluginName, message);
                    break;
                case LogLevel.warning:
                    logWarn("[plugin:%s] %s", m_pluginName, message);
                    break;
                case LogLevel.error:
                case LogLevel.critical:
                    logError("[plugin:%s] %s", m_pluginName, message);
                    break;
            }
        }
    }
}

/**
 * Central registry managing available plugins, providers, and ECS systems.
 * Facilitates loose coupling and dynamic discovery of capabilities.
 */
final class PluginRegistry
{
    private static PluginRegistry _instance;
    private Plugin[string] _plugins;
    private InputResolverSystem[] _inputResolvers;
    private FingerprintContributionSystem[] _fingerprintContributors;
    private ArtifactPublishingSystem[] _artifactPublishers;
    private BuildStepSystem[] _stepSystems;
    private BuildStepProvider[] _stepProviders;
    private ComputeProvider[] _computeProviders;
    private ArtifactStorage[] _artifactStorages;
    private ArtifactStorage[string] _artifactStoragesByType;
    private string _defaultArtifactStorageType;
    private BuildStateRepository[] _stateRepositories;
    private BuildStateRepository[string] _stateRepositoriesByType;
    private string _defaultStateRepositoryType;
    private WorkQueue[] _workQueues;
    private WorkQueue[string] _workQueuesByType;
    private string _defaultWorkQueueType;
    private VcsStateResolver[] _vcsResolvers;
    private Scheduler _scheduler;
    private PluginLogCallback _logCallback;
    private ConfigRegistry _configRegistry;

    public static PluginRegistry instance()
    {
        if (_instance is null)
        {
            _instance = new PluginRegistry();
        }
        return _instance;
    }

    public void setLogCallback(PluginLogCallback callback)
    {
        _logCallback = callback;
    }

    public void setConfigRegistry(ConfigRegistry registry)
    {
        _configRegistry = registry;
    }

    public ConfigRegistry getConfigRegistry()
    {
        return _configRegistry;
    }

    public void registerPlugin(Plugin plugin, ConfigAccessor configAccessor = null)
    {
        logDebug("[plugin_registry] registerPlugin: starting for '%s'", plugin.name);
        _plugins[plugin.name] = plugin;

        // Register any configuration definitions declared by the plugin
        if (_configRegistry !is null)
        {
            auto defs = plugin.configDefinitions();
            if (defs !is null)
            {
                foreach (ref def; defs)
                {
                    _configRegistry.registerDefinition(def);
                }
            }
        }

        ConfigAccessor scopeConfig = configAccessor;
        if (scopeConfig is null)
        {
            if (_configRegistry !is null)
            {
                scopeConfig = _configRegistry.getScope("plugins." ~ plugin.name);
            }
            else
            {
                scopeConfig = new ScopedConfigAccessor(new ResolutionEngine(Json.emptyObject), "plugins." ~ plugin.name);
            }
        }
        auto ctx = new HostPluginContext(plugin.name, _logCallback, scopeConfig);
        logDebug("[plugin_registry] Calling initialize() for '%s'", plugin.name);
        plugin.initialize(ctx);
        logDebug("[plugin_registry] initialize() returned for '%s'", plugin.name);

        // Automatically register implemented system interfaces
        if (auto resolver = cast(InputResolverSystem) plugin)
        {
            registerInputResolver(resolver);
        }
        if (auto contributor = cast(FingerprintContributionSystem) plugin)
        {
            registerFingerprintContributor(contributor);
        }
        if (auto pubSystem = cast(ArtifactPublishingSystem) plugin)
        {
            registerArtifactPublisher(pubSystem);
        }
        if (auto stepSystem = cast(BuildStepSystem) plugin)
        {
            registerStepSystem(stepSystem);
        }
        if (auto stepProvider = cast(BuildStepProvider) plugin)
        {
            registerStepProvider(stepProvider);
        }
        if (auto provider = cast(ComputeProvider) plugin)
        {
            registerComputeProvider(provider);
        }
        if (auto storage = cast(ArtifactStorage) plugin)
        {
            registerArtifactStorage(storage);
        }
        if (auto stateRepo = cast(BuildStateRepository) plugin)
        {
            registerStateRepository(stateRepo);
        }
        if (auto workQueue = cast(WorkQueue) plugin)
        {
            registerWorkQueue(workQueue);
        }
        if (auto vcsResolver = cast(VcsStateResolver) plugin)
        {
            registerVcsResolver(vcsResolver);
        }
        if (auto sched = cast(Scheduler) plugin)
        {
            registerScheduler(sched);
        }
        logDebug("[plugin_registry] registerPlugin: completed for '%s'", plugin.name);
    }

    public void registerInputResolver(InputResolverSystem system)
    {
        import std.algorithm : canFind;
        if (!_inputResolvers.canFind(system))
        {
            _inputResolvers ~= system;
        }
    }

    public void registerFingerprintContributor(FingerprintContributionSystem system)
    {
        import std.algorithm : canFind;
        if (!_fingerprintContributors.canFind(system))
        {
            _fingerprintContributors ~= system;
        }
    }

    public void registerArtifactPublisher(ArtifactPublishingSystem system)
    {
        import std.algorithm : canFind;
        if (!_artifactPublishers.canFind(system))
        {
            _artifactPublishers ~= system;
        }
    }

    public void registerStepSystem(BuildStepSystem system)
    {
        import std.algorithm : canFind;
        if (!_stepSystems.canFind(system))
        {
            _stepSystems ~= system;
        }
    }

    public void registerStepProvider(BuildStepProvider provider)
    {
        import std.algorithm : canFind;
        if (!_stepProviders.canFind(provider))
        {
            _stepProviders ~= provider;
        }
    }

    public void registerComputeProvider(ComputeProvider provider)
    {
        import std.algorithm : canFind;
        if (!_computeProviders.canFind(provider))
        {
            _computeProviders ~= provider;
        }
    }

    public void registerArtifactStorage(ArtifactStorage storage)
    {
        import std.algorithm : canFind;
        if (!_artifactStorages.canFind(storage))
        {
            _artifactStorages ~= storage;
            _artifactStoragesByType[storage.backendType] = storage;
            // First registered storage becomes the default
            if (_defaultArtifactStorageType.length == 0)
            {
                _defaultArtifactStorageType = storage.backendType;
            }
        }
    }

    public void registerStateRepository(BuildStateRepository repo)
    {
        import std.algorithm : canFind;
        if (!_stateRepositories.canFind(repo))
        {
            _stateRepositories ~= repo;
            _stateRepositoriesByType[repo.backendType] = repo;
            if (_defaultStateRepositoryType.length == 0)
            {
                _defaultStateRepositoryType = repo.backendType;
            }
        }
    }

    public void registerWorkQueue(WorkQueue queue)
    {
        import std.algorithm : canFind;
        if (!_workQueues.canFind(queue))
        {
            _workQueues ~= queue;
            _workQueuesByType[queue.backendType] = queue;
            if (_defaultWorkQueueType.length == 0)
            {
                _defaultWorkQueueType = queue.backendType;
            }
        }
    }

    public void registerVcsResolver(VcsStateResolver resolver)
    {
        import std.algorithm : canFind;
        if (!_vcsResolvers.canFind(resolver))
        {
            _vcsResolvers ~= resolver;
        }
    }

    public void unregisterPlugin(string name)
    {
        if (auto p = name in _plugins)
        {
            auto plugin = *p;
            _plugins.remove(name);
            plugin.shutdown();

            import std.algorithm.mutation : remove;
            if (auto resolver = cast(InputResolverSystem) plugin)
            {
                for (size_t i = 0; i < _inputResolvers.length; )
                {
                    if (_inputResolvers[i] is resolver) _inputResolvers = _inputResolvers.remove(i);
                    else i++;
                }
            }
            if (auto contributor = cast(FingerprintContributionSystem) plugin)
            {
                for (size_t i = 0; i < _fingerprintContributors.length; )
                {
                    if (_fingerprintContributors[i] is contributor) _fingerprintContributors = _fingerprintContributors.remove(i);
                    else i++;
                }
            }
            if (auto pubSystem = cast(ArtifactPublishingSystem) plugin)
            {
                for (size_t i = 0; i < _artifactPublishers.length; )
                {
                    if (_artifactPublishers[i] is pubSystem) _artifactPublishers = _artifactPublishers.remove(i);
                    else i++;
                }
            }
            if (auto stepSystem = cast(BuildStepSystem) plugin)
            {
                for (size_t i = 0; i < _stepSystems.length; )
                {
                    if (_stepSystems[i] is stepSystem) _stepSystems = _stepSystems.remove(i);
                    else i++;
                }
            }
            if (auto stepProvider = cast(BuildStepProvider) plugin)
            {
                for (size_t i = 0; i < _stepProviders.length; )
                {
                    if (_stepProviders[i] is stepProvider) _stepProviders = _stepProviders.remove(i);
                    else i++;
                }
            }
            if (auto provider = cast(ComputeProvider) plugin)
            {
                for (size_t i = 0; i < _computeProviders.length; )
                {
                    if (_computeProviders[i] is provider) _computeProviders = _computeProviders.remove(i);
                    else i++;
                }
            }
            if (auto storage = cast(ArtifactStorage) plugin)
            {
                for (size_t i = 0; i < _artifactStorages.length; )
                {
                    if (_artifactStorages[i] is storage) _artifactStorages = _artifactStorages.remove(i);
                    else i++;
                }
                if (auto it = storage.backendType in _artifactStoragesByType)
                {
                    if (*it is storage)
                    {
                        _artifactStoragesByType.remove(storage.backendType);
                        if (_defaultArtifactStorageType == storage.backendType && _artifactStorages.length > 0)
                        {
                            _defaultArtifactStorageType = _artifactStorages[0].backendType;
                        }
                        else if (_artifactStorages.length == 0)
                        {
                            _defaultArtifactStorageType = "";
                        }
                    }
                }
            }
            if (auto stateRepo = cast(BuildStateRepository) plugin)
            {
                for (size_t i = 0; i < _stateRepositories.length; )
                {
                    if (_stateRepositories[i] is stateRepo) _stateRepositories = _stateRepositories.remove(i);
                    else i++;
                }
                if (auto it = stateRepo.backendType in _stateRepositoriesByType)
                {
                    if (*it is stateRepo)
                    {
                        _stateRepositoriesByType.remove(stateRepo.backendType);
                        if (_defaultStateRepositoryType == stateRepo.backendType && _stateRepositories.length > 0)
                        {
                            _defaultStateRepositoryType = _stateRepositories[0].backendType;
                        }
                        else if (_stateRepositories.length == 0)
                        {
                            _defaultStateRepositoryType = "";
                        }
                    }
                }
            }
            if (auto workQueue = cast(WorkQueue) plugin)
            {
                for (size_t i = 0; i < _workQueues.length; )
                {
                    if (_workQueues[i] is workQueue) _workQueues = _workQueues.remove(i);
                    else i++;
                }
                if (auto it = workQueue.backendType in _workQueuesByType)
                {
                    if (*it is workQueue)
                    {
                        _workQueuesByType.remove(workQueue.backendType);
                        if (_defaultWorkQueueType == workQueue.backendType && _workQueues.length > 0)
                        {
                            _defaultWorkQueueType = _workQueues[0].backendType;
                        }
                        else if (_workQueues.length == 0)
                        {
                            _defaultWorkQueueType = "";
                        }
                    }
                }
            }
            if (auto vcsResolver = cast(VcsStateResolver) plugin)
            {
                for (size_t i = 0; i < _vcsResolvers.length; )
                {
                    if (_vcsResolvers[i] is vcsResolver) _vcsResolvers = _vcsResolvers.remove(i);
                    else i++;
                }
            }
        }
    }

    public InputResolverSystem[] getInputResolvers()
    {
        return _inputResolvers;
    }

    public FingerprintContributionSystem[] getFingerprintContributors()
    {
        return _fingerprintContributors;
    }

    public ArtifactPublishingSystem[] getArtifactPublishers()
    {
        return _artifactPublishers;
    }

    public BuildStepSystem[] getStepSystems()
    {
        return _stepSystems;
    }

    public BuildStepProvider[] getStepProviders()
    {
        return _stepProviders;
    }

    public BuildStepProvider getStepProvider(string stepType)
    {
        foreach (p; _stepProviders)
        {
            if (p.stepType == stepType)
            {
                return p;
            }
        }
        return null;
    }

    public ComputeProvider[] getComputeProviders()
    {
        return _computeProviders;
    }

    public ComputeProvider getComputeProvider(string providerType)
    {
        foreach (p; _computeProviders)
        {
            if (p.providerType == providerType)
            {
                return p;
            }
        }
        return null;
    }

    public ArtifactStorage[] getArtifactStorages()
    {
        return _artifactStorages;
    }

    public ArtifactStorage getArtifactStorage(string backendType)
    {
        if (auto s = backendType in _artifactStoragesByType)
            return *s;
        return null;
    }

    public ArtifactStorage getDefaultArtifactStorage()
    {
        if (_defaultArtifactStorageType.length > 0)
            return getArtifactStorage(_defaultArtifactStorageType);
        return null;
    }

    public string getDefaultArtifactStorageType()
    {
        return _defaultArtifactStorageType;
    }

    public void setDefaultArtifactStorage(string backendType)
    {
        if (backendType in _artifactStoragesByType)
        {
            _defaultArtifactStorageType = backendType;
        }
    }

    public BuildStateRepository[] getStateRepositories()
    {
        return _stateRepositories;
    }

    public BuildStateRepository getStateRepository(string backendType)
    {
        if (auto s = backendType in _stateRepositoriesByType)
            return *s;
        return null;
    }

    public BuildStateRepository getDefaultStateRepository()
    {
        if (_defaultStateRepositoryType.length > 0)
            return getStateRepository(_defaultStateRepositoryType);
        return null;
    }

    public string getDefaultStateRepositoryType()
    {
        return _defaultStateRepositoryType;
    }

    public void setDefaultStateRepository(string backendType)
    {
        if (backendType in _stateRepositoriesByType)
        {
            _defaultStateRepositoryType = backendType;
        }
    }

    public WorkQueue[] getWorkQueues()
    {
        return _workQueues;
    }

    public WorkQueue getWorkQueue(string backendType)
    {
        if (auto s = backendType in _workQueuesByType)
            return *s;
        return null;
    }

    public WorkQueue getDefaultWorkQueue()
    {
        if (_defaultWorkQueueType.length > 0)
            return getWorkQueue(_defaultWorkQueueType);
        return null;
    }

    public VcsStateResolver[] getVcsResolvers()
    {
        return _vcsResolvers;
    }

    public VcsStateResolver findVcsResolver(string repositoryUrl)
    {
        foreach (resolver; _vcsResolvers)
        {
            if (resolver.canHandle(repositoryUrl))
                return resolver;
        }
        return null;
    }

    public string getDefaultWorkQueueType()
    {
        return _defaultWorkQueueType;
    }

    public void setDefaultWorkQueue(string backendType)
    {
        if (backendType in _workQueuesByType)
        {
            _defaultWorkQueueType = backendType;
        }
    }

    public void registerScheduler(Scheduler scheduler)
    {
        _scheduler = scheduler;
    }

    public Scheduler getDefaultScheduler()
    {
        return _scheduler;
    }

    public void setScheduler(Scheduler scheduler)
    {
        _scheduler = scheduler;
    }

    public BuildStepSystem findStepSystem(in BuildStep step)
    {
        foreach (sys; _stepSystems)
        {
            if (sys.canExecuteStep(step))
            {
                return sys;
            }
        }
        return null;
    }

    public Plugin getPlugin(string name)
    {
        if (auto p = name in _plugins)
            return *p;
        return null;
    }

    public T[] getPluginsOfType(T)()
    {
        T[] matches;
        foreach (plugin; _plugins.byValue)
        {
            if (auto casted = cast(T) plugin)
            {
                matches ~= casted;
            }
        }
        return matches;
    }

    public Plugin[] allPlugins()
    {
        return _plugins.values;
    }

    public void shutdownAll()
    {
        foreach (plugin; _plugins.byValue)
        {
            plugin.shutdown();
        }
        _plugins.clear();
        _inputResolvers.length = 0;
        _fingerprintContributors.length = 0;
        _artifactPublishers.length = 0;
        _stepSystems.length = 0;
        _stepProviders.length = 0;
        _computeProviders.length = 0;
        _artifactStorages.length = 0;
        _artifactStoragesByType.clear();
        _defaultArtifactStorageType = "";
        _stateRepositories.length = 0;
        _stateRepositoriesByType.clear();
        _defaultStateRepositoryType = "";
        _workQueues.length = 0;
        _workQueuesByType.clear();
        _defaultWorkQueueType = "";
    }
}

unittest
{
    import std.json : JSONValue, JSONType;

    class MockPlugin : Plugin
    {
        bool initialized = false;
        bool shutdownCalled = false;

        @property string name() const { return "mock-plugin"; }
        @property string versionString() const { return "0.1.0"; }
        @property string description() const { return "Mock plugin for testing"; }
        @property PluginCategory category() const { return PluginCategory.step_executor; }

        ConfigDefinition[] configDefinitions() const { return null; }

        void initialize(PluginContext context = null) { initialized = true; }
        void shutdown() { shutdownCalled = true; }
    }

    auto registry = PluginRegistry.instance;
    auto mock = new MockPlugin();
    registry.registerPlugin(mock);

    assert(mock.initialized);
    assert(registry.getPlugin("mock-plugin") is mock);
    assert(registry.getPluginsOfType!MockPlugin().length == 1);
    assert(registry.getPluginsOfType!MockPlugin()[0] is mock);

    registry.shutdownAll();
    assert(mock.shutdownCalled);
    assert(registry.getPlugin("mock-plugin") is null);

    class IntegratedPlugin : Plugin, InputResolverSystem, BuildStepSystem, BuildStepProvider
    {
        @property string name() const { return "integrated-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Integrated test plugin"; }
        @property PluginCategory category() const { return PluginCategory.step_executor; }
        @property string systemName() const { return "integrated-system"; }
        @property string stepType() const { return "test-step"; }
        @property string displayName() const { return "Test Step"; }

        ConfigDefinition[] configDefinitions() const { return null; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canResolve(in TaskNode task) const { return task.id == "task-resolved"; }
        void resolveInputs(in TaskNode task, ref InputResolutionContext context) {}

        bool canExecuteStep(in BuildStep step) const { return step.type == "test-step"; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            res.success = true;
            return res;
        }

        JSONValue defaultParameters() const { return JSONValue(string[string].init); }
        string[] validateParameters(in JSONValue parameters) const { return null; }
        string renderStepFormHtml(in JSONValue currentParameters) const { return "<div>Test Step UI</div>"; }
    }

    auto integrated = new IntegratedPlugin();
    registry.registerPlugin(integrated);

    assert(registry.getInputResolvers().length == 1);
    assert(registry.getStepSystems().length == 1);
    assert(registry.getStepProviders().length == 1);
    assert(registry.getStepProvider("test-step") is integrated);
    assert(registry.getStepProvider("non-existent") is null);

    BuildStep step;
    step.type = "test-step";
    assert(registry.findStepSystem(step) is integrated);

    // Test unregistering
    registry.unregisterPlugin("integrated-plugin");
    assert(registry.getInputResolvers().length == 0);
    assert(registry.getStepSystems().length == 0);
    assert(registry.getStepProviders().length == 0);
    assert(registry.getStepProvider("test-step") is null);

    // Test ComputeProvider registration
    class MockComputeProvider : Plugin, ComputeProvider
    {
        @property string name() const { return "mock-compute"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock compute provider"; }
        @property PluginCategory category() const { return PluginCategory.worker; }
        @property string providerType() const { return "mock_pool"; }
        @property string displayName() const { return "Mock Pool"; }
        @property string[] supportedStepTypes() const { return ["bash", "powershell"]; }

        ConfigDefinition[] configDefinitions() const { return null; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        JSONValue defaultConfig() const { return JSONValue(["poolSize": JSONValue(2)]); }
        string[] validateConfig(in JSONValue config) const { return null; }
        string renderConfigFormHtml(in JSONValue currentConfig) const { return "<div>Config</div>"; }
        ComputeInstance createExecutor(in WorkerRecord record) { return null; }
        ComputeProvisioner createProvisioner(in WorkerRecord record) { return null; }
    }

    auto computePl = new MockComputeProvider();
    registry.registerPlugin(computePl);
    assert(registry.getComputeProviders().length == 1);
    assert(registry.getComputeProvider("mock_pool") is computePl);
    assert(registry.getComputeProvider("unknown") is null);

    registry.unregisterPlugin("mock-compute");
    assert(registry.getComputeProviders().length == 0);
    assert(registry.getComputeProvider("mock_pool") is null);
}

unittest
{
    // Test Plugin Config integration
    import vibe.data.json : parseJsonString;
    import std.process : environment;

    class ConfigurablePlugin : Plugin
    {
        string configuredRunner;
        size_t concurrency;

        @property string name() const { return "configurable_plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Plugin with config"; }
        @property PluginCategory category() const { return PluginCategory.step_executor; }

        ConfigDefinition[] configDefinitions() const
        {
            return [
                ConfigDefinition("plugins.configurable_plugin.customOption", "CUSTOM_OPTION_ENV", Json("default_opt"), "Custom option description")
            ];
        }

        void initialize(PluginContext context = null)
        {
            if (context !is null && context.config !is null)
            {
                configuredRunner = context.config.getString("runnerBinary", "default-bin");
                concurrency = context.config.get!size_t("maxConcurrency", 2);
            }
        }

        void shutdown() {}
    }

    string configJson = `{
        "plugins": {
            "configurable_plugin": {
                "runnerBinary": "custom/runner/bin",
                "maxConcurrency": 10
            }
        }
    }`;
    auto configRegistry = new ConfigRegistry(parseJsonString(configJson));

    auto reg = PluginRegistry.instance;
    reg.setConfigRegistry(configRegistry);

    auto plug = new ConfigurablePlugin();
    reg.registerPlugin(plug);

    assert(plug.configuredRunner == "custom/runner/bin");
    assert(plug.concurrency == 10);
    // Verify definition was registered in configRegistry
    auto scopeCfg = configRegistry.getScope("plugins.configurable_plugin");
    assert(scopeCfg.getString("customOption") == "default_opt");

    reg.unregisterPlugin("configurable_plugin");
    reg.setConfigRegistry(null);
}
