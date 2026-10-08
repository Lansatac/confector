module controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError, logInfo, logWarn;
import confector.core.model;
import confector.core.storage;
import confector.core.dag;
import confector.core.plugin : PluginRegistry;
import confector.core.system : BuildStepProvider;
import confector.runner_core.engine;
import confector.orchestrator.coordinator;
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

// View model for task summary on dashboard
struct DashboardTaskViewModel
{
    string id;
    string name;
    string[] dependsOn;
    string lastStatus;          // "succeeded", "cached", "failed", "running", "never_run"
    string changeStatus;        // "up_to_date", "pending_changes", "never_run" (stubbed)
    string lastFingerprint;
    string lastStartedAt;
    ulong lastDurationMs;
    string lastBuildId;
}

// View model for collapsible project panel on dashboard
struct DashboardProjectViewModel
{
    ProjectRecord project;
    DashboardTaskViewModel[] tasks;
    ulong totalTasks;
    ulong successfulTasks;
    ulong failedTasks;
}

// View model for task execution history item
struct TaskExecutionHistoryItem
{
    TaskExecutionRecord execution;
    string buildId;
    string projectName;
}

/**
 * Stubbed change detection helper function.
 * Evaluates whether a task was never run, has latest execution failures, or succeeded/cached.
 * Returns: "up_to_date", "pending_changes", or "never_run".
 */
string computeStubTaskChangeStatus(const TaskNode task, const TaskExecutionRecord latestExec) pure nothrow @safe
{
    if (latestExec.buildId.length == 0 || latestExec.status.length == 0 || latestExec.status == "never_run")
    {
        return "never_run";
    }

    if (latestExec.status == "succeeded" || latestExec.status == "cached")
    {
        return "up_to_date";
    }

    return "pending_changes";
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
        auto projects = stateRepo !is null ? stateRepo.listProjects() : [];
        auto builds = stateRepo !is null ? stateRepo.listBuilds(10) : [];
        auto recentTasks = stateRepo !is null ? stateRepo.listRecentTaskExecutions(10) : [];
        ulong pendingTasks = queue !is null ? queue.getPendingCount() : 0;
        ulong deadLetterCount = queue !is null ? queue.getDeadLetterMessages().length : 0;

        ulong totalBuilds = builds.length;
        ulong successfulBuilds = builds.filter!(b => b.status == "succeeded" || b.status == "cached").count;
        ulong failedBuilds = builds.filter!(b => b.status == "failed").count;

        DashboardProjectViewModel[] dashboardProjects;
        ulong totalProjects = projects.length;
        ulong totalTasksAll = 0;
        ulong successfulTasksAll = 0;
        ulong failedTasksAll = 0;

        foreach (proj; projects)
        {
            DashboardProjectViewModel pvm;
            pvm.project = proj;
            pvm.totalTasks = proj.tasks.length;
            totalTasksAll += proj.tasks.length;

            foreach (task; proj.tasks)
            {
                DashboardTaskViewModel tvm;
                tvm.id = task.id;
                tvm.name = task.name.length > 0 ? task.name : task.id;
                tvm.dependsOn = task.dependsOn;

                TaskExecutionRecord latestExec;
                if (stateRepo !is null)
                {
                    auto execs = stateRepo.listTaskExecutionsForTask(proj.id, task.id, 1);
                    if (execs.length > 0)
                    {
                        latestExec = execs[0];
                    }
                }

                if (latestExec.status.length > 0)
                {
                    tvm.lastStatus = latestExec.status;
                    tvm.lastFingerprint = latestExec.fingerprint;
                    tvm.lastStartedAt = latestExec.startedAt;
                    tvm.lastDurationMs = latestExec.durationMs;
                    tvm.lastBuildId = latestExec.buildId;
                }
                else
                {
                    tvm.lastStatus = "never_run";
                }

                tvm.changeStatus = computeStubTaskChangeStatus(task, latestExec);

                if (tvm.lastStatus == "succeeded" || tvm.lastStatus == "cached")
                {
                    pvm.successfulTasks++;
                    successfulTasksAll++;
                }
                else if (tvm.lastStatus == "failed")
                {
                    pvm.failedTasks++;
                    failedTasksAll++;
                }

                pvm.tasks ~= tvm;
            }

            dashboardProjects ~= pvm;
        }

        res.render!("dashboard/home.dt", dashboardProjects, builds, recentTasks, pendingTasks, deadLetterCount, totalBuilds, successfulBuilds, failedBuilds, totalProjects, totalTasksAll, successfulTasksAll, failedTasksAll);
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
    router.get("/projects/tasks/add", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("project_id", "");
        if (projId.length == 0) projId = req.query.get("id", "");
        res.redirect("/projects/tasks/edit?project_id=" ~ projId);
    });

    router.get("/projects/tasks/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("project_id", "");
        if (projId.length == 0) projId = req.query.get("id", "");
        string taskId = req.query.get("task_id", "");
        if (taskId.length == 0) taskId = req.query.get("id", "");

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
                    outDecls ~= OutputArtifactDecl(parts[0].strip(), parts[0].strip());
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
            if (projId.length == 0) projId = req.form.get("project_id", "");
            string targetTaskId = req.form.get("target_task_id", "");
            if (targetTaskId.length == 0) targetTaskId = req.form.get("taskId", "");
            if (targetTaskId.length == 0) targetTaskId = req.form.get("task_id", "");
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
                    logError("Cannot run project '%s': build coordinator is not configured", proj.id);
                }
            }
        }
        catch (Exception e)
        {
            logError("Failed to run project tasks: %s", e.msg);
        }
        res.redirect("/projects/");
    });

    // Tasks List & Active Work Queue (Task-Centric View)
    router.get("/tasks/", (HTTPServerRequest req, HTTPServerResponse res) {
        string statusFilter = req.query.get("status", "");
        string projectFilter = req.query.get("project_id", "");
        auto recentTasks = stateRepo !is null ? stateRepo.listRecentTaskExecutions(50, statusFilter, projectFilter) : [];
        auto queuedTasks = queue !is null ? queue.getPendingMessages(50) : [];
        res.render!("task/tasks.dt", recentTasks, queuedTasks, statusFilter, projectFilter);
    });

    router.get("/tasks", (HTTPServerRequest req, HTTPServerResponse res) {
        res.redirect("/tasks/");
    });

    // Task Details View (Static definition, configuration, steps, dependencies, and execution history)
    router.get("/tasks/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string buildId = req.query.get("build_id", "");
        if (buildId.length == 0) buildId = req.query.get("build", "");
        string projectId = req.query.get("project_id", "");
        if (projectId.length == 0) projectId = req.query.get("project", "");
        string taskId = req.query.get("task_id", "");
        if (taskId.length == 0) taskId = req.query.get("id", "");

        // Legacy redirect: if build_id is explicitly passed and no project_id is given,
        // redirect to dedicated execution instance page.
        if (buildId.length > 0 && projectId.length == 0)
        {
            res.redirect(format("/tasks/execution?build_id=%s&task_id=%s", buildId, taskId));
            return;
        }

        ProjectRecord project;
        TaskNode taskNode;
        bool foundTask = false;

        if (stateRepo !is null)
        {
            if (projectId.length > 0 && stateRepo.getProject(projectId, project))
            {
                foreach (t; project.tasks)
                {
                    if (t.id == taskId)
                    {
                        taskNode = t;
                        foundTask = true;
                        break;
                    }
                }
            }

            if (!foundTask)
            {
                foreach (p; stateRepo.listProjects())
                {
                    foreach (t; p.tasks)
                    {
                        if (t.id == taskId)
                        {
                            project = p;
                            projectId = p.id;
                            taskNode = t;
                            foundTask = true;
                            break;
                        }
                    }
                    if (foundTask) break;
                }
            }
        }

        if (!foundTask)
        {
            taskNode.id = taskId;
            taskNode.name = taskId;
            if (project.id.length == 0) project.id = projectId.length > 0 ? projectId : "default";
            if (project.name.length == 0) project.name = project.id;
        }

        TaskExecutionRecord[] history = stateRepo !is null ? stateRepo.listTaskExecutionsForTask(projectId, taskId, 50) : [];
        TaskExecutionRecord latestExec = history.length > 0 ? history[0] : TaskExecutionRecord.init;
        string changeStatus = computeStubTaskChangeStatus(taskNode, latestExec);

        res.render!("task/task-details.dt", project, taskNode, history, changeStatus);
    });

    // Dedicated Task Execution View (Runtime metrics, fingerprint, duration, exit code, produced artifacts, live logs)
    router.get("/tasks/execution", (HTTPServerRequest req, HTTPServerResponse res) {
        string buildId = req.query.get("build_id", "");
        if (buildId.length == 0) buildId = req.query.get("build", "");
        string taskId = req.query.get("task_id", "");
        if (taskId.length == 0) taskId = req.query.get("id", "");

        TaskExecutionRecord taskRecord;
        bool foundRecord = stateRepo !is null && stateRepo.getTaskExecution(buildId, taskId, taskRecord);
        if (!foundRecord)
        {
            taskRecord.buildId = buildId;
            taskRecord.taskId = taskId;
            taskRecord.status = "unknown";
        }

        string[] logs = stateRepo !is null ? stateRepo.getTaskLogs(buildId, taskId) : [];
        if (logs.length == 0 && stateRepo !is null && buildId.length > 0)
        {
            auto bLogs = stateRepo.getBuildLogs(buildId);
            string prefix = format("[%s]", taskId);
            foreach (line; bLogs)
            {
                if (line.length >= prefix.length && line[0 .. prefix.length] == prefix)
                {
                    logs ~= line[prefix.length .. $].strip();
                }
            }
            if (logs.length == 0) logs = bLogs;
        }

        BuildRecord build;
        if (stateRepo !is null && buildId.length > 0)
        {
            stateRepo.getBuild(buildId, build);
        }

        string projectId = taskRecord.projectId.length > 0 ? taskRecord.projectId : build.projectId;
        ProjectRecord project;
        TaskNode taskNode;
        bool foundTask = false;

        if (stateRepo !is null)
        {
            if (projectId.length > 0 && stateRepo.getProject(projectId, project))
            {
                foreach (t; project.tasks)
                {
                    if (t.id == taskId)
                    {
                        taskNode = t;
                        foundTask = true;
                        break;
                    }
                }
            }

            if (!foundTask)
            {
                foreach (p; stateRepo.listProjects())
                {
                    foreach (t; p.tasks)
                    {
                        if (t.id == taskId)
                        {
                            project = p;
                            taskNode = t;
                            foundTask = true;
                            break;
                        }
                    }
                    if (foundTask) break;
                }
            }
        }

        if (!foundTask)
        {
            taskNode.id = taskId;
            taskNode.name = taskId;
        }

        res.render!("task/task-execution.dt", taskRecord, logs, build, taskNode, project);
    });

    // Builds List & Active Work Queue
    router.get("/builds/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto builds = stateRepo !is null ? stateRepo.listBuilds(50) : [];
        auto queuedTasks = queue !is null ? queue.getPendingMessages(50) : [];
        auto recentTasks = stateRepo !is null ? stateRepo.listRecentTaskExecutions(25) : [];
        res.render!("build/builds.dt", builds, queuedTasks, recentTasks);
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
    tNode1.steps = [BuildStep("Echo", "bash", null, "echo dashboard test 1")];
    tNode1.inputs.repositories = ["repo_main"];
    tNode1.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];
    TaskNode tNode2;
    tNode2.id = "test_node_2";
    tNode2.dependsOn = ["test_node_1"];
    tNode2.steps = [BuildStep("Echo", "bash", null, "echo dashboard test 2")];
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

    // Test task execution record and task-scoped log queries
    TaskExecutionRecord taskRec;
    taskRec.buildId = "b_dash_2";
    taskRec.taskId = "test_node_2";
    taskRec.status = "succeeded";
    taskRec.durationMs = 45;
    taskRec.fingerprint = "0123456789abcdef";
    stateRepo.recordTaskExecution(taskRec);
    stateRepo.appendTaskLog("b_dash_2", "test_node_2", "Task step log line 1");

    auto recentTasks = stateRepo.listRecentTaskExecutions();
    assert(recentTasks.length >= 1);
    assert(stateRepo.getTaskLogs("b_dash_2", "test_node_2") == ["Task step log line 1"]);

    // Test listTaskExecutionsForTask
    auto taskExecs = stateRepo.listTaskExecutionsForTask("proj_dash_1", "test_node_2");
    assert(taskExecs.length >= 1);
    assert(taskExecs[0].taskId == "test_node_2");

    // Test computeStubTaskChangeStatus
    TaskNode sampleNode;
    sampleNode.id = "sample_task";

    TaskExecutionRecord emptyExec;
    assert(computeStubTaskChangeStatus(sampleNode, emptyExec) == "never_run");

    TaskExecutionRecord succExec;
    succExec.buildId = "b1";
    succExec.taskId = "sample_task";
    succExec.status = "succeeded";
    assert(computeStubTaskChangeStatus(sampleNode, succExec) == "up_to_date");

    TaskExecutionRecord cachedExec;
    cachedExec.buildId = "b2";
    cachedExec.taskId = "sample_task";
    cachedExec.status = "cached";
    assert(computeStubTaskChangeStatus(sampleNode, cachedExec) == "up_to_date");

    TaskExecutionRecord failedExec;
    failedExec.buildId = "b3";
    failedExec.taskId = "sample_task";
    failedExec.status = "failed";
    assert(computeStubTaskChangeStatus(sampleNode, failedExec) == "pending_changes");

    // Test Dashboard ViewModels
    DashboardTaskViewModel taskVm;
    taskVm.id = "test_node_1";
    taskVm.name = "Test Node 1";
    taskVm.lastStatus = "succeeded";
    taskVm.changeStatus = "up_to_date";
    taskVm.lastDurationMs = 120;
    taskVm.lastBuildId = "b_dash_2";

    DashboardProjectViewModel projVm;
    projVm.project = fetchedProj;
    projVm.tasks = [taskVm];
    projVm.totalTasks = 1;
    projVm.successfulTasks = 1;
    projVm.failedTasks = 0;

    assert(projVm.tasks.length == 1);
    assert(projVm.tasks[0].id == "test_node_1");
    assert(projVm.tasks[0].changeStatus == "up_to_date");

    // Test dashboard project assembly loop logic
    DashboardProjectViewModel[] testDashboardProjects;
    foreach (proj; stateRepo.listProjects())
    {
        DashboardProjectViewModel pvm;
        pvm.project = proj;
        pvm.totalTasks = proj.tasks.length;

        foreach (task; proj.tasks)
        {
            DashboardTaskViewModel tvm;
            tvm.id = task.id;
            tvm.name = task.name.length > 0 ? task.name : task.id;
            tvm.dependsOn = task.dependsOn;

            TaskExecutionRecord latestExec;
            auto execs = stateRepo.listTaskExecutionsForTask(proj.id, task.id, 1);
            if (execs.length > 0)
            {
                latestExec = execs[0];
            }

            if (latestExec.status.length > 0)
            {
                tvm.lastStatus = latestExec.status;
                tvm.lastFingerprint = latestExec.fingerprint;
                tvm.lastStartedAt = latestExec.startedAt;
                tvm.lastDurationMs = latestExec.durationMs;
                tvm.lastBuildId = latestExec.buildId;
            }
            else
            {
                tvm.lastStatus = "never_run";
            }

            tvm.changeStatus = computeStubTaskChangeStatus(task, latestExec);
            if (tvm.lastStatus == "succeeded" || tvm.lastStatus == "cached")
            {
                pvm.successfulTasks++;
            }
            else if (tvm.lastStatus == "failed")
            {
                pvm.failedTasks++;
            }

            pvm.tasks ~= tvm;
        }

        testDashboardProjects ~= pvm;
    }

    assert(testDashboardProjects.length == 1);
    assert(testDashboardProjects[0].tasks.length == 2);
    assert(testDashboardProjects[0].tasks[0].id == "test_node_1");
    assert(testDashboardProjects[0].tasks[0].changeStatus == "never_run");
    assert(testDashboardProjects[0].tasks[1].id == "test_node_2");
    assert(testDashboardProjects[0].tasks[1].changeStatus == "up_to_date");
    assert(testDashboardProjects[0].tasks[1].lastStatus == "succeeded");
    assert(testDashboardProjects[0].successfulTasks == 1);

    // Test Task Details definition resolution and execution history retrieval
    ProjectRecord detailProj;
    TaskNode detailTask;
    bool foundDetailTask = false;
    assert(stateRepo.getProject("proj_dash_1", detailProj));
    foreach (tsk; detailProj.tasks)
    {
        if (tsk.id == "test_node_2")
        {
            detailTask = tsk;
            foundDetailTask = true;
            break;
        }
    }
    assert(foundDetailTask);
    assert(detailTask.id == "test_node_2");
    assert(detailTask.steps.length == 1);
    assert(detailTask.dependsOn == ["test_node_1"]);

    auto node2History = stateRepo.listTaskExecutionsForTask("proj_dash_1", "test_node_2");
    assert(node2History.length == 1);
    assert(node2History[0].buildId == "b_dash_2");
    assert(node2History[0].status == "succeeded");
    assert(node2History[0].durationMs == 45);
    assert(node2History[0].fingerprint == "0123456789abcdef");

    // Test Task Execution instance lookup and log retrieval
    TaskExecutionRecord execRec;
    assert(stateRepo.getTaskExecution("b_dash_2", "test_node_2", execRec));
    assert(execRec.status == "succeeded");
    assert(execRec.durationMs == 45);
    auto execLogs = stateRepo.getTaskLogs("b_dash_2", "test_node_2");
    assert(execLogs.length == 1);
    assert(execLogs[0] == "Task step log line 1");

    import std.file : exists, rmdirRecurse;
    if (exists("test_dashboard_storage")) rmdirRecurse("test_dashboard_storage");
}
