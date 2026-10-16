module confector.core.api_token_store;

/**
 * API tokens in the state store (design record: bead confector-z7z.10). Only the SHA-256 of a
 * token's secret is stored, and it is the document id, so authenticating a request is one read by
 * id. Tokens are revoked, never removed, so a revoked token keeps failing to authenticate.
 */

import confector.core.build_stores : InvalidStateTransitionException;
import confector.core.document_collection;
import confector.core.model;
import confector.plugin_api.document_store;

import std.format : format;
import std.typecons : Nullable;

/// API tokens, by the SHA-256 of their secret; indexed by owner.
enum CollectionSpec apiTokensCollection = CollectionSpec("api_tokens", [IndexSpec("by_owner", "owner", "created_key")]);

/// The stored hash of an API token's secret: its SHA-256 in lowercase hex.
string hashTokenSecret(string secret) @safe
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;

    if (secret.length == 0) throw new Exception("An API token secret must not be empty");
    return toHexString!(LetterCase.lower)(sha256Of(secret)).idup;
}

/**
 * API tokens.
 */
final class ApiTokenStore
{
    private DocumentCollection!ApiToken m_tokens;

    /// Declares `apiTokensCollection` on `store`.
    this(DocumentStore store)
    {
        m_tokens = new DocumentCollection!ApiToken(store, apiTokensCollection, ["created_key"],
            (in ApiToken token) => ["created_key": sortableTimestamp(token.createdAt)]);
    }

    /**
     * The token whose secret is `secret`, if it exists, is not revoked and has a role. Strongly
     * consistent, so a revoked token stops authenticating at once.
     */
    Nullable!ApiToken authenticate(string secret)
    {
        auto token = m_tokens.get(hashTokenSecret(secret));
        if (token.isNull || token.get.revokedAt.length > 0 || token.get.role == Role.none) return Nullable!ApiToken.init;
        return Nullable!ApiToken(token.get.value);
    }

    /// Reads a token by the hash of its secret. Null if there is none.
    Nullable!(Versioned!ApiToken) get(string secretHash)
    {
        return m_tokens.get(secretHash);
    }

    /**
     * Records `token`.
     *
     * Throws: DocumentConflictException if a token with its hash exists;
     * InvalidStateTransitionException if it has no hash, name, owner or role, or is already revoked;
     * Exception if `createdAt` is not an ISO 8601 timestamp.
     */
    Versioned!ApiToken create(ApiToken token)
    {
        if (token.secretHash.length == 0 || token.name.length == 0 || token.owner.length == 0 || token.role == Role.none
            || token.revokedAt.length > 0)
        {
            throw new InvalidStateTransitionException(format("API token '%s' needs a secret hash, a name, an owner and a role, and must not be revoked",
                token.name));
        }
        return m_tokens.create(token.secretHash, token);
    }

    /**
     * Revokes the token `current` at `revokedAt`. Revoking is the only change a token allows.
     *
     * Throws: DocumentConflictException if the token changed since `current` was read;
     * InvalidStateTransitionException if it is already revoked; Exception if `revokedAt` is not
     * an ISO 8601 timestamp.
     */
    Versioned!ApiToken revoke(in Versioned!ApiToken current, string revokedAt)
    {
        if (current.revokedAt.length > 0)
        {
            throw new InvalidStateTransitionException(format("API token '%s' of '%s' is already revoked", current.name, current.owner));
        }
        sortableTimestamp(revokedAt);
        ApiToken next = current.value;
        next.revokedAt = revokedAt;
        return m_tokens.replace(current.secretHash, next, current.version_);
    }

    /// Lists `owner`'s tokens, revoked ones included, oldest first. Discovery.
    ApiToken[] listForOwner(string owner)
    {
        IndexQuery lookup;
        lookup.index = "by_owner";
        lookup.partitionKey = owner;
        lookup.limit = 100;
        ApiToken[] result;
        foreach (item; m_tokens.queryAll(lookup)) result ~= item.value;
        return result;
    }
}

unittest
{
    import confector.core.memory_document_store : InMemoryDocumentStore;

    bool throwsA(E)(scope void delegate() action)
    {
        try action();
        catch (E) return true;
        return false;
    }

    auto tokens = new ApiTokenStore(new InMemoryDocumentStore());
    ApiToken token;
    token.secretHash = hashTokenSecret("s3cret");
    token.name = "ci";
    token.owner = "jason";
    token.role = Role.member;
    token.createdAt = "2026-10-15T14:02:00Z";
    auto created = tokens.create(token);
    auto second = token;
    second.secretHash = hashTokenSecret("other");
    second.name = "laptop";
    second.createdAt = "2026-10-15T15:00:00Z";
    tokens.create(second);

    // The secret is never stored; the token is found by its hash
    assert(token.secretHash != "s3cret" && token.secretHash.length == 64);
    assert(tokens.authenticate("s3cret").get == token);
    assert(tokens.authenticate("wrong").isNull);
    assert(throwsA!Exception({ tokens.authenticate(""); }));
    auto listed = tokens.listForOwner("jason");
    assert(listed.length == 2 && listed[0].name == "ci" && listed[1].name == "laptop");

    // A revoked token stops authenticating at once, and stays recorded
    auto revoked = tokens.revoke(created, "2026-10-16T09:00:00Z");
    assert(revoked.revokedAt == "2026-10-16T09:00:00Z");
    assert(tokens.authenticate("s3cret").isNull);
    assert(!tokens.get(token.secretHash).isNull);
    assert(throwsA!InvalidStateTransitionException({ tokens.revoke(revoked, "2026-10-16T10:00:00Z"); }));
    assert(throwsA!DocumentConflictException({ tokens.revoke(created, "2026-10-16T10:00:00Z"); }));

    assert(throwsA!DocumentConflictException({ tokens.create(token); }));
    auto unowned = token;
    unowned.secretHash = hashTokenSecret("x");
    unowned.owner = null;
    assert(throwsA!InvalidStateTransitionException({ tokens.create(unowned); }));

    // A token whose role was never set is rejected, and one stored without a role (written
    // directly to the database) authenticates nothing: tokens fail closed
    auto roleless = token;
    roleless.secretHash = hashTokenSecret("roleless");
    roleless.role = Role.init;
    assert(roleless.role == Role.none);
    assert(throwsA!InvalidStateTransitionException({ tokens.create(roleless); }));
    auto documents = new InMemoryDocumentStore();
    auto direct = new ApiTokenStore(documents);
    import vibe.data.json : serializeToJson;
    documents.create(apiTokensCollection.name, roleless.secretHash, () {
        auto content = serializeToJson(roleless);
        content["created_key"] = sortableTimestamp(roleless.createdAt);
        return content;
    }());
    assert(!direct.get(roleless.secretHash).isNull);
    assert(direct.authenticate("roleless").isNull);
}
