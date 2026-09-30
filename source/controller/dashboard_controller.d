module controller.dashboard_controller;

import vibe.vibe;
import confector.core.model;
import confector.core.storage;
import confector.core.dag;
import confector.runner.engine;
import confector.queue.queue;

import std.algorithm : filter, count;
import std.datetime.systime : Clock;
import std.format : format;

URLRouter dashboardRouter(TaskEngine engine, WorkQueue queue, BuildStateRepository stateRepo)
{
    auto router = new URLRouter();

    // Home / Dashboard
    router.get("/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto builds = stateRepo !is null ? stateRepo.listBuilds(10) : [];
        auto triggers = stateRepo !is null ? stateRepo.listTriggerRules() : [];
        ulong pendingTasks = queue !is null ? queue.getPendingCount() : 0;
        ulong deadLetterCount = queue !is null ? queue.getDeadLetterMessages().length : 0;

        ulong totalBuilds = builds.length;
        ulong successfulBuilds = builds.filter!(b => b.status == "succeeded" || b.status == "cached").count;
        ulong failedBuilds = builds.filter!(b => b.status == "failed").count;

        res.render!("dashboard/home.dt", builds, triggers, pendingTasks, deadLetterCount, totalBuilds, successfulBuilds, failedBuilds);
    });

    // Builds List
    router.get("/builds/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto builds = stateRepo !is null ? stateRepo.listBuilds(50) : [];
        res.render!("build/builds.dt", builds);
    });

    // Build Details & DAG Visualization
    router.get("/builds/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string buildId = req.query.get("id", "");
        BuildRecord build;
        bool found = stateRepo !is null && stateRepo.getBuild(buildId, build);
        string[] logs = stateRepo !is null ? stateRepo.getBuildLogs(buildId) : [];

        if (!found)
        {
            build.buildId = buildId;
            build.status = "unknown";
            build.pipelineName = "default";
        }

        res.render!("build/build-details.dt", build, logs);
    });

    // Pipelines Visualizer & Runner
    router.get("/pipelines/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto triggers = stateRepo !is null ? stateRepo.listTriggerRules() : [];
        res.render!("pipeline/pipelines.dt", triggers);
    });

    // Triggers Management
    router.get("/triggers/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto triggers = stateRepo !is null ? stateRepo.listTriggerRules() : [];
        res.render!("trigger/triggers.dt", triggers);
    });

    router.post("/triggers/add", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            import std.uuid : randomUUID;
            TriggerRuleRecord rule;
            rule.id = "trig_" ~ randomUUID().toString()[0 .. 8];
            rule.name = req.form.get("name", "Trigger Rule");
            rule.pipelineId = req.form.get("pipeline_id", "default");
            rule.targetTaskId = req.form.get("target_task_id", "");
            rule.triggerType = req.form.get("trigger_type", "manual");
            rule.criteria = req.form.get("criteria", "");
            rule.forceExecution = req.form.get("force_execution", "false") == "true";
            rule.enabled = true;
            rule.createdAt = Clock.currTime.toISOString();

            if (stateRepo !is null)
            {
                stateRepo.saveTriggerRule(rule);
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/triggers/");
    });

    router.post("/triggers/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string ruleId = req.form.get("id", "");
            if (stateRepo !is null && ruleId.length > 0)
            {
                stateRepo.deleteTriggerRule(ruleId);
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/triggers/");
    });

    return router;
}

unittest
{
    auto stateRepo = new InMemoryBuildStateRepository();
    auto queue = new InMemoryWorkQueue();
    auto storage = new LocalArtifactStorage("test_dashboard_storage");
    auto engine = new TaskEngine(storage, stateRepo);

    auto router = dashboardRouter(engine, queue, stateRepo);
    assert(router !is null);

    // Populate dummy build & trigger
    BuildRecord b;
    b.buildId = "b_dash_1";
    b.pipelineName = "main_pipeline";
    b.status = "succeeded";
    stateRepo.recordBuild(b);

    TriggerRuleRecord t;
    t.id = "t_dash_1";
    t.name = "Weekly Nightly";
    t.triggerType = "cron";
    t.criteria = "0 0 * * 0";
    stateRepo.saveTriggerRule(t);

    assert(stateRepo.listBuilds().length == 1);
    assert(stateRepo.listTriggerRules().length == 1);

    import std.file : exists, rmdirRecurse;
    if (exists("test_dashboard_storage")) rmdirRecurse("test_dashboard_storage");
}
