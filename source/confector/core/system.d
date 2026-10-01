module confector.core.system;

import confector.core.model;
import confector.core.storage;
import confector.core.executor : ExecutionRequest, ExecutionResult, LogDelegate;
import vibe.data.json : Json;

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

    /**
     * Determines whether this system should process inputs for the given task node.
     */
    bool canResolve(in TaskNode task) const;

    /**
     * Executes input resolution for the task entity, staging data into the workspace.
     */
    void resolveInputs(in TaskNode task, ref InputResolutionContext context);
}

/**
 * Context payload provided to fingerprint contribution systems.
 */
struct FingerprintContributionContext
{
    string workspaceDir;
    string[string] resolvedEnv;
    string[string] upstreamArtifactHashes;
    string[string] parameters;
}

/**
 * Stateless system interface for calculating cryptographic fingerprint contributions
 * from specific components attached to a task node.
 */
interface FingerprintContributionSystem
{
    @property string systemName() const;

    /**
     * Determines whether this system contributes to the fingerprint of the given task node.
     */
    bool canContribute(in TaskNode task) const;

    /**
     * Calculates the deterministic SHA256 contribution string for this component/system.
     */
    string contributeFingerprint(in TaskNode task, in FingerprintContributionContext context) const;
}

/**
 * Stateless system interface for executing task payloads matching specific runner components.
 */
interface TaskExecutionSystem
{
    @property string systemName() const;

    /**
     * Determines whether this system can execute the given task node.
     */
    bool canExecute(in TaskNode task) const;

    /**
     * Executes the task node payload and returns the execution result.
     */
    ExecutionResult executeTask(in TaskNode task, in ExecutionRequest request, LogDelegate logCallback = null);
}

/**
 * Stateless system interface for publishing and persisting output artifacts.
 */
interface ArtifactPublishingSystem
{
    @property string systemName() const;

    /**
     * Determines whether this system publishes outputs for the given task node.
     */
    bool canPublish(in TaskNode task) const;

    /**
     * Publishes output artifacts declared on the task node to storage.
     */
    ArtifactMetadata[] publishArtifacts(
        in TaskNode task,
        string buildId,
        string workingDir,
        ArtifactStorage storage,
        LogDelegate logCallback = null
    );
}

unittest
{
    // Verify system interfaces can be instantiated in test mocks
    class MockInputSystem : InputResolverSystem
    {
        @property string systemName() const { return "mock-input-system"; }
        bool canResolve(in TaskNode task) const { return task.id == "test"; }
        void resolveInputs(in TaskNode task, ref InputResolutionContext context) {}
    }

    auto mock = new MockInputSystem();
    assert(mock.systemName == "mock-input-system");
    TaskNode node;
    node.id = "test";
    assert(mock.canResolve(node));
}
