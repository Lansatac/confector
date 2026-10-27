module confector.testing.threads;

import std.format : format;
import core.thread : Thread;
import core.time : Duration, seconds;
import vibe.http.server : HTTPServerOption, HTTPServerSettings;

/// Longest a test waits for work run off its thread: longer than a control-plane request may
/// take, so a request that times out fails with its own error first.
enum testWaitTimeout = 120.seconds;

/// A TCP port nothing listens on at the moment, for a test server.
ushort freePort()
{
    import std.socket : InternetAddress, Socket, TcpSocket;

    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    return (cast(InternetAddress) probe.localAddress).port;
}

/// Settings for a mock control plane on `port`, on the loopback address. Address reuse is off:
/// on Windows a listener that has it shares its port with another listener, so a client could
/// be answered by the wrong one. Without it, a port in use fails the bind.
HTTPServerSettings loopbackServerSettings(ushort port)
{
    auto settings = new HTTPServerSettings();
    settings.port = port;
    settings.bindAddresses = ["127.0.0.1"];
    settings.options = cast(HTTPServerOption)(HTTPServerOption.defaults & ~HTTPServerOption.reuseAddress);
    return settings;
}

/**
 * Runs `work` on a thread of its own while this thread's event loop serves the mock control plane,
 * and returns once it is done. Rethrows what `work` threw.
 *
 * The thread is a daemon and the wait is bounded by `testWaitTimeout`: past it, `abandon` is called
 * (to stop a worker loop) and this throws, so work that never returns fails the test rather than
 * keeping the test process alive.
 */
void runOffThread(void delegate() work, void delegate() abandon = null, Duration timeout = testWaitTimeout)
{
    import vibe.core.core : sleep;
    import core.time : msecs, MonoTime;

    Throwable thrown;
    auto thread = new Thread({
        try work();
        catch (Throwable t) thrown = t;
    });
    thread.isDaemon = true;
    thread.start();
    const deadline = MonoTime.currTime + timeout;
    while (thread.isRunning)
    {
        if (MonoTime.currTime > deadline)
        {
            if (abandon !is null) abandon();
            throw new Exception(format("The work did not finish within %s seconds", timeout.total!"seconds"));
        }
        sleep(10.msecs);
    }
    thread.join();
    if (thrown !is null) throw thrown;
}
