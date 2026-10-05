module confector.core.executor;

public import confector.plugin_api.executor;

unittest
{
    import std.json : JSONValue;

    WorkerRecord record;
    record.id = "exec_1";
    record.name = "Local Runner 1";
    record.providerType = "local";
    assert(!record.enabled, "Executors must be disabled by default");

    record.configuration = JSONValue(["maxConcurrency": JSONValue(4)]);
    assert(record.id == "exec_1");
    assert(record.name == "Local Runner 1");
    assert(!record.enabled);
    assert(record.configuration["maxConcurrency"].integer == 4);

    class TestWorkerPool : WorkerPool
    {
        private bool m_running = false;
        private size_t m_active = 0;
        private size_t m_max = 4;

        void start() { m_running = true; }
        void stop() { m_running = false; }
        @property size_t activeTaskCount() const { return m_active; }
        @property size_t maxConcurrentTasks() const { return m_max; }
    }

    WorkerPool pool = new TestWorkerPool();
    assert(pool.activeTaskCount == 0);
    assert(pool.maxConcurrentTasks == 4);
    pool.start();
    pool.stop();
}
