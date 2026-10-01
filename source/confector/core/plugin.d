module confector.core.plugin;

import confector.core.model : TaskNode;
import confector.core.system : InputResolverSystem, FingerprintContributionSystem, TaskExecutionSystem, ArtifactPublishingSystem;

/**
 * Base interface for all Confector plugins.
 * Encapsulates lifecycle hooks and metadata for modular extensions.
 */
interface Plugin
{
    @property string name() const;
    @property string versionString() const;
    @property string description() const;

    void initialize();
    void shutdown();
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

    public static PluginRegistry instance()
    {
        if (_instance is null)
        {
            _instance = new PluginRegistry();
        }
        return _instance;
    }

    public void registerPlugin(Plugin plugin)
    {
        _plugins[plugin.name] = plugin;
        plugin.initialize();

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
    }
}

unittest
{
    class MockPlugin : Plugin
    {
        bool initialized = false;
        bool shutdownCalled = false;

        @property string name() const { return "mock-plugin"; }
        @property string versionString() const { return "0.1.0"; }
        @property string description() const { return "Mock plugin for testing"; }

        void initialize() { initialized = true; }
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

    // Test system registration via plugin
    import confector.core.system : InputResolutionContext;
    import confector.core.executor : ExecutionRequest, ExecutionResult, LogDelegate;

    class IntegratedPlugin : Plugin, InputResolverSystem, TaskExecutionSystem
    {
        @property string name() const { return "integrated-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Integrated test plugin"; }
        @property string systemName() const { return "integrated-system"; }

        void initialize() {}
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
    }

    auto integrated = new IntegratedPlugin();
    registry.registerPlugin(integrated);

    assert(registry.getInputResolvers().length == 1);
    assert(registry.getExecutionSystems().length == 1);

    TaskNode testNode;
    testNode.id = "task-resolved";
    testNode.script = "echo hello";
    assert(registry.findExecutionSystem(testNode) is integrated);

    registry.shutdownAll();
    assert(registry.getInputResolvers().length == 0);
    assert(registry.getExecutionSystems().length == 0);
}
