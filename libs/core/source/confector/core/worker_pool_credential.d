module confector.core.worker_pool_credential;

import confector.core.constant_time : constantTimeEquals;
import std.format : format;

/// The request header a runner sends its worker pool credential in. Only receiving work sends it.
enum string workerPoolCredentialHeader = "X-Confector-Worker-Pool-Credential";

/// The shortest worker pool credential accepted, in bytes. A shorter one is a configuration error.
enum size_t minimumWorkerPoolCredentialLength = 32;

/**
 * Throws unless `credential` is long enough to be a secret. The server checks it at startup and
 * the runner checks it before it presents it, so neither runs on a short one. The message never
 * includes the credential.
 */
void requireWorkerPoolCredential(in char[] credential)
{
    if (credential.length < minimumWorkerPoolCredentialLength)
        throw new Exception(format("The worker pool credential must be at least %d bytes, not %d",
            minimumWorkerPoolCredentialLength, credential.length));
}

/**
 * Whether `presented` is the `expected` worker pool credential, compared in constant time.
 * Throws if `expected` is too short to be a credential, so an unset pool never admits anyone.
 */
bool matchesWorkerPoolCredential(in char[] expected, in char[] presented)
{
    requireWorkerPoolCredential(expected);
    return constantTimeEquals(expected, presented);
}

unittest
{
    import std.exception : assertThrown;

    enum credential = "0123456789abcdef0123456789abcdef";
    assert(matchesWorkerPoolCredential(credential, credential));
    assert(!matchesWorkerPoolCredential(credential, "0123456789abcdef0123456789abcdeX"));
    assert(!matchesWorkerPoolCredential(credential, ""));
    assert(!matchesWorkerPoolCredential(credential, credential ~ "x"));

    requireWorkerPoolCredential(credential);
    assertThrown!Exception(requireWorkerPoolCredential("too-short"));
    assertThrown!Exception(requireWorkerPoolCredential(""));
    assertThrown!Exception(matchesWorkerPoolCredential("", ""));
}
