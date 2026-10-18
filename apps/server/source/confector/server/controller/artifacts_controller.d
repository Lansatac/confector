module confector.server.controller.artifacts_controller;

import vibe.vibe;
import confector.api.model : ArtifactNotFoundException, ArtifactStorage, InvalidArtifactKeyException;
import std.array : Appender;

/**
 * Creates the URL router for the artifact endpoints workers use, under /api/v1/artifacts: presigned
 * URLs where `storage` supports them, and server-proxied upload, existence check, download and
 * delete otherwise (the runner's HttpArtifactStorage is the client).
 */
URLRouter artifactsRouter(ArtifactStorage storage)
{
    if (storage is null)
        throw new Exception("The artifact routes need an artifact store");

    auto router = new URLRouter();

    // A failed storage call answers with a short message (none for HEAD); the detail, which can
    // name server paths, is only logged.
    void writeStorageError(HTTPServerResponse res, Exception e, string action, bool withBody = true)
    {
        string message;
        if (cast(ArtifactNotFoundException) e)
        {
            res.statusCode = HTTPStatus.notFound;
            message = "Artifact not found";
            logDiagnostic("[artifacts] %s: %s", action, e.msg);
        }
        else if (cast(InvalidArtifactKeyException) e)
        {
            res.statusCode = HTTPStatus.badRequest;
            message = "Invalid fingerprint or artifact id";
            logInfo("[artifacts] %s: %s", action, e.msg);
        }
        else
        {
            res.statusCode = HTTPStatus.internalServerError;
            message = "Artifact storage error";
            logError("[artifacts] %s failed: %s", action, e.msg);
        }
        if (!withBody) return;
        Json err = Json.emptyObject;
        err["error"] = Json(message);
        res.writeJsonBody(err);
    }

    void writeBadRequest(HTTPServerResponse res, string message)
    {
        res.statusCode = HTTPStatus.badRequest;
        Json err = Json.emptyObject;
        err["error"] = Json(message);
        res.writeJsonBody(err);
    }

    void writeOk(HTTPServerResponse res)
    {
        Json resp = Json.emptyObject;
        resp["status"] = Json("ok");
        res.writeJsonBody(resp);
    }

    // GET /api/v1/artifacts/presign-upload?fingerprint=...&artifactId=...
    // GET /api/v1/artifacts/presign-download?fingerprint=...&artifactId=...
    // Answer { "uploadUrl": "..." } or { "downloadUrl": "..." } if the store hands out presigned
    // URLs, or {} to fall back to the proxy routes below.
    void presignRoute(string path, string field, string delegate(string, string) presign)
    {
        router.get(path, (HTTPServerRequest req, HTTPServerResponse res) {
            string fingerprint = req.query.get("fingerprint", "");
            string artifactId = req.query.get("artifactId", "");
            if (fingerprint.length == 0 || artifactId.length == 0)
                return writeBadRequest(res, "Missing fingerprint or artifactId");
            try
            {
                string url = presign(fingerprint, artifactId);
                Json resp = Json.emptyObject;
                if (url.length > 0)
                    resp[field] = Json(url);
                res.writeJsonBody(resp);
            }
            catch (Exception e)
            {
                writeStorageError(res, e, "Presigning " ~ fingerprint ~ "/" ~ artifactId);
            }
        });
    }
    presignRoute("/api/v1/artifacts/presign-upload", "uploadUrl", &storage.presignUpload);
    presignRoute("/api/v1/artifacts/presign-download", "downloadUrl", &storage.presignDownload);

    // Route parameters are URL-decoded once by the router; never decode them again.

    // POST /api/v1/artifacts/:fingerprint/:artifactId/upload
    // Server-proxied upload: the worker sends the artifact bytes, the server stores them.
    router.post("/api/v1/artifacts/:fingerprint/:artifactId/upload", (HTTPServerRequest req, HTTPServerResponse res) {
        import vibe.stream.operations : readAll;

        string fingerprint = req.params["fingerprint"];
        string artifactId = req.params["artifactId"];
        ubyte[] data = req.bodyReader.readAll();
        if (data.length == 0)
            return writeBadRequest(res, "An artifact upload needs a body");
        try
        {
            storage.storeArtifactStream(fingerprint, artifactId, (void delegate(const(ubyte)[]) sink) {
                sink(data);
            });
            writeOk(res);
        }
        catch (Exception e)
        {
            writeStorageError(res, e, "Storing " ~ fingerprint ~ "/" ~ artifactId);
        }
    });

    // HEAD /api/v1/artifacts/_head/:fingerprint/:artifactId
    // Checks that an artifact exists. URLRouter routes a HEAD request to the GET route.
    router.get("/api/v1/artifacts/_head/:fingerprint/:artifactId", (HTTPServerRequest req, HTTPServerResponse res) {
        // Every branch writes the response: an unwritten one falls through to later routes.
        try
        {
            res.statusCode = storage.artifactExists(req.params["fingerprint"], req.params["artifactId"])
                ? HTTPStatus.ok : HTTPStatus.notFound;
        }
        catch (Exception e)
        {
            writeStorageError(res, e, "Checking " ~ req.params["fingerprint"] ~ "/" ~ req.params["artifactId"], false);
        }
        res.writeVoidBody();
    });

    // GET /api/v1/artifacts/:fingerprint/:artifactId/download
    // Server-proxied download: the server sends the artifact bytes to the worker.
    router.get("/api/v1/artifacts/:fingerprint/:artifactId/download", (HTTPServerRequest req, HTTPServerResponse res) {
        string fingerprint = req.params["fingerprint"];
        string artifactId = req.params["artifactId"];
        Appender!(ubyte[]) buffer;
        try
        {
            storage.retrieveArtifactStream(fingerprint, artifactId, (const(ubyte)[] chunk) {
                buffer.put(chunk);
            });
        }
        catch (Exception e)
        {
            return writeStorageError(res, e, "Reading " ~ fingerprint ~ "/" ~ artifactId);
        }
        res.headers["Content-Type"] = "application/octet-stream";
        res.writeBody(buffer.data);
    });

    // DELETE /api/v1/artifacts/:fingerprint/:artifactId
    router.delete_("/api/v1/artifacts/:fingerprint/:artifactId", (HTTPServerRequest req, HTTPServerResponse res) {
        string fingerprint = req.params["fingerprint"];
        string artifactId = req.params["artifactId"];
        try
        {
            storage.deleteArtifact(fingerprint, artifactId);
            writeOk(res);
        }
        catch (Exception e)
        {
            writeStorageError(res, e, "Deleting " ~ fingerprint ~ "/" ~ artifactId);
        }
    });

    return router;
}

unittest
{
    import confector.backends.artifact.local : LocalArtifactStorage;
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    string base = buildPath(tempDir, "confector_artifact_routes_test_" ~ thisProcessID.to!string);
    if (exists(base)) rmdirRecurse(base);
    scope(exit) if (exists(base)) rmdirRecurse(base);
    auto router = artifactsRouter(new LocalArtifactStorage(base));

    struct Answer { int status; string body; }

    Answer call(HTTPMethod method, string path, string body = "")
    {
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        router.handleRequest(createTestHTTPServerRequest(URL("http://localhost" ~ path), method, InetHeaderMap.init,
            createMemoryStream(cast(ubyte[]) body.dup, false)), res);
        assert(res.headerWritten, "No route answered " ~ path);
        return Answer(res.statusCode, cast(string) sink.data);
    }

    void assertNoServerPath(Answer answer)
    {
        assert(!answer.body.canFind(base) && !answer.body.canFind(tempDir), answer.body);
    }

    // An empty upload is refused and stores nothing
    auto empty = call(HTTPMethod.POST, "/api/v1/artifacts/fp1/out/upload");
    assert(empty.status == HTTPStatus.badRequest, empty.body);
    assert(call(HTTPMethod.HEAD, "/api/v1/artifacts/_head/fp1/out").status == HTTPStatus.notFound);

    // Errors answer with a short message, never the storage's detail with its server paths
    auto missing = call(HTTPMethod.GET, "/api/v1/artifacts/fp1/out/download");
    assert(missing.status == HTTPStatus.notFound && missing.body.canFind("Artifact not found"), missing.body);
    assertNoServerPath(missing);

    auto invalid = call(HTTPMethod.POST, "/api/v1/artifacts/fp1/a%3Ab/upload", "bytes");
    assert(invalid.status == HTTPStatus.badRequest && invalid.body.canFind("Invalid fingerprint or artifact id"), invalid.body);
    assertNoServerPath(invalid);
    assert(call(HTTPMethod.HEAD, "/api/v1/artifacts/_head/fp1/a%3Ab").status == HTTPStatus.notFound);

    write(buildPath(base, "fpfile"), "a file where the fingerprint directory belongs");
    auto broken = call(HTTPMethod.POST, "/api/v1/artifacts/fpfile/out/upload", "bytes");
    assert(broken.status == HTTPStatus.internalServerError && broken.body.canFind("Artifact storage error"), broken.body);
    assertNoServerPath(broken);
}
