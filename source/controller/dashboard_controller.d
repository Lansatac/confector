module controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError, logInfo, logWarn;
import confector.core.model;
import confector.core.storage;
import confector.core.dag;
import confector.core.plugin : PluginRegistry;
import confector.core.system : BuildStepProvider;
import confector.runner.engine;
import confector.runner.coordinator;
import confector.queue.queue;

import std.algorithm : filter, count, canFind;
import std.datetime.systime : Clock;
import std.format : format;
import std.string : split, strip;
import std.uuid : randomUUID;

struct StepProviderViewModel
{
    string stepType;
    string displayName;
    string description;
    string defaultHtml;
}

URLRouter dashboardRouter(TaskEngine engine, WorkQueue queue, BuildStateRepository stateRepo, PluginRegistry registry = null, BuildCoordinator coordinator = null)
{
    if (registry is null)
    {
        registry = PluginRegistry.instance;
    }
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
        string projId = "";
        try
        {
            ProjectRecord proj;
            proj.id = req.form.get("id", "");
            if (proj.id.length == 0)
            {
                proj.id = "proj_" ~ randomUUID().toString()[0 .. 8];
            }
            projId = proj.id;
            proj.name = req.form.get("name", "Project");
            proj.description = req.form.get("description", "");
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
            logError("Failed to add project: %s", e.msg);
        }

        if (projId.length > 0)
        {
            res.redirect("/projects/details?id=" ~ projId);
        }
        else
        {
            res.redirect("/projects/");
        }
    });

    router.get("/projects/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        bool found = stateRepo !is null && stateRepo.getProject(projId, project);
        if (!found)
        {
            project.id = projId;
            project.name = "Unknown Project";
        }
        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-details.dt", project, tasksJson);
    });

    router.get("/projects/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        if (stateRepo !is null)
        {
            stateRepo.getProject(projId, project);
        }
        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-editor.dt", project, tasksJson);
    });

    router.post("/projects/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("id", "");
        try
        {
            ProjectRecord project;
            if (stateRepo !is null && projId.length > 0)
            {
                stateRepo.getProject(projId, project);
            }

            project.id = projId;
            project.name = req.form.get("name", project.name.length > 0 ? project.name : "Project");
            project.description = req.form.get("description", project.description);
            project.repositoryUrl = req.form.get("repository_url", project.repositoryUrl);

            string tasksJsonText = req.form.get("tasks_json", "[]");
            Json parsed = parseJsonString(tasksJsonText);
            if (parsed.type == Json.Type.array)
            {
                project.tasks = deserializeJson!(TaskNode[])(parsed);
            }

            // Validate DAG
            auto graph = new TaskGraph(project.tasks);

            project.updatedAt = Clock.currTime.toISOString();
            if (stateRepo !is null)
            {
                stateRepo.saveProject(project);
            }
        }
        catch (Exception e)
        {
            logError("Failed to save project: %s", e.msg);
        }
        res.redirect("/projects/details?id=" ~ projId);
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

    // Task Editor within Project
    router.get("/projects/tasks/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("project_id", "");
        string taskId = req.query.get("task_id", "");

        ProjectRecord project;
        if (stateRepo !is null && projId.length > 0)
        {
            stateRepo.getProject(projId, project);
        }

        TaskNode task;
        if (taskId.length > 0)
        {
            foreach (t; project.tasks)
            {
                if (t.id == taskId)
                {
                    task = t;
                    break;
                }
            }
        }

        auto repositories = stateRepo !is null ? stateRepo.listRepositories() : [];
        StepProviderViewModel[] stepProvidersView;
        if (registry !is null)
        {
            foreach (p; registry.getStepProviders())
            {
                StepProviderViewModel vm;
                vm.stepType = p.stepType;
                vm.displayName = p.displayName;
                vm.description = p.description;
                vm.defaultHtml = p.renderStepFormHtml(p.defaultParameters());
                stepProvidersView ~= vm;
            }
        }
        res.render!("project/task-editor.dt", project, task, repositories, stepProvidersView);
    });

    router.post("/projects/tasks/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("project_id", "");
        try
        {
            ProjectRecord project;
            if (stateRepo !is null && projId.length > 0)
            {
                stateRepo.getProject(projId, project);
            }

            TaskNode task;
            task.id = req.form.get("task_id", "").strip();
            if (task.id.length == 0)
            {
                task.id = "task_" ~ randomUUID().toString()[0 .. 8];
            }
            task.name = req.form.get("name", "").strip();

            // Build steps
            string stepsJsonStr = req.form.get("steps_json", "");
            BuildStep[] steps;
            if (stepsJsonStr.length > 0)
            {
                try
                {
                    Json parsedSteps = parseJsonString(stepsJsonStr);
                    if (parsedSteps.type == Json.Type.array)
                    {
                        steps = deserializeJson!(BuildStep[])(parsedSteps);
                    }
                }
                catch (Exception e)
                {
                    logWarn("Failed to deserialize steps_json: %s", e.msg);
                }
            }

            // Fallback to form parameters if steps_json was empty
            if (steps.length == 0)
            {
                auto stepTypes = req.form.getAll("step_type");
                auto stepCustomTypes = req.form.getAll("step_custom_type");
                auto stepNames = req.form.getAll("step_name");
                auto stepScripts = req.form.getAll("step_script");
                auto stepCommands = req.form.getAll("step_command");
                auto stepWorkDirs = req.form.getAll("step_working_dir");
                auto stepWorkDirs2 = req.form.getAll("step_workingDirectory");
                auto stepRepoUrls = req.form.getAll("step_repo_url");
                auto stepRepoUrls2 = req.form.getAll("step_param_repository");
                auto stepBranches = req.form.getAll("step_repo_branch");
                auto stepBranches2 = req.form.getAll("step_param_branch");
                auto stepTargetDirs = req.form.getAll("step_repo_target");
                auto stepTargetDirs2 = req.form.getAll("step_param_target_dir");
                auto stepExecutables = req.form.getAll("step_param_executable");
                auto stepProps = req.form.getAll("step_props");

                for (size_t i = 0; i < stepTypes.length; i++)
                {
                    string sType = stepTypes[i].strip();
                    if (sType == "custom" && i < stepCustomTypes.length && stepCustomTypes[i].strip().length > 0)
                    {
                        sType = stepCustomTypes[i].strip();
                    }
                    if (sType.length == 0) continue;

                    BuildStep step;
                    step.type = sType;
                    if (i < stepNames.length) step.name = stepNames[i].strip();
                    if (i < stepScripts.length && stepScripts[i].length > 0) step.script = stepScripts[i];
                    if (i < stepCommands.length && stepCommands[i].length > 0) step.command = stepCommands[i];
                    if (i < stepWorkDirs.length && stepWorkDirs[i].strip().length > 0) step.workingDirectory = stepWorkDirs[i].strip();
                    else if (i < stepWorkDirs2.length && stepWorkDirs2[i].strip().length > 0) step.workingDirectory = stepWorkDirs2[i].strip();

                    if (i < stepRepoUrls.length && stepRepoUrls[i].strip().length > 0)
                    {
                        step.parameters["repository"] = stepRepoUrls[i].strip();
                    }
                    else if (i < stepRepoUrls2.length && stepRepoUrls2[i].strip().length > 0)
                    {
                        step.parameters["repository"] = stepRepoUrls2[i].strip();
                    }

                    if (i < stepBranches.length && stepBranches[i].strip().length > 0)
                    {
                        step.parameters["branch"] = stepBranches[i].strip();
                    }
                    else if (i < stepBranches2.length && stepBranches2[i].strip().length > 0)
                    {
                        step.parameters["branch"] = stepBranches2[i].strip();
                    }

                    if (i < stepTargetDirs.length && stepTargetDirs[i].strip().length > 0)
                    {
                        step.parameters["target_dir"] = stepTargetDirs[i].strip();
                    }
                    else if (i < stepTargetDirs2.length && stepTargetDirs2[i].strip().length > 0)
                    {
                        step.parameters["target_dir"] = stepTargetDirs2[i].strip();
                    }

                    if (i < stepExecutables.length && stepExecutables[i].strip().length > 0)
                    {
                        step.parameters["executable"] = stepExecutables[i].strip();
                    }

                    if (i < stepProps.length && stepProps[i].strip().length > 0)
                    {
                        step.propertiesJson = stepProps[i].strip();
                    }

                    steps ~= step;
                }
            }
            task.steps = steps;

            // Dependencies
            string[] deps;
            foreach (dVal; req.form.getAll("depends_on"))
            {
                foreach (d; dVal.split(","))
                {
                    string s = d.strip();
                    if (s.length > 0 && s != task.id && !deps.canFind(s))
                    {
                        deps ~= s;
                    }
                }
            }
            task.dependsOn = deps;

            // Repository dependencies
            string[] repos;
            foreach (rVal; req.form.getAll("repositories"))
            {
                foreach (r; rVal.split(","))
                {
                    string s = r.strip();
                    if (s.length > 0 && !repos.canFind(s))
                    {
                        repos ~= s;
                    }
                }
            }
            task.inputs.repositories = repos;

            // Upstream artifacts
            string upStr = req.form.get("upstream_artifacts", "");
            UpstreamArtifactRef[] upstreamRefs;
            foreach (line; upStr.split("\n"))
            {
                string s = line.strip();
                if (s.length == 0) continue;
                auto parts = s.split(":");
                if (parts.length >= 2)
                {
                    upstreamRefs ~= UpstreamArtifactRef(parts[0].strip(), parts[1].strip());
                }
                else
                {
                    upstreamRefs ~= UpstreamArtifactRef(parts[0].strip(), parts[0].strip());
                }
            }
            task.inputs.upstreamArtifacts = upstreamRefs;

            // Output artifacts
            string outStr = req.form.get("output_artifacts", "");
            OutputArtifactDecl[] outDecls;
            foreach (line; outStr.split("\n"))
            {
                string s = line.strip();
                if (s.length == 0) continue;
                auto parts = s.split(":");
                if (parts.length >= 2)
                {
                    outDecls ~= OutputArtifactDecl(parts[0].strip(), parts[1].strip());
                }
                else
                {
                    outDecls ~= OutputArtifactDecl(parts[0].strip(), "file");
                }
            }
            task.outputs.artifacts = outDecls;

            // Trigger rules
            auto trigTypes = req.form.getAll("trigger_type");
            auto trigBranches = req.form.getAll("trigger_branches");
            auto trigTags = req.form.getAll("trigger_tags");
            auto trigEndpoints = req.form.getAll("trigger_endpoint");
            auto trigCrons = req.form.getAll("trigger_cron");

            TriggerRule[] triggerRules;
            for (size_t i = 0; i < trigTypes.length; i++)
            {
                string tTypeStr = trigTypes[i].strip();
                if (tTypeStr.length == 0) continue;

                TriggerRule rule;
                if (tTypeStr == "git_push") rule.type = TriggerType.gitPush;
                else if (tTypeStr == "git_tag") rule.type = TriggerType.gitTag;
                else if (tTypeStr == "webhook") rule.type = TriggerType.webhook;
                else if (tTypeStr == "cron") rule.type = TriggerType.cron;
                else rule.type = TriggerType.manual;

                if (i < trigBranches.length && trigBranches[i].strip().length > 0)
                {
                    string[] bList;
                    foreach (b; trigBranches[i].split(","))
                    {
                        string s = b.strip();
                        if (s.length > 0) bList ~= s;
                    }
                    rule.branches = bList;
                }

                if (i < trigTags.length && trigTags[i].strip().length > 0)
                {
                    string[] tgList;
                    foreach (tg; trigTags[i].split(","))
                    {
                        string s = tg.strip();
                        if (s.length > 0) tgList ~= s;
                    }
                    rule.tags = tgList;
                }

                if (i < trigEndpoints.length)
                {
                    rule.endpoint = trigEndpoints[i].strip();
                }

                if (i < trigCrons.length)
                {
                    rule.cronSchedule = trigCrons[i].strip();
                }

                triggerRules ~= rule;
            }
            task.triggers = triggerRules;

            // Replace existing or append
            bool updated = false;
            foreach (ref existing; project.tasks)
            {
                if (existing.id == task.id)
                {
                    existing = task;
                    updated = true;
                    break;
                }
            }
            if (!updated)
            {
                project.tasks ~= task;
            }

            // Validate DAG
            auto graph = new TaskGraph(project.tasks);

            project.updatedAt = Clock.currTime.toISOString();
            if (stateRepo !is null)
            {
                stateRepo.saveProject(project);
            }
        }
        catch (Exception e)
        {
            logError("Failed to save task: %s", e.msg);
        }

        res.redirect("/projects/details?id=" ~ projId);
    });

    router.post("/projects/tasks/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("project_id", "");
        string taskId = req.form.get("task_id", "");
        try
        {
            ProjectRecord project;
            if (stateRepo !is null && projId.length > 0 && stateRepo.getProject(projId, project))
            {
                TaskNode[] remaining;
                foreach (t; project.tasks)
                {
                    if (t.id != taskId)
                    {
                        remaining ~= t;
                    }
                }
                project.tasks = remaining;
                project.updatedAt = Clock.currTime.toISOString();
                stateRepo.saveProject(project);
            }
        }
        catch (Exception e)
        {
            logError("Failed to delete task: %s", e.msg);
        }
        res.redirect("/projects/details?id=" ~ projId);
    });

    // Execute Project Task Graph
    router.post("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        try
        {
            string projId = req.form.get("id", "");
            string targetTaskId = req.form.get("target_task_id", "");
            ProjectRecord proj;
            if (stateRepo !is null && stateRepo.getProject(projId, proj))
            {
                if (coordinator !is null)
                {
                    string buildId = coordinator.startBuild(proj, targetTaskId.length > 0 ? targetTaskId : null, false, "dashboard", ".");
                    res.redirect("/builds/details?id=" ~ buildId);
                    return;
                }
                else
                {
                    string workspaceDir = ".";

                    auto graph = new TaskGraph(proj.tasks);
                    string[] orderedTasks;
                    if (targetTaskId.length > 0)
                    {
                        orderedTasks = graph.resolveSubgraph(targetTaskId);
                    }
                    else
                    {
                        orderedTasks = graph.topologicalSort();
                    }

                    ExecutionPlan plan;
                    plan.orderedTaskIds = orderedTasks;
                    plan.toExecuteTaskIds = orderedTasks;

                    string buildId = "build_" ~ randomUUID().toString()[0 .. 8];
                    engine.executeTasks(buildId, proj.tasks, plan, workspaceDir, proj.id, proj.name, targetTaskId, false);
                    res.redirect("/builds/details?id=" ~ buildId);
                    return;
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to run project tasks: %s", e.msg);
        }
        res.redirect("/projects/");
    });

    // Builds List & Active Work Queue
    router.get("/builds/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto builds = stateRepo !is null ? stateRepo.listBuilds(50) : [];
        auto queuedTasks = queue !is null ? queue.getPendingMessages(50) : [];
        res.render!("build/builds.dt", builds, queuedTasks);
    });

    // Build Details & Task Graph Visualization
    router.get("/builds/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string buildId = req.query.get("id", "");
        BuildRecord build;
        bool found = stateRepo !is null && stateRepo.getBuild(buildId, build);
        string[] logs = stateRepo !is null ? stateRepo.getBuildLogs(buildId) : [];

        if (!found)
        {
            build.buildId = buildId;
            build.status = "unknown";
            build.projectName = "default";
        }

        TaskNode[] tasks;
        ProjectRecord project;
        if (stateRepo !is null && build.projectId.length > 0 && stateRepo.getProject(build.projectId, project))
        {
            tasks = project.tasks;
        }

        if (tasks.length == 0 && build.executedTasks.length > 0)
        {
            foreach (taskId; build.executedTasks)
            {
                TaskNode tn;
                tn.id = taskId;
                tn.name = taskId;
                tasks ~= tn;
            }
        }

        string[string] taskStatuses;
        auto recordedStatuses = stateRepo !is null ? stateRepo.getTaskStatusesForBuild(build.buildId) : (TaskStatus[string]).init;
        foreach (t; tasks)
        {
            if (auto p = t.id in recordedStatuses)
            {
                taskStatuses[t.id] = cast(string)*p;
            }
            else
            {
                bool wasExecuted = false;
                foreach (exId; build.executedTasks)
                {
                    if (exId == t.id)
                    {
                        wasExecuted = true;
                        break;
                    }
                }
                if (wasExecuted)
                {
                    taskStatuses[t.id] = build.status == "cached" ? "cached" : (build.status == "failed" ? "failed" : "succeeded");
                }
                else
                {
                    taskStatuses[t.id] = "pending";
                }
            }
        }

        string tasksJson = serializeToJson(tasks).toString();
        string taskStatusesJson = serializeToJson(taskStatuses).toString();

        res.render!("build/build-details.dt", build, logs, tasksJson, taskStatusesJson, taskStatuses);
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
    b.projectName = "main_project";
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

    // Populate and verify Project & Task state
    ProjectRecord p;
    p.id = "proj_dash_1";
    p.name = "Dashboard Project";
    TaskNode tNode1;
    tNode1.id = "test_node_1";
    tNode1.script = "echo dashboard test 1";
    tNode1.inputs.repositories = ["repo_main"];
    tNode1.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];
    TaskNode tNode2;
    tNode2.id = "test_node_2";
    tNode2.dependsOn = ["test_node_1"];
    tNode2.script = "echo dashboard test 2";
    tNode2.triggers = [TriggerRule(TriggerType.webhook, null, null, "/api/v1/deploy")];
    p.tasks = [tNode1, tNode2];
    stateRepo.saveProject(p);
    assert(stateRepo.listProjects().length == 1);

    RepositoryRecord rRecord;
    rRecord.name = "repo_main";
    rRecord.address = "https://github.com/example/repo_main.git";
    stateRepo.saveRepository(rRecord);
    assert(stateRepo.listRepositories().length == 1);

    ProjectRecord fetchedProj;
    assert(stateRepo.getProject("proj_dash_1", fetchedProj));
    assert(fetchedProj.tasks.length == 2);
    assert(fetchedProj.tasks[0].id == "test_node_1");
    assert(fetchedProj.tasks[0].inputs.repositories == ["repo_main"]);
    assert(fetchedProj.tasks[0].triggers.length == 1);
    assert(fetchedProj.tasks[0].triggers[0].type == TriggerType.gitPush);
    assert(fetchedProj.tasks[0].triggers[0].branches == ["main", "feature/*"]);
    assert(fetchedProj.tasks[1].id == "test_node_2");
    assert(fetchedProj.tasks[1].triggers.length == 1);
    assert(fetchedProj.tasks[1].triggers[0].type == TriggerType.webhook);
    assert(fetchedProj.tasks[1].triggers[0].endpoint == "/api/v1/deploy");

    // Test Build linked to project and task statuses
    BuildRecord b2;
    b2.buildId = "b_dash_2";
    b2.projectId = "proj_dash_1";
    b2.projectName = "Dashboard Project";
    b2.executedTasks = ["test_node_1", "test_node_2"];
    b2.status = "succeeded";
    stateRepo.recordBuild(b2);
    stateRepo.setTaskStatus("b_dash_2", "test_node_1", TaskStatus.cached);
    stateRepo.setTaskStatus("b_dash_2", "test_node_2", TaskStatus.succeeded);

    TaskStatus st1, st2;
    assert(stateRepo.getTaskStatus("b_dash_2", "test_node_1", st1) && st1 == TaskStatus.cached);
    assert(stateRepo.getTaskStatus("b_dash_2", "test_node_2", st2) && st2 == TaskStatus.succeeded);

    import std.file : exists, rmdirRecurse;
    if (exists("test_dashboard_storage")) rmdirRecurse("test_dashboard_storage");
}
