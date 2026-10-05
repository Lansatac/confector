module plugins.powershell.def;

import std.format;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model;
import confector.plugin_api.plugin;
import confector.plugin_api.system : BuildStepProvider;

/**
 * PowerShell step definition plugin.
 * Implements StepDefinitionPlugin and BuildStepProvider interfaces for PowerShell scripts.
 */
class PowerShellDefinitionPlugin : StepDefinitionPlugin, BuildStepProvider
{
    private PluginContext m_context;

    @property string name() const { return "powershell-def"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "PowerShell script step definition and UI template plugin"; }
    @property PluginCategory category() const { return PluginCategory.definition; }
    @property string stepType() const { return "powershell"; }
    @property string displayName() const { return "PowerShell Script"; }

    ConfigDefinition[] configDefinitions() const { return null; }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("PowerShellDefinitionPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("PowerShellDefinitionPlugin shut down");
        }
    }

    JSONValue defaultParameters() const
    {
        string defaultExe;
        version(Windows)
        {
            defaultExe = "powershell";
        }
        else
        {
            defaultExe = "pwsh";
        }
        JSONValue p = JSONValue(["script": JSONValue(""), "workingDirectory": JSONValue(""), "executable": JSONValue(defaultExe)]);
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
        auto pScript = "script" in parameters;
        auto pCommand = "command" in parameters;
        if ((pScript is null || pScript.str.length == 0) &&
            (pCommand is null || pCommand.str.length == 0))
        {
            errors ~= "PowerShell script or command cannot be empty";
        }
        return errors;
    }

    string renderStepFormHtml(in JSONValue currentParameters) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;
        string script = "";
        string workingDir = "";
        string executable = "";
        version(Windows)
        {
            executable = "powershell";
        }
        else
        {
            executable = "pwsh";
        }

        if (currentParameters.type == JSONType.object)
        {
            if (auto p = "script" in currentParameters) script = p.str;
            else if (auto p = "command" in currentParameters) script = p.str;

            if (auto p = "workingDirectory" in currentParameters) workingDir = p.str;
            else if (auto p = "working_directory" in currentParameters) workingDir = p.str;

            if (auto p = "executable" in currentParameters) executable = p.str;
        }

        compileHTMLDietFile!("step.dt", script, workingDir, executable)(html);

        return html.data;
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new PowerShellDefinitionPlugin();
}

unittest
{
    auto plugin = new PowerShellDefinitionPlugin();
    plugin.initialize(new NullPluginContext("powershell-def"));
    assert(plugin.name == "powershell-def");
    assert(plugin.category == PluginCategory.definition);
    assert(plugin.stepType == "powershell");
    assert(plugin.displayName == "PowerShell Script");

    JSONValue validParams = JSONValue(["script": JSONValue("Write-Output 'hello'")]);
    assert(plugin.validateParameters(validParams).length == 0);

    JSONValue invalidParams = JSONValue(["script": JSONValue("")]);
    assert(plugin.validateParameters(invalidParams).length > 0);

    auto html = plugin.renderStepFormHtml(validParams);
    assert(html.length > 0);
}
