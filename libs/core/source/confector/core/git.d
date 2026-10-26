module confector.core.git;

/**
 * Pure text helpers for git: the control-plane git resolver (confector.core.git_resolver), the
 * runner's checkout step, the repository store (which refuses addresses with credentials) and the
 * dashboard views (which never show them).
 *
 * A repository address is a URL (`scheme://[userinfo@]host/path`), an scp-like address
 * (`[userinfo@]host:path`, with no scheme) or a local path. Only the authority of a URL or
 * scp-like address can hold userinfo: the text up to the first '/', '?', '#', backslash or
 * whitespace.
 */

/**
 * True if `s` is a complete git object id: 40 (SHA-1) or 64 (SHA-256) hex digits.
 */
bool isFullSha(string s) pure nothrow @safe @nogc
{
    import std.ascii : isHexDigit;

    if (s.length != 40 && s.length != 64) return false;
    foreach (immutable char c; s)
    {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

/**
 * Replaces the userinfo of every URL in `text` (`https://user:token@host/...` becomes
 * `https://***@host/...`), so credentials embedded in a repository address never reach an
 * exception message or a log. Only URLs are recognised in text, not scp-like addresses. Pure.
 */
string redactUserInfo(string text) pure @safe
{
    import std.array : appender;
    import std.string : indexOf;

    auto app = appender!string();
    size_t i = 0;
    while (i < text.length)
    {
        const sep = text[i .. $].indexOf("://");
        if (sep < 0)
        {
            app.put(text[i .. $]);
            break;
        }
        const authorityStart = i + cast(size_t) sep + 3;
        app.put(text[i .. authorityStart]);

        // The userinfo ends at the last '@' of the authority
        const end = authorityEnd(text, authorityStart);
        ptrdiff_t at = -1;
        foreach (j; authorityStart .. end)
        {
            if (text[j] == '@') at = j;
        }
        if (at >= 0)
        {
            app.put("***");
            app.put(text[at .. end]);
        }
        else
        {
            app.put(text[authorityStart .. end]);
        }
        i = end;
    }
    return app.data;
}

/**
 * Whether repository address `address` embeds credentials that checkout must get from the secret
 * store instead. A password (`user:password@`, or the same with its ':' percent-encoded as `%3A`)
 * always counts. A bare user name counts unless the address is an ssh one (`ssh://git@host/r.git`,
 * `git+ssh://`, `ssh+git://`) or scp-like (`git@host:r.git`), where it only selects the login: on
 * any other scheme, such as https, a bare user name is a token. An empty user name is no
 * credential. Pure.
 */
bool addressCarriesCredentials(string address) pure @safe
{
    const parts = splitAddress(address);
    if (parts.at < 0) return false;
    const userinfo = address[parts.start .. cast(size_t) parts.at];
    if (hasPassword(userinfo)) return true;
    if (userinfo.length == 0) return false;
    const sshLogin = parts.scheme.length == 0 || isSshScheme(parts.scheme);
    return !sshLogin;
}

/**
 * `address` with its credentials replaced by `***`, so that a view can say where the repository
 * is without showing them. An address without credentials is returned as it is, so a login that
 * selects an ssh account stays visible. Pure.
 */
string redactAddress(string address) pure @safe
{
    if (!addressCarriesCredentials(address)) return address;
    const parts = splitAddress(address);
    return address[0 .. parts.start] ~ "***" ~ address[cast(size_t) parts.at .. $];
}

/// An address split into its scheme ("" unless it is a URL), its authority from `start` to `end`,
/// and `at`, the index of the '@' that ends the userinfo (-1 if the authority has none).
private struct AddressParts
{
    string scheme;
    size_t start;
    size_t end;
    ptrdiff_t at = -1;
}

private AddressParts splitAddress(string address) pure @safe
{
    import std.string : indexOf;

    AddressParts parts;
    const sep = address.indexOf("://");
    if (sep > 0 && isUrlScheme(address[0 .. cast(size_t) sep]))
    {
        parts.scheme = address[0 .. cast(size_t) sep];
        parts.start = cast(size_t) sep + 3;
    }
    parts.end = authorityEnd(address, parts.start);
    foreach (i; parts.start .. parts.end)
    {
        if (address[i] == '@') parts.at = i;
    }
    return parts;
}

/// The index where the authority that starts at `start` ends: the first '/', '?', '#', backslash
/// or whitespace, or the end of `text`. The backslash keeps a Windows path such as `C:\repos\a@b`
/// from having userinfo.
private size_t authorityEnd(string text, size_t start) pure nothrow @safe @nogc
{
    import std.ascii : isWhite;

    size_t end = start;
    while (end < text.length)
    {
        const c = text[end];
        if (c == '/' || c == '?' || c == '#' || c == '\\' || isWhite(c)) break;
        ++end;
    }
    return end;
}

/// Whether `s` is a URL scheme: a letter, then letters, digits, '+', '-' or '.' (as git reads it).
/// Anything else before "://" means the address is scp-like or a local path.
private bool isUrlScheme(string s) pure nothrow @safe @nogc
{
    import std.ascii : isAlpha, isAlphaNum;

    if (s.length == 0 || !isAlpha(s[0])) return false;
    foreach (c; s)
    {
        if (!isAlphaNum(c) && c != '+' && c != '-' && c != '.') return false;
    }
    return true;
}

/// Whether userinfo `userinfo` carries a password: a ':' or its percent-encoding "%3A" in any case.
private bool hasPassword(string userinfo) pure nothrow @safe @nogc
{
    foreach (i, c; userinfo)
    {
        if (c == ':') return true;
        if (c == '%' && i + 2 < userinfo.length && userinfo[i + 1] == '3'
            && (userinfo[i + 2] == 'A' || userinfo[i + 2] == 'a'))
        {
            return true;
        }
    }
    return false;
}

/// Whether `scheme` names an ssh transport, ignoring ASCII case: `ssh`, `git+ssh` or `ssh+git`.
private bool isSshScheme(string scheme) pure nothrow @safe
{
    import std.ascii : toLower;

    foreach (name; ["ssh", "git+ssh", "ssh+git"])
    {
        if (scheme.length != name.length) continue;
        size_t i = 0;
        while (i < name.length && toLower(scheme[i]) == name[i]) ++i;
        if (i == name.length) return true;
    }
    return false;
}

unittest // credentials in URLs are redacted
{
    assert(redactUserInfo("https://user:t0ken@example.test/r.git") == "https://***@example.test/r.git");
    assert(redactUserInfo("git ls-remote https://x-access-token:abc@github.com/o/r failed: fatal: https://tok@github.com/o/r not found")
        == "git ls-remote https://***@github.com/o/r failed: fatal: https://***@github.com/o/r not found");
    assert(redactUserInfo("ssh://git@host:22/r.git") == "ssh://***@host:22/r.git");
    assert(redactUserInfo("https://u:p@ss@host/r") == "https://***@host/r", "Userinfo ends at the last '@'");
    assert(redactUserInfo("https://example.test/a@b") == "https://example.test/a@b", "An '@' in the path is not userinfo");
    assert(redactUserInfo("https://host?x=a@b") == "https://host?x=a@b", "An '@' in the query is not userinfo");
    assert(redactUserInfo("git@host:org/r.git") == "git@host:org/r.git");
    assert(redactUserInfo("") == "" && redactUserInfo("no url here") == "no url here");
}

unittest // addresses: credentials are refused; a bare ssh or scp login, a query or a Windows path is not
{
    assert(!addressCarriesCredentials("https://github.com/o/r.git"));
    assert(!addressCarriesCredentials("/srv/repos/r.git") && !addressCarriesCredentials(""));
    assert(!addressCarriesCredentials("https://example.test/a@b"), "An '@' in the path is not userinfo");
    assert(!addressCarriesCredentials("https://host?x=a@b"), "An '@' in the query is not userinfo");
    assert(!addressCarriesCredentials("https://host#a@b"), "An '@' in the fragment is not userinfo");
    assert(!addressCarriesCredentials("host:org/a@b.git"), "An '@' after the path is not userinfo");
    assert(!addressCarriesCredentials(`C:\repos\a@b`), "A Windows path is not userinfo");
    assert(!addressCarriesCredentials("https://@host/r"), "An empty user name is no credential");
    assert(addressCarriesCredentials("https://token@github.com/o/r.git"));
    assert(addressCarriesCredentials("https://user:pass@host/x.git"));
    assert(addressCarriesCredentials("https://u:p@ss@host/r"), "Userinfo ends at the last '@'");
    assert(addressCarriesCredentials("git://token@host/r"));
    assert(addressCarriesCredentials("ssh://user:pass@host/r.git"));
    assert(addressCarriesCredentials("ssh://user%3Apass@host/r"), "A percent-encoded ':' is a password");
    assert(addressCarriesCredentials("https://user%3apass@host/r"));
    assert(addressCarriesCredentials("user:pass@host:org/repo.git"));
    assert(addressCarriesCredentials("user:pass@host:org/r.git?x=https://y"), "Only a valid scheme makes a URL");
    assert(!addressCarriesCredentials("ssh://git@host:22/r.git"));
    assert(!addressCarriesCredentials("SSH://git@host/r.git"));
    assert(!addressCarriesCredentials("git+ssh://git@host/r.git"));
    assert(!addressCarriesCredentials("ssh+git://git@host/r.git"));
    assert(!addressCarriesCredentials("git@github.com:org/repo.git"));
    assert(addressCarriesCredentials("ssh+git://user:pw@host/r"));
    assert(!addressCarriesCredentials("\u00DFsh://x@host/r"), "A scheme that is not ASCII is not a URL");
}

unittest // views hide credentials and keep the logins that select an account
{
    assert(redactAddress("https://user:pass@host/x.git") == "https://***@host/x.git");
    assert(redactAddress("https://token@host/x.git") == "https://***@host/x.git");
    assert(redactAddress("user:pass@host:org/repo.git") == "***@host:org/repo.git");
    assert(redactAddress("ssh://user%3Apass@host/r") == "ssh://***@host/r");
    assert(redactAddress("git@github.com:org/repo.git") == "git@github.com:org/repo.git");
    assert(redactAddress("ssh://git@host/r.git") == "ssh://git@host/r.git");
    assert(redactAddress("https://example.test/a@b") == "https://example.test/a@b");
    assert(redactAddress("https://host?x=a@b") == "https://host?x=a@b");
}

unittest
{
    assert(isFullSha("1111111111111111111111111111111111111111"));
    assert(isFullSha("AB" ~ "0000000000000000000000000000000000000000000000000000000000000000"[0 .. 62]));
    assert(!isFullSha("abc123"));
    assert(!isFullSha("g111111111111111111111111111111111111111"));
}
