module confector.plugin_api.plugin;

public import confector.plugin_api.logging;

/**
 * Formal plugin category indicating the role and execution boundary of a plugin.
 */
enum PluginCategory : string
{
    definition = "definition",     // Step Definition Plugins (BuildStepProvider, UI templates, validation schemas)
    step_executor = "step_executor", // Step Execution Plugins (BuildStepSystem, InputResolverSystem)
    worker = "worker",              // Worker / Compute Provider Plugins (fleet, provisioning, credentials)
    artifact = "artifact",          // Artifact Storage Plugins (content-addressed artifact backend)
    storage = "storage",            // State Storage Plugins (BuildStateRepository - builds, tasks, projects, etc.)
    queue = "queue"                 // Work Queue Plugins (WorkQueue - task message distribution)
}

/**
 * Base interface for all Confector plugins.
 * Encapsulates lifecycle hooks, metadata, and category classification for modular extensions.
 */
interface Plugin
{
    @property string name() const;
    @property string versionString() const;
    @property string description() const;
    @property PluginCategory category() const;

    ConfigDefinition[] configDefinitions() const;

    void initialize(PluginContext context = null);
    void shutdown();
}

/**
 * Convenience abstract base class for plugins providing default empty implementations.
 */
abstract class BasePlugin : Plugin
{
    ConfigDefinition[] configDefinitions() const { return null; }
    void initialize(PluginContext context = null) {}
    void shutdown() {}
}

/**
 * Interface for Step Definition Plugins.
 * Loaded by the server/control plane to provide step UI forms, default parameters, and validation.
 */
interface StepDefinitionPlugin : Plugin
{
}

/**
 * Interface for Step Execution Plugins.
 * Loaded exclusively by confector-runner to execute build steps and resolve task inputs.
 */
interface StepExecutionPlugin : Plugin
{
}

/**
 * Interface for Worker / Compute Provider Plugins.
 * Loaded by the server/control plane to manage compute fleets, worker lifecycles, and credential injection.
 */
interface WorkerPlugin : Plugin
{
}

/**
 * Interface for Artifact Storage Plugins.
 * Provides a content-addressed artifact backend (local filesystem, S3, Artifactory, etc.).
 */
interface ArtifactStoragePlugin : Plugin
{
}

/**
 * Interface for State Storage Plugins.
 * Provides a backend for build and task state persistence (MongoDB, DynamoDB, etc.).
 */
interface StateStoragePlugin : Plugin
{
}

/**
 * Interface for Work Queue Plugins.
 * Provides a backend for task message distribution (SQS, MongoDB queue, RabbitMQ, etc.).
 */
interface WorkQueuePlugin : Plugin
{
}

/**
 * Standard C-ABI export symbol name for plugin factories.
 */
enum string CONFECTOR_PLUGIN_FACTORY_SYMBOL = "confector_create_plugin";

/**
 * Function pointer type for plugin instantiation factory.
 */
alias PluginFactoryFn = extern(C) Plugin function();
