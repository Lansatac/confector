module confector.plugin_api.dispatch_queue;

/**
 * The dispatch queue backend interface: internal delivery of work to workers, one queue per
 * compute pool (design record: bead confector-z7z.4).
 *
 * The dispatch queue is never the source of truth and is never read for display; the build
 * queue users see is computed from the state store. Any lost message can be sent again from the
 * state store, so messages stay small (an execution id plus routing).
 *
 * Delivery contract:
 * - At least once and unordered. A message may be delivered more than once, so handlers must be
 *   idempotent.
 * - receive() leases messages: a received message is invisible to other receivers until its
 *   lease expires, is extended, or is released. A message whose lease expires without an ack is
 *   delivered again.
 * - Each delivery has its own receipt. Once a message has been delivered again, receipts from
 *   earlier deliveries are stale: extend() and release() reject them, and ack() with them never
 *   removes the message.
 * - receiveCount counts deliveries; the coordinator uses it to count execution attempts.
 */

import core.time : Duration, hours, minutes, seconds;
import vibe.data.json : Json;

/// Largest message a queue accepts, in bytes, measured as compact JSON (Json.toString()) by
/// validateMessage. Chosen to fit Azure Storage queues (64 KiB) as well as SQS.
enum size_t maxMessageBytes = 64 * 1024;

/// Longest queue name, in bytes. Chosen to fit Azure Storage queue names (63 characters).
enum size_t maxQueueNameBytes = 63;

/// Most messages one receive() may return. SQS returns at most 10 per call.
enum size_t maxReceiveBatch = 10;

/// Longest delay for send() and release(). SQS delays messages by at most 15 minutes.
enum Duration maxDelay = 15.minutes;

/// Longest lease for receive() and extend(). SQS visibility timeouts are at most 12 hours.
enum Duration maxVisibility = 12.hours;

/// One delivery of a message.
struct Lease
{
    /// Identifies this delivery; pass it to ack, extend and release. Opaque to callers.
    string receipt;
    /// How many times the message has been delivered, including this delivery: 1 the first time.
    uint receiveCount;
    /// The message as sent; always a JSON object.
    Json message;
}

/**
 * A dispatch queue backend. Every method throws on failure; none returns a sentinel.
 *
 * Operations on a queue that was never ensured throw DispatchQueueUsageException, as do invalid
 * arguments: see validateQueueName, validateMessage, validateDelay, validateVisibility and
 * validateReceiveBatch, which every backend calls so that all backends enforce the contract the
 * same way.
 *
 * Durations are whole seconds, the granularity of SQS. Lease and delay times are measured by the
 * backend's clock (for a database-backed queue, the database server's), not the caller's.
 */
interface DispatchQueue
{
    /**
     * Creates a queue if it does not exist, and returns once it can be used. Idempotent; any
     * instance of a backend may then use the queue. Names match [a-z][a-z0-9-]* and are at most
     * maxQueueNameBytes long, so every backend can use them as (part of) a native queue name.
     */
    void ensureQueue(string queue);

    /**
     * Sends a message, which becomes receivable after delay (0 to maxDelay). The message must be
     * a JSON object of at most maxMessageBytes.
     */
    void send(string queue, Json message, Duration delay = Duration.zero);

    /**
     * Leases up to maxMessages (1 to maxReceiveBatch) receivable messages for visibility (1
     * second to maxVisibility), and returns at once; the result is empty if none are receivable.
     * It may hold fewer messages than are receivable. No two receivers hold a lease on the same
     * message at the same time.
     */
    Lease[] receive(string queue, size_t maxMessages, Duration visibility);

    /**
     * Removes a received message. Acknowledging after the lease expired still removes the
     * message if it has not been delivered again. A receipt that is stale (the message was
     * delivered again, released, or already removed) never removes the message; backends that
     * can tell throw LeaseLostException, others (such as SQS after a later delivery) return
     * normally.
     */
    void ack(string queue, string receipt);

    /**
     * Extends a lease: the message stays invisible for visibility (1 second to maxVisibility)
     * from now. Throws LeaseLostException if the lease has expired or the receipt is stale.
     */
    void extend(string queue, string receipt, Duration visibility);

    /**
     * Gives up a lease: the message becomes receivable again after delay (0 to maxDelay). Its
     * receive count is kept. The receipt becomes stale at once, even while the message waits out
     * the delay: extend and release with it throw LeaseLostException, and ack with it never
     * removes the message. (A backend on SQS, where a receipt stays usable until the next
     * delivery, must track released receipts itself to meet this.) Throws LeaseLostException if
     * the lease has expired or the receipt is stale.
     */
    void release(string queue, string receipt, Duration delay = Duration.zero);
}

/// A lease no longer holds: it expired, or the message was delivered again, released or removed.
/// Another worker may be processing the message; stop work that depends on holding it.
class LeaseLostException : Exception
{
    string queue;
    string receipt;

    this(string msg, string queue, string receipt, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.queue = queue;
        this.receipt = receipt;
    }
}

/// The queue was used incorrectly: a queue that was never ensured, or an invalid argument.
class DispatchQueueUsageException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

// Validation shared by backends, so every backend enforces the contract the same way.

/// Throws DispatchQueueUsageException unless the name matches [a-z][a-z0-9-]* and is at most
/// maxQueueNameBytes long.
void validateQueueName(string queue) @safe pure
{
    import std.format : format;

    if (queue.length == 0 || queue.length > maxQueueNameBytes)
        throw new DispatchQueueUsageException(format("Queue name '%s' is %s bytes; it must be 1 to %s", queue, queue.length, maxQueueNameBytes));
    if (!(queue[0] >= 'a' && queue[0] <= 'z'))
        throw new DispatchQueueUsageException(format("Queue name '%s' does not match [a-z][a-z0-9-]*", queue));
    foreach (c; queue)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
            throw new DispatchQueueUsageException(format("Queue name '%s' does not match [a-z][a-z0-9-]*", queue));
}

/**
 * Checks a message about to be sent: a JSON object of at most maxMessageBytes. Returns its
 * compact JSON text, which backends may store as is. Throws DispatchQueueUsageException.
 */
string validateMessage(string queue, Json message) @safe
{
    import std.format : format;

    if (message.type != Json.Type.object)
        throw new DispatchQueueUsageException(format("Message for queue '%s' must be a JSON object", queue));
    auto text = message.toString();
    if (text.length > maxMessageBytes)
        throw new DispatchQueueUsageException(format(
            "Message for queue '%s' is %s bytes; the limit is %s. Send an id and keep the data in the state store.",
            queue, text.length, maxMessageBytes));
    return text;
}

/// Throws DispatchQueueUsageException unless delay is whole seconds from 0 to maxDelay.
void validateDelay(Duration delay) @safe pure
{
    validateSeconds("Delay", delay, Duration.zero, maxDelay);
}

/// Throws DispatchQueueUsageException unless visibility is whole seconds from 1 second to
/// maxVisibility.
void validateVisibility(Duration visibility) @safe pure
{
    validateSeconds("Visibility timeout", visibility, 1.seconds, maxVisibility);
}

/// Throws DispatchQueueUsageException unless maxMessages is 1 to maxReceiveBatch.
void validateReceiveBatch(size_t maxMessages) @safe pure
{
    import std.format : format;

    if (maxMessages == 0 || maxMessages > maxReceiveBatch)
        throw new DispatchQueueUsageException(format("receive() asked for %s messages; it must be 1 to %s", maxMessages, maxReceiveBatch));
}

private void validateSeconds(string what, Duration value, Duration min, Duration max) @safe pure
{
    import std.format : format;

    if (value < min || value > max)
        throw new DispatchQueueUsageException(format("%s %s is outside %s to %s", what, value, min, max));
    if (value != value.total!"seconds".seconds)
        throw new DispatchQueueUsageException(format("%s %s is not a whole number of seconds", what, value));
}

