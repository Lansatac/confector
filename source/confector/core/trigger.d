module confector.core.trigger;

import confector.core.model;
import std.path : globMatch;

/**
 * Utility for evaluating trigger rules against incoming trigger events.
 */
struct TriggerMatcher
{
    /**
     * Checks if a single TriggerRule matches an incoming TriggerEvent.
     */
    static bool matches(in TriggerRule rule, in TriggerEvent event) pure nothrow @safe
    {
        if (rule.type != event.type)
        {
            return false;
        }

        final switch (rule.type)
        {
            case TriggerType.manual:
                return true;

            case TriggerType.gitPush:
                if (rule.branches.length == 0) return true;
                foreach (branchPattern; rule.branches)
                {
                    if (globMatch(event.branch, branchPattern))
                    {
                        return true;
                    }
                }
                return false;

            case TriggerType.gitTag:
                if (rule.tags.length == 0) return true;
                foreach (tagPattern; rule.tags)
                {
                    if (globMatch(event.tag, tagPattern))
                    {
                        return true;
                    }
                }
                return false;

            case TriggerType.webhook:
                if (rule.endpoint.length == 0) return true;
                return rule.endpoint == event.endpoint;

            case TriggerType.cron:
                if (rule.cronSchedule.length == 0) return true;
                return true;
        }
    }

    /**
     * Finds all task IDs in a task list that are triggered by the specified event.
     */
    static string[] findMatchingTasks(in TaskNode[] tasks, in TriggerEvent event) @safe
    {
        // If an explicit target task was specified (e.g. manual dispatch to a specific node)
        if (event.targetTaskId.length > 0)
        {
            foreach (task; tasks)
            {
                if (task.id == event.targetTaskId)
                {
                    return [task.id];
                }
            }
            return [];
        }

        string[] matchingTaskIds;
        foreach (task; tasks)
        {
            foreach (rule; task.triggers)
            {
                if (matches(rule, event))
                {
                    matchingTaskIds ~= task.id;
                    break;
                }
            }
        }
        return matchingTaskIds;
    }
}

unittest
{
    // Test branch glob matching
    TriggerRule pushRule;
    pushRule.type = TriggerType.gitPush;
    pushRule.branches = ["main", "feature/*", "releases/v*"];

    TriggerEvent event1;
    event1.type = TriggerType.gitPush;
    event1.branch = "main";
    assert(TriggerMatcher.matches(pushRule, event1));

    TriggerEvent event2;
    event2.type = TriggerType.gitPush;
    event2.branch = "feature/login-oauth";
    assert(TriggerMatcher.matches(pushRule, event2));

    TriggerEvent event3;
    event3.type = TriggerType.gitPush;
    event3.branch = "bugfix/123";
    assert(!TriggerMatcher.matches(pushRule, event3));

    // Test tag glob matching
    TriggerRule tagRule;
    tagRule.type = TriggerType.gitTag;
    tagRule.tags = ["v*.*.*", "rc-*"];

    TriggerEvent tagEvent1;
    tagEvent1.type = TriggerType.gitTag;
    tagEvent1.tag = "v1.2.3";
    assert(TriggerMatcher.matches(tagRule, tagEvent1));

    TriggerEvent tagEvent2;
    tagEvent2.type = TriggerType.gitTag;
    tagEvent2.tag = "nightly";
    assert(!TriggerMatcher.matches(tagRule, tagEvent2));

    // Test webhook endpoint matching
    TriggerRule hookRule;
    hookRule.type = TriggerType.webhook;
    hookRule.endpoint = "/api/v1/triggers/deploy";

    TriggerEvent hookEvent1;
    hookEvent1.type = TriggerType.webhook;
    hookEvent1.endpoint = "/api/v1/triggers/deploy";
    assert(TriggerMatcher.matches(hookRule, hookEvent1));

    TriggerEvent hookEvent2;
    hookEvent2.type = TriggerType.webhook;
    hookEvent2.endpoint = "/api/v1/triggers/other";
    assert(!TriggerMatcher.matches(hookRule, hookEvent2));

    // Test task matching
    TaskNode lintNode;
    lintNode.id = "lint";
    lintNode.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];

    TaskNode deployNode;
    deployNode.id = "deploy";
    deployNode.triggers = [TriggerRule(TriggerType.webhook, [], [], "/api/v1/deploy")];

    TaskNode[] tasks = [lintNode, deployNode];

    assert(TriggerMatcher.findMatchingTasks(tasks, event2) == ["lint"]);
    assert(TriggerMatcher.findMatchingTasks(tasks, hookEvent1) == []);

    TriggerEvent deployHook;
    deployHook.type = TriggerType.webhook;
    deployHook.endpoint = "/api/v1/deploy";
    assert(TriggerMatcher.findMatchingTasks(tasks, deployHook) == ["deploy"]);

    // Test explicit targetTaskId
    TriggerEvent targeted;
    targeted.type = TriggerType.manual;
    targeted.targetTaskId = "deploy";
    assert(TriggerMatcher.findMatchingTasks(tasks, targeted) == ["deploy"]);
}
