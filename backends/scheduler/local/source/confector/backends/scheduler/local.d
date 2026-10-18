module confector.backends.scheduler.local;

import core.sync.mutex : Mutex;
import core.time : days, msecs;
import core.thread : Thread;
import std.algorithm.iteration : map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.datetime : Clock, DateTime, SysTime;
import std.format;
import std.string : indexOf;

import confector.api.scheduler : Scheduler, Schedule, ScheduleEntry, schedulerSecretHeader;

import std.net.curl : HTTP, post;
import vibe.core.log : logError, logWarn;
import nova.cron : CronExpr;

/**
 * LocalScheduler is the reference implementation of the Scheduler interface. It owns one thread
 * that watches the entries and POSTs to their endpoints on the server when they are due. The
 * thread is started by the first upsert and ends when the last entry is gone (a one-shot entry
 * that has fired, or remove), so a scheduler with no entries has no thread.
 *
 * Entries are held in memory only: they are lost on shutdown, and the server upserts them again
 * on restart. Cloud deployments use a scheduler backed by an external trigger service (e.g. AWS
 * EventBridge).
 */
class LocalScheduler : Scheduler
{
    /// An entry with what the thread needs to decide when it is due.
    private struct Held
    {
        ScheduleEntry entry;
        CronExpr cron;       // Parsed entry.when.cronExpression; unused for a one-shot entry
        bool hasNext;        // Whether nextFire is set (a cron expression may have no next time)
        DateTime nextFire;   // Next time a recurring entry is due, in local time
    }

    private Held[string] m_held;
    private Mutex m_mutex;
    private Thread m_thread;  // Null when there are no entries
    private string m_baseUrl;
    private string m_callbackSecret;  // Sent in schedulerSecretHeader on every fired request

    /**
     * A scheduler that POSTs to `baseUrl` ~ the entry's path (e.g. "http://127.0.0.1:8080"),
     * sending `callbackSecret` with every call. Throws if either is empty: scheduled callbacks
     * could not be authenticated or addressed.
     */
    this(string callbackSecret, string baseUrl)
    {
        // Never logged: the value is only held here and written into the callback headers.
        if (callbackSecret.length == 0)
            throw new Exception("The local scheduler needs a callback secret: scheduled callbacks cannot be authenticated without one.");
        if (baseUrl.length == 0)
            throw new Exception("The local scheduler needs a base URL to call back into.");
        m_callbackSecret = callbackSecret;
        m_baseUrl = baseUrl;
        m_mutex = new Mutex();
    }

    void upsert(ScheduleEntry entry)
    {
        if (entry.id.length == 0)
            throw new Exception("ScheduleEntry id cannot be empty");
        if (entry.path.length == 0 || entry.path[0] != '/')
            throw new Exception(format("ScheduleEntry path must start with '/' for entry '%s'", entry.id));
        const hasCron = entry.when.cronExpression.length > 0;
        const hasTime = entry.when.at != SysTime.init;
        if (hasCron == hasTime)
            throw new Exception(format("ScheduleEntry must have either a cron expression or a one-shot time, not %s, for entry '%s'",
                hasCron ? "both" : "neither", entry.id));

        Held held;
        held.entry = entry;
        if (hasCron)
        {
            try
            {
                held.cron = CronExpr.parse(entry.when.cronExpression);
            }
            catch (Exception e)
            {
                throw new Exception(format("Invalid cron expression for entry '%s': %s", entry.id, e.msg));
            }
        }

        synchronized (m_mutex)
        {
            if (auto existing = entry.id in m_held)
            {
                if (existing.entry == entry)
                    return;  // Nothing changed; keep the pending trigger as it is
            }
            if (hasCron)
                scheduleNext(held, Clock.currTime);
            if (m_thread is null)
            {
                // Started first so that a failure to start leaves the entries untouched and
                // reaches the caller. The thread waits for the mutex, which is held until the
                // entry is in.
                auto thread = new Thread(&runLoop);
                thread.isDaemon = true;
                thread.start();
                m_thread = thread;
            }
            m_held[entry.id] = held;
        }
    }

    void remove(string id)
    {
        synchronized (m_mutex)
        {
            m_held.remove(id);  // The thread ends itself on its next pass if this was the last
        }
    }

    ScheduleEntry[] list()
    {
        synchronized (m_mutex)
        {
            return m_held.values.map!(held => held.entry).array.sort!((a, b) => a.id < b.id).release;
        }
    }

    /// Sets when a recurring entry is next due after `now`.
    private static void scheduleNext(ref Held held, SysTime now)
    {
        auto next = held.cron.nextAfter(DateTime(now.year, now.month, now.day, now.hour, now.minute, now.second));
        held.hasNext = !next.isNull;
        if (held.hasNext)
            held.nextFire = next.get;
    }

    /**
     * The entries due at `now`. A recurring entry is returned once per due time and its next
     * time is set after `now`; a one-shot entry is returned once and dropped. Call with the
     * mutex held.
     */
    private ScheduleEntry[] collectDue(SysTime now)
    {
        auto nowDT = DateTime(now.year, now.month, now.day, now.hour, now.minute, now.second);
        ScheduleEntry[] due;
        string[] fired;
        foreach (id, ref held; m_held)
        {
            if (held.entry.when.isRecurring)
            {
                if (!held.hasNext || held.nextFire > nowDT)
                    continue;
                due ~= held.entry;
                scheduleNext(held, now);
            }
            else if (held.entry.when.at <= now)
            {
                due ~= held.entry;
                fired ~= id;  // A one-shot entry is gone once it fires
            }
        }
        foreach (id; fired)
            m_held.remove(id);
        return due;
    }

    private void runLoop()
    {
        try
        {
            while (true)
            {
                ScheduleEntry[] due;
                synchronized (m_mutex)
                {
                    if (m_held.length == 0)
                    {
                        m_thread = null;
                        return;
                    }
                    due = collectDue(Clock.currTime);
                }

                foreach (entry; due)
                {
                    try
                    {
                        fireEntry(entry);
                    }
                    catch (Exception e)
                    {
                        logWarn("[scheduler] Failed to fire entry '%s': %s", entry.id, e.msg);
                    }
                }

                Thread.sleep(msecs(100));
            }
        }
        catch (Throwable t)
        {
            // The loop cannot continue: record the failure and let the next upsert start a new thread
            logError("[scheduler] The scheduler thread stopped: %s", t.msg);
            synchronized (m_mutex)
                m_thread = null;
            throw t;
        }
    }

    private void fireEntry(ScheduleEntry entry)
    {
        // Phobos sends a request body only for a non-null slice, so a null jsonBody (no body) is
        // passed as an empty non-null slice; without it a POST goes out with no Content-Length.
        string body = entry.jsonBody is null ? "" : entry.jsonBody;

        auto http = HTTP();  // A bare `HTTP http;` has no libcurl handle and every call on it fails
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader(schedulerSecretHeader, m_callbackSecret);

        try
        {
            // Always a POST, even without a body: the server's callback routes are POST-only
            post(m_baseUrl ~ entry.path, body, http);
        }
        catch (Exception e)
        {
            logWarn("[scheduler] HTTP error for entry '%s': %s", entry.id, e.msg);
        }
    }
}

unittest
{
    import std.exception : assertThrown;

    // The callback secret and the base URL are required: construction fails loudly without them
    assertThrown!Exception(new LocalScheduler("", "http://127.0.0.1:8080"));
    assertThrown!Exception(new LocalScheduler("test-secret", ""));
}

/// Fires one entry at a loopback listener and returns the raw request it received. Every wait is
/// bounded so that a regression (no connection, or a stalled read) fails instead of hanging.
private string captureFiredRequest(string jsonBody)
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

    auto scheduler = new LocalScheduler("test-secret", format("http://127.0.0.1:%d", port));

    ScheduleEntry entry;
    entry.id = "header-check";
    entry.path = "/api/v1/projects/p1/run";
    entry.jsonBody = jsonBody;
    entry.when = Schedule.recurring("* * * * *");
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
    auto received = captureFiredRequest(null);
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
    auto received = captureFiredRequest(body);
    assert(received.startsWith("POST /api/v1/projects/p1/run "), received);
    assert(received.canFind("Content-Length: " ~ body.length.to!string ~ "\r\n"), received);
    assert(received.canFind("Content-Type: application/json\r\n"), received);
    assert(received.endsWith(body), received);
}

unittest
{
    import confector.testing.conformance.scheduler : checkScheduler;

    // The scheduler contract: idempotent upsert, replacement, remove, list
    checkScheduler(new LocalScheduler("test-secret", "http://127.0.0.1:1"));
}

unittest
{
    import std.exception : collectException;

    auto scheduler = new LocalScheduler("test-secret", "http://127.0.0.1:1");

    ScheduleEntry entry;
    entry.id = "e";
    entry.path = "/p";
    entry.when = Schedule.recurring("* * * * *");

    auto noPath = entry;
    noPath.path = "";
    assert(collectException(scheduler.upsert(noPath)).msg.indexOf("path") != -1);

    auto relativePath = entry;
    relativePath.path = "p";
    assert(collectException(scheduler.upsert(relativePath)).msg.indexOf("path") != -1);

    auto noId = entry;
    noId.id = "";
    assert(collectException(scheduler.upsert(noId)).msg.indexOf("id cannot be empty") != -1);

    auto neither = entry;
    neither.when = Schedule.init;
    assert(collectException(scheduler.upsert(neither)).msg.indexOf("neither") != -1);

    auto both = entry;
    both.when.at = Clock.currTime + 3650.days;
    assert(collectException(scheduler.upsert(both)).msg.indexOf("both") != -1);

    auto badCron = entry;
    badCron.when = Schedule.recurring("not a cron expression");
    assert(collectException(scheduler.upsert(badCron)).msg.indexOf("Invalid cron expression") != -1);

    // None of the rejected entries was kept, so no thread was started
    assert(scheduler.list().length == 0);
    assert(scheduler.m_thread is null);
}

unittest
{
    // Recurring due-selection, with synthetic times: due once at each minute boundary
    auto scheduler = new LocalScheduler("test-secret", "http://127.0.0.1:1");
    ScheduleEntry entry;
    entry.id = "every-minute";
    entry.path = "/p";
    entry.when = Schedule.recurring("* * * * *");

    LocalScheduler.Held held;
    held.entry = entry;
    held.cron = CronExpr.parse("* * * * *");
    auto at(int minute, int second) { return SysTime(DateTime(2030, 1, 1, 12, minute, second)); }
    scheduler.scheduleNext(held, at(0, 30));
    scheduler.m_held["every-minute"] = held;

    assert(scheduler.collectDue(at(0, 30)).length == 0);
    assert(scheduler.collectDue(at(0, 59)).length == 0);
    assert(scheduler.collectDue(at(1, 0)) == [entry]);
    assert(scheduler.collectDue(at(1, 0)).length == 0);
    assert(scheduler.collectDue(at(1, 45)).length == 0);
    assert(scheduler.collectDue(at(2, 0)) == [entry]);

    // A one-shot entry is due once and dropped
    scheduler.remove("every-minute");
    ScheduleEntry once = ScheduleEntry("once", Schedule.once(at(3, 0)), "/p", null);
    LocalScheduler.Held heldOnce;
    heldOnce.entry = once;
    scheduler.m_held["once"] = heldOnce;
    assert(scheduler.collectDue(at(2, 59)).length == 0);
    assert(scheduler.collectDue(at(3, 0)) == [once]);
    assert(scheduler.collectDue(at(3, 1)).length == 0);
    assert(scheduler.list().length == 0);
}

unittest
{
    import core.time : seconds;
    import std.socket : TcpSocket, InternetAddress, Socket, SocketSet;
    import std.algorithm.searching : startsWith;

    // The thread starts with the first entry, fires a due one-shot entry at the endpoint, drops
    // the entry, and ends with the last entry: nothing runs while nothing is scheduled.
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    listener.listen(1);
    ushort port = (cast(InternetAddress) listener.localAddress).port;

    auto scheduler = new LocalScheduler("test-secret", format("http://127.0.0.1:%d", port));
    assert(scheduler.m_thread is null);

    // Waits (bounded) for the thread to end itself
    void waitForThreadToEnd()
    {
        foreach (_; 0 .. 50)
        {
            synchronized (scheduler.m_mutex)
                if (scheduler.m_thread is null) return;
            Thread.sleep(100.msecs);
        }
        assert(false, "The thread outlived the last entry");
    }

    ScheduleEntry entry;
    entry.id = "once";
    entry.path = "/api/v1/once";
    entry.when = Schedule.once(Clock.currTime);
    scheduler.upsert(entry);

    auto waitSet = new SocketSet();
    waitSet.add(listener);
    assert(Socket.select(waitSet, null, null, 5.seconds) > 0, "The due one-shot entry was never fired");
    auto client = listener.accept();
    char[4096] buf;
    auto n = client.receive(buf[]);
    assert(n > 0 && buf[0 .. n].idup.startsWith("POST /api/v1/once "));
    client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    client.close();
    listener.close();

    waitForThreadToEnd();
    assert(scheduler.list().length == 0, "A fired one-shot entry was kept");

    // Removing the last entry ends the thread too
    entry.when = Schedule.once(Clock.currTime + 3650.days);
    scheduler.upsert(entry);
    synchronized (scheduler.m_mutex)
        assert(scheduler.m_thread !is null);
    scheduler.remove("once");
    waitForThreadToEnd();
}
