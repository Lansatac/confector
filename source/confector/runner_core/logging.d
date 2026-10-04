module confector.runner_core.logging;

import confector.plugin_api.executor : LogDelegate;
import std.format : format;
import core.sync.mutex : Mutex;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

/**
 * Thread-safe execution logger collecting step and script output lines
 * while forwarding them to an optional callback delegate and the system log.
 */
class ExecutionLogger
{
    private string[] m_logs;
    private LogDelegate m_logCallback;
    private Mutex m_mutex;

    this(LogDelegate logCallback = null)
    {
        m_logCallback = logCallback;
        m_mutex = new Mutex();
    }

    void log(string line)
    {
        synchronized (m_mutex)
        {
            m_logs ~= line;
        }

        if (m_logCallback !is null)
        {
            try
            {
                m_logCallback(line);
            }
            catch (Exception) {}
        }
    }

    void opCall(string line)
    {
        log(line);
    }

    string[] getLogs() const
    {
        synchronized (cast(Mutex)m_mutex)
        {
            return m_logs.dup;
        }
    }

    LogDelegate getLogDelegate()
    {
        return &this.log;
    }
}
