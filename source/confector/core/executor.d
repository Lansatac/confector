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
}
