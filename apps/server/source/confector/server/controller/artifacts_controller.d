module confector.server.controller.artifacts_controller;

import vibe.vibe;
import vibe.core.log : logInfo, logError;
import confector.core.plugin : PluginRegistry;
import confector.server.storage.configured_storage : ConfiguredArtifactStorage;
import std.array : Appender;

/**
 * Creates the URL router for the /artifacts endpoints.
 * Provides a read-only page listing the registered artifact storage backends,
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

    // --- UI endpoint ---

    // Artifacts list view: the registered backends and the default one, read-only
    router.get("/artifacts/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto storages = registry !is null ? registry.getArtifactStorages() : [];
        string defaultType = registry !is null ? registry.getDefaultArtifactStorageType() : "";

        res.render!("artifacts/artifacts.dt", storages, defaultType);
    });

    router.get("/artifacts", (HTTPServerRequest req, HTTPServerResponse res) {
        res.redirect("/artifacts/");
    });

    return router;
}

unittest
{
    import confector.testing.memory_artifact_storage : InMemoryArtifactStorage;
    import vibe.stream.memory : createMemoryOutputStream;
    import std.algorithm.searching : canFind;

    auto registry = new PluginRegistry();
    registry.registerArtifactStorage(new InMemoryArtifactStorage());
    auto router = artifactsRouter(registry);

    // The page lists the registered backends and offers no form to change them
    auto sink = createMemoryOutputStream();
    auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
    router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/artifacts/"), HTTPMethod.GET), res);
    assert(res.statusCode == HTTPStatus.ok);
    auto page = cast(string) sink.data;
    assert(page.canFind(new InMemoryArtifactStorage().backendType), page);
    assert(!page.canFind("<form"), "The artifacts page is read-only");
}
