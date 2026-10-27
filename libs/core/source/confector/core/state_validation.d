module confector.core.state_validation;

/**
 * Validation shared by the state stores and the state transitions (AGENTS.md, "Fail loudly"). This
 * is a leaf module: it imports only the API model, so the stores can use it without importing the
 * transitions, which depend on the stores through the evaluator.
 */

import confector.api.model;

import std.format : format;

/// A write that would break the build model's rules: changing an immutable field, rewriting a
/// chain's history, or changing a terminal execution.
class InvalidStateTransitionException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Throws InvalidStateTransitionException unless `state`, the state of request `requestId`, is well
 * formed: cached tasks that appear once, with a fingerprint and blocking tasks exactly when blocked;
 * and an error only on a failed request.
 */
void validateRequestState(string requestId, in RequestState state) @safe
{
    bool[string] seen;
    foreach (ref task; state.tasks)
    {
        requireValid(task.taskId.length > 0 && task.fingerprint.length > 0,
            format("A task state of request '%s' needs a task id and a fingerprint", requestId));
        requireValid(task.taskId !in seen, format("The state of request '%s' has task '%s' twice", requestId, task.taskId));
        seen[task.taskId] = true;
        requireValid((task.status == RequestTaskStatus.blocked) == (task.blockedBy.length > 0), format(
            "Task '%s' of request '%s' is %s and names %s blocking tasks", task.taskId, requestId, task.status, task.blockedBy.length));
    }
    requireValid(state.error.length == 0 || state.outcome == RequestOutcome.failed,
        format("Request '%s' is %s but records an error", requestId, state.outcome));
}

private void requireValid(bool condition, lazy string message) @safe
{
    if (!condition) throw new InvalidStateTransitionException(message);
}

version (unittest)
{
    /// Whether `action` throws InvalidStateTransitionException.
    private bool refuses(scope void delegate() action)
    {
        try action();
        catch (InvalidStateTransitionException) return true;
        return false;
    }
}

unittest
{
    // Malformed request states are refused: tasks twice, blocking tasks that disagree with the status,
    // a task without a fingerprint, and an error on a request that did not fail
    RequestState state;
    validateRequestState("r1", state);

    auto twice = state;
    twice.tasks = [RequestTaskState("compile", "fp1", RequestTaskStatus.queued), RequestTaskState("compile", "fp1", RequestTaskStatus.queued)];
    assert(refuses({ validateRequestState("r1", twice); }));
    auto blocked = state;
    blocked.tasks = [RequestTaskState("test", "fp2", RequestTaskStatus.blocked)];
    assert(refuses({ validateRequestState("r1", blocked); }));
    auto unfingerprinted = state;
    unfingerprinted.tasks = [RequestTaskState("test", "", RequestTaskStatus.queued)];
    assert(refuses({ validateRequestState("r1", unfingerprinted); }));
    auto errored = state;
    errored.error = "why";
    assert(refuses({ validateRequestState("r1", errored); }));
    errored.outcome = RequestOutcome.failed;
    validateRequestState("r1", errored);
}
