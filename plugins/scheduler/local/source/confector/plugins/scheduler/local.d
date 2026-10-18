module confector.plugins.scheduler.local;

import core.sync.mutex : Mutex;
import core.sync.event : Event;
import core.time : msecs;
import core.thread : Thread;
import std.format;
import std.string : indexOf;
import std.datetime : Clock, DateTime;

import confector.plugin_api.scheduler : Scheduler, ScheduleEntry, schedulerSecretHeader;

import std.net.curl : HTTP, get, post;
import std.stdio : writeln;
import nova.cron : CronExpr;

/**
 * LocalScheduler is the reference implementation of the Scheduler interface.
 * It uses a dedicated thread to iterate over registered schedule entries and fire
 * HTTP POST requests at their configured intervals.
 *
 * This implementation is fully in-memory: entries are lost on shutdown and rebuilt
 * on restart. Cloud deployments use a scheduler backed by an external trigger service
 * (e.g., AWS EventBridge).
 */
class LocalScheduler : Scheduler
{
    private ScheduleEntry[string] m_entries;
    private CronExpr[string] m_parsedCronExprs;  // Cached parsed cron expressions
    private Mutex m_mutex;
    private Thread m_thread;
    private Event* m_stopEvent;
    private bool m_running;
    private string m_callbackSecret;  // Sent in schedulerSecretHeader on every fired request

    /**
     * A scheduler that sends `callbackSecret` with every callback. Throws if the secret is empty:
     * scheduled callbacks could not be authenticated.
     */
    this(string callbackSecret)
    {
        // Never logged: the value is only held here and written into the callback headers.
        if (callbackSecret.length == 0)
            throw new Exception("The local scheduler needs a callback secret: scheduled callbacks cannot be authenticated without one.");
        m_callbackSecret = callbackSecret;
        m_entries = new ScheduleEntry[string];
        m_parsedCronExprs = new CronExpr[string];
        m_mutex = new Mutex();
        m_stopEvent = new Event(false, false);
        m_running = false;
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
            }
            catch (Exception e)
            {
                throw new Exception(format("Invalid cron expression for entry '%s': %s",
                    entry.id, e.msg));
            }
        }
    }

    void unschedule(string entryId)
    {
        synchronized (m_mutex)
        {
            m_entries.remove(entryId);
            m_parsedCronExprs.remove(entryId);
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
                }
            }

            // Sleep for a short interval before checking again
            Thread.sleep(msecs(100));
        }
    }

    private void fireEntry(ScheduleEntry entry)
    {
        auto httpMethod = entry.httpMethod.length > 0 ? entry.httpMethod : "POST";
        // Phobos sends a request body only for a non-null slice, so a null jsonBody (no body) is
        // passed as an empty non-null slice; without it a POST goes out with no Content-Length.
        string body = entry.jsonBody is null ? "" : entry.jsonBody;

        auto http = HTTP();  // A bare `HTTP http;` has no libcurl handle and every call on it fails
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader(schedulerSecretHeader, m_callbackSecret);

        char[] responseBody;

        try
        {
            // A POST stays a POST even without a body: the server's callback routes are POST-only
            if (httpMethod == "POST")
            {
                responseBody = post(entry.uri, body, http);
            }
            else if (httpMethod == "GET")
            {
                responseBody = get(entry.uri, http);
            }
            else if (body.length > 0)
            {
                responseBody = post(entry.uri, body, http);
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

unittest
{
    import std.exception : assertThrown;

    // The callback secret is required: construction fails loudly without one
    assertThrown!Exception(new LocalScheduler(""));
}

/// Fires one entry at a loopback listener and returns the raw request it received. Every wait is
/// bounded so that a regression (no connection, or a stalled read) fails instead of hanging.
private string captureFiredRequest(string httpMethod, string jsonBody)
{
    import std.socket : TcpSocket, InternetAddress, Socket, SocketSet, SocketOption, SocketOptionLevel;
    import core.time : seconds;

    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    listener.listen(1);
    ushort port = (cast(InternetAddress) listener.localAddress).port;

    string received;
    auto acceptor = new Thread(() {
        auto waitSet = new SocketSet();
        waitSet.add(listener);
        if (Socket.select(waitSet, null, null, 5.seconds) <= 0)
            return;  // Nothing connected: `received` stays empty and the caller's assertions report it
        auto client = listener.accept();
        client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5.seconds);
        char[16384] buf;
        size_t total = 0;
        size_t expected = size_t.max;  // Bytes wanted: headers plus the declared Content-Length
        while (total < buf.length)
        {
            auto n = client.receive(buf[total .. $]);
            if (n <= 0) break;
            total += cast(size_t) n;
            if (expected == size_t.max)
            {
                auto headerEnd = indexOf(buf[0 .. total], "\r\n\r\n");
                if (headerEnd >= 0)
                    expected = headerEnd + 4 + declaredContentLength(buf[0 .. headerEnd]);
            }
            if (total >= expected) break;
        }
        received = buf[0 .. total].idup;
        client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        client.close();
    });
    acceptor.start();

    auto scheduler = new LocalScheduler("test-secret");

    ScheduleEntry entry;
    entry.id = "header-check";
    entry.uri = format("http://127.0.0.1:%d/api/v1/projects/p1/run", port);
    entry.httpMethod = httpMethod;
    entry.jsonBody = jsonBody;
    entry.cronExpression = "* * * * *";
    scheduler.fireEntry(entry);

    acceptor.join();
    listener.close();
    return received;
}

/// The Content-Length value in a raw header block, or 0 when the header is absent.
private size_t declaredContentLength(const(char)[] headers)
{
    import std.conv : to;
    enum key = "Content-Length: ";
    auto at = indexOf(headers, key);
    if (at < 0) return 0;
    auto rest = headers[at + key.length .. $];
    auto lineEnd = indexOf(rest, "\r\n");  // The last header line has no terminator in this block
    if (lineEnd >= 0) rest = rest[0 .. lineEnd];
    return rest.to!size_t;
}

unittest
{
    import std.algorithm.searching : canFind, startsWith;

    // The scheduler sends the configured secret in the scheduler header
    auto received = captureFiredRequest("POST", null);
    assert(received.canFind("X-Confector-Scheduler-Secret: test-secret"), received);

    // A POST without a jsonBody stays a POST, with an explicit empty body rather than chunked or unframed
    assert(received.startsWith("POST /api/v1/projects/p1/run "), received);
    assert(received.canFind("Content-Length: 0\r\n"), received);
    assert(!received.canFind("Transfer-Encoding"), received);
}

unittest
{
    import std.algorithm.searching : canFind, endsWith, startsWith;
    import std.conv : to;

    // A POST with a JSON body sends the body intact, framed by its byte count, as JSON
    enum body = `{"repositoryUrl": "https://example.test/repo.git"}`;
    auto received = captureFiredRequest("POST", body);
    assert(received.startsWith("POST /api/v1/projects/p1/run "), received);
    assert(received.canFind("Content-Length: " ~ body.length.to!string ~ "\r\n"), received);
    assert(received.canFind("Content-Type: application/json\r\n"), received);
    assert(received.endsWith(body), received);
}

unittest
{
    auto scheduler = new LocalScheduler("test-secret");
    assert(!scheduler.isRunning);

    // Test scheduling with empty id
    bool caught = false;
    try
    {
        ScheduleEntry entry;
        entry.uri = "http://localhost:8080/test";
        entry.cronExpression = "* * * * *";
        scheduler.schedule(entry);
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
        scheduler.schedule(entry);
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
        scheduler.schedule(entry);
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
    scheduler.schedule(validEntry);

    // Test unschedule
    scheduler.unschedule("test-valid");
    scheduler.unschedule("non-existent"); // Should be no-op

    // Test start/stop
    scheduler.start();
    assert(scheduler.isRunning);
    scheduler.stop();
    assert(!scheduler.isRunning);
}
