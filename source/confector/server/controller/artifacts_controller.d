module controller.artifacts_controller;

import vibe.vibe;
import vibe.core.log : logInfo, logError;
import confector.core.plugin : PluginRegistry;
import confector.core.storage : ConfiguredArtifactStorage;
import confector.plugin_api.model : ArtifactStorage;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip;
import std.uri : encodeComponent;
import std.array : Appender;

/**
 * Creates the URL router for the /artifacts endpoints.
 * Provides UI for selecting and configuring artifact storage backends,
 * and API endpoints for agent artifact operations (presigned URLs and proxy).
 */
URLRouter artifactsRouter(PluginRegistry registry, ConfiguredArtifactStorage configuredStorage = null)
{
    auto router = new URLRouter();

    // --- API endpoints for agents (Option 4: Presigned URLs with proxy fallback) ---

    // GET /api/v1/artifacts/presign-upload?fingerprint=...&artifactId=...
    // Returns { "uploadUrl": "..." } if presigned URLs are supported, or {} to fall back to proxy.
    router.get("/api/v1/artifacts/presign-upload", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string fingerprint = req.query.get("fingerprint", "");
            string artifactId = req.query.get("artifactId", "");

            if (fingerprint.length == 0 || artifactId.length == 0)
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json("Missing fingerprint or artifactId");
                res.writeJsonBody(err);
                return;
            }

            string uploadUrl = null;
            if (configuredStorage !is null)
            {
                uploadUrl = configuredStorage.presignUpload(fingerprint, artifactId);
            }

            Json resp = Json.emptyObject;
            if (uploadUrl !is null && uploadUrl.length > 0)
            {
                resp["uploadUrl"] = Json(uploadUrl);
            }
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.internalServerError;
            Json err = Json.emptyObject;
            err["error"] = Json(format("Error generating presigned upload URL: %s", e.msg));
            res.writeJsonBody(err);
        }
    });

    // GET /api/v1/artifacts/presign-download?fingerprint=...&artifactId=...
    // Returns { "downloadUrl": "..." } if presigned URLs are supported, or {} to fall back to proxy.
    router.get("/api/v1/artifacts/presign-download", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string fingerprint = req.query.get("fingerprint", "");
            string artifactId = req.query.get("artifactId", "");

            if (fingerprint.length == 0 || artifactId.length == 0)
            {
                res.statusCode = HTTPStatus.badRequest;
                Json err = Json.emptyObject;
                err["error"] = Json("Missing fingerprint or artifactId");
                res.writeJsonBody(err);
                return;
            }

            string downloadUrl = null;
            if (configuredStorage !is null)
            {
                downloadUrl = configuredStorage.presignDownload(fingerprint, artifactId);
            }

            Json resp = Json.emptyObject;
            if (downloadUrl !is null && downloadUrl.length > 0)
            {
                resp["downloadUrl"] = Json(downloadUrl);
            }
            res.writeJsonBody(resp);
        }
        catch (Exception e)
        {
            res.statusCode = HTTPStatus.internalServerError;
            Json err = Json.emptyObject;
            err["error"] = Json(format("Error generating presigned download URL: %s", e.msg));
            res.writeJsonBody(err);
        }
    });

    // POST /api/v1/artifacts/:fingerprint/:artifactId/upload
    // Server-proxied upload: agent streams artifact bytes, server stores them.
    router.post("/api/v1/artifacts/*", (HTTPServerRequest req, HTTPServerResponse res) {
        // Match /api/v1/artifacts/:fingerprint/:artifactId/upload
        string uri = req.path;
        // Strip /api/v1/artifacts/ prefix
        string prefix = "/api/v1/artifacts/";
        if (uri.length > prefix.length)
        {
            string rest = uri[prefix.length .. $];
            // Check if it ends with /upload
            if (rest.length > 7 && rest[$ - 7 .. $] == "/upload")
            {
                string keyPart = rest[0 .. $ - 7];
                // Decode and split fingerprint/artifactId
                import std.uri : decodeComponent;
                import std.string : split;
                auto parts = keyPart.split("/");
                if (parts.length >= 2)
                {
                    string fingerprint = decodeComponent(parts[0]);
                    string artifactId = decodeComponent(parts[1]);

                    try
                    {
                        if (configuredStorage !is null)
                        {
                            // Read the request body as raw bytes via bodyReader
                            import vibe.stream.operations : readAll;
                            ubyte[] data = req.bodyReader.readAll();
                            if (data.length > 0)
                            {
                                configuredStorage.storeArtifactStream(fingerprint, artifactId, (void delegate(const(ubyte)[]) sink) {
                                    sink(data);
                                });
                            }

                            Json resp = Json.emptyObject;
                            resp["status"] = Json("ok");
                            res.writeJsonBody(resp);
                        }
                        else
                        {
                            res.statusCode = HTTPStatus.badRequest;
                            Json err = Json.emptyObject;
                            err["error"] = Json("No artifact storage configured");
                            res.writeJsonBody(err);
                        }
                    }
                    catch (Exception e)
                    {
                        res.statusCode = HTTPStatus.internalServerError;
                        Json err = Json.emptyObject;
                        err["error"] = Json(format("Failed to store artifact: %s", e.msg));
                        res.writeJsonBody(err);
                    }
                    return;
                }
            }
        }
        res.statusCode = HTTPStatus.notFound;
        Json err = Json.emptyObject;
        err["error"] = Json("Not found");
        res.writeJsonBody(err);
    });

    // HEAD /api/v1/artifacts/:fingerprint/:artifactId
    // Check if artifact exists (using GET since URLRouter has no head() method)
    router.get("/api/v1/artifacts/_head/*", (HTTPServerRequest req, HTTPServerResponse res) {
        string uri = req.path;
        string prefix = "/api/v1/artifacts/_head/";
        if (uri.length > prefix.length)
        {
            string rest = uri[prefix.length .. $];
            import std.uri : decodeComponent;
            import std.string : split;
            auto parts = rest.split("/");
            if (parts.length >= 2)
            {
                string fingerprint = decodeComponent(parts[0]);
                string artifactId = decodeComponent(parts[1]);

                try
                {
                    if (configuredStorage !is null && configuredStorage.artifactExists(fingerprint, artifactId))
                    {
                        res.statusCode = HTTPStatus.ok;
                    }
                    else
                    {
                        res.statusCode = HTTPStatus.notFound;
                    }
                }
                catch (Exception e)
                {
                    res.statusCode = HTTPStatus.internalServerError;
                }
                return;
            }
        }
        res.statusCode = HTTPStatus.notFound;
    });

    // GET /api/v1/artifacts/:fingerprint/:artifactId/download
    // Server-proxied download: server streams artifact bytes to agent.
    router.get("/api/v1/artifacts/*", (HTTPServerRequest req, HTTPServerResponse res) {
        string uri = req.path;
        string prefix = "/api/v1/artifacts/";
        if (uri.length > prefix.length)
        {
            string rest = uri[prefix.length .. $];
            // Check if it ends with /download
            if (rest.length > 9 && rest[$ - 9 .. $] == "/download")
            {
                string keyPart = rest[0 .. $ - 9];
                import std.uri : decodeComponent;
                import std.string : split;
                auto parts = keyPart.split("/");
                if (parts.length >= 2)
                {
                    string fingerprint = decodeComponent(parts[0]);
                    string artifactId = decodeComponent(parts[1]);

                    try
                    {
                        if (configuredStorage !is null)
                        {
                            Appender!(ubyte[]) buffer;
                            configuredStorage.retrieveArtifactStream(fingerprint, artifactId, (const(ubyte)[] chunk) {
                                buffer.put(chunk);
                            });

                            res.headers["Content-Type"] = "application/octet-stream";
                            res.headers["Content-Length"] = format("%d", buffer.data.length);
                            res.writeBody(buffer.data);
                        }
                        else
                        {
                            res.statusCode = HTTPStatus.badRequest;
                            Json err = Json.emptyObject;
                            err["error"] = Json("No artifact storage configured");
                            res.writeJsonBody(err);
                        }
                    }
                    catch (Exception e)
                    {
                        res.statusCode = HTTPStatus.notFound;
                        Json err = Json.emptyObject;
                        err["error"] = Json(format("Artifact not found: %s", e.msg));
                        res.writeJsonBody(err);
                    }
                    return;
                }
            }
        }
        res.statusCode = HTTPStatus.notFound;
        Json err = Json.emptyObject;
        err["error"] = Json("Not found");
        res.writeJsonBody(err);
    });

    // DELETE /api/v1/artifacts/:fingerprint/:artifactId
    router.delete_("/api/v1/artifacts/*", (HTTPServerRequest req, HTTPServerResponse res) {
        string uri = req.path;
        string prefix = "/api/v1/artifacts/";
        if (uri.length > prefix.length)
        {
            string rest = uri[prefix.length .. $];
            import std.uri : decodeComponent;
            import std.string : split;
            auto parts = rest.split("/");
            if (parts.length >= 2)
            {
                string fingerprint = decodeComponent(parts[0]);
                string artifactId = decodeComponent(parts[1]);

                try
                {
                    if (configuredStorage !is null)
                    {
                        configuredStorage.deleteArtifact(fingerprint, artifactId);
                        Json resp = Json.emptyObject;
                        resp["status"] = Json("ok");
                        res.writeJsonBody(resp);
                    }
                    else
                    {
                        res.statusCode = HTTPStatus.badRequest;
                        Json err = Json.emptyObject;
                        err["error"] = Json("No artifact storage configured");
                        res.writeJsonBody(err);
                    }
                }
                catch (Exception e)
                {
                    res.statusCode = HTTPStatus.internalServerError;
                    Json err = Json.emptyObject;
                    err["error"] = Json(format("Failed to delete artifact: %s", e.msg));
                    res.writeJsonBody(err);
                }
                return;
            }
        }
        res.statusCode = HTTPStatus.notFound;
        Json err = Json.emptyObject;
        err["error"] = Json("Not found");
        res.writeJsonBody(err);
    });

    // --- UI endpoints (existing) ---

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
