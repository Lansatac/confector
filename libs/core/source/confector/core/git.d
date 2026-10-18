module confector.core.git;

/**
 * Pure text helpers shared by the control-plane git resolver (confector.core.git_resolver) and
 * the runner's checkout step.
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
 * exception message or a log. Pure.
 */
string redactUserInfo(string text) pure @safe
{
    import std.array : appender;
    import std.ascii : isWhite;
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
        const authorityStart = i + sep + 3;
        app.put(text[i .. authorityStart]);

        // The authority runs to the next '/', whitespace or end; its userinfo ends at its last '@'.
        size_t end = authorityStart;
        ptrdiff_t at = -1;
        while (end < text.length && text[end] != '/' && !isWhite(text[end]))
        {
            if (text[end] == '@') at = end;
            ++end;
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

unittest // credentials in URLs are redacted
{
    assert(redactUserInfo("https://user:t0ken@example.test/r.git") == "https://***@example.test/r.git");
    assert(redactUserInfo("git ls-remote https://x-access-token:abc@github.com/o/r failed: fatal: https://tok@github.com/o/r not found")
        == "git ls-remote https://***@github.com/o/r failed: fatal: https://***@github.com/o/r not found");
    assert(redactUserInfo("ssh://git@host:22/r.git") == "ssh://***@host:22/r.git");
    assert(redactUserInfo("https://u:p@ss@host/r") == "https://***@host/r", "Userinfo ends at the last '@'");
    assert(redactUserInfo("https://example.test/a@b") == "https://example.test/a@b", "An '@' in the path is not userinfo");
    assert(redactUserInfo("git@host:org/r.git") == "git@host:org/r.git");
    assert(redactUserInfo("") == "" && redactUserInfo("no url here") == "no url here");
}

unittest
{
    assert(isFullSha("1111111111111111111111111111111111111111"));
    assert(isFullSha("AB" ~ "0000000000000000000000000000000000000000000000000000000000000000"[0 .. 62]));
    assert(!isFullSha("abc123"));
    assert(!isFullSha("g111111111111111111111111111111111111111"));
}
