module confector.core.constant_time;

/**
 * Compares two arrays without stopping at the first difference, so the time taken does not
 * reveal how much of a guessed secret or mac was right. Unequal lengths are rejected at once; the
 * length of the expected value is not treated as confidential.
 */
bool constantTimeEquals(T)(const(T)[] a, const(T)[] b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    uint difference = 0;
    foreach (i; 0 .. a.length)
        difference |= cast(uint)(a[i] ^ b[i]);
    return difference == 0;
}

unittest
{
    assert(constantTimeEquals("abc", "abc"));
    assert(!constantTimeEquals("abc", "abd"));
    assert(!constantTimeEquals("abc", "abcd"));
    assert(!constantTimeEquals("", "abc"));
    assert(constantTimeEquals(cast(const(ubyte)[]) [1, 2, 3], cast(const(ubyte)[]) [1, 2, 3]));
    assert(!constantTimeEquals(cast(const(ubyte)[]) [1, 2, 3], cast(const(ubyte)[]) [1, 2, 4]));
}
