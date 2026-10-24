module confector.server.scheduler_callback;

import vibe.vibe;
import std.format : format;
import confector.api.scheduler : schedulerSecretHeader;
import confector.core.constant_time : constantTimeEquals;

/**
 * Wraps a scheduler callback so that the handler runs only when the request carries the scheduler
 * secret in the X-Confector-Scheduler-Secret header. A request without the header, or with a
 * different value, is answered 401 and the handler does not run. An empty expected secret is a
 * configuration error and throws when the route is built, rather than leaving the callback open.
 */
void delegate(HTTPServerRequest, HTTPServerResponse) schedulerCallback(H)(string expectedSecret, H handler)
{
    if (expectedSecret.length == 0)
        throw new Exception("Scheduler callback route built without a scheduler secret");

    return (HTTPServerRequest req, HTTPServerResponse res) {
        string presented = req.headers.get(schedulerSecretHeader, "");
        if (presented.length == 0)
        {
            rejectSchedulerCallback(res, format("Missing %s header", schedulerSecretHeader));
            return;
        }
        if (!constantTimeEquals(presented, expectedSecret))
        {
            rejectSchedulerCallback(res, format("Invalid %s header", schedulerSecretHeader));
            return;
        }
        handler(req, res);
    };
}

private void rejectSchedulerCallback(HTTPServerResponse res, string message)
{
    res.statusCode = HTTPStatus.unauthorized;
    Json err = Json.emptyObject;
    err["error"] = Json(message);
    res.writeJsonBody(err);
}

unittest
{
    import std.exception : assertThrown;

    bool ran = false;
    void delegate(HTTPServerRequest, HTTPServerResponse) inner = (req, res) { ran = true; res.statusCode = HTTPStatus.ok; };
    auto guarded = schedulerCallback("expected-secret", inner);

    // Missing header
    auto req = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/p1/run"), HTTPMethod.POST);
    auto res = createTestHTTPServerResponse();
    guarded(req, res);
    assert(res.statusCode == HTTPStatus.unauthorized);
    assert(!ran);

    // Wrong secret, same length and different length
    req = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/p1/run"), HTTPMethod.POST);
    req.headers[schedulerSecretHeader] = "expected-secreT";
    res = createTestHTTPServerResponse();
    guarded(req, res);
    assert(res.statusCode == HTTPStatus.unauthorized);
    assert(!ran);

    req = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/p1/run"), HTTPMethod.POST);
    req.headers[schedulerSecretHeader] = "x";
    res = createTestHTTPServerResponse();
    guarded(req, res);
    assert(res.statusCode == HTTPStatus.unauthorized);
    assert(!ran);

    // Correct secret reaches the handler
    req = createTestHTTPServerRequest(URL("http://localhost/api/v1/projects/p1/run"), HTTPMethod.POST);
    req.headers[schedulerSecretHeader] = "expected-secret";
    res = createTestHTTPServerResponse();
    guarded(req, res);
    assert(ran);
    assert(res.statusCode == HTTPStatus.ok);

    // An unconfigured secret never builds a route
    assertThrown!Exception(schedulerCallback("", inner));
}
