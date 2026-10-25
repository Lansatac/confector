module confector.server.trusted_proxy_authenticator;

import vibe.vibe;
import std.array : split;
import std.string : strip;
import std.typecons : Nullable;
import std.uni : sicmp;
import confector.api.model : Role;
import confector.core.constant_time : constantTimeEquals;
import confector.server.authenticator : Authenticator, Identity;
import confector.server.config : RoleMappingConfig, TrustedProxyConfig, requireTrustedProxyConfig;

/**
 * Authenticates the requests an authenticating proxy (such as oauth2-proxy) forwards. The proxy
 * signs users in, sets their identity headers, and sends the shared secret on every request. The
 * identity headers are read only from a request carrying the secret; a request whose secret is
 * missing or wrong has no identity, and the server logs it as a warning. The server must only be
 * reachable through the proxy, which sets the secret itself and passes on no secret or identity
 * headers that a client sent: the server trusts any request that carries the secret.
 */
final class TrustedProxyAuthenticator : Authenticator
{
    private const TrustedProxyConfig m_config;

    /// Throws unless `config` is complete (see requireTrustedProxyConfig).
    this(in TrustedProxyConfig config)
    {
        requireTrustedProxyConfig(config);
        m_config = config;
    }

    Nullable!Identity authenticate(HTTPServerRequest req)
    {
        // A header sent twice could put a client's value ahead of the proxy's, and the first value is
        // the one read, so a repeated proxy header is refused outright
        const string[] proxyHeaders = [m_config.secretHeader, m_config.headers.user, m_config.headers.email,
            m_config.headers.groups];
        foreach (name; proxyHeaders)
        {
            if (req.headers.getAll(name).length > 1)
            {
                logWarn("[auth] Refused %s %s: it sends the %s header more than once", req.method, req.requestPath, name);
                return Nullable!Identity.init;
            }
        }

        const presented = req.headers.get(m_config.secretHeader, "");
        if (presented.length == 0)
        {
            logWarn("[auth] Refused %s %s: it carries no %s header, so it did not come through the authenticating proxy",
                req.method, req.requestPath, m_config.secretHeader);
            return Nullable!Identity.init;
        }
        if (!constantTimeEquals(presented, m_config.secret))
        {
            logWarn("[auth] Refused %s %s: its %s header is not the proxy's secret",
                req.method, req.requestPath, m_config.secretHeader);
            return Nullable!Identity.init;
        }

        const subject = req.headers.get(m_config.headers.user, "");
        if (subject.length == 0)
        {
            logWarn("[auth] Refused %s %s: the proxy sent no %s header naming the user",
                req.method, req.requestPath, m_config.headers.user);
            return Nullable!Identity.init;
        }

        const email = req.headers.get(m_config.headers.email, "");
        const groups = groupNames(req.headers.get(m_config.headers.groups, ""));
        Identity identity;
        identity.subject = subject;
        identity.displayName = subject;
        identity.email = email;
        Role role = mappedRole(m_config.roles, email, groups);
        if (role != Role.none)
            identity.roles = [role];
        return Nullable!Identity(identity);
    }
}

/// The group names in a comma-separated groups header, each stripped of spaces; empty ones are dropped.
string[] groupNames(string header)
{
    string[] groups;
    foreach (part; header.split(","))
    {
        const group = part.strip;
        if (group.length > 0)
            groups ~= group;
    }
    return groups;
}

/**
 * The highest role whose list holds `email` or one of `groups`; Role.none when no list does. Emails
 * match case-insensitively, group names exactly. An empty email matches nothing.
 */
Role mappedRole(in RoleMappingConfig roles, string email, in string[] groups)
{
    if (listHolds(roles.admins, email, groups)) return Role.admin;
    if (listHolds(roles.members, email, groups)) return Role.member;
    if (listHolds(roles.viewers, email, groups)) return Role.viewer;
    return Role.none;
}

private bool listHolds(in string[] entries, string email, in string[] groups)
{
    foreach (entry; entries)
    {
        if (email.length > 0 && sicmp(entry, email) == 0) return true;
        foreach (group; groups)
        {
            if (entry == group) return true;
        }
    }
    return false;
}

unittest
{
    assert(groupNames("eng, contractors ,,readers,") == ["eng", "contractors", "readers"]);
    assert(groupNames("").length == 0);
    assert(groupNames(" , ").length == 0);
}

unittest
{
    RoleMappingConfig roles;
    roles.admins = ["ada@example.com"];
    roles.members = ["eng"];
    roles.viewers = ["guest@example.com", "readers"];

    // Mapped by email and by group, to the role the list names
    assert(mappedRole(roles, "ada@example.com", []) == Role.admin);
    assert(mappedRole(roles, "someone@example.com", ["eng"]) == Role.member);
    assert(mappedRole(roles, "guest@example.com", []) == Role.viewer);
    assert(mappedRole(roles, "someone@example.com", ["readers"]) == Role.viewer);

    // The highest role an identity matches wins
    assert(mappedRole(roles, "ada@example.com", ["readers"]) == Role.admin);
    assert(mappedRole(roles, "guest@example.com", ["eng"]) == Role.member);

    // Emails match case-insensitively, group names exactly, and no match gives no role
    assert(mappedRole(roles, "Ada@example.com", []) == Role.admin);
    assert(mappedRole(roles, "ADA@EXAMPLE.COM", []) == Role.admin);
    assert(mappedRole(roles, "someone@example.com", ["Eng"]) == Role.none);
    assert(mappedRole(roles, "someone@example.com", []) == Role.none);

    // An empty email matches nothing, even a list that holds an empty string
    RoleMappingConfig withEmpty;
    withEmpty.viewers = [""];
    assert(mappedRole(withEmpty, "", []) == Role.none);
}

unittest
{
    import std.exception : assertThrown;
    import vibe.inet.message : InetHeaderMap;
    import confector.server.config : TrustedProxyConfig;
    import confector.server.authenticator : Identity;

    enum secret = "0123456789abcdef0123456789abcdef";

    TrustedProxyConfig config;
    config.secret = secret;
    config.roles.admins = ["ada@example.com"];
    config.roles.members = ["eng"];
    config.roles.viewers = ["guest@example.com"];
    auto authenticator = new TrustedProxyAuthenticator(config);

    // The identity a request presents, or null when it presents none
    Nullable!Identity authenticate(InetHeaderMap headers)
    {
        auto req = createTestHTTPServerRequest(URL("http://localhost/projects/"), HTTPMethod.GET, headers);
        return authenticator.authenticate(req);
    }

    // The identity headers a proxy sends for ada
    InetHeaderMap identityHeaders()
    {
        InetHeaderMap headers;
        headers["X-Forwarded-User"] = "ada";
        headers["X-Forwarded-Email"] = "ada@example.com";
        headers["X-Forwarded-Groups"] = "eng, readers";
        return headers;
    }

    // The same identity headers, with `presentedSecret` in the secret header
    InetHeaderMap proxied(string presentedSecret = secret)
    {
        auto headers = identityHeaders();
        headers["X-Confector-Proxy-Secret"] = presentedSecret;
        return headers;
    }

    // With the secret, the identity comes from the headers, and its roles from the mapping
    auto admin = authenticate(proxied());
    assert(!admin.isNull);
    assert(admin.get.subject == "ada" && admin.get.email == "ada@example.com" && admin.get.displayName == "ada");
    assert(admin.get.roles == [Role.admin]);

    // Mapped by group alone
    InetHeaderMap byGroup;
    byGroup["X-Confector-Proxy-Secret"] = secret;
    byGroup["X-Forwarded-User"] = "grace";
    byGroup["X-Forwarded-Groups"] = "eng";
    assert(authenticate(byGroup).get.roles == [Role.member]);

    // A user matching no role is authenticated, with no roles
    InetHeaderMap stranger;
    stranger["X-Confector-Proxy-Secret"] = secret;
    stranger["X-Forwarded-User"] = "stranger";
    stranger["X-Forwarded-Email"] = "stranger@example.com";
    auto unmapped = authenticate(stranger);
    assert(!unmapped.isNull && unmapped.get.roles.length == 0);

    // No secret, or a wrong one, is no identity, even with identity headers present
    assert(authenticate(identityHeaders()).isNull);
    assert(authenticate(proxied("0123456789abcdef0123456789abcdeX")).isNull);
    assert(authenticate(proxied("0123456789abcdef")).isNull);
    assert(authenticate(proxied("")).isNull);

    // With the secret but no user header, there is no identity to vouch for
    InetHeaderMap noUser;
    noUser["X-Confector-Proxy-Secret"] = secret;
    noUser["X-Forwarded-Email"] = "ada@example.com";
    assert(authenticate(noUser).isNull);

    // A proxy header sent twice is refused, whichever of them repeats, however the values compare
    auto secretTwice = proxied();
    secretTwice.addField("X-Confector-Proxy-Secret", secret);
    assert(authenticate(secretTwice).isNull, "A repeated secret header is refused");

    auto userTwice = proxied();
    userTwice.addField("X-Forwarded-User", "mallory");
    assert(authenticate(userTwice).isNull, "A repeated user header is refused");

    auto emailTwice = proxied();
    emailTwice.addField("X-Forwarded-Email", "mallory@example.com");
    assert(authenticate(emailTwice).isNull, "A repeated email header is refused");

    auto groupsTwice = proxied();
    groupsTwice.addField("X-Forwarded-Groups", "readers");
    assert(authenticate(groupsTwice).isNull, "A repeated groups header is refused");

    // A repeated header that the configuration does not read is no reason to refuse
    auto unrelatedTwice = proxied();
    unrelatedTwice.addField("X-Unrelated", "one");
    unrelatedTwice.addField("X-Unrelated", "two");
    assert(!authenticate(unrelatedTwice).isNull);

    // The header names are configurable
    TrustedProxyConfig custom = config;
    custom.secretHeader = "X-Custom-Secret";
    custom.headers.user = "X-Custom-User";
    auto customAuthenticator = new TrustedProxyAuthenticator(custom);
    InetHeaderMap customHeaders;
    customHeaders["X-Custom-Secret"] = secret;
    customHeaders["X-Custom-User"] = "custom";
    auto req = createTestHTTPServerRequest(URL("http://localhost/projects/"), HTTPMethod.GET, customHeaders);
    assert(customAuthenticator.authenticate(req).get.subject == "custom");
    assert(authenticate(customHeaders).isNull, "The default secret header does not admit a custom one");

    // A proxy without a secret is not constructed
    assertThrown!Exception(new TrustedProxyAuthenticator(TrustedProxyConfig.init));
}
