module confector.testing.memory_dispatch_queue;

import confector.plugin_api.dispatch_queue;
import core.time : Duration, MonoTime;
import std.format : format;
import vibe.data.json : Json;

/**
 * DispatchQueue kept in process memory. Used by tests; passes the DispatchQueue conformance
 * suite (confector.testing.conformance.dispatch_queue).
 *
 * Lease and delay times are read from the clock passed to the constructor, so tests can expire
 * leases without waiting. Sent and received messages are deep copies.
 */
class InMemoryDispatchQueue : DispatchQueue
{
    private static struct Entry
    {
        Json message;
        MonoTime visibleAt;
        /// Identifies the current delivery; null when the message has not been delivered since it
        /// was sent or released, so no receipt matches.
        string deliveryToken;
        uint receiveCount;
    }

    private MonoTime delegate() m_now;
    private bool[string] m_queues;
    private Entry[string][string] m_messages; // queue -> message id -> entry
    private ulong m_lastId;

    /// now returns the current time; when null, the queue uses MonoTime.currTime.
    this(MonoTime delegate() now = null)
    {
        m_now = now !is null ? now : () => MonoTime.currTime;
    }

    override void ensureQueue(string queue)
    {
        validateQueueName(queue);
        synchronized (this)
            m_queues[queue] = true;
    }

    override void send(string queue, Json message, Duration delay = Duration.zero)
    {
        validateMessage(queue, message);
        validateDelay(delay);
        synchronized (this)
        {
            expectEnsured(queue);
            m_lastId++;
            m_messages[queue][format("%s", m_lastId)] = Entry(message.clone(), m_now() + delay, null, 0);
        }
    }

    override Lease[] receive(string queue, size_t maxMessages, Duration visibility)
    {
        import std.uuid : randomUUID;

        validateReceiveBatch(maxMessages);
        validateVisibility(visibility);
        synchronized (this)
        {
            expectEnsured(queue);
            Lease[] leases;
            auto messages = queue in m_messages;
            if (messages is null)
                return leases;
            const now = m_now();
            foreach (id, ref entry; *messages)
            {
                if (leases.length == maxMessages)
                    break;
                if (entry.visibleAt > now)
                    continue;
                entry.deliveryToken = randomUUID().toString();
                entry.receiveCount++;
                entry.visibleAt = now + visibility;
                leases ~= Lease(id ~ receiptSeparator ~ entry.deliveryToken, entry.receiveCount, entry.message.clone());
            }
            return leases;
        }
    }

    override void ack(string queue, string receipt)
    {
        synchronized (this)
        {
            expectEnsured(queue);
            const id = currentDelivery(queue, receipt, "acknowledge", false);
            m_messages[queue].remove(id);
        }
    }

    override void extend(string queue, string receipt, Duration visibility)
    {
        validateVisibility(visibility);
        synchronized (this)
        {
            expectEnsured(queue);
            const id = currentDelivery(queue, receipt, "extend", true);
            m_messages[queue][id].visibleAt = m_now() + visibility;
        }
    }

    override void release(string queue, string receipt, Duration delay = Duration.zero)
    {
        validateDelay(delay);
        synchronized (this)
        {
            expectEnsured(queue);
            const id = currentDelivery(queue, receipt, "release", true);
            auto entry = &m_messages[queue][id];
            entry.visibleAt = m_now() + delay;
            entry.deliveryToken = null;
        }
    }

    /// Receipts are "<message id>/<delivery token>"; message ids never contain the separator.
    private enum receiptSeparator = "/";

    private void expectEnsured(string queue)
    {
        validateQueueName(queue);
        if (queue !in m_queues)
            throw new DispatchQueueUsageException(format("Queue '%s' was not ensured", queue));
    }

    /**
     * Returns the id of the message the receipt delivered, or throws LeaseLostException unless
     * the receipt is the message's current delivery (and, if requireUnexpired, its lease has not
     * expired).
     */
    private string currentDelivery(string queue, string receipt, string operation, bool requireUnexpired)
    {
        import std.string : indexOf;

        const separator = receipt.indexOf(receiptSeparator);
        if (separator <= 0 || separator == receipt.length - 1)
            throw new DispatchQueueUsageException(format("Malformed receipt '%s' for queue '%s'", receipt, queue));
        const id = receipt[0 .. separator];
        const token = receipt[separator + 1 .. $];

        if (auto messages = queue in m_messages)
        {
            if (auto entry = id in *messages)
            {
                if (entry.deliveryToken is null || entry.deliveryToken != token)
                    throw new LeaseLostException(format(
                        "Cannot %s receipt '%s' on queue '%s': the message was delivered again or released", operation, receipt, queue), queue, receipt);
                if (requireUnexpired && entry.visibleAt <= m_now())
                    throw new LeaseLostException(format(
                        "Cannot %s receipt '%s' on queue '%s': its lease has expired", operation, receipt, queue), queue, receipt);
                return id;
            }
        }
        throw new LeaseLostException(format(
            "Cannot %s receipt '%s' on queue '%s': the message has been removed", operation, receipt, queue), queue, receipt);
    }
}
