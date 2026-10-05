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
    @property string displayName() const { return "Clone Git Repository"; }

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

    JSONValue defaultParameters() const
    {
        JSONValue p = JSONValue(["repository": JSONValue(""), "branch": JSONValue(""), "target_dir": JSONValue("")]);
        return p;
    }

    string[] validateParameters(in JSONValue parameters) const
    {
        string[] errors;
        if (parameters.type != JSONType.object)
        {
            errors ~= "Parameters must be a JSON object";
            return errors;
        }

        string target = "";
        if (auto p = "target_dir" in parameters) target = p.str;
        else if (auto p = "targetDirectory" in parameters) target = p.str;
        else if (auto p = "target" in parameters) target = p.str;

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
        string repoUrl = "";
        string branch = "";
        string targetDir = "";

        if (currentParameters.type == JSONType.object)
        {
            if (auto p = "repository" in currentParameters) repoUrl = p.str;
            else if (auto p = "url" in currentParameters) repoUrl = p.str;
            else if (auto p = "address" in currentParameters) repoUrl = p.str;

            if (auto p = "branch" in currentParameters) branch = p.str;
            if (auto p = "target_dir" in currentParameters) targetDir = p.str;
            else if (auto p = "targetDirectory" in currentParameters) targetDir = p.str;
            else if (auto p = "target" in currentParameters) targetDir = p.str;
        }

        compileHTMLDietFile!("step.dt", repoUrl, branch, targetDir)(html);

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
    assert(plugin.displayName == "Clone Git Repository");

    JSONValue validParams = JSONValue(["repository": JSONValue("https://github.com/user/repo.git"), "target_dir": JSONValue("src")]);
    assert(plugin.validateParameters(validParams).length == 0);

    JSONValue invalidParams = JSONValue(["target_dir": JSONValue("../escaped")]);
    assert(plugin.validateParameters(invalidParams).length > 0);

    auto html = plugin.renderStepFormHtml(validParams);
    assert(html.length > 0);
}
