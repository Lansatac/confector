module confector.server.authenticator;

import vibe.vibe;
import std.typecons : Nullable;
import confector.api.model : Role;

/**
 * Who made a request: the identity an authenticator vouches for. Roles are global, and a role
 * implies every lower one (see permits). An identity with no roles is authenticated and reaches
 * nothing.
 */
struct Identity
{
    /// The identity provider's stable name for the user.
    string subject;
    string email;
    string displayName;
    /// The roles the identity holds. Role.none grants nothing.
    Role[] roles;
}

/**
 * The authenticator: the port that maps a request to the identity that made it, or to nobody. It
 * is compiled in and chosen at startup (see buildAuthenticator). An implementation returns an
 * identity only for a request it can vouch for; anything else has no identity, and the server
 * refuses it with 401.
 */
interface Authenticator
{
    /// The identity that made `req`, or a null Nullable when the request vouches for none.
    Nullable!Identity authenticate(HTTPServerRequest req);
}

/**
 * How much a role grants: Role.none grants nothing, and each role above it implies the ones below.
 */
int roleRank(Role role) pure nothrow @safe
{
    final switch (role)
    {
        case Role.none: return 0;
        case Role.viewer: return 1;
        case Role.member: return 2;
        case Role.admin: return 3;
    }
}

/**
 * Whether `identity` may use a route that needs `required`: one of its roles must grant at least
 * `required`. Throws for Role.none, which grants nothing and so cannot be required.
 */
bool permits(in Identity identity, Role required) pure
{
    if (required == Role.none)
        throw new Exception("[auth] A route cannot require the role 'none', which grants nothing");
    foreach (role; identity.roles)
    {
        if (roleRank(role) >= roleRank(required))
            return true;
    }
    return false;
}

unittest
{
    import std.exception : assertThrown;

    assert(roleRank(Role.none) < roleRank(Role.viewer));
    assert(roleRank(Role.viewer) < roleRank(Role.member));
    assert(roleRank(Role.member) < roleRank(Role.admin));

    // A higher role implies the lower ones
    Identity admin;
    admin.roles = [Role.admin];
    assert(admin.permits(Role.admin) && admin.permits(Role.member) && admin.permits(Role.viewer));

    Identity member;
    member.roles = [Role.member];
    assert(!member.permits(Role.admin) && member.permits(Role.member) && member.permits(Role.viewer));

    Identity viewer;
    viewer.roles = [Role.viewer];
    assert(!viewer.permits(Role.member) && viewer.permits(Role.viewer));

    // Several roles: the highest one decides
    Identity both;
    both.roles = [Role.viewer, Role.member];
    assert(both.permits(Role.member));

    // An identity with no role, or only Role.none, reaches nothing
    Identity nobody;
    assert(!nobody.permits(Role.viewer));
    Identity roleless;
    roleless.roles = [Role.none];
    assert(!roleless.permits(Role.viewer));

    // Role.none names no access, so it cannot be required
    assertThrown!Exception(admin.permits(Role.none));
}

version (unittest)
{
    /// Authenticates every request as `identity`, or as nobody when it is null.
    final class FixedAuthenticator : Authenticator
    {
        private Nullable!Identity m_identity;

        this(Nullable!Identity identity)
        {
            m_identity = identity;
        }

        Nullable!Identity authenticate(HTTPServerRequest req)
        {
            return m_identity;
        }
    }

    /// The identity of a test user holding `roles`.
    Nullable!Identity testIdentity(Role[] roles...)
    {
        Identity identity;
        identity.subject = "test-user";
        identity.roles = roles.dup;
        return Nullable!Identity(identity);
    }
}
