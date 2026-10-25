module confector.core.worker_token;

import confector.api.model : InputKind, WorkOrder;
import confector.core.constant_time : constantTimeEquals;
import core.time : minutes;
import std.base64 : Base64URLNoPadding;
import std.digest.hmac : HMAC;
import std.digest.sha : SHA256;
import std.format : format;
import vibe.data.json : Json, parseJsonString;

/**
 * Per-execution worker tokens. A token is minted when a worker receives a work order and is
 * carried in it; the server checks it on every worker route without looking anything up.
 *
 * Format: `<claims>.<mac>`, both base64url without padding. The claims are a JSON object; the mac
 * is HMAC-SHA256 over a version label and the encoded claims, keyed by the server's signing key.
 * Verification checks the mac before it parses the claims. The token allows only what its claims
 * name: the execution's own logs, heartbeats, release and completion, uploads under the
 * execution's fingerprint, and downloads of the artifacts its inputs name.
 */

/// The request header a worker sends its token in.
enum workerTokenHeader = "X-Confector-Worker-Token";

/// The shortest signing key accepted, in bytes. A shorter key is a configuration error.
enum size_t minimumSigningKeyLength = 32;

/// How long a token outlives its task's timeout: the time to stage inputs, upload outputs and
/// report the completion after the last step.
enum workerTokenGrace = 30.minutes;

private enum macLabel = "confector-worker-token-v1.";

/// An artifact a task input names: the upstream fingerprint and the artifact id.
struct InputArtifact
{
    string fingerprint;
    string artifactId;
}

/// What a token allows.
struct WorkerTokenClaims
{
    /// The execution whose logs and completion the holder may post.
    string executionId;
    /// The fingerprint the holder may upload artifacts under.
    string fingerprint;
    /// The execution attempt the token was issued for (`TaskExecution.attempts` when it was claimed).
    /// A worker from a superseded attempt holds a token for an attempt that is no longer current.
    ulong attempt;
    /// When the token stops being valid, in seconds since the Unix epoch.
    long expiresAt;
    /// The artifacts the holder may check for and download.
    InputArtifact[] inputs;
}

/// A worker request was refused. `statusCode` is the HTTP status to answer with.
class WorkerAuthException : Exception
{
    int statusCode;

    this(int statusCode, string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.statusCode = statusCode;
    }
}

/// The request has no token, or its token is malformed, altered, signed with another key or
/// expired: 401.
class WorkerTokenInvalidException : WorkerAuthException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(401, msg, file, line);
    }
}

/// The token is genuine but does not allow what the request does: 403.
class WorkerTokenScopeException : WorkerAuthException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(403, msg, file, line);
    }
}

/**
 * The claims for the token of `order`, claimed at `issuedAt` (seconds since the Unix epoch) for
 * execution attempt `attempt`. The token expires when the task's timeout and `workerTokenGrace`
 * have passed. Pure.
 *
 * Throws: Exception if the work order lacks an execution, a fingerprint or a resolved
 * task_output input: a token that allowed too little would only fail later, at the worker.
 */
WorkerTokenClaims workerTokenClaimsFor(in WorkOrder order, ulong attempt, long issuedAt)
{
    if (order.executionId.length == 0)
        throw new Exception("Cannot issue a worker token for a work order that names no execution");
    if (order.fingerprint.length == 0)
        throw new Exception(format("Cannot issue a worker token for execution '%s': its work order has no fingerprint", order.executionId));

    WorkerTokenClaims claims;
    claims.executionId = order.executionId;
    claims.fingerprint = order.fingerprint;
    claims.attempt = attempt;
    claims.expiresAt = issuedAt + order.timeoutSeconds + workerTokenGrace.total!"seconds";

    import std.algorithm.sorting : sort;
    foreach (name; order.taskNode.inputs.keys.sort)
    {
        const decl = order.taskNode.inputs[name];
        if (decl.kind != InputKind.taskOutput || decl.spec.artifact.length == 0) continue;
        bool found = false;
        foreach (resolved; order.payload.inputs)
        {
            if (resolved.name != name) continue;
            if (resolved.kind != InputKind.taskOutput || resolved.pinned.type != Json.Type.string)
                throw new Exception(format("Cannot issue a worker token for execution '%s': input '%s' is not pinned to an upstream fingerprint",
                    order.executionId, name));
            claims.inputs ~= InputArtifact(resolved.pinned.get!string, decl.spec.artifact);
            found = true;
            break;
        }
        if (!found)
            throw new Exception(format("Cannot issue a worker token for execution '%s': input '%s' has no resolved value",
                order.executionId, name));
    }
    return claims;
}

/**
 * Signs `claims` with `key`.
 *
 * Throws: Exception if the key is shorter than `minimumSigningKeyLength`.
 */
string mintWorkerToken(in char[] key, in WorkerTokenClaims claims)
{
    requireSigningKey(key);
    Json json = Json.emptyObject;
    json["exec"] = Json(claims.executionId);
    json["fp"] = Json(claims.fingerprint);
    json["att"] = Json(claims.attempt);
    json["exp"] = Json(claims.expiresAt);
    Json inputs = Json.emptyArray;
    foreach (input; claims.inputs)
    {
        Json entry = Json.emptyObject;
        entry["fp"] = Json(input.fingerprint);
        entry["art"] = Json(input.artifactId);
        inputs ~= entry;
    }
    json["in"] = inputs;

    const encoded = Base64URLNoPadding.encode(cast(const(ubyte)[]) json.toString());
    return (encoded ~ "." ~ Base64URLNoPadding.encode(sign(key, encoded))).idup;
}

/**
 * The claims of `token`, if it was signed with `key` and has not expired at `now` (seconds since
 * the Unix epoch). The mac is compared in constant time.
 *
 * Throws: WorkerTokenInvalidException if the token is missing, malformed, altered, signed with
 * another key or expired. Exception if the key is shorter than `minimumSigningKeyLength`.
 */
WorkerTokenClaims verifyWorkerToken(in char[] key, in char[] token, long now)
{
    requireSigningKey(key);
    if (token.length == 0)
        throw new WorkerTokenInvalidException("The request carries no worker token (" ~ workerTokenHeader ~ " header)");

    import std.string : indexOf;
    const dot = token.indexOf('.');
    if (dot < 0 || token[dot + 1 .. $].indexOf('.') >= 0)
        throw new WorkerTokenInvalidException("The worker token is malformed");
    const encoded = token[0 .. dot].idup;

    const presented = decodeBase64Url(token[dot + 1 .. $]);
    if (!constantTimeEquals(presented, sign(key, encoded)))
        throw new WorkerTokenInvalidException("The worker token's signature does not match: it was altered or signed with another key");

    // The mac matched, so the claims are ones this server wrote; a fault here is a bug, not an attack
    WorkerTokenClaims claims;
    try
    {
        const json = parseJsonString(cast(string) decodeBase64Url(encoded));
        claims.executionId = json["exec"].get!string;
        claims.fingerprint = json["fp"].get!string;
        claims.attempt = json["att"].get!ulong;
        claims.expiresAt = json["exp"].get!long;
        foreach (entry; json["in"])
            claims.inputs ~= InputArtifact(entry["fp"].get!string, entry["art"].get!string);
    }
    catch (Exception e)
        throw new WorkerTokenInvalidException("The worker token's claims are malformed: " ~ e.msg);

    if (now >= claims.expiresAt)
        throw new WorkerTokenInvalidException(format("The worker token expired %d seconds ago", now - claims.expiresAt));
    return claims;
}

/// Throws WorkerTokenScopeException unless the token is for `executionId`.
void requireExecution(in WorkerTokenClaims claims, string executionId)
{
    if (claims.executionId != executionId)
        throw new WorkerTokenScopeException(format("The worker token is for execution '%s', not '%s'", claims.executionId, executionId));
}

/// Throws WorkerTokenScopeException unless the token's attempt is `currentAttempt`, the attempt
/// the execution is on now: a worker from a superseded attempt may not report or upload.
void requireCurrentAttempt(in WorkerTokenClaims claims, ulong currentAttempt)
{
    if (claims.attempt != currentAttempt)
        throw new WorkerTokenScopeException(format("The worker token is for attempt %d of execution '%s', which is on attempt %d now",
            claims.attempt, claims.executionId, currentAttempt));
}

/// Throws WorkerTokenScopeException unless the token may upload artifacts under `fingerprint`.
void requireUpload(in WorkerTokenClaims claims, string fingerprint)
{
    if (claims.fingerprint != fingerprint)
        throw new WorkerTokenScopeException(format("The worker token allows uploads under fingerprint '%s', not '%s'", claims.fingerprint, fingerprint));
}

/// Throws WorkerTokenScopeException unless one of the token's inputs names artifact `artifactId`
/// of `fingerprint`.
void requireInputArtifact(in WorkerTokenClaims claims, string fingerprint, string artifactId)
{
    foreach (input; claims.inputs)
    {
        if (input.fingerprint == fingerprint && input.artifactId == artifactId) return;
    }
    throw new WorkerTokenScopeException(format("The worker token's inputs do not name artifact '%s' of fingerprint '%s'", artifactId, fingerprint));
}

/// Throws Exception unless `key` is at least `minimumSigningKeyLength` bytes.
void requireSigningKey(in char[] key)
{
    if (key.length < minimumSigningKeyLength)
        throw new Exception(format("The worker token signing key must be at least %d bytes, not %d", minimumSigningKeyLength, key.length));
}

// Decodes unpadded base64url, checking the text first: Phobos' decoder fails with an Error, not an
// Exception, on some malformed input.
private ubyte[] decodeBase64Url(in char[] text)
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum;
    if (text.length % 4 == 1 || !text.all!(c => isAlphaNum(c) || c == '-' || c == '_'))
        throw new WorkerTokenInvalidException("The worker token is malformed: it is not base64url");
    return Base64URLNoPadding.decode(text);
}

private ubyte[] sign(in char[] key, in char[] encodedClaims)
{
    auto hmac = HMAC!SHA256(cast(const(ubyte)[]) key);
    hmac.put(cast(const(ubyte)[]) macLabel);
    hmac.put(cast(const(ubyte)[]) encodedClaims);
    return hmac.finish().dup;
}

version (unittest)
{
    import confector.api.model : TaskNode, taskOutputInput, valueInput, ResolvedInput;

    private enum testKey = "0123456789abcdef0123456789abcdef";
    private enum testNow = 1_000_000L;

    private WorkOrder testOrder()
    {
        WorkOrder order;
        order.executionId = "exe_1";
        order.fingerprint = "fp_1";
        order.timeoutSeconds = 600;
        order.taskNode.id = "package";
        order.taskNode.inputs["engine"] = taskOutputInput("build-engine", "engine.zip");
        order.taskNode.inputs["setup"] = taskOutputInput("setup");
        order.taskNode.inputs["flavor"] = valueInput("external");
        order.payload.inputs = [
            ResolvedInput("engine", InputKind.taskOutput, Json("fp_engine")),
            ResolvedInput("flavor", InputKind.value, Json("external")),
            ResolvedInput("setup", InputKind.taskOutput, Json("fp_setup")),
        ];
        return order;
    }
}

unittest
{
    // The claims name the execution, its fingerprint, the attempt, the inputs' artifacts and an
    // expiry after the timeout and the grace; a task_output input that names no artifact
    // contributes none
    const claims = workerTokenClaimsFor(testOrder(), 1, testNow);
    assert(claims.executionId == "exe_1" && claims.fingerprint == "fp_1");
    assert(claims.attempt == 1);
    assert(claims.expiresAt == testNow + 600 + 30 * 60);
    assert(claims.inputs == [InputArtifact("fp_engine", "engine.zip")]);

    // A work order that cannot be completed, or whose inputs are not resolved, gets no token
    import std.exception : assertThrown;
    auto noExecution = testOrder();
    noExecution.executionId = "";
    assertThrown!Exception(workerTokenClaimsFor(noExecution, 1, testNow));
    auto noFingerprint = testOrder();
    noFingerprint.fingerprint = "";
    assertThrown!Exception(workerTokenClaimsFor(noFingerprint, 1, testNow));
    auto unresolved = testOrder();
    unresolved.payload.inputs = unresolved.payload.inputs[1 .. $];
    assertThrown!Exception(workerTokenClaimsFor(unresolved, 1, testNow));
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown, collectException;

    // A minted token verifies to the claims it was minted with
    const claims = workerTokenClaimsFor(testOrder(), 1, testNow);
    const token = mintWorkerToken(testKey, claims);
    assert(verifyWorkerToken(testKey, token, testNow) == claims);

    // No token, a malformed one, or one signed with another key is a 401
    foreach (bad; ["", "nodot", "a.b.c", "!!!.!!!", token ~ "x", token[0 .. $ - 2]])
    {
        auto failure = cast(WorkerAuthException) collectException(verifyWorkerToken(testKey, bad, testNow));
        assert(failure !is null && failure.statusCode == 401, "Accepted '" ~ bad ~ "'");
    }
    auto otherKey = cast(WorkerAuthException) collectException(verifyWorkerToken("fedcba9876543210fedcba9876543210", token, testNow));
    assert(otherKey !is null && otherKey.statusCode == 401 && otherKey.msg.canFind("signature"));

    // Altering the claims (here: another execution, with the original signature) is caught
    import std.string : indexOf;
    auto forgedClaims = cast() claims;
    forgedClaims.executionId = "exe_other";
    const forgedToken = mintWorkerToken(testKey, forgedClaims);
    const spliced = forgedToken[0 .. forgedToken.indexOf('.')] ~ token[token.indexOf('.') .. $];
    auto tampered = cast(WorkerAuthException) collectException(verifyWorkerToken(testKey, spliced, testNow));
    assert(tampered !is null && tampered.statusCode == 401 && tampered.msg.canFind("signature"), spliced);

    // A token is valid until its expiry, then refused
    verifyWorkerToken(testKey, token, claims.expiresAt - 1);
    auto expired = cast(WorkerAuthException) collectException(verifyWorkerToken(testKey, token, claims.expiresAt));
    assert(expired !is null && expired.statusCode == 401 && expired.msg.canFind("expired"));

    // A short key neither signs nor verifies
    assertThrown!Exception(mintWorkerToken("short", claims));
    assertThrown!Exception(verifyWorkerToken("short", token, testNow));
}

unittest
{
    import std.exception : collectException;

    const claims = workerTokenClaimsFor(testOrder(), 1, testNow);

    // Each scope check passes for what the claims name and refuses anything else with a 403
    requireExecution(claims, "exe_1");
    requireCurrentAttempt(claims, 1);
    requireUpload(claims, "fp_1");
    requireInputArtifact(claims, "fp_engine", "engine.zip");

    void refused(void delegate() check)
    {
        auto failure = cast(WorkerAuthException) collectException(check());
        assert(failure !is null && failure.statusCode == 403);
    }
    refused({ requireExecution(claims, "exe_2"); });
    refused({ requireCurrentAttempt(claims, 2); });
    refused({ requireCurrentAttempt(claims, 0); });
    refused({ requireUpload(claims, "fp_2"); });
    refused({ requireUpload(claims, "fp_engine"); });
    refused({ requireInputArtifact(claims, "fp_engine", "other.zip"); });
    refused({ requireInputArtifact(claims, "fp_1", "engine.zip"); });
    refused({ requireInputArtifact(claims, "fp_setup", "setup"); });
}
