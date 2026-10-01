module confector.runner.worker;

import confector.core.model;
import confector.core.storage;
import confector.core.executor : TaskRunner;
import confector.runner.engine;
import confector.queue.queue;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath, dirName;
import std.format : format;
import std.datetime.systime : Clock;
import std.uuid : randomUUID;

/**
 * Configuration for worker runner instances.
 */
struct WorkerConfig
{
    string workerId;
    string workspaceDir = ".confector/worker_workspace";
    string storageDir = ".confector/artifacts";
    size_t pollIntervalSeconds = 2;
    size_t visibilityTimeoutSeconds = 60;
    size_t heartbeatIntervalSeconds = 15;
    size_t maxTasksToProcess = 0; // 0 = continuous loop, 1 = single-shot ephemeral container / K8s job
}

/**
 * Worker runner that consumes tasks from WorkQueue and executes them via TaskEngine.
 */
class WorkerRunner
{
    private WorkerConfig m_config;
    private WorkQueue m_queue;
    private TaskEngine m_engine;
    private ArtifactStorage m_storage;
    private BuildStateRepository m_stateRepo;

    this(
        WorkerConfig config,
        WorkQueue queue,
        TaskEngine engine,
        ArtifactStorage storage,
        BuildStateRepository stateRepo
    )
    {
        m_config = config;
        if (m_config.workerId.length == 0)
        {
            m_config.workerId = "worker_" ~ randomUUID().toString();
        }
        m_queue = queue;
        m_engine = engine;
        m_storage = storage;
        m_stateRepo = stateRepo;

        if (!exists(m_config.workspaceDir))
        {
            mkdirRecurse(m_config.workspaceDir);
        }
    }

    /**
     * Attempts to dequeue and process a single task message.
     * Returns true if a task was processed, false if the queue was empty.
     */
    bool processNextTask()
    {
        auto messages = m_queue.dequeue(1, m_config.visibilityTimeoutSeconds);
        if (messages.length == 0)
        {
            return false;
        }

        TaskQueueMessage msg = messages[0];
        string buildId = msg.buildId.length > 0 ? msg.buildId : "build_default";
        string taskId = msg.taskId;

        // Record running status
        m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.running);

        try
        {
            // Prepare workspace & upstream artifacts
            string taskWorkspace = buildPath(m_config.workspaceDir, buildId, taskId);
            if (!exists(taskWorkspace))
            {
                mkdirRecurse(taskWorkspace);
            }

            // Retrieve input artifacts if declared in execution payload
            string[string] upstreamHashes;
            foreach (inputArt; msg.executionPayload.inputArtifacts)
            {
                string targetPath = buildPath(taskWorkspace, inputArt.targetPath);
                if (m_storage.artifactExists(buildId, inputArt.taskId, inputArt.targetPath))
                {
                    m_storage.retrieveArtifact(buildId, inputArt.taskId, inputArt.targetPath, targetPath);
                    ArtifactMetadata meta;
                    if (m_storage.getArtifactMetadata(buildId, inputArt.taskId, inputArt.targetPath, meta))
                    {
                        upstreamHashes[inputArt.targetPath] = meta.sha256;
                    }
                }
            }

            // Construct TaskNode if not fully populated
            TaskNode node = msg.taskNode;
            if (node.id.length == 0)
            {
                node.id = taskId;
                node.name = taskId;
                node.script = msg.executionPayload.script;
                node.environment = msg.executionPayload.environment;
                node.outputs.artifacts = msg.executionPayload.expectedOutputs;
            }

            // Execute task
            auto execResult = m_engine.executeTask(
                buildId,
                node,
                taskWorkspace,
                upstreamHashes,
                false
            );

            if (execResult.status == TaskStatus.succeeded || execResult.status == TaskStatus.cached)
            {
                // Acknowledge task from queue
                m_queue.ack(msg.receiptHandle);
                return true;
            }
            else
            {
                // Negative acknowledge (retry or dead-letter)
                string errorMsg = execResult.errorMessage.length > 0 ? execResult.errorMessage : format("Task failed with exit code %d", execResult.exitCode);
                m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.failed, errorMsg);
                m_queue.nack(msg.receiptHandle, true, errorMsg);
                return true;
            }
        }
        catch (Exception e)
        {
            m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.failed, e.msg);
            m_queue.nack(msg.receiptHandle, true, e.msg);
            return true;
        }
    }

    /**
     * Runs worker execution loop.
     * In single-shot mode (maxTasksToProcess = 1), processes one task and exits.
     */
    size_t runWorkerLoop(bool delegate() shouldStop = null)
    {
        size_t processedCount = 0;

        while (true)
        {
            if (shouldStop !is null && shouldStop())
            {
                break;
            }

            bool processed = processNextTask();
            if (processed)
            {
                processedCount++;
                if (m_config.maxTasksToProcess > 0 && processedCount >= m_config.maxTasksToProcess)
                {
                    break;
                }
            }
            else
            {
                if (m_config.maxTasksToProcess > 0)
                {
                    // Ephemeral container with no ready tasks -> exit
                    break;
                }
                import core.thread : Thread, dur;
                Thread.sleep(dur!"seconds"(m_config.pollIntervalSeconds > 0 ? m_config.pollIntervalSeconds : 1));
            }
        }

        return processedCount;
    }
}

unittest
{
    import confector.core.plugin;
    import plugins.process_runner;
    import std.file : rmdirRecurse;

    if (PluginRegistry.instance.getPluginsOfType!TaskRunner().length == 0)
    {
        PluginRegistry.instance.registerPlugin(new ProcessTaskRunnerPlugin());
    }

    string testDir = "test_worker_runner_env";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);

    auto queue = new InMemoryWorkQueue();
    auto storage = new LocalArtifactStorage(buildPath(testDir, "artifacts"));
    auto stateRepo = new InMemoryBuildStateRepository();
    auto engine = new TaskEngine(storage, stateRepo);

    WorkerConfig config;
    config.workerId = "worker_test_1";
    config.workspaceDir = buildPath(testDir, "workspace");
    config.storageDir = buildPath(testDir, "artifacts");
    config.maxTasksToProcess = 1;

    auto worker = new WorkerRunner(config, queue, engine, storage, stateRepo);

    // Enqueue a successful task
    TaskQueueMessage msg;
    msg.buildId = "bld_work_1";
    msg.taskId = "echo_worker_task";
    version(Windows)
    {
        msg.executionPayload.script = "cmd /c \"echo Worker executed successfully\"";
    }
    else
    {
        msg.executionPayload.script = "echo Worker executed successfully";
    }

    queue.enqueue(msg);
    assert(queue.getPendingCount() == 1);

    // Run single-shot ephemeral worker
    size_t processed = worker.runWorkerLoop();
    assert(processed == 1);
    assert(queue.getPendingCount() == 0);

    TaskStatus status;
    assert(stateRepo.getTaskStatus("bld_work_1", "echo_worker_task", status));
    assert(status == TaskStatus.succeeded);
}
