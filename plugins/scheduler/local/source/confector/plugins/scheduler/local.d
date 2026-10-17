module confector.plugins.scheduler.local;

import core.sync.mutex : Mutex;
import core.sync.event : Event;
import core.time : msecs;
import core.thread : Thread;
import std.format;
import std.string : indexOf;
import std.datetime : Clock, DateTime;

import confector.plugin_api.plugin : Plugin, PluginContext, NullPluginContext, PluginCategory, SchedulerPlugin, ConfigDefinition, ScopedConfigAccessor, ResolutionEngine;
import confector.plugin_api.scheduler : Scheduler, ScheduleEntry, schedulerSecretHeader;

import vibe.data.json : Json;
import std.net.curl : HTTP, get, post;
import std.stdio : writeln;
import nova.cron : CronExpr;

/**
 * LocalSchedulerPlugin is a reference implementation of the Scheduler interface.
 * It uses a dedicated thread to iterate over registered schedule entries and fire
 * HTTP POST requests at their configured intervals.
 *
 * This implementation is fully in-memory — entries are lost on shutdown and rebuilt
 * on restart. For cloud-based scheduling, implement a different SchedulerPlugin that
 * uses external trigger services (e.g., AWS CloudWatch Events).
 */
class LocalSchedulerPlugin : SchedulerPlugin, Scheduler
{
    private PluginContext m_context;
    private ScheduleEntry[string] m_entries;
    private CronExpr[string] m_parsedCronExprs;  // Cached parsed cron expressions
    private Mutex m_mutex;
    private Thread m_thread;
    private Event* m_stopEvent;
    private bool m_running;
    private string m_callbackSecret;  // Sent in schedulerSecretHeader on every fired request

    this()
    {
        m_entries = new ScheduleEntry[string];
        m_parsedCronExprs = new CronExpr[string];
        m_mutex = new Mutex();
        m_stopEvent = new Event(false, false);
        m_running = false;
    }

    @property string name() const { return "local-scheduler"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Local thread-based scheduler that fires HTTP POST requests to registered URIs"; }
    @property PluginCategory category() const { return PluginCategory.scheduler; }

    ConfigDefinition[] configDefinitions() const
    {
        return [
            ConfigDefinition("callbackSecret", "CONFECTOR_SCHEDULER_CALLBACK_SECRET", Json.undefined,
                "Secret sent in the X-Confector-Scheduler-Secret header on every callback (required)", true)
        ];
    }

    void initialize(PluginContext context = null)
    {
        if (context is null)
            throw new Exception("[local-scheduler] PluginContext must not be null; the host failed to provide configuration.");
        m_context = context;

        // Never logged: the value is only held here and written into the callback headers.
        m_callbackSecret = m_context.config.getString("callbackSecret");
        if (m_callbackSecret.length == 0)
            throw new Exception("[local-scheduler] Required setting 'callbackSecret' is missing (plugins.local-scheduler.callbackSecret or CONFECTOR_SCHEDULER_CALLBACK_SECRET): scheduled callbacks cannot be authenticated.");

        m_context.info("LocalSchedulerPlugin initialized");
    }

    void shutdown()
    {
        stop();
        if (m_context !is null)
        {
            m_context.info("LocalSchedulerPlugin shut down");
        }
    }

    void schedule(ScheduleEntry entry)
    {
        if (entry.id.length == 0)
        {
            throw new Exception("ScheduleEntry id cannot be empty");
        }
        if (entry.uri.length == 0)
        {
            throw new Exception(format("ScheduleEntry uri cannot be empty for entry '%s'", entry.id));
        }
        if (entry.cronExpression.length == 0)
        {
            throw new Exception(format("ScheduleEntry must have a cron expression for entry '%s'", entry.id));
        }

        synchronized (m_mutex)
        {
            m_entries[entry.id] = entry;

            // Parse and cache cron expression
            try
            {
                m_parsedCronExprs[entry.id] = CronExpr.parse(entry.cronExpression);
                if (m_context !is null)
                {
                    m_context.info(format("Scheduled entry '%s': %s %s (cron: %s, recurring: %s)",
                        entry.id, entry.httpMethod.length > 0 ? entry.httpMethod : "POST",
                        entry.uri, entry.cronExpression, entry.recurring ? "true" : "false"));
                }
            }
            catch (Exception e)
            {
                if (m_context !is null)
                {
                    m_context.error(format("Invalid cron expression for entry '%s': %s - %s",
                        entry.id, entry.cronExpression, e.msg));
                }
                throw new Exception(format("Invalid cron expression for entry '%s': %s",
                    entry.id, e.msg));
            }
        }
    }

    void unschedule(string entryId)
    {
        bool removed;
        synchronized (m_mutex)
        {
            removed = m_entries.remove(entryId);
            m_parsedCronExprs.remove(entryId);
        }
        if (removed && m_context !is null)
        {
            m_context.info(format("Unscheduled entry '%s'", entryId));
        }
    }

    void start()
    {
        if (m_running)
        {
            return;
        }
        m_running = true;
        m_stopEvent.reset();
        void delegate() dg = &runLoop;
        m_thread = new Thread(dg);
        m_thread.isDaemon = true;
        m_thread.start();

        if (m_context !is null)
        {
            m_context.info("LocalSchedulerPlugin started");
        }
    }

    void stop()
    {
        if (!m_running)
        {
            return;
        }
        m_running = false;
        m_stopEvent.setIfInitialized();
        if (m_thread !is null)
        {
            m_thread.join();
            m_thread = null;
        }

        if (m_context !is null)
        {
            m_context.info("LocalSchedulerPlugin stopped");
        }
    }

    @property bool isRunning() const
    {
        return m_running;
    }

    void reconcile()
    {
        // No-op for local scheduler — in-memory state is always consistent
    }

    private void runLoop()
    {
        if (m_context !is null)
        {
            m_context.info("Scheduler thread started");
        }

        while (m_running)
        {
            ScheduleEntry[string] entriesCopy;
            CronExpr[string] cronExprsCopy;
            synchronized (m_mutex)
            {
                entriesCopy = m_entries.dup;
                cronExprsCopy = m_parsedCronExprs.dup;
            }

            auto nowSys = Clock.currTime;
            auto nowDT = DateTime(nowSys.year, nowSys.month, nowSys.day,
                nowSys.hour, nowSys.minute, nowSys.second);

            // Truncate to current minute
            auto truncatedNow = DateTime(nowDT.year, nowDT.month, nowDT.day,
                nowDT.hour, nowDT.minute, 0);

            foreach (id, entry; entriesCopy)
            {
                if (!m_running) break;

                bool shouldFire = false;

                // Cron-based scheduling
                if (auto it = id in cronExprsCopy)
                {
                    auto expr = *it;

                    // Check if the next occurrence is within the current minute
                    auto next = expr.nextAfter(truncatedNow);
                    if (!next.isNull && next.get <= DateTime(nowDT.year, nowDT.month, nowDT.day,
                        nowDT.hour, nowDT.minute, 59))
                    {
                        shouldFire = true;
                    }
                }

                if (!shouldFire)
                {
                    continue;
                }

                // Fire the HTTP request
                try
                {
                    fireEntry(entry);
                }
                catch (Throwable t)
                {
                    writeln("[scheduler] Failed to fire entry '", entry.id, "': ", t.msg);
                }

                // Remove one-time (non-recurring) entries after firing
                if (!entry.recurring)
                {
                    synchronized (m_mutex)
                    {
                        m_entries.remove(id);
                        m_parsedCronExprs.remove(id);
                    }
                    if (m_context !is null)
                    {
                        m_context.info(format("Removed one-time entry '%s' after firing", id));
                    }
                }
            }

            // Sleep for a short interval before checking again
            Thread.sleep(msecs(100));
        }

        if (m_context !is null)
        {
            m_context.info("Scheduler thread stopped");
        }
    }

    private void fireEntry(ScheduleEntry entry)
    {
        auto httpMethod = entry.httpMethod.length > 0 ? entry.httpMethod : "POST";
        string body = entry.jsonBody;

        auto http = HTTP();  // A bare `HTTP http;` has no libcurl handle and every call on it fails
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader(schedulerSecretHeader, m_callbackSecret);

        char[] responseBody;

        try
        {
            if (httpMethod == "POST" && body.length > 0)
            {
                http.setPostData(body, "application/json");
                auto data = cast(const(void[])[]) [body.dup];
                responseBody = post(entry.uri, data, http);
            }
            else if (httpMethod == "GET")
            {
                responseBody = get(entry.uri, http);
            }
            else if (body.length > 0)
            {
                http.setPostData(body, "application/json");
                auto data = cast(const(void[])[]) [body.dup];
                responseBody = post(entry.uri, data, http);
            }
            else
            {
                responseBody = get(entry.uri, http);
            }
        }
        catch (Exception e)
        {
            writeln("[scheduler] HTTP error for entry '", entry.id, "': ", e.msg);
            return;
        }
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new LocalSchedulerPlugin();
}

/// A context whose plugins.local-scheduler scope holds the given callback secret (empty = unset).
private PluginContext schedulerTestContext(string callbackSecret)
{
    Json fileConfig = Json.emptyObject;
    fileConfig["plugins"] = Json.emptyObject;
    fileConfig["plugins"]["local-scheduler"] = Json.emptyObject;
    if (callbackSecret.length > 0)
        fileConfig["plugins"]["local-scheduler"]["callbackSecret"] = Json(callbackSecret);
    auto scope_ = new ScopedConfigAccessor(new ResolutionEngine(fileConfig), "plugins.local-scheduler");
    return new NullPluginContext("local-scheduler", scope_);
}

unittest
{
    import std.exception : assertThrown;

    // The callback secret is required: initialization fails loudly when it is unset
    auto plugin = new LocalSchedulerPlugin();
    assertThrown!Exception(plugin.initialize(schedulerTestContext("")));
    assertThrown!Exception(plugin.initialize(null));
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.socket : TcpSocket, InternetAddress;

    // The plugin sends the configured secret in the scheduler header. A raw loopback listener
    // records the request headers the plugin sends and answers 200.
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    listener.listen(1);
    ushort port = (cast(InternetAddress) listener.localAddress).port;

    string received;
    auto acceptor = new Thread(() {
        auto client = listener.accept();
        char[8192] buf;
        size_t total = 0;
        while (total < buf.length)
        {
            auto n = client.receive(buf[total .. $]);
            if (n <= 0) break;
            total += cast(size_t) n;
            if (indexOf(buf[0 .. total], "\r\n\r\n") >= 0) break;
        }
        received = buf[0 .. total].idup;
        client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        client.close();
    });
    acceptor.start();

    auto plugin = new LocalSchedulerPlugin();
    plugin.initialize(schedulerTestContext("test-secret"));

    // A GET carries no body, so the loopback listener can answer and close without unread data
    ScheduleEntry entry;
    entry.id = "header-check";
    entry.uri = format("http://127.0.0.1:%d/api/v1/broker/evaluate", port);
    entry.httpMethod = "GET";
    entry.cronExpression = "* * * * *";
    plugin.fireEntry(entry);

    acceptor.join();
    listener.close();
    assert(received.canFind("X-Confector-Scheduler-Secret: test-secret"), received);
}

unittest
{
    auto plugin = new LocalSchedulerPlugin();
    plugin.initialize(schedulerTestContext("test-secret"));
    assert(plugin.name == "local-scheduler");
    assert(plugin.category == PluginCategory.scheduler);
    assert(!plugin.isRunning);

    // Test scheduling with empty id
    bool caught = false;
    try
    {
        ScheduleEntry entry;
        entry.uri = "http://localhost:8080/test";
        entry.cronExpression = "* * * * *";
        plugin.schedule(entry);
    }
    catch (Exception e)
    {
        assert(e.msg.indexOf("id cannot be empty") != -1);
        caught = true;
    }
    assert(caught);

    // Test scheduling with empty uri
    caught = false;
    try
    {
        ScheduleEntry entry;
        entry.id = "test-1";
        entry.cronExpression = "* * * * *";
        plugin.schedule(entry);
    }
    catch (Exception e)
    {
        assert(e.msg.indexOf("uri cannot be empty") != -1);
        caught = true;
    }
    assert(caught);

    // Test scheduling with empty cron expression
    caught = false;
    try
    {
        ScheduleEntry entry;
        entry.id = "test-2";
        entry.uri = "http://localhost:8080/test";
        plugin.schedule(entry);
    }
    catch (Exception e)
    {
        assert(e.msg.indexOf("cron expression") != -1);
        caught = true;
    }
    assert(caught);

    // Test valid schedule entry
    ScheduleEntry validEntry;
    validEntry.id = "test-valid";
    validEntry.name = "Test Valid Entry";
    validEntry.uri = "http://localhost:8080/api/v1/test";
    validEntry.httpMethod = "POST";
    validEntry.jsonBody = `{"test": true}`;
    validEntry.cronExpression = "*/5 * * * *";
    validEntry.recurring = true;
    plugin.schedule(validEntry);

    // Test unschedule
    plugin.unschedule("test-valid");
    plugin.unschedule("non-existent"); // Should be no-op

    // Test start/stop
    plugin.start();
    assert(plugin.isRunning);
    plugin.stop();
    assert(!plugin.isRunning);

    plugin.shutdown();
}
