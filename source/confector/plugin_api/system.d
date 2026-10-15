module confector.plugin_api.system;

import confector.plugin_api.model;
import confector.plugin_api.executor : LogDelegate;
import std.json : JSONValue, JSONType;
import vibe.data.serialization : optional;

/**
 * Context payload provided to a build step system during step execution.
 */
struct StepExecutionContext
{
    string buildId;
    string taskId;
    string workspaceDir;
    string workingDirectory;
    string[string] environment;
    ArtifactStorage artifactStorage;
    LogDelegate logCallback;
    string[string] taskParameters;
    /// The task's resolved inputs, keyed by input name, exactly as the work order pinned them.
    /// Inputs are not materialized automatically: a step that needs one (the built-in checkout
    /// step) looks it up by name.
    ResolvedInput[string] inputs;
    /// Address of the repository each repository input names, keyed by input name. Used only
    /// by the built-in checkout step.
    string[string] repositoryAddresses;
}

/**
 * Result of executing an individual build step.
 */
struct StepExecutionResult
{
    bool success = true;
    int exitCode = 0;
    string errorMessage;
    string[] outputLines;
}

/**
 * Plugin interface for providing build step types, validation, and dynamic sub-template configuration UI.
 */
interface BuildStepProvider
{
    @property string stepType() const;
    @property string displayName() const;
    @property string description() const;

    JSONValue defaultParameters() const;
    string[] validateParameters(in JSONValue parameters) const;
    string renderStepFormHtml(in JSONValue currentParameters) const;
}

/**
 * Stateless system interface for executing plugin-defined build steps.
 */
interface BuildStepSystem
{
    @property string systemName() const;
    bool canExecuteStep(in BuildStep step) const;
    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context);
}

/**
 * Stateless system interface for publishing and persisting output artifacts.
 */
interface ArtifactPublishingSystem
{
    @property string systemName() const;
    bool canPublish(in TaskNode task) const;
    ArtifactMetadata[] publishArtifacts(
        in TaskNode task,
        string buildId,
        string workingDir,
        ArtifactStorage storage,
        LogDelegate logCallback = null
    );
}
