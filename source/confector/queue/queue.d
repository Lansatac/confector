module confector.queue.queue;

import confector.core.model;
import vibe.data.json;
import vibe.data.serialization : asName = name;

import std.datetime.systime : Clock;
import std.format : format;
import std.uuid : randomUUID;

/**
 * Artifact reference to fetch before task execution.
 */
struct InputArtifactRef
{
    @asName("task_id") string taskId;
    @asName("storage_uri") string storageUri;
    @asName("target_path") string targetPath;
}

/**
 * Detailed upstream artifact location for remote worker fetching.
 */
struct UpstreamArtifactLocation
{
    @asName("task_id") string taskId;
    @asName("artifact_path") string artifactPath;
    @optional @asName("storage_backend") string storageBackend = "local";
    @optional @asName("storage_uri") string storageUri;
    @optional @asName("sha256") string sha256;
    @optional @asName("target_path") string targetPath;
}

/**
 * Self-contained execution payload for worker tasks.
 */
struct TaskExecutionPayload
{
    @optional @asName("repository_url") string repositoryUrl;
    @optional @asName("commit_sha") string commitSha;
    @optional @asName("allowed_repositories") string[] allowedRepositories;
    @optional @asName("repository_map") string[string] repositoryMap;
    @optional string script;
    @optional string[string] environment;
    @optional @asName("input_artifacts") InputArtifactRef[] inputArtifacts;
    @optional @asName("upstream_artifact_locations") UpstreamArtifactLocation[] upstreamArtifactLocations;
    @optional @asName("upstream_artifact_hashes") string[string] upstreamArtifactHashes;
    @optional @asName("expected_outputs") OutputArtifactDecl[] expectedOutputs;
    @optional @asName("workspace_dir") string workspaceDir;
    @optional @asName("callback_url") string callbackUrl;
    @optional @asName("force") bool force = false;
}

/**
 * Message queued for worker consumption.
 */
struct TaskQueueMessage
{
    @asName("message_id") string messageId;
    @asName("receipt_handle") string receiptHandle;
    @asName("build_id") string buildId;
    @asName("task_id") string taskId;
    @asName("node_fingerprint") string nodeFingerprint;
    @asName("execution_payload") TaskExecutionPayload executionPayload;
    @asName("task_node") TaskNode taskNode;
    @asName("created_at") string createdAt;
    int attempt = 1;
    @asName("max_attempts") int maxAttempts = 3;
    @asName("timeout_seconds") size_t timeoutSeconds = 900;
    @asName("visible_after") long visibleAfterUnix = 0;
    @asName("error_reason") string errorReason;
}

/**
 * Generic Work Queue interface for decoupled task distribution.
 */
interface WorkQueue
{
    /**
     * Enqueues a task execution message.
     */
    void enqueue(TaskQueueMessage message);

    /**
     * Dequeues up to maxMessages ready for processing.
     * Sets visibility timeout on returned messages.
     */
    TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30);

    /**
     * Acknowledges successful processing of a message, removing it from the queue.
     */
    void ack(string receiptHandle);

    /**
     * Negatively acknowledges a message. If requeue is true and attempts < maxAttempts,
     * the message is made visible again; otherwise it is moved to the dead-letter queue.
     */
    void nack(string receiptHandle, bool requeue = true, string errorReason = null);

    /**
     * Extends visibility timeout for an in-flight message while a worker is still processing.
     */
    void heartbeat(string receiptHandle, long extensionSeconds = 30);

    /**
     * Returns dead-lettered messages.
     */
    TaskQueueMessage[] getDeadLetterMessages();

    /**
     * Returns count of ready/pending messages.
     */
    ulong getPendingCount();

    /**
     * Returns pending / ready messages for inspection or queue monitoring.
     */
    TaskQueueMessage[] getPendingMessages(size_t limit = 50);
}

/**
 * In-memory implementation of WorkQueue for testing and local execution.
 */
class InMemoryWorkQueue : WorkQueue
{
    private struct QueueEntry
    {
        TaskQueueMessage message;
        bool inFlight = false;
        long visibleAfterUnix = 0;
        string activeReceiptHandle;
    }

    private QueueEntry[] m_entries;
    private TaskQueueMessage[] m_deadLetters;

    private static long currentUnixTime()
    {
        return Clock.currTime.toUnixTime();
    }

    override void enqueue(TaskQueueMessage message)
    {
        if (message.messageId.length == 0)
        {
            message.messageId = "msg_" ~ randomUUID().toString();
        }
        if (message.createdAt.length == 0)
        {
            message.createdAt = Clock.currTime.toISOString();
        }
        if (message.maxAttempts <= 0)
        {
            message.maxAttempts = 3;
        }

        QueueEntry entry;
        entry.message = message;
        entry.inFlight = false;
        entry.visibleAfterUnix = message.visibleAfterUnix > 0 ? message.visibleAfterUnix : currentUnixTime();
        m_entries ~= entry;
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;

        foreach (ref entry; m_entries)
        {
            if (result.length >= maxMessages)
            {
                break;
            }

            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                string handle = "rcpt_" ~ randomUUID().toString();
                entry.inFlight = true;
                entry.activeReceiptHandle = handle;
                entry.visibleAfterUnix = now + visibilityTimeoutSeconds;

                TaskQueueMessage msg = entry.message;
                msg.receiptHandle = handle;
                msg.visibleAfterUnix = entry.visibleAfterUnix;
                result ~= msg;
            }
            else if (entry.inFlight && entry.visibleAfterUnix <= now)
            {
                // Visibility timeout expired without ACK -> retry attempt
                entry.message.attempt++;
                if (entry.message.attempt > entry.message.maxAttempts)
                {
                    // Move to dead letter
                    entry.message.errorReason = "Visibility timeout expired and max attempts reached";
                    m_deadLetters ~= entry.message;
                    entry.inFlight = false;
                    entry.visibleAfterUnix = long.max; // mark inactive
                }
                else
                {
                    string handle = "rcpt_" ~ randomUUID().toString();
                    entry.activeReceiptHandle = handle;
                    entry.visibleAfterUnix = now + visibilityTimeoutSeconds;

                    TaskQueueMessage msg = entry.message;
                    msg.receiptHandle = handle;
                    msg.visibleAfterUnix = entry.visibleAfterUnix;
                    result ~= msg;
                }
            }
        }

        // Cleanup dead letters from active entries
        QueueEntry[] remaining;
        foreach (entry; m_entries)
        {
            if (entry.visibleAfterUnix != long.max)
            {
                remaining ~= entry;
            }
        }
        m_entries = remaining;

        return result;
    }

    override void ack(string receiptHandle)
    {
        QueueEntry[] remaining;
        bool found = false;

        foreach (entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                found = true;
                continue; // removed from queue
            }
            remaining ~= entry;
        }

        if (!found)
        {
            throw new Exception(format("Message with receipt handle '%s' not found or already acknowledged", receiptHandle));
        }

        m_entries = remaining;
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        foreach (ref entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                entry.message.errorReason = errorReason;
                entry.inFlight = false;
                entry.activeReceiptHandle = null;

                if (!requeue || entry.message.attempt >= entry.message.maxAttempts)
                {
                    m_deadLetters ~= entry.message;
                    entry.visibleAfterUnix = long.max; // mark for cleanup
                }
                else
                {
                    entry.message.attempt++;
                    entry.visibleAfterUnix = currentUnixTime(); // make available immediately
                }
                break;
            }
        }

        // Cleanup dead letters
        QueueEntry[] remaining;
        foreach (entry; m_entries)
        {
            if (entry.visibleAfterUnix != long.max)
            {
                remaining ~= entry;
            }
        }
        m_entries = remaining;
    }

    override void heartbeat(string receiptHandle, long extensionSeconds = 30)
    {
        long now = currentUnixTime();
        foreach (ref entry; m_entries)
        {
            if (entry.inFlight && entry.activeReceiptHandle == receiptHandle)
            {
                entry.visibleAfterUnix = now + extensionSeconds;
                return;
            }
        }
        throw new Exception(format("Cannot heartbeat; receipt handle '%s' not found or expired", receiptHandle));
    }

    override TaskQueueMessage[] getDeadLetterMessages()
    {
        return m_deadLetters.dup;
    }

    override ulong getPendingCount()
    {
        long now = currentUnixTime();
        ulong count = 0;
        foreach (entry; m_entries)
        {
            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                count++;
            }
        }
        return count;
    }

    override TaskQueueMessage[] getPendingMessages(size_t limit = 50)
    {
        long now = currentUnixTime();
        TaskQueueMessage[] result;
        foreach (ref entry; m_entries)
        {
            if (!entry.inFlight && entry.visibleAfterUnix <= now)
            {
                result ~= entry.message;
                if (result.length >= limit) break;
            }
        }
        return result;
    }
}

unittest
{
    auto queue = new InMemoryWorkQueue();
    assert(queue.getPendingCount() == 0);

    TaskQueueMessage msg1;
    msg1.taskId = "task_1";
    msg1.buildId = "b1";
    msg1.maxAttempts = 2;

    queue.enqueue(msg1);
    assert(queue.getPendingCount() == 1);

    auto dequeued = queue.dequeue(1, 10);
    assert(dequeued.length == 1);
    assert(dequeued[0].taskId == "task_1");
    assert(dequeued[0].receiptHandle.length > 0);
    assert(queue.getPendingCount() == 0);

    // Heartbeat
    queue.heartbeat(dequeued[0].receiptHandle, 20);

    // Ack
    queue.ack(dequeued[0].receiptHandle);
    assert(queue.getPendingCount() == 0);

    // Test Nack and Dead Lettering
    TaskQueueMessage msg2;
    msg2.taskId = "task_fail";
    msg2.buildId = "b2";
    msg2.maxAttempts = 1;

    queue.enqueue(msg2);
    auto dequeued2 = queue.dequeue(1, 10);
    assert(dequeued2.length == 1);

    queue.nack(dequeued2[0].receiptHandle, true, "Execution failed");
    assert(queue.getPendingCount() == 0);
    assert(queue.getDeadLetterMessages().length == 1);
    assert(queue.getDeadLetterMessages()[0].taskId == "task_fail");
    assert(queue.getDeadLetterMessages()[0].errorReason == "Execution failed");
}
