module confector.server.controller.artifacts_controller;

import vibe.vibe;
import confector.api.model : ArtifactNotFoundException, ArtifactStorage, InvalidArtifactKeyException;
import confector.core.state_stores : StateStores;
import confector.core.worker_token : WorkerTokenClaims, WorkerTokenScopeException, requireInputArtifact, requireSigningKey, requireUpload;
import confector.server.worker_auth : authenticateWorker, permitWorker, requireCurrentExecutionAttempt;
import confector.server.authenticator : Authenticator;
import confector.server.route_access : AuthorizedRoutes, ExcludedBy;
import std.array : Appender;

/**
 * Creates the routes for the artifact endpoints workers use, under /api/v1/artifacts: presigned
 * URLs where `storage` supports them, and server-proxied upload, existence check and download
 * otherwise (the runner's HttpArtifactStorage is the client).
 *
 * No user identity reaches these routes: each is excluded from authentication and checks the
 * worker token itself. The token is signed with `workerTokenKey`, and it must allow the artifact:
 * uploads and presigned upload URLs for the execution's own fingerprint, and only while the token's
 * attempt is the execution's current one; existence checks, downloads and presigned download URLs for
 * the artifacts its inputs name. No token may delete: retention removes artifacts, not workers.
 */
AuthorizedRoutes artifactsRouter(Authenticator authenticator, ArtifactStorage storage, string workerTokenKey, StateStores stores)
{
    if (storage is null)
        throw new Exception("The artifact routes need an artifact store");
    if (stores is null)
        throw new Exception("The artifact routes need the state stores, to check an upload's execution attempt");
    requireSigningKey(workerTokenKey);

    auto router = new AuthorizedRoutes(authenticator);

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
    void presignRoute(string path, string field, string delegate(string, string) presign,
        void delegate(in WorkerTokenClaims, string, string) requireScope)
    {
        router.excluded(HTTPMethod.GET, path, ExcludedBy.workerToken, (HTTPServerRequest req, HTTPServerResponse res) {
            WorkerTokenClaims claims;
            if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
            string fingerprint = req.query.get("fingerprint", "");
            string artifactId = req.query.get("artifactId", "");
            if (fingerprint.length == 0 || artifactId.length == 0)
                return writeBadRequest(res, "Missing fingerprint or artifactId");
            if (!permitWorker(req, res, { requireScope(claims, fingerprint, artifactId); })) return;
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
    presignRoute("/api/v1/artifacts/presign-upload", "uploadUrl", &storage.presignUpload,
        (in WorkerTokenClaims claims, string fingerprint, string artifactId) {
            requireUpload(claims, fingerprint);
            requireCurrentExecutionAttempt(stores, claims, true);
        });
    presignRoute("/api/v1/artifacts/presign-download", "downloadUrl", &storage.presignDownload,
        (in WorkerTokenClaims claims, string fingerprint, string artifactId) { requireInputArtifact(claims, fingerprint, artifactId); });

    // Route parameters are URL-decoded once by the router; never decode them again.

    // POST /api/v1/artifacts/:fingerprint/:artifactId/upload
    // Server-proxied upload: the worker sends the artifact bytes, the server stores them.
    router.excluded(HTTPMethod.POST, "/api/v1/artifacts/:fingerprint/:artifactId/upload", ExcludedBy.workerToken, (HTTPServerRequest req, HTTPServerResponse res) {
        import vibe.stream.operations : readAll;

        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        string fingerprint = req.params["fingerprint"];
        string artifactId = req.params["artifactId"];
        if (!permitWorker(req, res, {
            requireUpload(claims, fingerprint);
            requireCurrentExecutionAttempt(stores, claims, true);
        })) return;
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
    router.excluded(HTTPMethod.GET, "/api/v1/artifacts/_head/:fingerprint/:artifactId", ExcludedBy.workerToken, (HTTPServerRequest req, HTTPServerResponse res) {
        // Every branch writes the response: an unwritten one falls through to later routes.
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        if (!permitWorker(req, res, { requireInputArtifact(claims, req.params["fingerprint"], req.params["artifactId"]); })) return;
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
    router.excluded(HTTPMethod.GET, "/api/v1/artifacts/:fingerprint/:artifactId/download", ExcludedBy.workerToken, (HTTPServerRequest req, HTTPServerResponse res) {
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        string fingerprint = req.params["fingerprint"];
        string artifactId = req.params["artifactId"];
        if (!permitWorker(req, res, { requireInputArtifact(claims, fingerprint, artifactId); })) return;
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
    // A worker token never allows deleting: a cache entry outlives the execution that wrote it.
    router.excluded(HTTPMethod.DELETE, "/api/v1/artifacts/:fingerprint/:artifactId", ExcludedBy.workerToken, (HTTPServerRequest req, HTTPServerResponse res) {
        WorkerTokenClaims claims;
        if (!authenticateWorker(workerTokenKey, req, res, claims)) return;
        permitWorker(req, res, {
            throw new WorkerTokenScopeException("A worker token does not allow deleting artifacts");
        });
    });

    return router;
}

unittest
{
    import confector.api.model : ActiveExecution;
    import confector.core.work_orders : releaseExecution, startExecution;
    import confector.backends.artifact.local : LocalArtifactStorage;
    import confector.server.authenticator : FixedAuthenticator, Identity;
    import std.typecons : Nullable;
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import confector.core.worker_token : InputArtifact, WorkerTokenClaims, mintWorkerToken, workerTokenHeader;
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.datetime.systime : Clock;
    import core.time : minutes;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    string base = buildPath(tempDir, "confector_artifact_routes_test_" ~ thisProcessID.to!string);
    if (exists(base)) rmdirRecurse(base);
    scope(exit) if (exists(base)) rmdirRecurse(base);
    enum signingKey = "0123456789abcdef0123456789abcdef";
    auto storage = new LocalArtifactStorage(base);
    auto stores = new StateStores(new InMemoryDocumentStore());
    // Fingerprint "fp1" has an execution on its second attempt: started, released, started again
    ActiveExecution execution;
    execution.projectId = "proj";
    execution.taskId = "task";
    execution.definitionId = "def1";
    execution.createdAt = "2026-10-16T10:00:00Z";
    const executionId = stores.ledgers.claim("fp1", 0, execution).executionId;
    startExecution(stores, "fp1", "w1", 1.minutes, "2026-10-16T10:00:00Z");
    releaseExecution(stores, "fp1", executionId, 1);
    startExecution(stores, "fp1", "w1", 1.minutes, "2026-10-16T10:00:00Z");
    // The worker routes answer the same with or without a user identity: they never consult it
    auto router = artifactsRouter(new FixedAuthenticator(Nullable!Identity.init), storage, signingKey, stores);

    // The token of an execution with fingerprint "fp1", whose one input names artifact
    // "in.zip" of upstream fingerprint "fp_up"
    WorkerTokenClaims claims;
    claims.executionId = executionId;
    claims.fingerprint = "fp1";
    claims.attempt = 2;
    claims.expiresAt = Clock.currTime.toUnixTime() + 600;
    claims.inputs = [InputArtifact("fp_up", "in.zip")];
    const token = mintWorkerToken(signingKey, claims);

    struct Answer { int status; string body; }

    Answer callWith(string presented, HTTPMethod method, string path, string body = "")
    {
        InetHeaderMap headers;
        if (presented.length > 0) headers[workerTokenHeader] = presented;
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink, null, TestHTTPResponseMode.bodyOnly);
        router.handleRequest(createTestHTTPServerRequest(URL("http://localhost" ~ path), method, headers,
            createMemoryStream(cast(ubyte[]) body.dup, false)), res);
        assert(res.headerWritten, "No route answered " ~ path);
        return Answer(res.statusCode, cast(string) sink.data);
    }

    Answer call(HTTPMethod method, string path, string body = "")
    {
        return callWith(token, method, path, body);
    }

    void assertNoServerPath(Answer answer)
    {
        assert(!answer.body.canFind(base) && !answer.body.canFind(tempDir), answer.body);
    }

    // An empty upload is refused and stores nothing
    auto empty = call(HTTPMethod.POST, "/api/v1/artifacts/fp1/out/upload");
    assert(empty.status == HTTPStatus.badRequest, empty.body);
    assert(call(HTTPMethod.HEAD, "/api/v1/artifacts/_head/fp_up/in.zip").status == HTTPStatus.notFound);

    // Errors answer with a short message, never the storage's detail with its server paths
    auto missing = call(HTTPMethod.GET, "/api/v1/artifacts/fp_up/in.zip/download");
    assert(missing.status == HTTPStatus.notFound && missing.body.canFind("Artifact not found"), missing.body);
    assertNoServerPath(missing);

    auto invalid = call(HTTPMethod.POST, "/api/v1/artifacts/fp1/a%3Ab/upload", "bytes");
    assert(invalid.status == HTTPStatus.badRequest && invalid.body.canFind("Invalid fingerprint or artifact id"), invalid.body);
    assertNoServerPath(invalid);

    write(buildPath(base, "fp1"), "a file where the fingerprint directory belongs");
    auto broken = call(HTTPMethod.POST, "/api/v1/artifacts/fp1/out/upload", "bytes");
    assert(broken.status == HTTPStatus.internalServerError && broken.body.canFind("Artifact storage error"), broken.body);
    assertNoServerPath(broken);
    remove(buildPath(base, "fp1"));

    // The execution uploads under its own fingerprint, and downloads what its inputs name
    assert(call(HTTPMethod.POST, "/api/v1/artifacts/fp1/out/upload", "built").status == HTTPStatus.ok);
    assert(storage.artifactExists("fp1", "out"));
    storage.storeArtifactStream("fp_up", "in.zip", (void delegate(const(ubyte)[]) sink) { sink(cast(const(ubyte)[]) "upstream"); });
    assert(call(HTTPMethod.HEAD, "/api/v1/artifacts/_head/fp_up/in.zip").status == HTTPStatus.ok);
    auto download = call(HTTPMethod.GET, "/api/v1/artifacts/fp_up/in.zip/download");
    assert(download.status == HTTPStatus.ok && download.body == "upstream", download.body);
    assert(call(HTTPMethod.GET, "/api/v1/artifacts/presign-upload?fingerprint=fp1&artifactId=out").status == HTTPStatus.ok);
    assert(call(HTTPMethod.GET, "/api/v1/artifacts/presign-download?fingerprint=fp_up&artifactId=in.zip").status == HTTPStatus.ok);

    // Every route refuses a request without a valid token, and the refusal touches nothing
    struct Route { HTTPMethod method; string path; string body; }
    const routes = [
        Route(HTTPMethod.GET, "/api/v1/artifacts/presign-upload?fingerprint=fp1&artifactId=other", ""),
        Route(HTTPMethod.GET, "/api/v1/artifacts/presign-download?fingerprint=fp_up&artifactId=in.zip", ""),
        Route(HTTPMethod.POST, "/api/v1/artifacts/fp1/other/upload", "bytes"),
        Route(HTTPMethod.HEAD, "/api/v1/artifacts/_head/fp_up/in.zip", ""),
        Route(HTTPMethod.GET, "/api/v1/artifacts/fp_up/in.zip/download", ""),
        Route(HTTPMethod.DELETE, "/api/v1/artifacts/fp1/out", ""),
        Route(HTTPMethod.GET, "/api/v1/artifacts/presign-upload", ""),
    ];
    auto expiredClaims = claims;
    expiredClaims.expiresAt = 1;
    const expiredToken = mintWorkerToken(signingKey, expiredClaims);
    const otherKeyToken = mintWorkerToken("fedcba9876543210fedcba9876543210", claims);
    const tamperedToken = token[0 .. 10] ~ (token[10] == 'A' ? "B" : "A") ~ token[11 .. $];
    foreach (route; routes)
    {
        foreach (bad; ["", "garbage", expiredToken, otherKeyToken, tamperedToken])
        {
            auto refused = callWith(bad, route.method, route.path, route.body);
            assert(refused.status == HTTPStatus.unauthorized, route.path ~ " accepted token '" ~ bad ~ "'");
        }
    }
    auto expired = callWith(expiredToken, HTTPMethod.GET, "/api/v1/artifacts/fp_up/in.zip/download");
    assert(expired.body.canFind("expired"), expired.body);
    assert(!storage.artifactExists("fp1", "other"));

    // A genuine token for another execution's fingerprint or artifacts is refused with 403
    auto otherClaims = claims;
    otherClaims.fingerprint = "fp_other";
    otherClaims.inputs = [InputArtifact("fp_up_other", "in.zip")];
    const otherToken = mintWorkerToken(signingKey, otherClaims);
    foreach (route; routes[0 .. $ - 1])
    {
        auto forbidden = callWith(otherToken, route.method, route.path, route.body);
        assert(forbidden.status == HTTPStatus.forbidden, route.path);
    }
    assert(!storage.artifactExists("fp1", "other"));
    assert(call(HTTPMethod.POST, "/api/v1/artifacts/fp_up/other/upload", "bytes").status == HTTPStatus.forbidden,
        "An input's fingerprint is for downloading, not uploading");
    assert(call(HTTPMethod.GET, "/api/v1/artifacts/fp1/out/download").status == HTTPStatus.forbidden,
        "The execution's own fingerprint is not an input");
    assert(call(HTTPMethod.GET, "/api/v1/artifacts/fp_up/other.zip/download").status == HTTPStatus.forbidden,
        "Only the artifact an input names");

    // A token from a superseded attempt may not upload, though it may still read its inputs: the
    // refusal is 409, since the attempt is superseded rather than out of scope
    auto oldClaims = claims;
    oldClaims.attempt = 1;
    const oldAttemptToken = mintWorkerToken(signingKey, oldClaims);
    assert(callWith(oldAttemptToken, HTTPMethod.POST, "/api/v1/artifacts/fp1/other/upload", "bytes").status == HTTPStatus.conflict);
    assert(callWith(oldAttemptToken, HTTPMethod.GET, "/api/v1/artifacts/presign-upload?fingerprint=fp1&artifactId=other").status
        == HTTPStatus.conflict);
    assert(!storage.artifactExists("fp1", "other"));
    assert(callWith(oldAttemptToken, HTTPMethod.GET, "/api/v1/artifacts/fp_up/in.zip/download").status == HTTPStatus.ok);

    // No token deletes
    auto deleted = call(HTTPMethod.DELETE, "/api/v1/artifacts/fp1/out");
    assert(deleted.status == HTTPStatus.forbidden && deleted.body.canFind("deleting"), deleted.body);
    assert(storage.artifactExists("fp1", "out"));

    // A router needs a signing key
    import std.exception : assertThrown;
    auto nobody = new FixedAuthenticator(Nullable!Identity.init);
    assertThrown!Exception(artifactsRouter(nobody, storage, "", stores));
    assertThrown!Exception(artifactsRouter(nobody, storage, "short", stores));
    assertThrown!Exception(artifactsRouter(nobody, storage, signingKey, null));
    assertThrown!Exception(artifactsRouter(null, storage, signingKey, stores));
}
