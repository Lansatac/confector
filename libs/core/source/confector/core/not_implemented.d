module confector.core.not_implemented;

/**
 * Thrown by a stub: code that must exist so the project compiles, but whose behaviour a later
 * bead implements. A stub fails loudly with this exception instead of doing something
 * plausible, and names the bead, so whoever hits it knows where the work is tracked.
 */
class NotImplementedException : Exception
{
    /// What is not implemented, as a phrase ("Starting builds").
    string what;
    /// The bead that implements it, for example "confector-z7z.23.7".
    string bead;

    this(string what, string bead, string file = __FILE__, size_t line = __LINE__) @safe
    {
        import std.format : format;

        if (what.length == 0 || bead.length == 0)
        {
            throw new Exception("A NotImplementedException must say what is missing and name the bead that implements it");
        }
        super(format("%s is not implemented yet (bead %s)", what, bead), file, line);
        this.what = what;
        this.bead = bead;
    }
}

unittest
{
    auto e = new NotImplementedException("Starting builds", "confector-z7z.23.7");
    assert(e.msg == "Starting builds is not implemented yet (bead confector-z7z.23.7)");
    assert(e.what == "Starting builds" && e.bead == "confector-z7z.23.7");

    bool threw = false;
    try new NotImplementedException("Starting builds", "");
    catch (Exception) threw = true;
    assert(threw, "A stub must name its bead");
}
