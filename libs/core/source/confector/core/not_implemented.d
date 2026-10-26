module confector.core.not_implemented;

/**
 * Thrown by a stub: code that must exist so the project compiles, but whose behaviour is not
 * written yet. A stub fails loudly with this exception instead of doing something plausible.
 */
class NotImplementedException : Exception
{
    /// What is not implemented, as a phrase ("Starting builds").
    string what;

    this(string what, string file = __FILE__, size_t line = __LINE__) @safe
    {
        import std.format : format;

        if (what.length == 0)
        {
            throw new Exception("A NotImplementedException must say what is missing");
        }
        super(format("%s is not implemented yet", what), file, line);
        this.what = what;
    }
}

unittest
{
    auto e = new NotImplementedException("Starting builds");
    assert(e.msg == "Starting builds is not implemented yet");
    assert(e.what == "Starting builds");

    bool threw = false;
    try new NotImplementedException("");
    catch (Exception) threw = true;
    assert(threw, "A stub must say what is missing");
}
