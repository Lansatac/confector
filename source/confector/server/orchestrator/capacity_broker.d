module confector.orchestrator.capacity_broker;

import confector.core.model;
import confector.core.executor;
import confector.core.queue;
import confector.orchestrator.coordinator;

import core.sync.mutex : Mutex;
import core.time : Duration, seconds, msecs;
import std.algorithm.searching : canFind;
import std.datetime.systime : Clock;
import std.format : format;
import vibe.core.log : logInfo, logError, logWarn, logDebug, logTrace;

/**
 * Server-side capacity broker that inspects queue backlog / demand and delegates
 * compute provisioning to registered ComputeProvisioner plugins (such as LocalProcessProvisioner,
 * ECS provisioner, Kubernetes provisioner, etc.).
 */
class DefaultCapacityBroker : CapacityBroker
{
    private WorkQueue m_workQueue;
    private BuildCoordinator m_coordinator;
    private ComputeProvisioner[] m_provisioners;
    private Mutex m_mutex;

    // Allow one-shot local workers time to start and claim work before spawning
    // another worker for the same still-visible queue backlog.
    this(WorkQueue workQueue, BuildCoordinator coordinator = null)
    {
        this.m_workQueue = workQueue;
        this.m_coordinator = coordinator;
        this.m_mutex = new Mutex();
    }

    void registerProvisioner(ComputeProvisioner provisioner)
    {
        if (provisioner is null)
        {
            logError("[capacity_broker] registerProvisioner called with null provisioner");
            return;
        }
        synchronized (m_mutex)
        {
            m_provisioners ~= provisioner;
            logDebug("[capacity_broker] Registered compute provisioner '%s' (activeInstances=%d, maxCapacity=%d)",
                provisioner.providerType, provisioner.activeInstanceCount, provisioner.maxCapacity);
        }
    }

    @property ComputeProvisioner[] provisioners()
    {
        synchronized (m_mutex)
        {
            return m_provisioners.dup;
        }
    }

    @property size_t activeInstanceCount() const
    {
        size_t total = 0;
        synchronized (m_mutex)
        {
            foreach (prov; m_provisioners)
            {
                total += prov.activeInstanceCount;
            }
        }
        return total;
    }

    @property size_t maxCapacity() const
    {
        size_t total = 0;
        synchronized (m_mutex)
        {
            foreach (prov; m_provisioners)
            {
                total += prov.maxCapacity;
            }
        }
        return total;
    }

    void evaluateDemand()
    {
        if (m_workQueue is null)
        {
            logError("[capacity_broker] evaluateDemand: work queue is null, skipping evaluation");
            return;
        }

        // Inspect pending queue backlog
        TaskQueueMessage[] pending = m_workQueue.getPendingMessages(100);
        if (pending.length == 0)
        {
            return;
        }

        logInfo("[capacity_broker] evaluateDemand: found %d pending queue message(s)", pending.length);

        // Group pending messages by (executorType, requirements) into QueueDemand items
        QueueDemand[string] demandMap;
        foreach (msg; pending)
        {
            string execType = msg.workOrder.executorType.length > 0 ? msg.workOrder.executorType : msg.executorType;
            string reqKey = execType;
            if (msg.workOrder.requirements !is null)
            {
                foreach (k, v; msg.workOrder.requirements)
                {
                    reqKey ~= ";" ~ k ~ "=" ~ v;
                }
            }

            logInfo("[capacity_broker] evaluateDemand: pending msg '%s' (task '%s', build '%s', executorType='%s', reqKey='%s')",
                msg.id, msg.workOrder.taskId, msg.workOrder.buildId, execType, reqKey);

            if (auto p = reqKey in demandMap)
            {
                p.pendingWorkOrderCount++;
            }
            else
            {
                QueueDemand dem;
                dem.executorType = execType;
                dem.requirements = msg.workOrder.requirements.dup;
                dem.pendingWorkOrderCount = 1;
                demandMap[reqKey] = dem;
            }
        }

        logInfo("[capacity_broker] evaluateDemand: grouped into %d distinct demand specification(s)", demandMap.length);

        // For each demand, find matching provisioners and request capacity
        synchronized (m_mutex)
        {
            if (m_provisioners.length == 0)
            {
                logError("[capacity_broker] evaluateDemand: %d pending work order(s) but 0 provisioners registered — builds will not execute.", pending.length);
                logError("[capacity_broker] evaluateDemand: ensure ComputeProvider plugins are loaded and createProvisioner() returns non-null.");
                return;
            }

            foreach (key, demand; demandMap)
            {
                logInfo("[capacity_broker] evaluateDemand: matching provisioners for demand key '%s' (executorType='%s', pendingCount=%d)",
                    key, demand.executorType, demand.pendingWorkOrderCount);

                bool matched = false;
                foreach (prov; m_provisioners)
                {
                    bool canProv = prov.canProvision(demand);
                    logInfo("[capacity_broker] evaluateDemand: provisioner '%s' (active=%d, max=%d) canProvision=%s for '%s'",
                        prov.providerType, prov.activeInstanceCount, prov.maxCapacity, canProv, key);

                    if (canProv)
                    {
                        logInfo("[capacity_broker] evaluateDemand: requesting capacity from provisioner '%s' for %d work order(s)",
                            prov.providerType, demand.pendingWorkOrderCount);
                        prov.requestCapacity(demand);
                        matched = true;
                        break;
                    }
                }

                if (!matched)
                {
                    logWarn("[capacity_broker] evaluateDemand: no registered provisioner could satisfy demand key '%s' (executorType='%s')",
                        key, demand.executorType);
                }
            }
        }
    }
}

unittest
{
    import confector.core.test_storage : InMemoryArtifactStorage, InMemoryBuildStateRepository, InMemoryWorkQueue;

    // Test Mock Provisioner
    class MockProvisioner : ComputeProvisioner
    {
        private string m_type; 
        private size_t m_max;
        private size_t m_active = 0;
        size_t requestedDemandCount = 0;
        QueueDemand lastDemand;

        this(string type, size_t maxCap)
        {
            m_type = type;
            m_max = maxCap;
        }

        @property string providerType() const { return m_type; }
        @property size_t activeInstanceCount() const { return m_active; }
        @property size_t maxCapacity() const { return m_max; }

        bool canProvision(in QueueDemand demand) const
        {
            if (demand.executorType == m_type || (m_type == "local" && (demand.executorType == "local_process" || demand.executorType == "")))
            {
                if (demand.requirements !is null && "gpu" in demand.requirements && m_type != "gpu")
                {
                    return false;
                }
                return true;
            }
            return false;
        }

        void requestCapacity(in QueueDemand demand)
        {
            requestedDemandCount += demand.pendingWorkOrderCount;
            lastDemand.executorType = demand.executorType;
            lastDemand.pendingWorkOrderCount = demand.pendingWorkOrderCount;
            lastDemand.requirements = demand.requirements.dup;
            m_active += demand.pendingWorkOrderCount;
            if (m_active > m_max) m_active = m_max;
        }
    }

    auto queue = new InMemoryWorkQueue();
    auto broker = new DefaultCapacityBroker(queue);

    auto localProv = new MockProvisioner("local", 4);
    auto gpuProv = new MockProvisioner("gpu", 2);

    broker.registerProvisioner(localProv);
    broker.registerProvisioner(gpuProv);

    assert(broker.provisioners.length == 2);
    assert(broker.maxCapacity == 6);
    assert(broker.activeInstanceCount == 0);

    // Enqueue 2 local tasks, 1 gpu task, 1 kubernetes task
    TaskQueueMessage msg1;
    msg1.id = "m1";
    msg1.workOrder.executorType = "local";
    queue.enqueue(msg1);

    TaskQueueMessage msg2;
    msg2.id = "m2";
    msg2.workOrder.executorType = "local_process";
    queue.enqueue(msg2);

    TaskQueueMessage msgGpu;
    msgGpu.id = "m3";
    msgGpu.workOrder.executorType = "gpu";
    msgGpu.workOrder.requirements = ["gpu": "true"];
    queue.enqueue(msgGpu);

    TaskQueueMessage msgK8s;
    msgK8s.id = "m4";
    msgK8s.workOrder.executorType = "kubernetes";
    queue.enqueue(msgK8s);

    assert(queue.getPendingCount() == 4);

    // Evaluate demand
    broker.evaluateDemand();

    // Verify local provisioner handled 2 local tasks
    assert(localProv.requestedDemandCount == 2);
    assert(localProv.activeInstanceCount == 2);

    // Verify gpu provisioner handled 1 gpu task
    assert(gpuProv.requestedDemandCount == 1);
    assert(gpuProv.activeInstanceCount == 1);

    // Total active across broker
    assert(broker.activeInstanceCount == 3);

    // 2. End-to-end integration: BuildCoordinator + WorkQueue + DefaultCapacityBroker
    auto storage = new InMemoryArtifactStorage();
    auto stateRepo = new InMemoryBuildStateRepository();
    auto e2eQueue = new InMemoryWorkQueue();
    auto coord = new BuildCoordinator(storage, stateRepo, e2eQueue);
    auto e2eBroker = new DefaultCapacityBroker(e2eQueue, coord);

    // Provisioner that acts as an automated executor worker
    class AutoExecutingProvisioner : ComputeProvisioner
    {
        private WorkQueue m_q;
        private BuildCoordinator m_coord;
        private size_t m_active = 0;

        this(WorkQueue q, BuildCoordinator c)
        {
            m_q = q;
            m_coord = c;
        }

        @property string providerType() const { return "local"; }
        @property size_t activeInstanceCount() const { return m_active; }
        @property size_t maxCapacity() const { return 4; }

        bool canProvision(in QueueDemand demand) const
        {
            return demand.executorType == "local" || demand.executorType == "local_process" || demand.executorType == "";
        }

        void requestCapacity(in QueueDemand demand)
        {
            auto msgs = m_q.dequeue(demand.pendingWorkOrderCount, 30, ["local", "local_process", ""]);
            foreach (msg; msgs)
            {
                TaskExecutionResult res;
                res.taskId = msg.taskId;
                res.buildId = msg.buildId;
                res.status = TaskStatus.succeeded;
                res.fingerprint = msg.nodeFingerprint.length > 0 ? msg.nodeFingerprint : "fp_" ~ msg.taskId;
                m_coord.onTaskCompleted(msg.buildId, msg.taskId, res);
                m_q.ack(msg.receiptHandle);
            }
        }
    }

    auto autoProv = new AutoExecutingProvisioner(e2eQueue, coord);
    e2eBroker.registerProvisioner(autoProv);

    // Build DAG: Step1 -> (Step2A, Step2B) -> Step3
    TaskNode step1; step1.id = "step1";
    step1.steps = [BuildStep("Step1", "bash", null, "echo step 1")];
    TaskNode step2A; step2A.id = "step2A"; step2A.dependsOn = ["step1"];
    step2A.steps = [BuildStep("Step2A", "bash", null, "echo step 2A")];
    TaskNode step2B; step2B.id = "step2B"; step2B.dependsOn = ["step1"];
    step2B.steps = [BuildStep("Step2B", "bash", null, "echo step 2B")];
    TaskNode step3; step3.id = "step3"; step3.dependsOn = ["step2A", "step2B"];
    step3.steps = [BuildStep("Step3", "bash", null, "echo step 3")] ;

    ProjectRecord dagProj;
    dagProj.id = "dag_proj";
    dagProj.tasks = [step1, step2A, step2B, step3];

    string buildId = coord.startBuild(dagProj, null, true);
    assert(buildId.length > 0);

    // Initial demand: step1
    assert(e2eQueue.getPendingCount() == 1);
    e2eBroker.evaluateDemand();

    // After step1 completes, step2A and step2B are unblocked and enqueued
    assert(e2eQueue.getPendingCount() == 2);
    e2eBroker.evaluateDemand();

    // After step2A & step2B complete, step3 is unblocked and enqueued
    assert(e2eQueue.getPendingCount() == 1);
    e2eBroker.evaluateDemand();

    // All steps done
    assert(e2eQueue.getPendingCount() == 0);
    BuildRecord finalBuild;
    assert(stateRepo.getBuild(buildId, finalBuild));
    assert(finalBuild.status == "succeeded");
    assert(finalBuild.executedTasks.length == 4);
}
