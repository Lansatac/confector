module confector.core.plugin;

public import confector.plugin_api.logging;
public import confector.plugin_api.plugin;
public import confector.plugin_api.model;
public import confector.plugin_api.executor;
public import confector.plugin_api.system;
public import confector.plugin_api.vcs;

import vibe.core.log : logDebug, logInfo, logWarn, logError;

/**
 * Concrete PluginContext provided by the Confector host.
 * Routes plugin logging to custom sinks or host logs.
 */
class HostPluginContext : PluginContext
{
    private string m_pluginName;
    private PluginLogCallback m_logSink;

    this(string pluginName, PluginLogCallback logSink = null)
    {
        m_pluginName = pluginName;
        m_logSink = logSink;
    }

    @property string pluginName() const
    {
        return m_pluginName;
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
    private TaskExecutionSystem[] _executionSystems;
    private ArtifactPublishingSystem[] _artifactPublishers;
    private BuildStepSystem[] _stepSystems;
    private BuildStepProvider[] _stepProviders;
    private ExecutorProvider[] _executorProviders;
    private PluginLogCallback _logCallback;

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

    public void registerPlugin(Plugin plugin)
    {
        _plugins[plugin.name] = plugin;
        auto ctx = new HostPluginContext(plugin.name, _logCallback);
        plugin.initialize(ctx);

        // Automatically register implemented system interfaces
        if (auto resolver = cast(InputResolverSystem) plugin)
        {
            registerInputResolver(resolver);
        }
        if (auto contributor = cast(FingerprintContributionSystem) plugin)
        {
            registerFingerprintContributor(contributor);
        }
        if (auto execSystem = cast(TaskExecutionSystem) plugin)
        {
            registerExecutionSystem(execSystem);
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
        if (auto provider = cast(ExecutorProvider) plugin)
        {
            registerExecutorProvider(provider);
        }
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

    public void registerExecutionSystem(TaskExecutionSystem system)
    {
        import std.algorithm : canFind;
        if (!_executionSystems.canFind(system))
        {
            _executionSystems ~= system;
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

    public void registerExecutorProvider(ExecutorProvider provider)
    {
        import std.algorithm : canFind;
        if (!_executorProviders.canFind(provider))
        {
            _executorProviders ~= provider;
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
            if (auto execSystem = cast(TaskExecutionSystem) plugin)
            {
                for (size_t i = 0; i < _executionSystems.length; )
                {
                    if (_executionSystems[i] is execSystem) _executionSystems = _executionSystems.remove(i);
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
            if (auto provider = cast(ExecutorProvider) plugin)
            {
                for (size_t i = 0; i < _executorProviders.length; )
                {
                    if (_executorProviders[i] is provider) _executorProviders = _executorProviders.remove(i);
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

    public TaskExecutionSystem[] getExecutionSystems()
    {
        return _executionSystems;
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

    public ExecutorProvider[] getExecutorProviders()
    {
        return _executorProviders;
    }

    public ExecutorProvider getExecutorProvider(string providerType)
    {
        foreach (p; _executorProviders)
        {
            if (p.providerType == providerType)
            {
                return p;
            }
        }
        return null;
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

    public TaskExecutionSystem findExecutionSystem(in TaskNode task)
    {
        foreach (sys; _executionSystems)
        {
            if (sys.canExecute(task))
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
        _executionSystems.length = 0;
        _artifactPublishers.length = 0;
        _stepSystems.length = 0;
        _stepProviders.length = 0;
        _executorProviders.length = 0;
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

    class IntegratedPlugin : Plugin, InputResolverSystem, TaskExecutionSystem, BuildStepSystem, BuildStepProvider
    {
        @property string name() const { return "integrated-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Integrated test plugin"; }
        @property string systemName() const { return "integrated-system"; }
        @property string stepType() const { return "test-step"; }
        @property string displayName() const { return "Test Step"; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canResolve(in TaskNode task) const { return task.id == "task-resolved"; }
        void resolveInputs(in TaskNode task, ref InputResolutionContext context) {}

        bool canExecute(in TaskNode task) const { return task.script == "echo hello"; }
        ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null)
        {
            ExecutionResult res;
            res.success = true;
            return res;
        }

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
    assert(registry.getExecutionSystems().length == 1);
    assert(registry.getStepSystems().length == 1);
    assert(registry.getStepProviders().length == 1);
    assert(registry.getStepProvider("test-step") is integrated);
    assert(registry.getStepProvider("non-existent") is null);

    TaskNode testNode;
    testNode.id = "task-resolved";
    testNode.script = "echo hello";
    assert(registry.findExecutionSystem(testNode) is integrated);

    BuildStep step;
    step.type = "test-step";
    assert(registry.findStepSystem(step) is integrated);

    // Test unregistering
    registry.unregisterPlugin("integrated-plugin");
    assert(registry.getInputResolvers().length == 0);
    assert(registry.getExecutionSystems().length == 0);
    assert(registry.getStepSystems().length == 0);
    assert(registry.getStepProviders().length == 0);
    assert(registry.getStepProvider("test-step") is null);
}
