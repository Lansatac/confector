module confector.runner_core.http_artifact_storage;

import confector.plugin_api.model : ArtifactStorage;
import std.json : JSONValue, JSONType, parseJSON;
import std.net.curl : HTTP;
import std.array : Appender;
import std.format : format;
import confector.runner_core.logging : logInfo, logError, logWarn, logDebug;

/**
 * ArtifactStorage implementation that communicates with the Confector server via HTTP.
 *
 * For each store/retrieve operation, it first asks the server for a presigned URL.
 * If the server returns a presigned URL, the agent uploads/downloads directly to the
 * storage backend. If the server returns null (no presigned URL support), the agent
 * falls back to streaming through the server's proxy endpoints.
 *
 * Agents using this class do not need to know anything about artifact storage backends.
 */
class HttpArtifactStorage : ArtifactStorage
{
    private string m_serverUrl;
    private string m_workerToken;

    /**
     * Creates an HttpArtifactStorage that communicates with the specified server.
     *
     * Params:
     *   serverUrl = Base URL of the Confector server (e.g., "http://localhost:8080")
     *   workerToken = Optional worker authorization token
     */
    this(string serverUrl, string workerToken = "")
    {
        import std.string : endsWith;
        string url = serverUrl;
        while (url.length > 0 && url.endsWith("/"))
            url = url[0 .. $ - 1];
        this.m_serverUrl = url;
        this.m_workerToken = workerToken;
    }

    private string apiPath(string subPath) const
    {
        import std.string : startsWith;
        string path = subPath;
        if (!path.startsWith("/"))
            path = "/" ~ path;
        return m_serverUrl ~ "/api/v1" ~ path;
    }

    /**
     * Make an HTTP request and return the response body as a string.
     */
    private string doRequest(string url, HTTP.Method method = HTTP.Method.get, ubyte[] body = null)
    {
        auto http = HTTP(url);
        http.method = method;

        if (m_workerToken.length > 0)
        {
            http.addRequestHeader("X-Worker-Token", m_workerToken);
            http.addRequestHeader("Authorization", "Bearer " ~ m_workerToken);
        }
        http.addRequestHeader("Accept", "application/json");

        char[] responseData;
        http.onReceive = (ubyte[] data) {
            responseData ~= cast(char[])data;
            return data.length;
        };

        if (body !is null && body.length > 0)
        {
            http.addRequestHeader("Content-Type", "application/octet-stream");
            http.setPostData(body, "application/octet-stream");
        }

        http.perform();

        if (http.statusLine.code >= 200 && http.statusLine.code < 300)
        {
            return responseData.idup;
        }
        else
        {
            string errMsg;
            if (responseData.length > 0)
            {
                errMsg = responseData.idup;
            }
            else
            {
                errMsg = format("HTTP %d %s", http.statusLine.code, http.statusLine.reason);
            }
            throw new Exception(format("HTTP %d %s: %s", http.statusLine.code, http.statusLine.reason, errMsg));
        }
    }

    /**
     * Make an HTTP HEAD request and return the status code.
     */
    private int doHeadRequest(string url)
    {
        auto http = HTTP(url);
        http.method = HTTP.Method.head;

        if (m_workerToken.length > 0)
        {
            http.addRequestHeader("X-Worker-Token", m_workerToken);
            http.addRequestHeader("Authorization", "Bearer " ~ m_workerToken);
        }

        http.perform();
        return http.statusLine.code;
    }

    // -- ArtifactStorage interface --

    override void storeArtifactStream(string taskFingerprint, string artifactId,
        void delegate(void delegate(const(ubyte)[])) writer)
    {
        if (writer is null)
            throw new Exception("Writer delegate cannot be null");
        if (taskFingerprint.length == 0)
            throw new Exception("taskFingerprint cannot be empty");
        if (artifactId.length == 0)
            throw new Exception("artifactId cannot be empty");

        // Collect the artifact data into a buffer
        Appender!(ubyte[]) buffer;
        writer((const(ubyte)[] chunk) {
            if (chunk.length > 0)
                buffer.put(chunk);
        });
        auto data = buffer.data;

        // Step 1: Ask the server for a presigned upload URL
        auto presignedUrl = presignUpload(taskFingerprint, artifactId);

        if (presignedUrl !is null && presignedUrl.length > 0)
        {
            // Direct upload to presigned URL
            logDebug("[HttpArtifactStorage] Uploading artifact '%s' (fp: %s) via presigned URL",
                artifactId, taskFingerprint);
            doRequest(presignedUrl, HTTP.Method.put, data);
        }
        else
        {
            // Fall back to server-proxied upload
            logDebug("[HttpArtifactStorage] Uploading artifact '%s' (fp: %s) via server proxy",
                artifactId, taskFingerprint);
            import std.uri : encodeComponent;
            string url = apiPath(format("/artifacts/%s/%s/upload",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));
            doRequest(url, HTTP.Method.post, data);
        }
    }

    override void retrieveArtifactStream(string taskFingerprint, string artifactId,
        void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
            throw new Exception("Sink delegate cannot be null");
        if (taskFingerprint.length == 0)
            throw new Exception("taskFingerprint cannot be empty");
        if (artifactId.length == 0)
            throw new Exception("artifactId cannot be empty");

        // Step 1: Ask the server for a presigned download URL
        auto presignedUrl = presignDownload(taskFingerprint, artifactId);

        string body;
        if (presignedUrl !is null && presignedUrl.length > 0)
        {
            // Direct download from presigned URL
            logDebug("[HttpArtifactStorage] Downloading artifact '%s' (fp: %s) via presigned URL",
                artifactId, taskFingerprint);
            body = doRequest(presignedUrl, HTTP.Method.get);
        }
        else
        {
            // Fall back to server-proxied download
            logDebug("[HttpArtifactStorage] Downloading artifact '%s' (fp: %s) via server proxy",
                artifactId, taskFingerprint);
            import std.uri : encodeComponent;
            string url = apiPath(format("/artifacts/%s/%s/download",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));
            body = doRequest(url, HTTP.Method.get);
        }

        if (body.length > 0)
            sink(cast(const(ubyte)[]) body);
    }

    override bool artifactExists(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0)
            return false;

        try
        {
            import std.uri : encodeComponent;
            // Use _head endpoint since Vibe.d URLRouter has no head() method
            string url = apiPath(format("/artifacts/_head/%s/%s",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));

            int code = doHeadRequest(url);
            return code == 200;
        }
        catch (Exception e)
        {
            logWarn("[HttpArtifactStorage] Failed to check artifact existence '%s' (fp: %s): %s",
                artifactId, taskFingerprint, e.msg);
            return false;
        }
    }

    override void deleteArtifact(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0)
            return;

        try
        {
            import std.uri : encodeComponent;
            string url = apiPath(format("/artifacts/%s/%s",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));

            doRequest(url, HTTP.Method.del);
        }
        catch (Exception e)
        {
            logWarn("[HttpArtifactStorage] Failed to delete artifact '%s' (fp: %s): %s",
                artifactId, taskFingerprint, e.msg);
        }
    }

    override string presignUpload(string taskFingerprint, string artifactId)
    {
        // Ask the server for a presigned upload URL
        try
        {
            import std.uri : encodeComponent;
            string url = apiPath(format("/artifacts/presign-upload?fingerprint=%s&artifactId=%s",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));

            string body = doRequest(url, HTTP.Method.get);
            if (body.length == 0)
                return null;

            auto json = parseJSON(body);
            if (json.type == JSONType.object)
            {
                if (auto p = "uploadUrl" in json)
                {
                    if (p.type == JSONType.string)
                        return p.str;
                }
            }
            return null;
        }
        catch (Exception e)
        {
            logWarn("[HttpArtifactStorage] Failed to get presigned upload URL for '%s' (fp: %s): %s",
                artifactId, taskFingerprint, e.msg);
            return null;
        }
    }

    override string presignDownload(string taskFingerprint, string artifactId)
    {
        // Ask the server for a presigned download URL
        try
        {
            import std.uri : encodeComponent;
            string url = apiPath(format("/artifacts/presign-download?fingerprint=%s&artifactId=%s",
                encodeComponent(taskFingerprint), encodeComponent(artifactId)));

            string body = doRequest(url, HTTP.Method.get);
            if (body.length == 0)
                return null;

            auto json = parseJSON(body);
            if (json.type == JSONType.object)
            {
                if (auto p = "downloadUrl" in json)
                {
                    if (p.type == JSONType.string)
                        return p.str;
                }
            }
            return null;
        }
        catch (Exception e)
        {
            logWarn("[HttpArtifactStorage] Failed to get presigned download URL for '%s' (fp: %s): %s",
                artifactId, taskFingerprint, e.msg);
            return null;
        }
    }

    // -- Display/config methods (not used by agents, but required by interface) --

    @property string backendType() const pure nothrow @safe { return "http"; }
    @property string displayName() const pure nothrow @safe { return "HTTP (Server-Proxyed)"; }
    @property string description() const { return "Artifact storage via Confector server — supports presigned URLs with proxy fallback."; }

    JSONValue defaultConfig() const { return JSONValue(string[string].init); }
    string[] validateConfig(in JSONValue config) const { return null; }
    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        return "<p>HTTP artifact storage — configured via server URL.</p>";
    }
}
