module confector.api.protocol;

/**
 * Whether a worker route's answer with HTTP `status` rejects the request for good: repeating the
 * same request is refused the same way, so it is not retried. The rejections are 400 (malformed
 * request), 401 (token missing, altered or expired), 403 (token does not allow the request), 404
 * (unknown execution: the ledger never claimed it, and a token is only minted for a claimed one),
 * 409 (the attempt no longer holds the execution, or it already finished) and 422 (a completion that
 * can never be recorded). Any other status, such as the 500 of a store failure, may succeed when
 * repeated.
 */
bool isPermanentRejection(int status) pure nothrow @safe @nogc
{
    return status == 400 || status == 401 || status == 403 || status == 404 || status == 409 || status == 422;
}

/**
 * Whether a worker route's answer with HTTP `status` refuses the worker's token or the attempt it
 * names: 401 (the token is missing, altered or expired), 403 (the token does not allow the request)
 * or 409 (the attempt no longer holds the execution). The token of an execution does not change
 * while it is held, so the same token is refused the same way on every route.
 */
bool isTokenRefusal(int status) pure nothrow @safe @nogc
{
    return status == 401 || status == 403 || status == 409;
}

unittest
{
    // A refused token or attempt is a permanent rejection; a store failure or a success is neither
    foreach (status; [400, 401, 403, 404, 409, 422])
        assert(isPermanentRejection(status), "Retried a permanent rejection");
    foreach (status; [200, 204, 500, 503])
        assert(!isPermanentRejection(status) && !isTokenRefusal(status), "Called a retryable answer a rejection");
    foreach (status; [401, 403, 409])
        assert(isTokenRefusal(status));
    foreach (status; [400, 404, 422])
        assert(!isTokenRefusal(status), "Called a malformed or unknown request a token refusal");
}
