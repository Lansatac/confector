module confector.core.model;

/// Re-export all domain models and interfaces from plugin_api for backward compatibility.
/// All types defined here are now owned by plugin_api.model; this module exists solely
/// to maintain backward compatibility for existing import paths.
public import confector.plugin_api.model;
public import confector.plugin_api.system : StepExecutionResult, StepExecutionContext;
