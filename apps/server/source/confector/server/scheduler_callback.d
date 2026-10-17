module confector.server.scheduler_callback;

import vibe.vibe;
import std.format : format;
import confector.plugin_api.scheduler : schedulerSecretHeader;

/**
 * Compares two strings without stopping at the first difference, so the time taken does not
 * reveal how much of a guessed secret was right. Unequal lengths are rejected at once; the
 * length of the configured secret is not treated as confidential.
 */
bool constantTimeEquals(in char[] a, in char[] b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    uint difference = 0;
    foreach (i; 0 .. a.length)
        difference |= cast(uint)(a[i] ^ b[i]);
    return difference == 0;
}

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

    assert(constantTimeEquals("abc", "abc"));
    assert(!constantTimeEquals("abc", "abd"));
    assert(!constantTimeEquals("abc", "abcd"));
    assert(!constantTimeEquals("", "abc"));

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
