module controller.artifacts_controller;

import vibe.vibe;
import vibe.core.log : logInfo, logError;
import confector.core.plugin : PluginRegistry;
import confector.plugin_api.model : ArtifactStorage;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip;
import std.uri : encodeComponent;

/**
 * Creates the URL router for the /artifacts endpoints.
 * Provides UI for selecting and configuring artifact storage backends.
 */
URLRouter artifactsRouter(PluginRegistry registry)
{
    auto router = new URLRouter();

    // 1. Artifacts List & Configuration View
    router.get("/artifacts/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto storages = registry !is null ? registry.getArtifactStorages() : [];
        string defaultType = registry !is null ? registry.getDefaultArtifactStorageType() : "";

        ArtifactStorage selectedStorage = null;
        if (defaultType.length > 0 && registry !is null)
        {
            selectedStorage = registry.getArtifactStorage(defaultType);
        }
        if (selectedStorage is null && storages.length > 0)
        {
            selectedStorage = storages[0];
        }

        string configFormHtml = "";
        if (selectedStorage !is null)
        {
            configFormHtml = selectedStorage.renderConfigFormHtml(selectedStorage.defaultConfig());
        }

        string errorMessage = req.query.get("error", "");
        string successMessage = req.query.get("success", "");

        res.render!("artifacts/artifacts.dt", storages, selectedStorage, configFormHtml, defaultType, errorMessage, successMessage);
    });

    router.get("/artifacts", (HTTPServerRequest req, HTTPServerResponse res) {
        res.redirect("/artifacts/");
    });

    // 2. Select default artifact storage backend
    router.post("/artifacts/select", (HTTPServerRequest req, HTTPServerResponse res) {
        string backendType = req.form.get("backendType", "").strip;

        if (backendType.length == 0)
        {
            res.redirect("/artifacts/?error=" ~ encodeComponent("Please select an artifact storage backend"));
            return;
        }

        if (registry !is null)
        {
            auto storage = registry.getArtifactStorage(backendType);
            if (storage is null)
            {
                res.redirect("/artifacts/?error=" ~ encodeComponent("Artifact storage backend '" ~ backendType ~ "' not found"));
                return;
            }

            registry.setDefaultArtifactStorage(backendType);
            logInfo("Artifact storage backend '%s' selected as default", backendType);
            res.redirect("/artifacts/?success=" ~ encodeComponent("Artifact storage backend '" ~ backendType ~ "' selected as default"));
        }
        else
        {
            res.redirect("/artifacts/?error=" ~ encodeComponent("Plugin registry not available"));
        }
    });

    // 3. Update artifact storage configuration
    router.post("/artifacts/configure", (HTTPServerRequest req, HTTPServerResponse res) {
        string backendType = req.form.get("backendType", "").strip;

        if (backendType.length == 0)
        {
            res.redirect("/artifacts/?error=" ~ encodeComponent("Backend type is required"));
            return;
        }

        if (registry !is null)
        {
            auto storage = registry.getArtifactStorage(backendType);
            if (storage is null)
            {
                res.redirect("/artifacts/?error=" ~ encodeComponent("Artifact storage backend '" ~ backendType ~ "' not found"));
                return;
            }

            // Build config JSON from form fields (prefixed with "config_")
            JSONValue config = storage.defaultConfig();
            if (config.type != JSONType.object)
            {
                config = JSONValue(string[string].init);
            }

            // Extract known config_ prefixed form fields
            string baseDir = req.form.get("config_baseDir", "").strip;
            if (baseDir.length > 0)
            {
                config["baseDir"] = JSONValue(baseDir);
            }

            // Validate the configuration
            auto errors = storage.validateConfig(config);
            if (errors.length > 0)
            {
                import std.string : join;
                res.redirect("/artifacts/?error=" ~ encodeComponent("Configuration validation failed: " ~ errors.join("; ")));
                return;
            }

            logInfo("Artifact storage '%s' configuration updated", backendType);
            res.redirect("/artifacts/?success=" ~ encodeComponent("Configuration for '" ~ backendType ~ "' backend updated successfully"));
        }
        else
        {
            res.redirect("/artifacts/?error=" ~ encodeComponent("Plugin registry not available"));
        }
    });

    return router;
}
