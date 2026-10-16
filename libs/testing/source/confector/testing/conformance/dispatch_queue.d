module confector.testing.conformance.dispatch_queue;

/**
 * Conformance suite for DispatchQueue backends. Every backend, including in-memory test fakes,
 * must pass it (design record: bead confector-z7z.4).
 *
 * Run it from a backend's tests:
 *
 *     checkDispatchQueue(
 *         (size_t clients) => connectClients(freshTestDatabase(), clients),
 *         (Duration elapsed) => Thread.sleep(elapsed));
 *
 * makeClients is called once per check and must return that many clients of one new, empty
 * backend: separate connections where the backend has them, so that concurrency checks exercise
 * the backend rather than a lock in the client. letTimePass must return once at least `elapsed`
 * has passed on the backend's clock: a backend with an injectable clock advances it, a backend
 * that uses real time sleeps. Checks wait about 20 seconds in total.
 */

import confector.plugin_api.dispatch_queue;
import core.time : Duration, hours, seconds;
import std.format : format;
import vibe.data.json : Json;

/// A backend broke the DispatchQueue contract.
class DispatchQueueConformanceException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Runs every check against clients from makeClients. Throws DispatchQueueConformanceException
/// on the first failure.
void checkDispatchQueue(DispatchQueue[] delegate(size_t clients) makeClients, void delegate(Duration elapsed) letTimePass)
{
    foreach (check; checks)
    {
        auto clients = makeClients(check.clients);
        if (clients.length != check.clients)
            throw new DispatchQueueConformanceException(format(
                "DispatchQueue conformance check '%s': makeClients(%s) returned %s clients", check.name, check.clients, clients.length));
        try
            check.run(Context(clients, letTimePass));
        catch (Exception e)
            throw new DispatchQueueConformanceException(format("DispatchQueue conformance check '%s' failed: %s%s",
                check.name, cast(DispatchQueueConformanceException) e ? "" : typeid(e).name ~ ": ", e.msg), e.file, e.line);
    }
}

private:

struct Context
{
    DispatchQueue[] clients;
    void delegate(Duration) letTimePass;

    DispatchQueue queue() { return clients[0]; }
}

struct Check
{
    string name;
    void function(Context) run;
    size_t clients = 1;
}

immutable Check[] checks = [
    Check("send, receive and ack", &sendReceiveAndAck),
    Check("messages round-trip", &messagesRoundTrip),
    Check("messages are isolated from callers", &messagesAreIsolated),
    Check("receive in batches", &receiveInBatches),
    Check("duplicate messages are delivered separately", &duplicatesAreSeparate),
    Check("queues are separate", &queuesAreSeparate),
    Check("ensureQueue is idempotent", &ensureQueueIsIdempotent),
    Check("usage errors", &usageErrors),
    Check("delayed send", &delayedSend),
    Check("expired lease is delivered again", &expiredLeaseIsDeliveredAgain),
    Check("ack after the lease expired", &ackAfterExpiry),
    Check("extend", &extendLease),
    Check("release", &releaseLease),
    Check("concurrent receive", &concurrentReceive, 8),
];

enum poolA = "pool-a";
enum poolB = "pool-b";
enum noExpiry = 1.hours;   // a lease that does not expire during a check

// Leases and delays that must not run out before a check looks are kept at least 2 seconds
// longer than the time the check lets pass, so slow machines and real-time backends (which
// sleep) do not fail spuriously. Only leases a check expires on purpose are 1 second.

void expect(bool condition, lazy string message, string file = __FILE__, size_t line = __LINE__)
{
    if (!condition)
        throw new DispatchQueueConformanceException(message, file, line);
}

void expectThrows(E : Throwable)(scope void delegate() action, string what, string file = __FILE__, size_t line = __LINE__)
{
    try
        action();
    catch (E)
        return;
    catch (Exception e)
        throw new DispatchQueueConformanceException(format("%s: expected %s, got %s: %s", what, E.stringof, typeid(e).name, e.msg), file, line);
    throw new DispatchQueueConformanceException(format("%s: expected %s, nothing was thrown", what, E.stringof), file, line);
}

/// Acknowledges with a stale receipt, which must not remove the message. Backends may throw
/// LeaseLostException or return normally; callers check afterwards that the message survived.
void ackStale(DispatchQueue queue, string name, string receipt, string what, string file = __FILE__, size_t line = __LINE__)
{
    try
        queue.ack(name, receipt);
    catch (LeaseLostException)
        return;
    catch (Exception e)
        throw new DispatchQueueConformanceException(format("%s: expected LeaseLostException or no exception, got %s: %s", what, typeid(e).name, e.msg), file, line);
}

Json numbered(long n)
{
    auto message = Json.emptyObject;
    message["n"] = n;
    return message;
}

Lease receiveOne(DispatchQueue queue, string name, Duration visibility, string what, string file = __FILE__, size_t line = __LINE__)
{
    auto leases = queue.receive(name, 1, visibility);
    expect(leases.length == 1, format("%s: receive returned %s messages, not 1", what, leases.length), file, line);
    return leases[0];
}

void expectNothing(DispatchQueue queue, string name, string what, string file = __FILE__, size_t line = __LINE__)
{
    auto leases = queue.receive(name, maxReceiveBatch, noExpiry);
    expect(leases.length == 0, format("%s: receive returned %s messages, not none: %s", what, leases.length, leases), file, line);
}

void sendReceiveAndAck(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    expect(queue.receive(poolA, maxReceiveBatch, noExpiry).length == 0, "receive from an empty queue returned messages");

    auto message = Json.emptyObject;
    message["execution"] = "e1";
    queue.send(poolA, message);
    auto lease = receiveOne(queue, poolA, noExpiry, "receive after send");
    expect(lease.receipt.length > 0, "the lease has an empty receipt");
    expect(lease.receiveCount == 1, format("the first delivery has receive count %s, not 1", lease.receiveCount));
    expect(lease.message == message, format("received %s, not %s", lease.message, message));

    expectNothing(queue, poolA, "receive while the only message is leased");
    queue.ack(poolA, lease.receipt);
    expectThrows!LeaseLostException(() { queue.extend(poolA, lease.receipt, noExpiry); }, "extend after ack");
    expectThrows!LeaseLostException(() { queue.release(poolA, lease.receipt); }, "release after ack");
    ackStale(queue, poolA, lease.receipt, "a second ack");
}

void messagesRoundTrip(Context context)
{
    import vibe.data.json : parseJsonString;

    auto queue = context.queue;
    queue.ensureQueue(poolA);
    auto message = parseJsonString(`{
        "float": 0.1, "negative": -2.5e-300, "big": 9007199254740993, "min": -9223372036854775808,
        "zero": 0, "bool": false, "null": null,
        "text": "quote \" backslash \\ newline \n tab \t nul \u0000 emoji 😀 accent é",
        "empty_array": [], "empty_object": {}, "nested": {"a": [1, "two", [3], {"four": 4}]},
        "$dollar": 1, "dotted.name": 2, "id": "content id", "receipt": "content receipt"
    }`);
    queue.send(poolA, message);
    auto lease = receiveOne(queue, poolA, noExpiry, "receive");
    expect(lease.message == message, format("message did not round-trip:\n sent     %s\n received %s", message, lease.message));
    expect(queue.receive(poolA, maxReceiveBatch, noExpiry).length == 0, "message fields named like queue fields produced another message");
}

void messagesAreIsolated(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    auto message = numbered(1);
    queue.send(poolA, message);
    message["n"] = 2;
    auto lease = receiveOne(queue, poolA, 1.seconds, "receive");
    expect(lease.message == numbered(1), "changing a message after send changed the queued message");

    lease.message["n"] = 3;
    context.letTimePass(1.seconds);
    auto again = receiveOne(queue, poolA, noExpiry, "receive after the lease expired");
    expect(again.message == numbered(1), "changing a received message changed the queued message");
}

void receiveInBatches(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    enum total = 25;
    foreach (n; 0 .. total)
        queue.send(poolA, numbered(n));

    bool[long] seen;
    foreach (attempt; 0 .. 100)
    {
        auto leases = queue.receive(poolA, maxReceiveBatch, noExpiry);
        expect(leases.length <= maxReceiveBatch, format("receive returned %s messages, more than the %s asked for", leases.length, maxReceiveBatch));
        if (seen.length < total)
            expect(leases.length > 0, format("receive returned nothing with %s messages receivable", total - seen.length));
        foreach (lease; leases)
        {
            const n = lease.message["n"].get!long;
            expect(n !in seen, format("message %s was delivered twice while leased", n));
            seen[n] = true;
        }
        if (seen.length == total)
            break;
    }
    expect(seen.length == total, format("received %s distinct messages, not %s", seen.length, total));
    expectNothing(queue, poolA, "receive with every message leased");

    auto one = queue.receive(poolA, 1, noExpiry);
    expect(one.length == 0, "receive(1) returned a leased message");
}

void duplicatesAreSeparate(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(7));
    queue.send(poolA, numbered(7));
    auto first = receiveOne(queue, poolA, noExpiry, "first receive");
    auto second = receiveOne(queue, poolA, noExpiry, "second receive");
    expect(first.receipt != second.receipt, "two identical messages share a receipt");
    expect(first.message == numbered(7) && second.message == numbered(7), "identical messages changed");
    queue.ack(poolA, first.receipt);
    queue.ack(poolA, second.receipt);
}

void queuesAreSeparate(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.ensureQueue(poolB);
    queue.send(poolA, numbered(1));
    expectNothing(queue, poolB, "receive from another queue");
    auto lease = receiveOne(queue, poolA, noExpiry, "receive from the queue the message was sent to");
    expectThrows!LeaseLostException(() { queue.extend(poolB, lease.receipt, noExpiry); }, "extend with a receipt from another queue");
    ackStale(queue, poolB, lease.receipt, "ack with a receipt from another queue");
    queue.extend(poolA, lease.receipt, noExpiry);
    queue.ack(poolA, lease.receipt);
}

void ensureQueueIsIdempotent(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1));
    queue.ensureQueue(poolA);
    receiveOne(queue, poolA, noExpiry, "receive after ensuring the queue again");
}

void usageErrors(Context context)
{
    import core.time : msecs;
    import std.array : replicate;

    auto queue = context.queue;
    alias Usage = DispatchQueueUsageException;

    expectThrows!Usage(() { queue.send(poolA, numbered(1)); }, "send to a queue that was not ensured");
    expectThrows!Usage(() { queue.receive(poolA, 1, noExpiry); }, "receive from a queue that was not ensured");

    expectThrows!Usage(() { queue.ensureQueue(""); }, "ensureQueue with an empty name");
    expectThrows!Usage(() { queue.ensureQueue("Pool"); }, "ensureQueue with an upper-case name");
    expectThrows!Usage(() { queue.ensureQueue("1pool"); }, "ensureQueue with a name starting with a digit");
    expectThrows!Usage(() { queue.ensureQueue("pool_a"); }, "ensureQueue with an underscore in the name");
    expectThrows!Usage(() { queue.ensureQueue("p" ~ "x".replicate(maxQueueNameBytes)); }, "ensureQueue with a name over maxQueueNameBytes");
    queue.ensureQueue("p" ~ "x".replicate(maxQueueNameBytes - 1));

    queue.ensureQueue(poolA);
    expectThrows!Usage(() { queue.send(poolA, Json([Json(1)])); }, "send of an array");
    expectThrows!Usage(() { queue.send(poolA, Json("text")); }, "send of a string");

    // {"pad":"..."} with the pad sized to land exactly on the limit.
    auto atLimit = Json.emptyObject;
    atLimit["pad"] = "";
    const overhead = atLimit.toString().length;
    atLimit["pad"] = "x".replicate(maxMessageBytes - overhead);
    expect(atLimit.toString().length == maxMessageBytes, "test setup: message is not exactly at the limit");
    auto overLimit = Json.emptyObject;
    overLimit["pad"] = "x".replicate(maxMessageBytes - overhead + 1);
    expectThrows!Usage(() { queue.send(poolA, overLimit); }, "send over the size limit");
    expect(queue.receive(poolA, maxReceiveBatch, noExpiry).length == 0, "a send over the size limit queued a message");
    queue.send(poolA, atLimit);
    auto big = receiveOne(queue, poolA, noExpiry, "receive of a message exactly at the size limit");
    expect(big.message == atLimit, "a message exactly at the size limit did not round-trip");

    expectThrows!Usage(() { queue.send(poolA, numbered(1), -1.seconds); }, "send with a negative delay");
    expectThrows!Usage(() { queue.send(poolA, numbered(1), maxDelay + 1.seconds); }, "send with a delay over maxDelay");
    expectThrows!Usage(() { queue.send(poolA, numbered(1), 1500.msecs); }, "send with a delay that is not whole seconds");
    expectThrows!Usage(() { queue.receive(poolA, 0, noExpiry); }, "receive of 0 messages");
    expectThrows!Usage(() { queue.receive(poolA, maxReceiveBatch + 1, noExpiry); }, "receive of more than maxReceiveBatch messages");
    expectThrows!Usage(() { queue.receive(poolA, 1, Duration.zero); }, "receive with a visibility timeout of 0");
    expectThrows!Usage(() { queue.receive(poolA, 1, maxVisibility + 1.seconds); }, "receive with a visibility timeout over maxVisibility");
    expectThrows!Usage(() { queue.receive(poolA, 1, 1500.msecs); }, "receive with a visibility timeout that is not whole seconds");
    expect(queue.receive(poolA, maxReceiveBatch, noExpiry).length == 0, "a rejected send queued a message");

    queue.send(poolA, numbered(1));
    auto lease = receiveOne(queue, poolA, noExpiry, "receive");
    expectThrows!Usage(() { queue.extend(poolA, lease.receipt, Duration.zero); }, "extend to a visibility timeout of 0");
    expectThrows!Usage(() { queue.extend(poolA, lease.receipt, maxVisibility + 1.seconds); }, "extend over maxVisibility");
    expectThrows!Usage(() { queue.release(poolA, lease.receipt, -1.seconds); }, "release with a negative delay");
    expectThrows!Usage(() { queue.release(poolA, lease.receipt, maxDelay + 1.seconds); }, "release with a delay over maxDelay");
    expectThrows!Usage(() { queue.ack(poolB, lease.receipt); }, "ack on a queue that was not ensured");
    expectThrows!Usage(() { queue.extend(poolB, lease.receipt, noExpiry); }, "extend on a queue that was not ensured");
    expectThrows!Usage(() { queue.release(poolB, lease.receipt); }, "release on a queue that was not ensured");
    queue.ack(poolA, lease.receipt);  // the rejected calls left the lease intact

    foreach (receipt; ["", "not a receipt"])
    {
        try
        {
            queue.ack(poolA, receipt);
            throw new DispatchQueueConformanceException(format("ack with the made-up receipt '%s' did not throw", receipt));
        }
        catch (DispatchQueueUsageException) {}
        catch (LeaseLostException) {}
    }
}

void delayedSend(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1), 3.seconds);
    expectNothing(queue, poolA, "receive before the delay");
    context.letTimePass(1.seconds);
    expectNothing(queue, poolA, "receive halfway through the delay");
    context.letTimePass(2.seconds);
    auto lease = receiveOne(queue, poolA, noExpiry, "receive after the delay");
    expect(lease.receiveCount == 1, format("a delayed message's first delivery has receive count %s, not 1", lease.receiveCount));
}

void expiredLeaseIsDeliveredAgain(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1));
    auto first = receiveOne(queue, poolA, 1.seconds, "first receive");
    expectNothing(queue, poolA, "receive before the lease expired");

    context.letTimePass(1.seconds);
    auto second = receiveOne(queue, poolA, 3.seconds, "receive after the lease expired");
    expect(second.receiveCount == 2, format("the second delivery has receive count %s, not 2", second.receiveCount));
    expect(second.receipt != first.receipt, "the second delivery has the first delivery's receipt");
    expect(second.message == numbered(1), format("the second delivery holds %s, not %s", second.message, numbered(1)));

    // The first receipt is stale: it must not extend, release or remove the message.
    expectThrows!LeaseLostException(() { queue.extend(poolA, first.receipt, noExpiry); }, "extend with a stale receipt");
    expectThrows!LeaseLostException(() { queue.release(poolA, first.receipt); }, "release with a stale receipt");
    ackStale(queue, poolA, first.receipt, "ack with a stale receipt");
    expectNothing(queue, poolA, "receive while the second delivery is leased");

    queue.ack(poolA, second.receipt);
    context.letTimePass(3.seconds);
    expectNothing(queue, poolA, "receive after acknowledging the second delivery");
}

void ackAfterExpiry(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1));
    auto lease = receiveOne(queue, poolA, 1.seconds, "receive");
    context.letTimePass(1.seconds);
    queue.ack(poolA, lease.receipt);
    expectNothing(queue, poolA, "receive after acknowledging an expired, undelivered lease");
}

void extendLease(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1));
    auto lease = receiveOne(queue, poolA, 1.seconds, "receive");
    queue.extend(poolA, lease.receipt, 3.seconds);
    context.letTimePass(1.seconds);
    expectNothing(queue, poolA, "receive after the original lease would have expired");
    queue.extend(poolA, lease.receipt, 1.seconds);  // extension counts from now, not from the old expiry
    context.letTimePass(1.seconds);
    auto again = receiveOne(queue, poolA, 1.seconds, "receive after the extended lease expired");
    expect(again.receiveCount == 2, format("delivery after an extended lease expired has receive count %s, not 2", again.receiveCount));

    // An expired lease cannot be extended or released, even before the message is delivered again.
    context.letTimePass(1.seconds);
    expectThrows!LeaseLostException(() { queue.extend(poolA, again.receipt, noExpiry); }, "extend of an expired lease");
    expectThrows!LeaseLostException(() { queue.release(poolA, again.receipt); }, "release of an expired lease");
    auto third = receiveOne(queue, poolA, noExpiry, "receive after a rejected extend");
    expect(third.receiveCount == 3, format("third delivery has receive count %s, not 3", third.receiveCount));
}

void releaseLease(Context context)
{
    auto queue = context.queue;
    queue.ensureQueue(poolA);
    queue.send(poolA, numbered(1));
    auto first = receiveOne(queue, poolA, noExpiry, "first receive");
    queue.release(poolA, first.receipt);
    auto second = receiveOne(queue, poolA, noExpiry, "receive after release");
    expect(second.receiveCount == 2, format("delivery after release has receive count %s, not 2", second.receiveCount));
    expect(second.receipt != first.receipt, "delivery after release has the released receipt");
    expectThrows!LeaseLostException(() { queue.extend(poolA, first.receipt, noExpiry); }, "extend with a released receipt");
    expectThrows!LeaseLostException(() { queue.release(poolA, first.receipt); }, "release with a released receipt");
    ackStale(queue, poolA, first.receipt, "ack with a released receipt");

    // release succeeds only while the message exists and the lease holds, so this also shows the
    // stale ack above did not remove the message.
    queue.release(poolA, second.receipt, 3.seconds);
    expectNothing(queue, poolA, "receive before the release delay");

    // A released receipt is stale at once, before the message is delivered again. The delivery
    // after the delay below shows the stale ack did not remove the message.
    expectThrows!LeaseLostException(() { queue.extend(poolA, second.receipt, noExpiry); }, "extend with a receipt released with a delay, before redelivery");
    expectThrows!LeaseLostException(() { queue.release(poolA, second.receipt); }, "release with a receipt released with a delay, before redelivery");
    ackStale(queue, poolA, second.receipt, "ack with a receipt released with a delay, before redelivery");
    context.letTimePass(1.seconds);
    expectNothing(queue, poolA, "receive halfway through the release delay");
    context.letTimePass(2.seconds);
    auto third = receiveOne(queue, poolA, 2.seconds, "receive after the release delay");
    expect(third.receiveCount == 3, format("delivery after a delayed release has receive count %s, not 3", third.receiveCount));
    queue.ack(poolA, third.receipt);
    context.letTimePass(2.seconds);
    expectNothing(queue, poolA, "receive after ack");
}

void concurrentReceive(Context context)
{
    import core.atomic : atomicOp, atomicLoad;
    import core.thread : Thread;

    enum total = 200;
    context.queue.ensureQueue(poolA);
    foreach (n; 0 .. total)
        context.queue.send(poolA, numbered(n));

    // Every client receives until all messages are leased. Leases outlast the check, so a message
    // received twice means two receivers claimed it at once.
    shared size_t received;
    auto perClient = new long[][](context.clients.length);
    auto failures = new Exception[](context.clients.length);
    Thread[] threads;
    foreach (i, client; context.clients)
    {
        threads ~= new Thread(((size_t index, DispatchQueue queue) => () {
            try
            {
                foreach (attempt; 0 .. total * 10)
                {
                    if (atomicLoad(received) >= total)
                        return;
                    foreach (lease; queue.receive(poolA, maxReceiveBatch, noExpiry))
                    {
                        perClient[index] ~= lease.message["n"].get!long;
                        atomicOp!"+="(received, 1);
                    }
                }
            }
            catch (Exception e)
                failures[index] = e;
        })(i, client));
    }
    foreach (thread; threads)
        thread.start();
    foreach (thread; threads)
        thread.join();
    foreach (i, failure; failures)
        if (failure !is null)
            throw new DispatchQueueConformanceException(format("client %s failed: %s: %s", i, typeid(failure).name, failure.msg));

    size_t[long] deliveries;
    foreach (numbers; perClient)
        foreach (n; numbers)
            deliveries[n]++;
    foreach (n; 0 .. total)
    {
        const count = deliveries.get(n, 0);
        expect(count == 1, format("message %s was delivered %s times to %s concurrent receivers, not once", n, count, context.clients.length));
    }
    expect(deliveries.length == total, format("concurrent receivers got %s distinct messages, not %s", deliveries.length, total));
    expectNothing(context.queue, poolA, "receive after concurrent receivers leased every message");
}

unittest
{
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import core.time : MonoTime;

    // A fake clock, so lease and delay checks run without waiting.
    const start = MonoTime.currTime;
    Duration elapsed;
    checkDispatchQueue(
        (size_t clients) {
            auto queue = new InMemoryDispatchQueue(() => start + elapsed);
            auto result = new DispatchQueue[](clients);
            result[] = queue;
            return result;
        },
        (Duration time) { elapsed += time; });
}
