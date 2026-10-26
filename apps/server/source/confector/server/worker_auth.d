module confector.server.worker_auth;

import vibe.vibe;
import confector.core.state_stores : StateStores;
import confector.core.worker_pool_credential : matchesWorkerPoolCredential, workerPoolCredentialHeader;
import confector.core.work_orders : currentAttempt;
import confector.core.worker_token : WorkerAuthException, WorkerTokenClaims, WorkerTokenScopeException, requireCurrentAttempt,
    verifyWorkerToken, workerTokenHeader;
import std.datetime.systime : Clock;
import std.format : format;

/**
 * Checks that `req` presents the worker pool credential `expected` in the pool credential header.
 * Returns true if it does. Otherwise answers 401, saying only which header is missing or wrong,
 * and returns false: the caller must not run the route. Call it before anything else about the
 * request is looked at.
 */
bool authenticateWorkerPool(string expected, HTTPServerRequest req, HTTPServerResponse res)
{
    const presented = req.headers.get(workerPoolCredentialHeader, "");
    if (presented.length > 0 && matchesWorkerPoolCredential(expected, presented))
        return true;
    const reason = presented.length == 0
        ? format("Missing %s header", workerPoolCredentialHeader)
        : format("Invalid %s header", workerPoolCredentialHeader);
    refuseWorker(req, res, new WorkerAuthException(HTTPStatus.unauthorized, reason));
    return false;
}

/**
 * Checks the worker token of `req` against the server's signing `key`. Returns true and sets
 * `claims` if the token is genuine and unexpired. Otherwise answers 401 with the reason, and
 * returns false: the caller must not run the route. Call it before anything else about the
 * request is looked at. Add it to every route a worker calls.
 */
bool authenticateWorker(string key, HTTPServerRequest req, HTTPServerResponse res, out WorkerTokenClaims claims)
{
    try
    {
        claims = verifyWorkerToken(key, req.headers.get(workerTokenHeader, ""), Clock.currTime.toUnixTime());
        return true;
    }
    catch (WorkerAuthException e)
    {
        refuseWorker(req, res, e);
        return false;
    }
}

/**
 * Runs `requireScope`, which checks that an authenticated worker's claims allow the request. If
 * it throws WorkerAuthException, answers 403 with the reason and returns false.
 */
bool permitWorker(HTTPServerRequest req, HTTPServerResponse res, void delegate() requireScope)
{
    try
    {
        requireScope();
        return true;
    }
    catch (WorkerAuthException e)
    {
        refuseWorker(req, res, e);
        return false;
    }
}

/**
 * Throws WorkerTokenScopeException unless the token's attempt is the one its execution is on, so
 * a worker from a superseded attempt cannot report or upload. An execution that does not exist
 * is refused when `missingIsRefused`; otherwise the route is left to answer for it.
 */
void requireCurrentExecutionAttempt(StateStores stores, in WorkerTokenClaims claims, bool missingIsRefused)
{
    auto attempt = currentAttempt(stores, claims.fingerprint, claims.executionId);
    if (attempt.isNull)
    {
        if (missingIsRefused)
            throw new WorkerTokenScopeException(format("Execution '%s' does not exist", claims.executionId));
        return;
    }
    requireCurrentAttempt(claims, attempt.get);
}

private void refuseWorker(HTTPServerRequest req, HTTPServerResponse res, WorkerAuthException e)
{
    logWarn("[auth] Refused %s %s (HTTP %d): %s", req.method, req.requestPath, e.statusCode, e.msg);
    res.statusCode = e.statusCode;
    Json err = Json.emptyObject;
    err["error"] = Json(e.msg);
    res.writeJsonBody(err);
}
