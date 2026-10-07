module confector.runner_core.logging;

import confector.plugin_api.executor : LogDelegate;
import std.format : format;
import std.stdio : stderr, writeln, writefln;
import core.sync.mutex : Mutex;

/**
 * Log helper functions for runner_core without vibe-d dependencies.
 */
void logInfo(Args...)(string fmt, Args args)
{
    try
    {
        stderr.writefln("[INFO] " ~ fmt, args);
    }
    catch (Exception) {}
}

void logDebug(Args...)(string fmt, Args args)
{
    try
    {
        stderr.writefln("[DEBUG] " ~ fmt, args);
    }
    catch (Exception) {}
}

void logTrace(Args...)(string fmt, Args args)
{
    try
    {
        stderr.writefln("[TRACE] " ~ fmt, args);
    }
    catch (Exception) {}
}

void logWarn(Args...)(string fmt, Args args)
{
    try
    {
        stderr.writefln("[WARN] " ~ fmt, args);
    }
    catch (Exception) {}
}

void logError(Args...)(string fmt, Args args)
{
    try
    {
        stderr.writefln("[ERROR] " ~ fmt, args);
    }
    catch (Exception) {}
}

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
