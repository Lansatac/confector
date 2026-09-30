module confector.queue.cloud_queue;

import confector.queue.queue;
import confector.core.model;

import vibe.data.json;
import vibe.data.serialization : asName = name;

import std.format : format;
import std.datetime.systime : Clock;

/**
 * Configuration for cloud message queue providers (e.g. cloud pub/sub, webhook queues).
 */
struct CloudQueueConfig
{
    @asName("endpoint_url") string endpointUrl;
    @asName("queue_name") string queueName;
    @asName("auth_token") string authToken;
    @asName("visibility_timeout_seconds") size_t visibilityTimeoutSeconds = 30;
    @asName("max_attempts") int maxAttempts = 3;
}

/**
 * Interface for cloud queue transport providers (e.g., HTTP REST broker, SQS-compatible gateway).
 */
interface CloudQueueTransport
{
    void sendPayload(string endpoint, string payloadJson);
    string receivePayload(string endpoint, size_t maxMessages, long visibilityTimeout);
    void deleteMessage(string endpoint, string receiptHandle);
    void updateVisibility(string endpoint, string receiptHandle, long extensionSeconds);
    void nackMessage(string endpoint, string receiptHandle, bool requeue, string errorReason);
}

/**
 * Generic cloud message queue driver implementing WorkQueue.
 */
class CloudWorkQueue : WorkQueue
{
    private CloudQueueConfig m_config;
    private CloudQueueTransport m_transport;
    private WorkQueue m_localFallbackQueue;

    this(CloudQueueConfig config, CloudQueueTransport transport = null)
    {
        m_config = config;
        m_transport = transport;
        m_localFallbackQueue = new InMemoryWorkQueue();
    }

    override void enqueue(TaskQueueMessage message)
    {
        if (m_transport !is null && m_config.endpointUrl.length > 0)
        {
            m_transport.sendPayload(m_config.endpointUrl, serializeToJsonString(message));
        }
        else
        {
            m_localFallbackQueue.enqueue(message);
        }
    }

    override TaskQueueMessage[] dequeue(size_t maxMessages = 1, long visibilityTimeoutSeconds = 30)
    {
        if (m_transport !is null && m_config.endpointUrl.length > 0)
        {
            string resp = m_transport.receivePayload(m_config.endpointUrl, maxMessages, visibilityTimeoutSeconds);
            if (resp.length == 0)
            {
                return [];
            }
            Json parsed = parseJsonString(resp);
            return deserializeJson!(TaskQueueMessage[])(parsed);
        }
        else
        {
            return m_localFallbackQueue.dequeue(maxMessages, visibilityTimeoutSeconds);
        }
    }

    override void ack(string receiptHandle)
    {
        if (m_transport !is null && m_config.endpointUrl.length > 0)
        {
            m_transport.deleteMessage(m_config.endpointUrl, receiptHandle);
        }
        else
        {
            m_localFallbackQueue.ack(receiptHandle);
        }
    }

    override void nack(string receiptHandle, bool requeue = true, string errorReason = null)
    {
        if (m_transport !is null && m_config.endpointUrl.length > 0)
        {
            m_transport.nackMessage(m_config.endpointUrl, receiptHandle, requeue, errorReason);
        }
        else
        {
            m_localFallbackQueue.nack(receiptHandle, requeue, errorReason);
        }
    }

    override void heartbeat(string receiptHandle, long extensionSeconds = 30)
    {
        if (m_transport !is null && m_config.endpointUrl.length > 0)
        {
            m_transport.updateVisibility(m_config.endpointUrl, receiptHandle, extensionSeconds);
        }
        else
        {
            m_localFallbackQueue.heartbeat(receiptHandle, extensionSeconds);
        }
    }

    override TaskQueueMessage[] getDeadLetterMessages()
    {
        return m_localFallbackQueue.getDeadLetterMessages();
    }

    override ulong getPendingCount()
    {
        return m_localFallbackQueue.getPendingCount();
    }
}

unittest
{
    CloudQueueConfig config;
    config.queueName = "build-tasks";
    config.endpointUrl = ""; // fallback to in-memory

    auto cloudQueue = new CloudWorkQueue(config);
    TaskQueueMessage msg;
    msg.taskId = "cloud_task_1";
    msg.buildId = "bld_cloud";

    cloudQueue.enqueue(msg);
    assert(cloudQueue.getPendingCount() == 1);

    auto dequeued = cloudQueue.dequeue(1, 15);
    assert(dequeued.length == 1);
    assert(dequeued[0].taskId == "cloud_task_1");

    cloudQueue.heartbeat(dequeued[0].receiptHandle, 30);
    cloudQueue.ack(dequeued[0].receiptHandle);
    assert(cloudQueue.getPendingCount() == 0);
}
