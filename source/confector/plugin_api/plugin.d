module confector.plugin_api.plugin;

public import confector.plugin_api.logging;

/**
 * Base interface for all Confector plugins.
 * Encapsulates lifecycle hooks and metadata for modular extensions.
 */
interface Plugin
{
    @property string name() const;
    @property string versionString() const;
    @property string description() const;

    void initialize(PluginContext context = null);
    void shutdown();
}

/**
 * Standard C-ABI export symbol name for plugin factories.
 */
enum string CONFECTOR_PLUGIN_FACTORY_SYMBOL = "confector_create_plugin";

/**
 * Function pointer type for plugin instantiation factory.
 */
alias PluginFactoryFn = extern(C) Plugin function();
