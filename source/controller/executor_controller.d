module controller.executor_controller;

import vibe.vibe;
import vibe.core.log : logError, logInfo;
import vibe.data.json : Json, serializeToJson;

import confector.core.executor : ExecutorRecord, ExecutorProvider;
import confector.core.plugin : PluginRegistry;
import confector.core.storage : BuildStateRepository;

import std.algorithm : filter, count;
import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.string : split, strip;
import std.uuid : randomUUID;
import std.uri : encodeComponent;

URLRouter executorRouter(BuildStateRepository stateRepo, PluginRegistry registry)
{
    auto router = new URLRouter();

    // 1. Inventory View
    router.get("/executors/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto executors = stateRepo !is null ? stateRepo.listExecutors() : [];
        auto providers = registry !is null ? registry.getExecutorProviders() : [];

        ulong enabledCount = executors.filter!(e => e.enabled).count;
        ulong disabledCount = executors.filter!(e => !e.enabled).count;

        res.render!("executor/executors.dt", executors, providers, enabledCount, disabledCount);
    });

    // 2. Add Executor View
    router.get("/executors/add", (HTTPServerRequest req, HTTPServerResponse res) {
        auto providers = registry !is null ? registry.getExecutorProviders() : [];
        string selectedType = req.query.get("provider", "");

        ExecutorProvider selectedProvider = null;
        if (selectedType.length > 0 && registry !is null)
        {
            selectedProvider = registry.getExecutorProvider(selectedType);
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
    Json buildConfigFromForm(HTTPServerRequest req, ExecutorProvider provider)
    {
        Json config = provider !is null ? provider.defaultConfig() : Json.emptyObject;
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
        ExecutorProvider provider = registry !is null ? registry.getExecutorProvider(providerType) : null;

        Json config = buildConfigFromForm(req, provider);

        if (provider !is null)
        {
            string[] errors = provider.validateConfig(config);
            if (errors.length > 0)
            {
                import std.string : join;
                res.redirect(format("/executors/add?provider=%s&error=%s", providerType, encodeComponent(errors.join("; "))));
                return;
            }
        }

        ExecutorRecord record;
        record.id = execId;
        record.name = req.form.get("name", "Local Executor").strip;
        record.providerType = providerType;
        record.description = req.form.get("description", "").strip;
        record.enabled = false; // Strictly disabled by default
        record.configuration = config;

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
        ExecutorRecord executor;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, executor);
        if (!found)
        {
            executor.id = id;
            executor.name = "Unknown Executor";
            executor.providerType = "unknown";
            executor.configuration = Json.emptyObject;
        }

        ExecutorProvider provider = registry !is null ? registry.getExecutorProvider(executor.providerType) : null;
        string configPrettyJson = executor.configuration.toPrettyString();

        res.render!("executor/executor-details.dt", executor, provider, configPrettyJson);
    });

    // 5. Edit View
    router.get("/executors/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.query.get("id", "");
        ExecutorRecord executor;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, executor);

        ExecutorProvider provider = registry !is null ? registry.getExecutorProvider(executor.providerType) : null;
        string configFormHtml = provider !is null ? provider.renderConfigFormHtml(executor.configuration) : "";

        string errorMessage = req.query.get("error", "");
        res.render!("executor/executor-editor.dt", executor, provider, configFormHtml, errorMessage);
    });

    // 6. Save Edits
    router.post("/executors/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string id = req.form.get("id", "");
        string providerType = req.form.get("provider_type", "");
        ExecutorProvider provider = registry !is null ? registry.getExecutorProvider(providerType) : null;

        Json config = buildConfigFromForm(req, provider);

        if (provider !is null)
        {
            string[] errors = provider.validateConfig(config);
            if (errors.length > 0)
            {
                import std.string : join;
                res.redirect(format("/executors/edit?id=%s&error=%s", id, encodeComponent(errors.join("; "))));
                return;
            }
        }

        ExecutorRecord existing;
        bool found = stateRepo !is null && stateRepo.getExecutor(id, existing);

        ExecutorRecord record;
        record.id = id;
        record.name = req.form.get("name", existing.name).strip;
        record.providerType = providerType.length > 0 ? providerType : existing.providerType;
        record.description = req.form.get("description", existing.description).strip;
        record.enabled = req.form.get("enabled", "") == "true";
        record.configuration = config;
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
        ExecutorRecord executor;
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
    import plugins.local_executor : LocalExecutorPlugin;

    auto repo = new InMemoryBuildStateRepository();
    auto reg = PluginRegistry.instance;
    reg.shutdownAll();

    auto localPlugin = new LocalExecutorPlugin();
    reg.registerPlugin(localPlugin);

    assert(reg.getExecutorProviders().length == 1);
    assert(reg.getExecutorProvider("local") is localPlugin);

    auto router = executorRouter(repo, reg);
    assert(router !is null);

    // Test record persistence and disabled by default status
    ExecutorRecord exec;
    exec.id = "exec-test-init";
    exec.name = "Initial Executor";
    exec.providerType = "local";
    exec.enabled = false;
    exec.configuration = localPlugin.defaultConfig();
    repo.saveExecutor(exec);

    assert(repo.listExecutors().length == 1);
    ExecutorRecord fetched;
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
