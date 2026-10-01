module controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError, logInfo;
import confector.core.model;
import confector.core.storage;
import confector.core.dag;
import confector.runner.engine;
import confector.queue.queue;

import std.algorithm : filter, count;
import std.datetime.systime : Clock;
import std.format : format;
import std.uuid : randomUUID;

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

    // Projects Management
    router.get("/projects/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto projects = stateRepo !is null ? stateRepo.listProjects() : [];
        res.render!("project/projects.dt", projects);
    });

    router.get("/projects/add", (HTTPServerRequest req, HTTPServerResponse res) {
        res.render!("project/add-project.dt");
    });

    router.post("/projects/add", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            ProjectRecord proj;
            proj.id = req.form.get("id", "");
            if (proj.id.length == 0)
            {
                proj.id = "proj_" ~ randomUUID().toString()[0 .. 8];
            }
            proj.name = req.form.get("name", "Project");
            proj.description = req.form.get("description", "");
            proj.workspaceDir = req.form.get("workspace_dir", ".");
            proj.repositoryUrl = req.form.get("repository_url", "");
            string now = Clock.currTime.toISOString();
            proj.createdAt = now;
            proj.updatedAt = now;

            if (stateRepo !is null)
            {
                stateRepo.saveProject(proj);
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/projects/");
    });

    router.get("/projects/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        bool found = stateRepo !is null && stateRepo.getProject(projId, project);
        if (!found)
        {
            project.id = projId;
            project.name = "Unknown Project";
            project.workspaceDir = ".";
        }
        auto pipelines = stateRepo !is null ? stateRepo.listPipelinesForProject(projId) : [];
        res.render!("project/project-details.dt", project, pipelines);
    });

    router.post("/projects/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.form.get("id", "");
            if (stateRepo !is null && projId.length > 0)
            {
                stateRepo.deleteProject(projId);
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/projects/");
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

    // Pipelines List & Runner
    router.get("/pipelines/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto pipelines = stateRepo !is null ? stateRepo.listAllPipelines() : [];
        auto triggers = stateRepo !is null ? stateRepo.listTriggerRules() : [];
        res.render!("pipeline/pipelines.dt", pipelines, triggers);
    });

    // Pipeline Dynamic DAG Editor
    router.get("/pipelines/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string pipeId = req.query.get("id", "");
        string projId = req.query.get("project_id", "");

        PipelineRecord pipeline;
        if (stateRepo !is null && pipeId.length > 0)
        {
            stateRepo.getPipeline(pipeId, pipeline);
        }
        if (pipeline.projectId.length == 0 && projId.length > 0)
        {
            pipeline.projectId = projId;
        }

        ProjectRecord project;
        if (stateRepo !is null && pipeline.projectId.length > 0)
        {
            stateRepo.getProject(pipeline.projectId, project);
        }

        auto projects = stateRepo !is null ? stateRepo.listProjects() : [];
        string tasksJson = serializeToJson(pipeline.definition.tasks).toString();

        res.render!("pipeline/pipeline-editor.dt", pipeline, project, projects, tasksJson);
    });

    router.post("/pipelines/save", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string pipeId = req.form.get("id", "");
            if (pipeId.length == 0)
            {
                pipeId = "pipe_" ~ randomUUID().toString()[0 .. 8];
            }

            string projId = req.form.get("project_id", "");
            string name = req.form.get("name", "Pipeline");
            string description = req.form.get("description", "");
            string defJsonText = req.form.get("definition_json", "{}");

            Json defJson = parseJsonString(defJsonText);
            PipelineDefinition def;
            if (defJson.type == Json.Type.array)
            {
                def.tasks = deserializeJson!(TaskNode[])(defJson);
            }
            else if (defJson.type == Json.Type.object)
            {
                def = deserializeJson!PipelineDefinition(defJson);
            }

            // Validate DAG
            auto graph = new TaskGraph(def);

            PipelineRecord pipe;
            pipe.id = pipeId;
            pipe.projectId = projId;
            pipe.name = name;
            pipe.description = description;
            pipe.definition = def;
            string now = Clock.currTime.toISOString();
            pipe.createdAt = now;
            pipe.updatedAt = now;

            if (stateRepo !is null)
            {
                stateRepo.savePipeline(pipe);
            }

            if (projId.length > 0)
            {
                res.redirect("/projects/details?id=" ~ projId);
                return;
            }
        }
        catch (Exception e)
        {
            logError("Failed to save pipeline: %s", e.msg);
        }
        res.redirect("/pipelines/");
    });

    router.post("/pipelines/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string pipeId = req.form.get("id", "");
            if (stateRepo !is null && pipeId.length > 0)
            {
                stateRepo.deletePipeline(pipeId);
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/pipelines/");
    });

    router.post("/pipelines/run", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string pipeId = req.form.get("id", "");
            PipelineRecord pipe;
            if (stateRepo !is null && stateRepo.getPipeline(pipeId, pipe))
            {
                ProjectRecord proj;
                string workspaceDir = ".";
                if (pipe.projectId.length > 0 && stateRepo.getProject(pipe.projectId, proj) && proj.workspaceDir.length > 0)
                {
                    workspaceDir = proj.workspaceDir;
                }

                auto graph = new TaskGraph(pipe.definition);
                string[] orderedTasks = graph.topologicalSort();
                ExecutionPlan plan;
                plan.orderedTaskIds = orderedTasks;
                plan.toExecuteTaskIds = orderedTasks;

                string buildId = "build_" ~ randomUUID().toString()[0 .. 8];
                engine.executePipeline(buildId, pipe.definition, plan, workspaceDir, false);
                res.redirect("/builds/details?id=" ~ buildId);
                return;
            }
        }
        catch (Exception e)
        {
        }
        res.redirect("/pipelines/");
    });

    // Triggers Management
    router.get("/triggers/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto triggers = stateRepo !is null ? stateRepo.listTriggerRules() : [];
        res.render!("trigger/triggers.dt", triggers);
    });

    router.post("/triggers/add", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
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

    // Populate and verify Project & Pipeline state
    ProjectRecord p;
    p.id = "proj_dash_1";
    p.name = "Dashboard Project";
    p.workspaceDir = ".";
    stateRepo.saveProject(p);
    assert(stateRepo.listProjects().length == 1);

    PipelineRecord pipe;
    pipe.id = "pipe_dash_1";
    pipe.projectId = "proj_dash_1";
    pipe.name = "Dashboard Pipeline";
    TaskNode tNode;
    tNode.id = "test_node";
    tNode.script = "echo dashboard test";
    pipe.definition.tasks = [tNode];
    stateRepo.savePipeline(pipe);

    assert(stateRepo.listAllPipelines().length == 1);
    assert(stateRepo.listPipelinesForProject("proj_dash_1").length == 1);

    import std.file : exists, rmdirRecurse;
    if (exists("test_dashboard_storage")) rmdirRecurse("test_dashboard_storage");
}
