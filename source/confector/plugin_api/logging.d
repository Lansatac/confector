module confector.plugin_api.logging;

/**
 * Standard log severity levels for plugins.
 */
enum LogLevel
{
    trace,
    debug_,
    info,
    warning,
    error,
    critical
}

/**
 * Structured log message passed across the plugin boundary.
 */
struct LogEntry
{
    LogLevel level;
    string message;
    string pluginName;
    string context; // e.g. task ID, step type, or file/line
}

/**
 * Logging sink delegate provided by host.
 */
alias PluginLogCallback = void delegate(in LogEntry entry);

/**
 * Context passed to a plugin during initialization.
 */
interface PluginContext
{
    @property string pluginName() const;
    void log(LogLevel level, string message, string context = null);

    final void trace(string message, string context = null) { log(LogLevel.trace, message, context); }
    final void debug_(string message, string context = null) { log(LogLevel.debug_, message, context); }
    final void info(string message, string context = null) { log(LogLevel.info, message, context); }
    final void warn(string message, string context = null) { log(LogLevel.warning, message, context); }
    final void error(string message, string context = null) { log(LogLevel.error, message, context); }
    final void critical(string message, string context = null) { log(LogLevel.critical, message, context); }
}

/**
 * Null/No-op PluginContext implementation for stand-alone unit tests or fallback.
 */
class NullPluginContext : PluginContext
{
    private string m_name;

    this(string name = "plugin")
    {
        m_name = name;
    }

    @property string pluginName() const
    {
        return m_name;
    }

    void log(LogLevel level, string message, string context = null)
    {
        // No-op
    }
}
