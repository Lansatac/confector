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

    Json defaultParameters() const;
    string[] validateParameters(in Json parameters) const;
    string renderStepFormHtml(in Json currentParameters) const;
}

/**
 * Stateless system interface for executing plugin-defined build steps.
 */
interface BuildStepSystem
{
    @property string stepType() const;

    /**
     * Determines whether this system can execute the given build step.
     */
    bool canExecuteStep(in BuildStep step) const;

    /**
     * Executes the build step and returns the result.
     */
    StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context);
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

    class MockStepSystem : BuildStepSystem
    {
        @property string stepType() const { return "mock-step"; }
        bool canExecuteStep(in BuildStep step) const { return step.type == "mock-step"; }
        StepExecutionResult executeStep(in BuildStep step, ref StepExecutionContext context)
        {
            StepExecutionResult res;
            res.success = true;
            res.outputLines = ["mock-step executed"];
            return res;
        }
    }

    auto stepSys = new MockStepSystem();
    assert(stepSys.stepType == "mock-step");
    BuildStep bStep;
    bStep.type = "mock-step";
    assert(stepSys.canExecuteStep(bStep));
    StepExecutionContext sCtx;
    auto sRes = stepSys.executeStep(bStep, sCtx);
    assert(sRes.success);
    assert(sRes.outputLines == ["mock-step executed"]);

    class MockStepProvider : BuildStepProvider
    {
        @property string stepType() const { return "mock-step"; }
        @property string displayName() const { return "Mock Step"; }
        @property string description() const { return "Mock step description"; }
        Json defaultParameters() const { return Json.emptyObject; }
        string[] validateParameters(in Json parameters) const { return null; }
        string renderStepFormHtml(in Json currentParameters) const { return "<div>Mock</div>"; }
    }

    auto stepProv = new MockStepProvider();
    assert(stepProv.stepType == "mock-step");
    assert(stepProv.displayName == "Mock Step");
    assert(stepProv.renderStepFormHtml(Json.emptyObject) == "<div>Mock</div>");
}
