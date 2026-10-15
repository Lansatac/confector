module plugins.git.def;

import std.format;
import std.path : buildNormalizedPath, isAbsolute, dirSeparator;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.system : BuildStepProvider;

/**
 * Git step definition plugin.
 * Implements StepDefinitionPlugin and BuildStepProvider interfaces for Git checkout/clone steps.
 */
class GitDefinitionPlugin : StepDefinitionPlugin, BuildStepProvider
{
    private PluginContext m_context;

    @property string name() const { return "git-def"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Git step definition and UI template plugin"; }
    @property PluginCategory category() const { return PluginCategory.definition; }
    @property string stepType() const { return "clone_repository"; }
    @property string displayName() const { return "Check Out Repository Input"; }

    ConfigDefinition[] configDefinitions() const { return null; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("GitDefinitionPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("GitDefinitionPlugin shut down");
        }
    }

    /// A checkout step names a declared repository input (`input`) and checks out its pinned
    /// commit; it takes no URL, repository or ref. See the git runner plugin for its options.
    JSONValue defaultParameters() const
    {
        JSONValue p = JSONValue(["input": JSONValue(""), "target_dir": JSONValue("")]);
        return p;
    }

    string[] validateParameters(in JSONValue parameters) const
    {
        import std.algorithm.searching : canFind;

        static immutable string[] supported = ["input", "target_dir", "depth", "submodules"];

        string[] errors;
        if (parameters.type != JSONType.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }

        foreach (key, value; parameters.object)
        {
            if (!supported.canFind(key))
            {
                errors ~= format("Parameter '%s' is not supported; a checkout step names a repository input with 'input'", key);
            }
        }
        auto input = "input" in parameters;
        if (input is null || input.type != JSONType.string || input.str.length == 0)
        {
            errors ~= "A checkout step must name the repository input to check out ('input')";
        }

        string target = "";
        if (auto p = "target_dir" in parameters) target = p.str;

        if (target.length > 0 && target != ".")
        {
            import std.algorithm.searching : startsWith;
            string norm = buildNormalizedPath(target);
            if (isAbsolute(norm) || norm == ".." || norm.startsWith(".." ~ dirSeparator) || norm.startsWith("../") || norm.startsWith("..\\"))
            {
                errors ~= "Target directory cannot be an absolute path or escape the workspace directory";
            }
        }

        return errors;
    }

    string renderStepFormHtml(in JSONValue currentParameters) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;
        string inputName = "";
        string targetDir = "";

        if (currentParameters.type == JSONType.object)
        {
            if (auto p = "input" in currentParameters) inputName = p.str;
            if (auto p = "target_dir" in currentParameters) targetDir = p.str;
        }

        compileHTMLDietFile!("step.dt", inputName, targetDir)(html);

        return html.data;
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new GitDefinitionPlugin();
}

unittest
{
    auto plugin = new GitDefinitionPlugin();
    plugin.initialize(new NullPluginContext("git-def"));
    assert(plugin.name == "git-def");
    assert(plugin.category == PluginCategory.definition);
    assert(plugin.stepType == "clone_repository");
    assert(plugin.displayName == "Check Out Repository Input");

    JSONValue validParams = JSONValue(["input": JSONValue("src"), "target_dir": JSONValue("src")]);
    assert(plugin.validateParameters(validParams).length == 0);

    JSONValue invalidParams = JSONValue(["input": JSONValue("src"), "target_dir": JSONValue("../escaped")]);
    assert(plugin.validateParameters(invalidParams).length > 0);

    // A checkout step takes an input name, never a URL
    JSONValue urlParams = JSONValue(["input": JSONValue("src"), "repository": JSONValue("https://github.com/user/repo.git")]);
    assert(plugin.validateParameters(urlParams).length == 1);
    assert(plugin.validateParameters(JSONValue(["target_dir": JSONValue("src")])).length == 1);
    // The git program is not a task's choice
    assert(plugin.validateParameters(JSONValue(["input": JSONValue("src"), "executable": JSONValue("evil")])).length == 1);

    import std.string : indexOf;
    auto html = plugin.renderStepFormHtml(validParams);
    assert(html.indexOf(`name="step_param_input"`) >= 0 && html.indexOf(`<select`) >= 0 && html.indexOf(`value="src"`) >= 0);
    assert(html.indexOf("step_param_repository") < 0);
}
