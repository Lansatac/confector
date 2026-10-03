module confector.runner.worker;

import confector.core.model;
import confector.core.storage;
import confector.core.executor : TaskRunner;
import confector.runner.engine;
import confector.queue.queue;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath, dirName;
import std.format : format;
import std.algorithm.searching : canFind;
import std.datetime.systime : Clock;
import std.uuid : randomUUID;
import vibe.core.log : logInfo, logError, logWarn, logDebug;

/**
 * Delegate callback type for notifying build coordinator of task completions.
 */
alias TaskCompletionHandler = void delegate(string buildId, string taskId, TaskExecutionResult result);

/**
 * Configuration for worker runner instances.
 */
struct WorkerConfig
{
    string workerId;
    string workspaceDir = ".confector/worker_workspace";
    string storageDir = ".confector/artifacts";
    string callbackBaseUrl;
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
    private TaskCompletionHandler m_completionHandler;

    this(
        WorkerConfig config,
        WorkQueue queue,
        TaskEngine engine,
        ArtifactStorage storage,
        BuildStateRepository stateRepo = null,
        TaskCompletionHandler completionHandler = null
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
        m_completionHandler = completionHandler;

        if (!exists(m_config.workspaceDir))
        {
            mkdirRecurse(m_config.workspaceDir);
        }
    }

    @property TaskCompletionHandler completionHandler() { return m_completionHandler; }
    @property void completionHandler(TaskCompletionHandler handler) { m_completionHandler = handler; }

    /**
     * Attempts to dequeue and process a single task message.
     * Returns true if a task was processed, false if the queue was empty.
     */
    bool processNextTask()
    {
        TaskQueueMessage[] messages;
        try
        {
            messages = m_queue.dequeue(1, m_config.visibilityTimeoutSeconds);
        }
        catch (Exception e)
        {
            logError("[worker:%s] Error dequeuing task from work queue: %s\n%s", m_config.workerId, e.msg, e.toString());
            return false;
        }

        if (messages.length == 0)
        {
            return false;
        }

        TaskQueueMessage msg = messages[0];
        string buildId = msg.buildId.length > 0 ? msg.buildId : "build_default";
        string taskId = msg.taskId;

        logInfo("[worker:%s] Picked up task '%s' for build '%s' (messageId: '%s', receipt: '%s')", m_config.workerId, taskId, buildId, msg.messageId, msg.receiptHandle);

        // Record running status if repository is available
        if (m_stateRepo !is null)
        {
            m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.running);
        }

        try
        {
            // Prepare workspace
            string taskWorkspace = buildPath(m_config.workspaceDir, buildId, taskId);
            if (!exists(taskWorkspace))
            {
                mkdirRecurse(taskWorkspace);
            }
            logInfo("[worker:%s] Task '%s' workspace prepared at '%s'", m_config.workerId, taskId, taskWorkspace);

            import confector.core.zip_packager : ZipPackager;
            import std.array : Appender;

            // Authoritative upstream fingerprints (taskId -> fingerprint) from coordinator
            string[string] upstreamFingerprints;
            if (msg.executionPayload.upstreamArtifactHashes !is null)
            {
                foreach (k, v; msg.executionPayload.upstreamArtifactHashes)
                {
                    upstreamFingerprints[k] = v;
                }
            }

            // Single authoritative upstream staging path: payload.inputArtifacts only
            foreach (inputArt; msg.executionPayload.inputArtifacts)
            {
                string upFp = inputArt.taskFingerprint;
                if (upFp.length == 0 && inputArt.taskId in upstreamFingerprints)
                {
                    upFp = upstreamFingerprints[inputArt.taskId];
                }
                string artId = inputArt.artifactId;
                if (artId.length == 0)
                {
                    throw new Exception(format("Input artifact for upstream task '%s' is missing artifactId", inputArt.taskId));
                }
                // Empty destination => unpack into workspace root
                string targetPath = inputArt.destination.length > 0
                    ? buildPath(taskWorkspace, inputArt.destination)
                    : taskWorkspace;

                if (m_storage is null)
                {
                    throw new Exception("ArtifactStorage is null but task requires upstream artifacts");
                }
                if (upFp.length == 0 || !m_storage.artifactExists(upFp, artId))
                {
                    throw new Exception(format(
                        "Missing upstream artifact '%s' from task '%s' (fingerprint: %s)",
                        artId, inputArt.taskId, upFp.length > 0 ? upFp : "<unknown>"));
                }

                Appender!(ubyte[]) zipBuf;
                m_storage.retrieveArtifactStream(upFp, artId, (const(ubyte)[] chunk) {
                    zipBuf.put(chunk);
                });
                ZipPackager.unpack(zipBuf.data, targetPath);
                logInfo("[worker:%s] Task '%s' unpacked upstream artifact '%s' (fp: %s) to '%s'",
                    m_config.workerId, taskId, artId, upFp, targetPath);
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
            // Ensure expected outputs are present on the node for packaging
            if (node.outputs.artifacts.length == 0 && msg.executionPayload.expectedOutputs.length > 0)
            {
                node.outputs.artifacts = msg.executionPayload.expectedOutputs.dup;
            }

            logInfo("[worker:%s] Task '%s': executing via TaskEngine (%d steps, script length: %d)", m_config.workerId, taskId, node.steps.length, node.script.length);

            string[] allowedRepos = msg.executionPayload.allowedRepositories.dup;
            if (msg.executionPayload.repositoryUrl.length > 0 && !allowedRepos.canFind(msg.executionPayload.repositoryUrl))
            {
                allowedRepos ~= msg.executionPayload.repositoryUrl;
            }

            // Coordinator/graph fingerprint is authoritative
            string effectiveFingerprint = msg.nodeFingerprint.length > 0
                ? msg.nodeFingerprint
                : msg.executionPayload.nodeFingerprint;

            // Execute steps only — worker owns artifact staging/packaging
            auto execResult = m_engine.executeTask(
                buildId,
                node,
                taskWorkspace,
                upstreamFingerprints,
                msg.executionPayload.force,
                null,
                allowedRepos,
                msg.executionPayload.repositoryMap,
                effectiveFingerprint,
                false // manageArtifacts=false: pure execution helper
            );

            if (effectiveFingerprint.length > 0 && effectiveFingerprint != "unknown")
            {
                execResult.fingerprint = effectiveFingerprint;
            }
            else
            {
                effectiveFingerprint = execResult.fingerprint;
            }

            // Package and store declared outputs once, keyed by coordinator fingerprint
            if (execResult.status == TaskStatus.succeeded)
            {
                ArtifactMetadata[] producedArtifacts;
                if (m_storage !is null && effectiveFingerprint.length > 0 && effectiveFingerprint != "unknown")
                {
                    OutputArtifactDecl[] outputs = node.outputs.artifacts;
                    if (outputs.length == 0)
                    {
                        outputs = msg.executionPayload.expectedOutputs;
                    }

                    foreach (artDecl; outputs)
                    {
                        string artId = artDecl.effectiveId;
                        string artPath = artDecl.effectivePath;

                        m_storage.storeArtifactStream(effectiveFingerprint, artId, (void delegate(const(ubyte)[]) sink) {
                            ZipPackager.pack(taskWorkspace, artPath, sink);
                        });

                        ArtifactMetadata meta;
                        meta.artifactId = artId;
                        meta.taskFingerprint = effectiveFingerprint;
                        meta.buildId = buildId;
                        meta.taskId = taskId;
                        meta.filePath = artPath;
                        meta.storageBackend = "local";
                        meta.storageUri = format(".confector/artifacts/%s/%s.zip", effectiveFingerprint, artId);
                        meta.createdAt = Clock.currTime.toISOString();
                        producedArtifacts ~= meta;

                        logInfo("[worker:%s] Packaged output artifact '%s' (ID: %s, fp: %s)",
                            m_config.workerId, artPath, artId, effectiveFingerprint);
                    }
                }

                execResult.producedArtifacts = producedArtifacts;

                if (m_stateRepo !is null && effectiveFingerprint.length > 0 && effectiveFingerprint != "unknown")
                {
                    m_stateRepo.saveCachedFingerprint(taskId, effectiveFingerprint, producedArtifacts);
                }
            }

            if (execResult.status == TaskStatus.succeeded || execResult.status == TaskStatus.cached)
            {
                logInfo("[worker:%s] Task '%s' (build '%s') %s in %d ms", m_config.workerId, taskId, buildId, execResult.status == TaskStatus.cached ? "resolved from cache" : "succeeded", execResult.durationMs);
                m_queue.ack(msg.receiptHandle);
                notifyCompletion(msg, execResult);
                return true;
            }
            else
            {
                string errorMsg = execResult.errorMessage.length > 0 ? execResult.errorMessage : format("Task failed with exit code %d", execResult.exitCode);
                logWarn("[worker:%s] Task '%s' (build '%s') failed with exit code %d: %s", m_config.workerId, taskId, buildId, execResult.exitCode, errorMsg);
                if (m_stateRepo !is null)
                {
                    m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.failed, errorMsg);
                }
                notifyCompletion(msg, execResult);
                m_queue.nack(msg.receiptHandle, false, errorMsg);
                return true;
            }
        }
        catch (Exception e)
        {
            logError("[worker:%s] Task '%s' (build '%s') encountered error: %s\n%s", m_config.workerId, taskId, buildId, e.msg, e.toString());
            TaskExecutionResult failResult;
            failResult.buildId = buildId;
            failResult.taskId = taskId;
            failResult.status = TaskStatus.failed;
            failResult.errorMessage = e.msg;

            if (m_stateRepo !is null)
            {
                m_stateRepo.setTaskStatus(buildId, taskId, TaskStatus.failed, e.msg);
            }
            notifyCompletion(msg, failResult);
            m_queue.nack(msg.receiptHandle, false, e.msg);
            return true;
        }
    }

    private void notifyCompletion(in TaskQueueMessage msg, in TaskExecutionResult result)
    {
        if (m_completionHandler !is null)
        {
            try
            {
                m_completionHandler(msg.buildId, msg.taskId, cast(TaskExecutionResult)result);
            }
            catch (Exception e)
            {
                logWarn("Error in worker completion handler: %s", e.msg);
            }
        }

        string callbackUrl = msg.executionPayload.callbackUrl;
        if (callbackUrl.length == 0 && m_config.callbackBaseUrl.length > 0)
        {
            callbackUrl = format("%s/api/v1/builds/%s/tasks/%s/complete", m_config.callbackBaseUrl, msg.buildId, msg.taskId);
        }

        if (callbackUrl.length > 0)
        {
            try
            {
                import vibe.http.client : requestHTTP, HTTPMethod;
                import vibe.inet.url : URL;

                requestHTTP(URL(callbackUrl), (scope req) {
                    req.method = HTTPMethod.POST;
                    req.writeJsonBody(result);
                }, (scope res) {
                    // completion received
                });
            }
            catch (Exception e)
            {
                logWarn("Failed to send HTTP completion callback to %s: %s", callbackUrl, e.msg);
            }
        }
    }

    /**
     * Runs worker execution loop.
     * In single-shot mode (maxTasksToProcess = 1), processes one task and exits.
     */
    size_t runWorkerLoop(bool delegate() shouldStop = null)
    {
        size_t processedCount = 0;
        logInfo("[worker:%s] Background worker started, polling queue every %ds", m_config.workerId, m_config.pollIntervalSeconds > 0 ? m_config.pollIntervalSeconds : 1);

        while (true)
        {
            if (shouldStop !is null && shouldStop())
            {
                break;
            }

            try
            {
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
                    import vibe.core.core : sleep;
                    import core.time : dur;
                    sleep(dur!"seconds"(m_config.pollIntervalSeconds > 0 ? m_config.pollIntervalSeconds : 1));
                }
            }
            catch (Exception e)
            {
                logError("[worker:%s] Unexpected error in worker loop: %s", m_config.workerId, e.msg);
                import vibe.core.core : sleep;
                import core.time : dur;
                sleep(dur!"seconds"(m_config.pollIntervalSeconds > 0 ? m_config.pollIntervalSeconds : 1));
            }
        }

        return processedCount;
    }
}

unittest
{
    import confector.core.plugin;
    import confector.core.system : TaskExecutionSystem;
    import confector.core.executor : TaskRunner, ExecutionRequest, ExecutionResult, LogDelegate;
    import std.file : rmdirRecurse;
    import std.process : pipeShell, Redirect, Config, wait;

    class MockWorkerTaskRunnerPlugin : Plugin, TaskRunner, TaskExecutionSystem
    {
        @property string name() const { return "mock-worker-runner"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock worker task runner"; }
        @property string runnerType() const { return "process"; }
        @property string systemName() const { return "mock-worker-system"; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        bool canExecute(in ExecutionRequest request) const { return true; }
        bool canExecute(in TaskNode task) const { return true; }

        ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
        {
            ExecutionResult res;
            try
            {
                auto pipe = pipeShell(request.command, Redirect.stdout | Redirect.stderrToStdout, request.environmentVariables.length > 0 ? request.environmentVariables : null, Config.retainStderr, request.workingDirectory);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (logCallback !is null) logCallback(line);
                }
                res.exitCode = wait(pipe.pid);
                res.success = (res.exitCode == 0);
            }
            catch (Exception e)
            {
                res.exitCode = -1;
                res.success = false;
                res.errorMessage = e.msg;
            }
            return res;
        }

        ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null)
        {
            ExecutionResult res;
            try
            {
                auto pipe = pipeShell(task.script, Redirect.stdout | Redirect.stderrToStdout, null, Config.retainStderr, request.workingDirectory);
                foreach (line; pipe.stdout.byLineCopy)
                {
                    res.outputLines ~= line;
                    if (logCallback !is null) logCallback(line);
                }
                res.exitCode = wait(pipe.pid);
                res.success = (res.exitCode == 0);
            }
            catch (Exception e)
            {
                res.exitCode = -1;
                res.success = false;
                res.errorMessage = e.msg;
            }
            return res;
        }
    }

    if (PluginRegistry.instance.getPluginsOfType!TaskRunner().length == 0)
    {
        PluginRegistry.instance.registerPlugin(new MockWorkerTaskRunnerPlugin());
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

    // Multi-Worker Parallel DAG Integration Test with BuildCoordinator
    import confector.runner.coordinator : BuildCoordinator;

    auto coord = new BuildCoordinator(storage, stateRepo, queue);

    WorkerConfig w1Config;
    w1Config.workerId = "worker_parallel_1";
    w1Config.workspaceDir = buildPath(testDir, "w1_workspace");
    auto worker1 = new WorkerRunner(w1Config, queue, engine, storage, stateRepo, (bId, tId, res) {
        coord.onTaskCompleted(bId, tId, res);
    });

    WorkerConfig w2Config;
    w2Config.workerId = "worker_parallel_2";
    w2Config.workspaceDir = buildPath(testDir, "w2_workspace");
    auto worker2 = new WorkerRunner(w2Config, queue, engine, storage, stateRepo, (bId, tId, res) {
        coord.onTaskCompleted(bId, tId, res);
    });

    TaskNode rootT;
    rootT.id = "root";
    version(Windows) rootT.script = "cmd /c \"echo root done\"";
    else rootT.script = "echo root done";

    TaskNode parA;
    parA.id = "parA";
    parA.dependsOn = ["root"];
    version(Windows) parA.script = "cmd /c \"echo parA done\"";
    else parA.script = "echo parA done";

    TaskNode parB;
    parB.id = "parB";
    parB.dependsOn = ["root"];
    version(Windows) parB.script = "cmd /c \"echo parB done\"";
    else parB.script = "echo parB done";

    TaskNode finalT;
    finalT.id = "final";
    finalT.dependsOn = ["parA", "parB"];
    version(Windows) finalT.script = "cmd /c \"echo final done\"";
    else finalT.script = "echo final done";

    ProjectRecord parProj;
    parProj.id = "proj_par";
    parProj.tasks = [rootT, parA, parB, finalT];

    string parBuildId = coord.startBuild(parProj, null, true);

    // Worker 1 processes root
    assert(worker1.processNextTask());

    // Now parA and parB are both queued
    assert(queue.getPendingCount() == 2);

    // Worker 1 processes parA, Worker 2 processes parB
    assert(worker1.processNextTask());
    assert(worker2.processNextTask());

    // Both parallel tasks finished -> final task is now queued
    assert(queue.getPendingCount() == 1);

    // Worker 2 processes final
    assert(worker2.processNextTask());
    assert(queue.getPendingCount() == 0);

    BuildRecord parBuildRec;
    assert(stateRepo.getBuild(parBuildId, parBuildRec));
    assert(parBuildRec.status == "succeeded");
    assert(parBuildRec.executedTasks.length == 4);

    // End-to-End Zip Stream Pipeline with counting storage (detects double pack/unpack)
    class CountingArtifactStorage : LocalArtifactStorage
    {
        int storeStreamCount;
        int retrieveStreamCount;
        int legacyStoreCount;
        int legacyRetrieveCount;
        string[] storeKeys;
        string[] retrieveKeys;

        this(string baseDir) { super(baseDir); }

        override void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
        {
            storeStreamCount++;
            storeKeys ~= taskFingerprint ~ "/" ~ artifactId;
            super.storeArtifactStream(taskFingerprint, artifactId, writer);
        }

        override void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
        {
            retrieveStreamCount++;
            retrieveKeys ~= taskFingerprint ~ "/" ~ artifactId;
            super.retrieveArtifactStream(taskFingerprint, artifactId, sink);
        }

        override ArtifactMetadata storeArtifact(string buildId, string taskId, string localFilePath, string artifactType = "file")
        {
            legacyStoreCount++;
            return super.storeArtifact(buildId, taskId, localFilePath, artifactType);
        }

        override void retrieveArtifact(string buildId, string taskId, string artifactPath, string targetLocalPath)
        {
            legacyRetrieveCount++;
            super.retrieveArtifact(buildId, taskId, artifactPath, targetLocalPath);
        }
    }

    auto countStorage = new CountingArtifactStorage(buildPath(testDir, "stream_artifacts"));
    auto streamState = new InMemoryBuildStateRepository();
    auto streamEngine = new TaskEngine(countStorage, streamState);
    auto streamQueue = new InMemoryWorkQueue();
    auto streamCoord = new BuildCoordinator(countStorage, streamState, streamQueue);

    WorkerConfig streamWConfig;
    streamWConfig.workerId = "worker_stream_e2e";
    streamWConfig.workspaceDir = buildPath(testDir, "stream_workspace");
    auto streamWorker = new WorkerRunner(streamWConfig, streamQueue, streamEngine, countStorage, streamState, (bId, tId, res) {
        streamCoord.onTaskCompleted(bId, tId, res);
    });

    TaskNode prodNode;
    prodNode.id = "producer";
    version(Windows)
    {
        prodNode.script = "cmd /c \"if not exist dist\\sub mkdir dist\\sub && echo hello-prod > dist\\file1.txt && echo nested-prod > dist\\sub\\file2.txt\"";
    }
    else
    {
        prodNode.script = "mkdir -p dist/sub && echo hello-prod > dist/file1.txt && echo nested-prod > dist/sub/file2.txt";
    }
    prodNode.outputs.artifacts = [OutputArtifactDecl("dist", "dist/*")];

    TaskNode consNode;
    consNode.id = "consumer";
    consNode.dependsOn = ["producer"];
    consNode.inputs.upstreamArtifacts = [UpstreamArtifactRef("producer", "dist", "imported_dist")];
    version(Windows)
    {
        consNode.script = "cmd /c \"type imported_dist\\dist\\file1.txt && type imported_dist\\dist\\sub\\file2.txt && if not exist out mkdir out && echo consumed-success > out\\final.txt\"";
    }
    else
    {
        consNode.script = "test -f imported_dist/dist/file1.txt && test -f imported_dist/dist/sub/file2.txt && mkdir -p out && echo consumed-success > out/final.txt";
    }
    consNode.outputs.artifacts = [OutputArtifactDecl("final_out", "out/*")];

    ProjectRecord streamProj;
    streamProj.id = "proj_stream_e2e";
    streamProj.tasks = [prodNode, consNode];

    // Precompute expected graph fingerprints for alignment assertions
    import confector.core.dag : TaskGraph;
    auto expectedGraph = new TaskGraph(streamProj.tasks);
    string expectedProdFp = expectedGraph.getFingerprint("producer");
    string expectedConsFp = expectedGraph.getFingerprint("consumer");

    string streamBuildId = streamCoord.startBuild(streamProj, null, true);

    // 1. Process producer
    assert(streamQueue.getPendingCount() == 1);
    assert(streamWorker.processNextTask());

    // Producer finished -> consumer queued
    assert(streamQueue.getPendingCount() == 1);

    // Inspect consumer queue message without consuming it: single inputArtifacts, no dual locations
    {
        auto pending = streamQueue.getPendingMessages(1);
        assert(pending.length == 1);
        auto consMsg = pending[0];
        assert(consMsg.nodeFingerprint == expectedConsFp);
        assert(consMsg.executionPayload.nodeFingerprint == expectedConsFp);
        assert(consMsg.executionPayload.inputArtifacts.length == 1);
        assert(consMsg.executionPayload.upstreamArtifactLocations.length == 0);
        assert(consMsg.executionPayload.inputArtifacts[0].artifactId == "dist");
        assert(consMsg.executionPayload.inputArtifacts[0].taskFingerprint == expectedProdFp);
        assert(consMsg.executionPayload.inputArtifacts[0].destination == "imported_dist");
        assert(consMsg.executionPayload.upstreamArtifactHashes.get("producer", "") == expectedProdFp);
    }

    // Producer result: fingerprint matches graph, single stream store, no legacy
    TaskExecutionRecord prodRec;
    assert(streamState.getTaskExecution(streamBuildId, "producer", prodRec));
    assert(prodRec.fingerprint == expectedProdFp);
    assert(countStorage.artifactExists(expectedProdFp, "dist"));
    assert(countStorage.storeStreamCount == 1);
    assert(countStorage.retrieveStreamCount == 0);
    assert(countStorage.legacyStoreCount == 0);
    assert(countStorage.legacyRetrieveCount == 0);
    assert(countStorage.storeKeys == [expectedProdFp ~ "/dist"]);

    // 2. Worker processes consumer
    assert(streamWorker.processNextTask());
    assert(streamQueue.getPendingCount() == 0);

    TaskExecutionRecord consRec;
    assert(streamState.getTaskExecution(streamBuildId, "consumer", consRec));
    assert(consRec.fingerprint == expectedConsFp);
    assert(countStorage.artifactExists(expectedConsFp, "final_out"));

    // Exactly one retrieve (consumer unpack) and one additional store (consumer pack) — no duplication
    assert(countStorage.retrieveStreamCount == 1);
    assert(countStorage.storeStreamCount == 2);
    assert(countStorage.legacyStoreCount == 0);
    assert(countStorage.legacyRetrieveCount == 0);
    assert(countStorage.retrieveKeys == [expectedProdFp ~ "/dist"]);
    assert(countStorage.storeKeys == [expectedProdFp ~ "/dist", expectedConsFp ~ "/final_out"]);

    // producedArtifacts metadata uses coordinator fingerprints
    assert(prodRec.producedArtifacts.length == 1);
    assert(prodRec.producedArtifacts[0].taskFingerprint == expectedProdFp);
    assert(prodRec.producedArtifacts[0].artifactId == "dist");
    assert(consRec.producedArtifacts.length == 1);
    assert(consRec.producedArtifacts[0].taskFingerprint == expectedConsFp);
    assert(consRec.producedArtifacts[0].artifactId == "final_out");

    BuildRecord streamBuildRec;
    assert(streamState.getBuild(streamBuildId, streamBuildRec));
    assert(streamBuildRec.status == "succeeded");
    assert(streamBuildRec.executedTasks.length == 2);

    // 3. Cache Hit Subgraph Short-Circuiting
    int storesBeforeCache = countStorage.storeStreamCount;
    int retrievesBeforeCache = countStorage.retrieveStreamCount;
    string cachedBuildId = streamCoord.startBuild(streamProj, null, false);
    assert(streamQueue.getPendingCount() == 0);
    BuildRecord cachedBuildRec;
    assert(streamState.getBuild(cachedBuildId, cachedBuildRec));
    assert(cachedBuildRec.status == "cached");
    // Cache hit must not touch storage streams
    assert(countStorage.storeStreamCount == storesBeforeCache);
    assert(countStorage.retrieveStreamCount == retrievesBeforeCache);
}
