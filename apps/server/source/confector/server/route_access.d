module confector.server.route_access;

import vibe.vibe;
import std.algorithm.searching : startsWith;
import std.format : format;
import std.typecons : Nullable;
import confector.api.model : Role;
import confector.server.authenticator : Authenticator, Identity, permits;

/// A route's handler. Its attributes are inferred, as they are for the handlers the controllers register.
alias RouteHandler = void delegate(HTTPServerRequest req, HTTPServerResponse res);

/**
 * The credentials that protect the routes no user identity reaches. Such a route is registered as
 * excluded, naming its credential; its handler checks that credential itself, before anything else
 * about the request is looked at. The name of each credential is what the route table shows.
 */
enum ExcludedBy : string
{
    /// The per-execution worker token, signed with the worker token signing key.
    workerToken = "worker-token",
    /// The worker pool credential, which only receiving work presents.
    workerPoolCredential = "worker-pool-credential",
    /// The scheduler callback secret, which every scheduler callback presents.
    schedulerSecret = "scheduler-secret",
}

/**
 * One registered route and its access: the role a user identity needs, or the credential that
 * protects the route instead. Exactly one of the two is set.
 */
struct RouteRule
{
    HTTPMethod method;
    string path;
    Nullable!Role role;
    Nullable!ExcludedBy excludedBy;

    /// The access as text: the role's name, or the name of the credential that protects the route.
    string access() const
    {
        return role.isNull ? cast(string) excludedBy.get : cast(string) role.get;
    }
}

/**
 * The server's routes. Every route is registered with its access, so none exists without one: a
 * user route names the role it needs, and an excluded route names its credential. Every user
 * route is wrapped here, so the authenticator runs before its handler and nothing registers a
 * route around it.
 */
final class AuthorizedRoutes : HTTPServerRequestHandler
{
    private struct Entry
    {
        RouteRule rule;
        RouteHandler handler;
    }

    private URLRouter m_router;
    private Authenticator m_authenticator;
    private Entry[] m_entries;
    private bool m_answersUnmatched;
    private string[] m_unmatchedExempt;

    /// Routes that `authenticator` admits requests through. Required: without one the routes could
    /// not tell who is asking, so the server cannot start.
    this(Authenticator authenticator)
    {
        if (authenticator is null)
            throw new Exception("[auth] The routes need an authenticator: without one they cannot tell who is asking");
        m_authenticator = authenticator;
        m_router = new URLRouter();
    }

    /// Registers a GET route that needs `role`.
    void get(string path, Role role, RouteHandler handler)
    {
        route(HTTPMethod.GET, path, role, handler);
    }

    /// Registers a POST route that needs `role`.
    void post(string path, Role role, RouteHandler handler)
    {
        route(HTTPMethod.POST, path, role, handler);
    }

    /// Registers a DELETE route that needs `role`.
    void delete_(string path, Role role, RouteHandler handler)
    {
        route(HTTPMethod.DELETE, path, role, handler);
    }

    /// Registers a route no user identity reaches. `handler` checks `protectedBy` itself.
    void excluded(HTTPMethod method, string path, ExcludedBy protectedBy, RouteHandler handler)
    {
        add(RouteRule(method, path, Nullable!Role.init, Nullable!ExcludedBy(protectedBy)), handler);
    }

    /// Adds every route of `routes`, with its access, to these routes. Both must share one
    /// authenticator: the included routes are guarded by this one.
    void include(AuthorizedRoutes routes)
    {
        if (routes.m_authenticator !is m_authenticator)
            throw new Exception("[auth] Routes can only be included into routes that share their authenticator");
        foreach (entry; routes.m_entries)
            add(entry.rule, entry.handler);
    }

    /// Answers a request that no route matches: 401 to one with no identity, 404 to one with an identity.
    /// A path that starts with one of `exemptPrefixes` is left unanswered, so its own handling applies.
    void answerUnmatched(string[] exemptPrefixes)
    {
        m_answersUnmatched = true;
        m_unmatchedExempt = exemptPrefixes.dup;
    }

    /// Every route registered here, in registration order.
    RouteRule[] rules()
    {
        RouteRule[] all;
        foreach (entry; m_entries)
            all ~= entry.rule;
        return all;
    }

    // Trusted: the authenticator and the refusal are system code, as the handlers they guard are.
    @trusted void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        m_router.handleRequest(req, res);
        if (res.headerWritten || !m_answersUnmatched)
            return;

        const path = req.requestPath.toString();
        foreach (prefix; m_unmatchedExempt)
        {
            if (path.startsWith(prefix))
                return;
        }
        if (m_authenticator.authenticate(req).isNull)
        {
            refuse(req, res, HTTPStatus.unauthorized, "Authentication required");
            return;
        }
        res.statusCode = HTTPStatus.notFound;
        Json err = Json.emptyObject;
        err["error"] = Json("Not found");
        res.writeJsonBody(err);
    }

    private void route(HTTPMethod method, string path, Role role, RouteHandler handler)
    {
        if (role == Role.none)
            throw new Exception(format("[auth] The route %s %s names no role: it needs viewer, member or admin", method, path));
        add(RouteRule(method, path, Nullable!Role(role), Nullable!ExcludedBy.init), handler);
    }

    // Wraps `handler` with this router's authenticator when its rule names a role, so a route
    // added from another router is guarded here.
    private void add(RouteRule rule, RouteHandler handler)
    {
        foreach (entry; m_entries)
        {
            if (entry.rule.method == rule.method && entry.rule.path == rule.path)
                throw new Exception(format("[auth] The route %s %s is registered twice", rule.method, rule.path));
        }

        RouteHandler served = handler;
        if (!rule.role.isNull)
        {
            auto authenticator = m_authenticator;
            auto role = rule.role.get;
            served = (HTTPServerRequest req, HTTPServerResponse res) {
                if (!authorize(authenticator, req, res, role)) return;
                handler(req, res);
            };
        }
        m_router.match(rule.method, rule.path, served);
        m_entries ~= Entry(rule, handler);
    }
}

/**
 * Checks that the identity of `req` may run a route that needs `required`. Answers 401 when the
 * authenticator vouches for no identity, and 403 when the identity's roles do not reach `required`,
 * and returns false: the route must not run then. Returns true otherwise.
 */
bool authorize(Authenticator authenticator, HTTPServerRequest req, HTTPServerResponse res, Role required)
{
    auto identity = authenticator.authenticate(req);
    if (identity.isNull)
    {
        refuse(req, res, HTTPStatus.unauthorized, "Authentication required");
        return false;
    }
    if (!identity.get.permits(required))
    {
        refuse(req, res, HTTPStatus.forbidden, format("This needs the '%s' role", cast(string) required));
        return false;
    }
    return true;
}

private void refuse(HTTPServerRequest req, HTTPServerResponse res, HTTPStatus status, string reason)
{
    logInfo("[auth] Refused %s %s (HTTP %d): %s", req.method, req.requestPath, cast(int) status, reason);
    res.statusCode = status;
    Json err = Json.emptyObject;
    err["error"] = Json(reason);
    res.writeJsonBody(err);
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown, collectException;
    import confector.server.authenticator : FixedAuthenticator, testIdentity;

    // A handler that answers 200, so a status other than 200 shows that the guard answered
    RouteHandler ok = (HTTPServerRequest req, HTTPServerResponse res) {
        res.statusCode = HTTPStatus.ok;
        res.writeVoidBody();
    };

    // The status a request gets, or 0 when no route answered it
    int answered(AuthorizedRoutes routes, HTTPMethod method, string path)
    {
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method);
        auto res = createTestHTTPServerResponse();
        routes.handleRequest(req, res);
        return res.headerWritten ? res.statusCode : 0;
    }

    AuthorizedRoutes routesFor(Nullable!Identity identity)
    {
        auto routes = new AuthorizedRoutes(new FixedAuthenticator(identity));
        routes.get("/read", Role.viewer, ok);
        routes.post("/write", Role.member, ok);
        routes.delete_("/remove", Role.admin, ok);
        routes.excluded(HTTPMethod.POST, "/hook", ExcludedBy.schedulerSecret, ok);
        routes.answerUnmatched(["/hidden/"]);
        return routes;
    }

    // Without an identity every user route answers 401, and the excluded route runs on its own check
    auto nobody = routesFor(Nullable!Identity.init);
    assert(answered(nobody, HTTPMethod.GET, "/read") == HTTPStatus.unauthorized);
    assert(answered(nobody, HTTPMethod.POST, "/write") == HTTPStatus.unauthorized);
    assert(answered(nobody, HTTPMethod.DELETE, "/remove") == HTTPStatus.unauthorized);
    assert(answered(nobody, HTTPMethod.POST, "/hook") == HTTPStatus.ok);

    // A role too low for a route answers 403, and a higher role reaches it
    auto viewer = routesFor(testIdentity(Role.viewer));
    assert(answered(viewer, HTTPMethod.GET, "/read") == HTTPStatus.ok);
    assert(answered(viewer, HTTPMethod.POST, "/write") == HTTPStatus.forbidden);
    assert(answered(viewer, HTTPMethod.DELETE, "/remove") == HTTPStatus.forbidden);

    auto member = routesFor(testIdentity(Role.member));
    assert(answered(member, HTTPMethod.POST, "/write") == HTTPStatus.ok);
    assert(answered(member, HTTPMethod.DELETE, "/remove") == HTTPStatus.forbidden);

    auto admin = routesFor(testIdentity(Role.admin));
    assert(answered(admin, HTTPMethod.GET, "/read") == HTTPStatus.ok);
    assert(answered(admin, HTTPMethod.DELETE, "/remove") == HTTPStatus.ok);

    // An identity with no role, or only Role.none, is refused everywhere a role is needed: fail closed
    assert(answered(routesFor(testIdentity()), HTTPMethod.GET, "/read") == HTTPStatus.forbidden);
    assert(answered(routesFor(testIdentity(Role.none)), HTTPMethod.GET, "/read") == HTTPStatus.forbidden);

    // A path no route is registered on: an anonymous request is answered 401, so the response does not
    // reveal which paths exist; a signed-in request is answered 404, for a wrong method too
    assert(answered(nobody, HTTPMethod.GET, "/unregistered") == HTTPStatus.unauthorized);
    assert(answered(viewer, HTTPMethod.GET, "/unregistered") == HTTPStatus.notFound);
    assert(answered(viewer, HTTPMethod.GET, "/write") == HTTPStatus.notFound, "A wrong method is unmatched");

    // Paths under an exempt prefix are left unanswered, to their own handling
    assert(answered(nobody, HTTPMethod.GET, "/hidden/x") == 0);
    assert(answered(viewer, HTTPMethod.GET, "/hidden/x") == 0);

    // The route table: each route with its access
    auto rules = routesFor(Nullable!Identity.init).rules();
    assert(rules.length == 4);
    assert(rules[0].access == "viewer" && rules[1].access == "member" && rules[2].access == "admin");
    assert(rules[3].access == "scheduler-secret" && rules[3].method == HTTPMethod.POST);
    foreach (rule; rules)
        assert(rule.role.isNull != rule.excludedBy.isNull, "A route has exactly one of a role or an exclusion");

    // A route cannot be registered without a role, a second time, or without an authenticator
    assert(collectException(routesFor(Nullable!Identity.init).get("/none", Role.none, ok)) !is null);
    auto twice = new AuthorizedRoutes(new FixedAuthenticator(Nullable!Identity.init));
    twice.get("/twice", Role.viewer, ok);
    auto duplicate = collectException(twice.get("/twice", Role.admin, ok));
    assert(duplicate !is null && duplicate.msg.canFind("/twice"), "A second registration of a route must throw");
    assertThrown!Exception(new AuthorizedRoutes(null));

    // Routes added from another AuthorizedRoutes keep their access, under the same authenticator; one
    // with another authenticator is refused
    auto sharedAuth = new FixedAuthenticator(Nullable!Identity.init);
    auto combined = new AuthorizedRoutes(sharedAuth);
    auto sub = new AuthorizedRoutes(sharedAuth);
    sub.delete_("/remove", Role.admin, ok);
    combined.include(sub);
    assert(answered(combined, HTTPMethod.DELETE, "/remove") == HTTPStatus.unauthorized);
    assert(combined.rules().length == 1);
    auto foreign = collectException(combined.include(routesFor(testIdentity(Role.admin))));
    assert(foreign !is null && foreign.msg.canFind("authenticator"), "Routes with another authenticator are refused");
}
