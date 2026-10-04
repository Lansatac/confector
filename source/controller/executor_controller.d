module controller.executor_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.storage : BuildStateRepository;
import confector.core.plugin : PluginRegistry;
import confector.core.executor : ComputeProvider, WorkerRecord, ComputeInstance;
import confector.core.json_compat : toStdJson, toVibeJson;

import std.algorithm : filter, count;
import std.array : array;
import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : split, strip;
import std.uri : encodeComponent;
import std.uuid : randomUUID;

/**
 * Creates the URL router for the /executors endpoints.
 */
URLRouter executorRouter(BuildStateRepository stateRepo, PluginRegistry registry)
{
    auto router = new URLRouter();

    // 1. Executors List View
    router.get("/executors/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto executors = stateRepo !is null ? stateRepo.listExecutors() : [];
        auto providers = registry !is null ? registry.getComputeProviders() : [];

        size_t enabledCount = executors.filter!(e => e.enabled).count;
        size_t disabledCount = executors.length - enabledCount;

        res.render!("executor/executors.dt", executors, providers, enabledCount, disabledCount);
    });

    // 2. Add Executor View
    router.get("/executors/add", (HTTPServerRequest req, HTTPServerResponse res) {
        auto providers = registry !is null ? registry.getComputeProviders() : [];
        string selectedType = req.query.get("provider", "");

        ComputeProvider selectedProvider = null;
        if (selectedType.length > 0 && registry !is null)
        {
            selectedProvider = registry.getComputeProvider(selectedType);
        }
        if (selectedProvider is null && providers.length > 0)
        {
            selectedProvider = providers[0];
        }

        string configFormHtml = "";
        if (selectedProvider !is null)
        {
            configFormHtml = selectedProvider.renderConfigFormHtml(selectedProvider.defaultConfig());
        }

        string errorMessage = req.query.get("error", "");
        res.render!("executor/add-executor.dt", providers, selectedProvider, configFormHtml, errorMessage);
    });

    // Helper function to build Json configuration from form
    Json buildConfigFromForm(HTTPServerRequest req, ComputeProvider provider)
    {
        Json config = provider !is null ? provider.defaultConfig().toVibeJson : Json.emptyObject;
        if (config.type != Json.Type.object)
        {
            config = Json.emptyObject;
        }

        string maxConcurrencyStr = req.form.get("config_maxConcurrency", "");
        if (maxConcurrencyStr.length > 0)
        {
            try
            {
                config["maxConcurrency"] = maxConcurrencyStr.to!int;
            }
            catch (Exception e)
            {
                config["maxConcurrency"] = 1;
            }
        }

        string workspaceDirStr = req.form.get("config_workspaceDir", "");
        if (workspaceDirStr.length > 0)
        {
            config["workspaceDir"] = workspaceDirStr;
        }

        string defaultShellStr = req.form.get("config_defaultShell", "");
        if (defaultShellStr.length > 0)
        {
            config["defaultShell"] = defaultShellStr;
        }

        string runnerBinaryStr = req.form.get("config_runnerBinary", "");
        if (runnerBinaryStr.length > 0)
        {
            config["runnerBinary"] = runnerBinaryStr;
        }

        string secretTokenStr = req.form.get("config_secretToken", "");
        if (secretTokenStr.length > 0)
        {
            config["secretToken"] = secretTokenStr;
        }

        string isolateEnvStr = req.form.get("config_isolateEnvironment", "");
        if (isolateEnvStr.length > 0)
        {
            config["isolateEnvironment"] = (isolateEnvStr == "true" || isolateEnvStr == "1" || isolateEnvStr == "on");
        }

        string allowedStepTypesStr = req.form.get("config_allowedStepTypes", "");
        if (allowedStepTypesStr.length > 0)
        {
            Json stepArr = Json.emptyArray;
            foreach (part; allowedStepTypesStr.split(","))
            {
                string s = part.strip;
                if (s.length > 0)
                {
                    stepArr ~= Json(s);
                }
            }
            config["allowedStepTypes"] = stepArr;
        }

        return config;
    }

    // 3. Create Executor (Disabled by Default)
    router.post("/executors/add", (HTTPServerRequest req, HTTPServerResponse res) {
        string execId = req.form.get("id", "").strip;
        if (execId.length == 0)
        {
            execId = "exec_" ~ randomUUID().toString()[0 .. 8];
        }

        string providerType = req.form.get("provider_type", "").strip;
        ComputeProvider provider = registry !is null ? registry.getComputeProvider(providerType) : null;

        Json config = buildConfigFromForm(req, provider);

        if (provider !is null)
        {
            string[] errors = provider.validateConfig(config.toStdJson);
            if (errors.length > 0)
            {
                import std.string : join;
                res.redirect(format("/executors/add?provider=%s&error=%s", providerType, encodeComponent(errors.join("; "))));
                return;
            }
        }

        WorkerRecord record;
        record.id = execId;
        record.name = req.form.get("name", "Local Executor").strip;
        record.providerType = providerType;
        record.description = req.form.get("description", "").strip;
        record.enabled = false; // Strictly disabled by default
        record.configuration = config.toStdJson;

        string now = Clock.currTime.toISOString();
        record.createdAt = now;
        record.updatedAt = now;

        if (stateRepo !is null)
        {
            stateRepo.saveExecutor(record);
        }

        res.redirect("/executors/details?id=" ~ execId);
    });

    // 4. Details View
    router.get("/executors/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.query.get("id", "");
        WorkerRecord executor;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, executor);
        if (!found)
        {
            executor.id = id;
            executor.name = "Unknown Executor";
            executor.providerType = "unknown";
            executor.configuration = JSONValue(string[string].init);
        }

        ComputeProvider provider = registry !is null ? registry.getComputeProvider(executor.providerType) : null;
        string configPrettyJson = executor.configuration.toPrettyString();

        res.render!("executor/executor-details.dt", executor, provider, configPrettyJson);
    });

    // 5. Edit View
    router.get("/executors/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.query.get("id", "");
        WorkerRecord executor;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, executor);

        ComputeProvider provider = registry !is null ? registry.getComputeProvider(executor.providerType) : null;
        string configFormHtml = provider !is null ? provider.renderConfigFormHtml(executor.configuration) : "";

        string errorMessage = req.query.get("error", "");
        res.render!("executor/executor-editor.dt", executor, provider, configFormHtml, errorMessage);
    });

    // 6. Save Edits
    router.post("/executors/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.form.get("id", "");
        string providerType = req.form.get("provider_type", "");
        ComputeProvider provider = registry !is null ? registry.getComputeProvider(providerType) : null;

        Json config = buildConfigFromForm(req, provider);

        if (provider !is null)
        {
            string[] errors = provider.validateConfig(config.toStdJson);
            if (errors.length > 0)
            {
                import std.string : join;
                res.redirect(format("/executors/edit?id=%s&error=%s", id, encodeComponent(errors.join("; "))));
                return;
            }
        }

        WorkerRecord existing;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, existing);

        WorkerRecord record;
        record.id = id;
        record.name = req.form.get("name", existing.name).strip;
        record.providerType = providerType.length > 0 ? providerType : existing.providerType;
        record.description = req.form.get("description", existing.description).strip;
        record.enabled = req.form.get("enabled", "") == "true";
        record.configuration = config.toStdJson;
        record.createdAt = existing.createdAt.length > 0 ? existing.createdAt : Clock.currTime.toISOString();
        record.updatedAt = Clock.currTime.toISOString();

        if (stateRepo !is null)
        {
            stateRepo.saveExecutor(record);
        }

        res.redirect("/executors/details?id=" ~ id);
    });

    // 7. Toggle Enable/Disable
    router.post("/executors/toggle", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.form.get("id", "");
        WorkerRecord executor;
        if (stateRepo !is null && stateRepo.getExecutor(id, executor))
        {
            executor.enabled = !executor.enabled;
            executor.updatedAt = Clock.currTime.toISOString();
            stateRepo.saveExecutor(executor);
        }

        string redirectTo = req.form.get("redirect_to", "/executors/");
        res.redirect(redirectTo);
    });

    // 8. Delete Executor
    router.post("/executors/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.form.get("id", "");
        if (stateRepo !is null)
        {
            stateRepo.deleteExecutor(id);
        }
        res.redirect("/executors/");
    });

    return router;
}

unittest
{
    import confector.core.storage : InMemoryBuildStateRepository;
    import confector.core.plugin : Plugin, PluginContext, PluginCategory;
    import confector.core.executor : ComputeProvider, ComputeInstance, WorkerRecord;

    class MockComputeProvider : Plugin, ComputeProvider
    {
        @property string name() const { return "mock-executor-plugin"; }
        @property string versionString() const { return "1.0.0"; }
        @property string description() const { return "Mock Executor Provider"; }
        @property PluginCategory category() const { return PluginCategory.worker; }
        @property string providerType() const { return "mock-local"; }
        @property string displayName() const { return "Mock Local Executor"; }
        @property string[] supportedStepTypes() const { return ["process", "mock"]; }

        void initialize(PluginContext context = null) {}
        void shutdown() {}

        JSONValue defaultConfig() const
        {
            JSONValue c = JSONValue(["maxConcurrency": JSONValue(2), "workspaceDir": JSONValue(".workspaces")]);
            return c;
        }

        string[] validateConfig(in JSONValue config) const { return null; }
        string renderConfigFormHtml(in JSONValue currentConfig) const { return "<div>Mock Config</div>"; }
        ComputeInstance createExecutor(in WorkerRecord record) { return null; }
    }

    auto repo = new InMemoryBuildStateRepository();
    auto reg = PluginRegistry.instance;
    reg.shutdownAll();

    auto mockPlugin = new MockComputeProvider();
    reg.registerPlugin(mockPlugin);

    assert(reg.getComputeProviders().length == 1);
    assert(reg.getComputeProvider("mock-local") is mockPlugin);

    auto router = executorRouter(repo, reg);
    assert(router !is null);

    // Test record persistence and disabled by default status
    WorkerRecord exec;
    exec.id = "exec-test-init";
    exec.name = "Initial Executor";
    exec.providerType = "mock-local";
    exec.enabled = false;
    exec.configuration = mockPlugin.defaultConfig();
    repo.saveExecutor(exec);

    assert(repo.listExecutors().length == 1);
    WorkerRecord fetched;
    assert(repo.getExecutor("exec-test-init", fetched));
    assert(!fetched.enabled);

    // Toggle status
    fetched.enabled = true;
    repo.saveExecutor(fetched);
    assert(repo.getExecutor("exec-test-init", fetched));
    assert(fetched.enabled);

    // Delete
    assert(repo.deleteExecutor("exec-test-init"));
    assert(repo.listExecutors().length == 0);
}
