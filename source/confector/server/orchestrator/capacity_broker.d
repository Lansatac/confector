module confector.orchestrator.capacity_broker;

import confector.core.model;
import confector.core.executor;

import core.sync.mutex : Mutex;
import core.time : Duration, seconds, msecs;
import std.algorithm.searching : canFind;
import std.datetime.systime : Clock;
import std.format : format;
import vibe.core.log : logInfo, logError, logWarn, logDebug, logTrace;

/**
 * Server-side capacity broker that inspects outstanding work demand and delegates
 * compute provisioning to registered ComputeProvisioner plugins (such as LocalProcessProvisioner,
 * ECS provisioner, Kubernetes provisioner, etc.).
 */
class DefaultCapacityBroker : CapacityBroker
{
    private QueueDemand[] delegate() m_demandSource;
    private ComputeProvisioner[] m_provisioners;
    private Mutex m_mutex;

    /**
     * demandSource returns the work waiting for a worker, one QueueDemand per work order or
     * grouped. (The dispatch queue cannot be inspected, so demand comes from the coordinator.)
     */
    this(QueueDemand[] delegate() demandSource)
    {
        if (demandSource is null)
        {
            throw new Exception("DefaultCapacityBroker requires a demand source");
        }
        this.m_demandSource = demandSource;
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
        // Ask for demand before taking the broker's lock: the source may take its own lock, and
        // the coordinator calls evaluateDemand while holding that one.
        QueueDemand[] pending = m_demandSource();
        if (pending.length == 0)
        {
            return;
        }

        logInfo("[capacity_broker] evaluateDemand: found %d pending demand item(s)", pending.length);

        // Group demand by (executorType, requirements)
        QueueDemand[string] demandMap;
        foreach (item; pending)
        {
            import std.algorithm.sorting : sort;

            string reqKey = item.executorType;
            foreach (k; item.requirements.keys.sort)
            {
                reqKey ~= ";" ~ k ~ "=" ~ item.requirements[k];
            }
            const count = item.pendingWorkOrderCount > 0 ? item.pendingWorkOrderCount : 1;

            logInfo("[capacity_broker] evaluateDemand: pending demand (executorType='%s', reqKey='%s', count=%d)",
                item.executorType, reqKey, count);

            if (auto p = reqKey in demandMap)
            {
                p.pendingWorkOrderCount += count;
            }
            else
            {
                demandMap[reqKey] = QueueDemand(item.executorType, count, item.requirements.dup);
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
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import confector.core.state_stores : StateStores;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.testing.memory_dispatch_queue : InMemoryDispatchQueue;
    import confector.plugin_api.dispatch_queue : DispatchQueue;
    import confector.orchestrator.coordinator : BuildCoordinator, countReceivable, receiveWorkOrders, defaultPoolQueue;

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

    // 2 local work orders, 1 gpu work order, 1 kubernetes work order
    QueueDemand[] demand = [
        QueueDemand("local", 1),
        QueueDemand("local_process", 1),
        QueueDemand("gpu", 1, ["gpu": "true"]),
        QueueDemand("kubernetes", 1),
    ];
    auto broker = new DefaultCapacityBroker(() => demand);

    auto localProv = new MockProvisioner("local", 4);
    auto gpuProv = new MockProvisioner("gpu", 2);

    broker.registerProvisioner(localProv);
    broker.registerProvisioner(gpuProv);

    assert(broker.provisioners.length == 2);
    assert(broker.maxCapacity == 6);
    assert(broker.activeInstanceCount == 0);

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

    // 2. End-to-end integration: BuildCoordinator + DispatchQueue + DefaultCapacityBroker
    auto storage = new InMemoryArtifactStorage();
    auto stores = new StateStores(new InMemoryDocumentStore());
    auto e2eQueue = new InMemoryDispatchQueue();
    auto coord = new BuildCoordinator(storage, stores, e2eQueue);
    auto e2eBroker = new DefaultCapacityBroker(() => coord.queuedDemand());

    // Provisioner that acts as an automated executor worker
    class AutoExecutingProvisioner : ComputeProvisioner
    {
        private DispatchQueue m_q;
        private BuildCoordinator m_coord;
        private size_t m_active = 0;

        this(DispatchQueue q, BuildCoordinator c)
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
            foreach (received; receiveWorkOrders(m_q, demand.pendingWorkOrderCount))
            {
                auto order = received.workOrder;
                TaskExecutionResult res;
                res.taskId = order.taskId;
                res.buildId = order.buildId;
                res.status = TaskStatus.succeeded;
                res.fingerprint = order.fingerprint.length > 0 ? order.fingerprint : "fp_" ~ order.taskId;
                m_coord.onTaskCompleted(order.buildId, order.taskId, res);
                m_q.ack(defaultPoolQueue, received.receipt);
            }
        }
    }

    auto autoProv = new AutoExecutingProvisioner(e2eQueue, coord);
    e2eBroker.registerProvisioner(autoProv);

    // Build DAG: Step1 -> (Step2A, Step2B) -> Step3
    TaskNode step1; step1.id = "step1";
    step1.steps = [BuildStep("Step1", "bash", null, "echo step 1")];
    TaskNode step2A; step2A.id = "step2A"; step2A.inputs["step1"] = taskOutputInput("step1");
    step2A.steps = [BuildStep("Step2A", "bash", null, "echo step 2A")];
    TaskNode step2B; step2B.id = "step2B"; step2B.inputs["step1"] = taskOutputInput("step1");
    step2B.steps = [BuildStep("Step2B", "bash", null, "echo step 2B")];
    TaskNode step3; step3.id = "step3"; step3.inputs["step2A"] = taskOutputInput("step2A"); step3.inputs["step2B"] = taskOutputInput("step2B");
    step3.steps = [BuildStep("Step3", "bash", null, "echo step 3")] ;

    ProjectRecord dagProj;
    dagProj.id = "dag_proj";
    dagProj.tasks = [step1, step2A, step2B, step3];

    string buildId = coord.startBuild(dagProj, null, true);
    assert(buildId.length > 0);

    // Initial demand: step1
    assert(countReceivable(e2eQueue) == 1);
    e2eBroker.evaluateDemand();

    // After step1 completes, step2A and step2B are unblocked and enqueued
    assert(countReceivable(e2eQueue) == 2);
    e2eBroker.evaluateDemand();

    // After step2A & step2B complete, step3 is unblocked and enqueued
    assert(countReceivable(e2eQueue) == 1);
    e2eBroker.evaluateDemand();

    // All steps done
    assert(countReceivable(e2eQueue) == 0);
    BuildRecord finalBuild;
    assert(stores.legacyBuilds.getBuild(buildId, finalBuild));
    assert(finalBuild.status == "succeeded");
    assert(finalBuild.executedTasks.length == 4);
}
