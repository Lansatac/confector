module confector.core.queue;

/// Re-export WorkQueue and all domain models from plugin_api for backward compatibility.
/// All types defined here are now owned by plugin_api.model; this module exists solely
/// to maintain backward compatibility for existing import paths.
public import confector.plugin_api.model : WorkQueue, TaskQueueMessage, WorkOrder, TaskExecutionPayload, InputArtifactRef;

unittest
{
    import confector.core.test_storage : InMemoryWorkQueue;
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

    // Test Executor Capability Filtering on Dequeue
    auto tagQueue = new InMemoryWorkQueue();
    TaskQueueMessage localTask;
    localTask.taskId = "local_task";
    localTask.workOrder.executorType = "local";
    tagQueue.enqueue(localTask);

    TaskQueueMessage gpuTask;
    gpuTask.taskId = "gpu_task";
    gpuTask.workOrder.executorType = "gpu";
    tagQueue.enqueue(gpuTask);

    assert(tagQueue.getPendingCount() == 2);

    // Filter for local executor only
    auto localClaimed = tagQueue.dequeue(10, 30, ["local"]);
    assert(localClaimed.length == 1);
    assert(localClaimed[0].taskId == "local_task");

    // GPU task remains untouched in queue (not claimed, not nacked)
    assert(tagQueue.getPendingCount() == 1);

    // Remote GPU worker can claim its task
    auto gpuClaimed = tagQueue.dequeue(10, 30, ["gpu"]);
    assert(gpuClaimed.length == 1);
    assert(gpuClaimed[0].taskId == "gpu_task");
    assert(gpuClaimed[0].attempt == 1);
}
