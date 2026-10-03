module confector.core.system;

public import confector.plugin_api.system;

unittest
{
    import std.json : JSONValue;

    class MockStepProvider : BuildStepProvider
    {
        @property string stepType() const { return "mock-step"; }
        @property string displayName() const { return "Mock Step"; }
        @property string description() const { return "Mock step description"; }
        JSONValue defaultParameters() const { return JSONValue(string[string].init); }
        string[] validateParameters(in JSONValue parameters) const { return null; }
        string renderStepFormHtml(in JSONValue currentParameters) const { return "<div>Mock</div>"; }
    }

    auto stepProv = new MockStepProvider();
    assert(stepProv.stepType == "mock-step");
    assert(stepProv.displayName == "Mock Step");
    assert(stepProv.renderStepFormHtml(JSONValue(string[string].init)) == "<div>Mock</div>");
}
