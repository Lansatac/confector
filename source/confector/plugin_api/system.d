module confector.plugin_api.system;

import confector.plugin_api.model;
import confector.plugin_api.executor : ExecutionRequest, ExecutionResult, LogDelegate;
import std.json : JSONValue, JSONType;
import vibe.data.serialization : optional;

/**
 * Context payload provided to input resolution systems during workflow preparation.
 */
struct InputResolutionContext
{
    string buildId;
    string workspaceDir;
    string effectiveWorkingDir;
    ArtifactStorage artifactStorage;
    LogDelegate logCallback;
    string[string] parameters;
}

/**
 * Stateless system interface for resolving input components attached to task nodes
 * (e.g., Git clones, remote tarballs, S3 datasets, upstream artifacts).
 */
interface InputResolverSystem
{
    @property string systemName() const;
    bool canResolve(in TaskNode task) const;
    void resolveInputs(in TaskNode task, ref InputResolutionContext context);
}

/**
 * Context payload provided to fingerprint contribution systems.
 */
struct FingerprintContributionContext
{
    string workspaceDir;
    string[string] upstreamArtifactHashes;
    @optional string[string] upstreamFingerprints;
    string[string] parameters;
}

/**
 * Stateless system interface for calculating cryptographic fingerprint contributions
 * from specific components attached to a task node.
 */
interface FingerprintContributionSystem
{
    @property string systemName() const;
    bool canContribute(in TaskNode task) const;
    string contributeFingerprint(in TaskNode task, in FingerprintContributionContext context) const;
}

/**
 * Stateless system interface for executing task payloads matching specific runner components.
 */
interface TaskExecutionSystem
{
    @property string systemName() const;
    bool canExecute(in TaskNode task) const;
    ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null);
}

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
    string[] allowedRepositories;
    string[string] repositoryMap;
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
