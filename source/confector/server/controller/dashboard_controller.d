module controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError, logInfo, logWarn;
import confector.core.model;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;
import confector.core.dag;
import confector.core.input_resolution : InputResolutionException;
import confector.core.plugin : PluginRegistry;
import confector.core.system : BuildStepProvider;
import confector.runner_core.engine;
import confector.orchestrator.coordinator;

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
    string[] upstreamTasks;
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

/**
 * Thrown when the task editor's input fields cannot be mapped onto declared inputs,
 * for example when two different inputs would get the same name.
 */
class TaskInputFormException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * One row of the task editor's Inputs tab: a named input as the form submits it. Every row
 * carries every kind's fields (the editor hides the ones that do not apply to `kind`); only
 * the fields of the row's own kind are read.
 */
struct TaskInputRow
{
    string name;
    /// An `InputKind` wire value: "repository", "value" or "task_output".
    string kind;
    string repository;
    string refSelector;
    string value;
    string task;
    string artifact;
}

/// The editor rows for a task's declared inputs, sorted by input name.
TaskInputRow[] taskInputRows(in InputDecl[string] inputs) pure @safe
{
    import std.algorithm.sorting : sort;

    string[] names;
    foreach (name; inputs.byKey) names ~= name;
    names.sort();

    TaskInputRow[] rows;
    foreach (name; names)
    {
        const decl = inputs[name];
        TaskInputRow row;
        row.name = name;
        row.kind = cast(string) decl.kind;
        row.repository = decl.spec.repository;
        row.refSelector = decl.spec.refSelector;
        row.value = decl.spec.value;
        row.task = decl.spec.task;
        row.artifact = decl.spec.artifact;
        rows ~= row;
    }
    return rows;
}

/**
 * Zips the parallel `input_*` form fields into rows.
 *
 * Throws: TaskInputFormException if the fields do not all have the same length.
 */
TaskInputRow[] taskInputRowsFromForm(
    in string[] names, in string[] kinds, in string[] repositories, in string[] refSelectors,
    in string[] values, in string[] tasks, in string[] artifacts
) pure @safe
{
    foreach (fieldLength; [kinds.length, repositories.length, refSelectors.length, values.length, tasks.length, artifacts.length])
    {
        if (fieldLength != names.length)
        {
            throw new TaskInputFormException("The input fields of the form are inconsistent; reload the editor and try again");
        }
    }
    TaskInputRow[] rows;
    foreach (i; 0 .. names.length)
    {
        rows ~= TaskInputRow(names[i], kinds[i], repositories[i], refSelectors[i], values[i], tasks[i], artifacts[i]);
    }
    return rows;
}

/**
 * Validates the editor's input rows and turns them into the task's declared inputs.
 *
 * Rows with no content at all are ignored. Every other row must have a unique name and the
 * fields its kind needs: a repository input must name a registered repository and a ref
 * selector (there is no default ref); a value input a value; a task output input another task
 * of the project. All problems are reported together, one per line.
 *
 * Throws: TaskInputFormException listing every problem.
 */
InputDecl[string] parseTaskInputRows(
    string taskId,
    in TaskInputRow[] rows,
    in string[] registeredRepositories,
    in string[] otherTaskIds
) @safe
{
    import std.algorithm.searching : canFind;
    import std.array : join;

    InputDecl[string] result;
    string[] errors;
    bool[string] seenNames;

    foreach (i, row; rows)
    {
        const name = row.name.strip();
        const repository = row.repository.strip();
        const refSelector = row.refSelector.strip();
        const value = row.value.strip();
        const task = row.task.strip();
        const artifact = row.artifact.strip();

        if (name.length == 0 && repository.length == 0 && refSelector.length == 0
            && value.length == 0 && task.length == 0 && artifact.length == 0)
        {
            continue;
        }

        const label = name.length > 0 ? format("Input '%s'", name) : format("Input %s", i + 1);
        bool ok = true;
        void fail(string problem)
        {
            errors ~= format("%s: %s", label, problem);
            ok = false;
        }

        if (name.length == 0) fail("needs a name");
        else if (name in seenNames) fail("the name is used by another input");
        seenNames[name] = true;

        InputDecl decl;
        switch (row.kind)
        {
            case "repository":
                if (repository.length == 0) fail("choose a repository");
                else if (!registeredRepositories.canFind(repository)) fail(format("repository '%s' is not registered", repository));
                if (refSelector.length == 0) fail("a ref selector is required (for example a branch or tag name); there is no default ref");
                decl = repositoryInput(repository, refSelector);
                break;
            case "value":
                if (value.length == 0) fail("needs a value");
                decl = valueInput(value);
                break;
            case "task_output":
                if (task.length == 0) fail("choose an upstream task");
                else if (task == taskId) fail("a task cannot take its own output as an input");
                else if (!otherTaskIds.canFind(task)) fail(format("task '%s' is not in this project", task));
                decl = taskOutputInput(task, artifact);
                break;
            default:
                fail(format("unknown input kind '%s'", row.kind));
                break;
        }

        if (ok) result[name] = decl;
    }

    if (errors.length > 0) throw new TaskInputFormException(errors.join("\n"));
    return result;
}

/// The step type of the built-in checkout step, whose `input` parameter names a repository input.
enum checkoutStepType = "clone_repository";

/**
 * Problems with the checkout steps in `steps`, aligned with `steps` (empty for steps without
 * problems and for steps of other types). A checkout step's parameters are validated with
 * `validateParameters` (when given), which flags parameters it no longer supports, such as an
 * old `repository` or `branch`; and its `input` must name one of the task's repository inputs.
 */
string[][] checkoutStepIssues(
    in BuildStep[] steps,
    in InputDecl[string] inputs,
    string[] delegate(in string[string] parameters) @safe validateParameters
) @safe
{
    string[][] issues;
    issues.length = steps.length;
    foreach (i, step; steps)
    {
        if (step.type != checkoutStepType) continue;
        if (validateParameters !is null) issues[i] ~= validateParameters(step.parameters);
        if (auto name = "input" in step.parameters)
        {
            if (name.length > 0)
            {
                auto decl = *name in inputs;
                if (decl is null || decl.kind != InputKind.repository)
                {
                    issues[i] ~= format("Input '%s' is not a repository input declared on this task", *name);
                }
            }
        }
    }
    return issues;
}

/// Formats step issues for the error banner of a rejected save.
string formatStepIssues(in BuildStep[] steps, in string[][] issues) pure @safe
{
    import std.array : join;

    string[] lines;
    foreach (i, stepIssues; issues)
    {
        foreach (issue; stepIssues)
        {
            lines ~= format("Step %s (%s): %s", i + 1, steps[i].name.length > 0 ? steps[i].name : steps[i].type, issue);
        }
    }
    return lines.join("\n");
}

unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import std.algorithm.searching : canFind;

    // Round trip: declared inputs of every kind survive rendering and saving the form.
    InputDecl[string] existing = [
        "src": repositoryInput("game", "main"),
        "lib": repositoryInput("game", "release"),
        "flavor": valueInput("external"),
        "eng": taskOutputInput("build-engine", "engine.zip"),
        "setup": taskOutputInput("setup"),
    ];
    auto rows = taskInputRows(existing);
    assert(rows.length == 5 && rows[0].name == "eng");
    assert(parseTaskInputRows("package", rows, ["game"], ["build-engine", "setup"]) == existing);

    // Fully blank rows are ignored; removed rows are gone.
    assert(parseTaskInputRows("package", [TaskInputRow("", "value", "", "", "", "", "")], [], []).length == 0);
    assert(parseTaskInputRows("package", rows[0 .. 1], [], ["build-engine"]).length == 1);

    // Form fields zip into rows; mismatched lengths are rejected.
    assert(taskInputRowsFromForm(["a"], ["value"], [""], [""], ["v"], [""], [""]) == [TaskInputRow("a", "value", "", "", "v", "", "")]);
    assertThrown!TaskInputFormException(taskInputRowsFromForm(["a"], [], [""], [""], ["v"], [""], [""]));

    // An empty ref selector or repository is rejected, not defaulted.
    auto noRef = collectExceptionMsg!TaskInputFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "game", "  ", "", "", "")], ["game"], []));
    assert(noRef.canFind("src") && noRef.canFind("ref selector"));
    auto noRepo = collectExceptionMsg!TaskInputFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "", "main", "", "", "")], ["game"], []));
    assert(noRepo.canFind("choose a repository"));
    assert(collectExceptionMsg!TaskInputFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "gone", "main", "", "", "")], ["game"], [])).canFind("not registered"));

    // Other mistakes, all reported together.
    auto many = collectExceptionMsg!TaskInputFormException(parseTaskInputRows("t", [
        TaskInputRow("", "value", "", "", "x", "", ""),
        TaskInputRow("v", "value", "", "", "", "", ""),
        TaskInputRow("o", "task_output", "", "", "", "t", ""),
        TaskInputRow("p", "task_output", "", "", "", "ghost", ""),
        TaskInputRow("q", "nonsense", "", "", "", "", ""),
        TaskInputRow("v", "value", "", "", "dup", "", ""),
    ], [], ["up"]));
    foreach (fragment; ["needs a name", "needs a value", "its own output", "'ghost' is not in this project", "unknown input kind", "used by another"])
    {
        assert(many.canFind(fragment), fragment);
    }

    // Checkout steps must name a declared repository input, and old parameters are flagged.
    BuildStep checkout;
    checkout.type = checkoutStepType;
    checkout.parameters = ["input": "src"];
    BuildStep bash;
    bash.type = "bash";
    bash.parameters = ["input": "ignored"];
    BuildStep legacy;
    legacy.type = checkoutStepType;
    legacy.parameters = ["input": "flavor", "repository": "x"];
    string[] validator(in string[string] p) @safe { return "repository" in p ? ["Parameter 'repository' is not supported"] : null; }
    auto issues = checkoutStepIssues([checkout, bash, legacy], existing, &validator);
    assert(issues.length == 3 && issues[0].length == 0 && issues[1].length == 0);
    assert(issues[2].length == 2 && issues[2][1].canFind("flavor"));
    assert(formatStepIssues([checkout, bash, legacy], issues).canFind("Step 3"));
}

URLRouter dashboardRouter(TaskEngine engine, StateStores stores, PluginRegistry registry = null, BuildCoordinator coordinator = null)
{
    if (registry is null)
    {
        registry = PluginRegistry.instance;
    }
    auto router = new URLRouter();

    // Validates a checkout step's parameters with the checkout step provider's own rules.
    string[] validateCheckoutParameters(in string[string] parameters) @trusted
    {
        import std.json : JSONValue, parseJSON;

        if (registry is null) return null;
        foreach (p; registry.getStepProviders())
        {
            if (p.stepType != checkoutStepType) continue;
            JSONValue json = parseJSON("{}");
            foreach (key, value; parameters) json[key] = value;
            return p.validateParameters(json);
        }
        return null;
    }

    // Renders the task editor. `inputRows` are the Inputs tab rows to show: the task's declared
    // inputs, or the submitted rows when the editor is shown again after a rejected save.
    // `formError` is shown at the top of the editor; checkout steps with problems (including old
    // parameters the step no longer supports) are flagged in the Steps tab.
    void renderTaskEditor(HTTPServerResponse res, ProjectRecord project, TaskNode task,
        TaskInputRow[] inputRows, string formError)
    {
        auto repositories = stores !is null ? stores.repositories.list() : [];
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
        // Checked against the rows being shown, which may include edits that were not saved.
        InputDecl[string] shownInputs;
        foreach (row; inputRows)
        {
            if (row.kind == InputKind.repository && row.name.strip().length > 0)
            {
                shownInputs[row.name.strip()] = repositoryInput(row.repository, row.refSelector);
            }
        }
        string[][] stepIssues = checkoutStepIssues(task.steps, shownInputs, &validateCheckoutParameters);
        res.render!("project/task-editor.dt", project, task, repositories, stepProvidersView, inputRows, stepIssues, formError);
    }

    // Home / Dashboard
    router.get("/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto projects = stores !is null ? stores.projects.list() : [];
        auto builds = stores !is null ? stores.legacyBuilds.listBuilds(10) : [];
        auto recentTasks = stores !is null ? stores.legacyBuilds.listRecentTaskExecutions(10) : [];

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
                tvm.upstreamTasks = upstreamTaskIds(task);

                TaskExecutionRecord latestExec;
                if (stores !is null)
                {
                    auto execs = stores.legacyBuilds.listTaskExecutionsForTask(proj.id, task.id, 1);
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

        res.render!("dashboard/home.dt", dashboardProjects, builds, recentTasks, totalBuilds, successfulBuilds, failedBuilds, totalProjects, totalTasksAll, successfulTasksAll, failedTasksAll);
    });

    // Projects Management
    router.get("/projects/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto projects = stores !is null ? stores.projects.list() : [];
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
            string now = Clock.currTime.toISOString();
            proj.createdAt = now;
            proj.updatedAt = now;

            if (stores !is null)
            {
                stores.projects.put(proj);
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
        bool found = stores !is null && stores.projects.get(projId).tryValue(project);
        if (!found)
        {
            project.id = projId;
            project.name = "Unknown Project";
        }

        // TODO(confector-z7z.24.1): show pending changes per repository from tracked branches.
        // Until then there are none to show; the count this replaced always came out empty.
        string pendingCommitsJson = "{}";
        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-details.dt", project, tasksJson, pendingCommitsJson);
    });

    router.get("/projects/edit", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        if (stores !is null)
        {
            stores.projects.get(projId).tryValue(project);
        }
        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-editor.dt", project, tasksJson);
    });

    router.post("/projects/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("id", "");
        try
        {
            ProjectRecord project;
            if (stores !is null && projId.length > 0)
            {
                stores.projects.get(projId).tryValue(project);
            }

            project.id = projId;
            project.name = req.form.get("name", project.name.length > 0 ? project.name : "Project");
            project.description = req.form.get("description", project.description);

            string tasksJsonText = req.form.get("tasks_json", "[]");
            Json parsed = parseJsonString(tasksJsonText);
            if (parsed.type == Json.Type.array)
            {
                project.tasks = deserializeJson!(TaskNode[])(parsed);
            }

            // Validate DAG
            auto graph = new TaskGraph(project.tasks);

            project.updatedAt = Clock.currTime.toISOString();
            if (stores !is null)
            {
                stores.projects.put(project);
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
            if (stores !is null && projId.length > 0)
            {
                stores.projects.remove(projId);
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
        if (stores !is null && projId.length > 0)
        {
            stores.projects.get(projId).tryValue(project);
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

        renderTaskEditor(res, project, task, taskInputRows(task.inputs), "");
    });

    router.post("/projects/tasks/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("project_id", "");
        ProjectRecord project;
        TaskNode task;
        TaskInputRow[] inputRows;
        try
        {
            if (stores !is null && projId.length > 0)
            {
                stores.projects.get(projId).tryValue(project);
            }

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
                auto stepInputs = req.form.getAll("step_param_input");
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

                    // A checkout step names a declared repository input; it takes no URL or ref
                    if (i < stepInputs.length && stepInputs[i].strip().length > 0)
                    {
                        step.parameters["input"] = stepInputs[i].strip();
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

            // Inputs. Validated here, on the server: the editor's own checks are a convenience.
            // The submitted rows are kept so a rejected save shows the editor with the user's edits.
            inputRows = taskInputRowsFromForm(
                req.form.getAll("input_name"),
                req.form.getAll("input_kind"),
                req.form.getAll("input_repository"),
                req.form.getAll("input_ref"),
                req.form.getAll("input_value"),
                req.form.getAll("input_task"),
                req.form.getAll("input_artifact")
            );
            string[] registeredRepositories;
            if (stores !is null)
            {
                foreach (r; stores.repositories.list()) registeredRepositories ~= r.name;
            }
            string[] otherTaskIds;
            foreach (t; project.tasks)
            {
                if (t.id != task.id) otherTaskIds ~= t.id;
            }
            task.inputs = parseTaskInputRows(task.id, inputRows, registeredRepositories, otherTaskIds);

            auto stepIssues = checkoutStepIssues(task.steps, task.inputs, &validateCheckoutParameters);
            string stepProblems = formatStepIssues(task.steps, stepIssues);
            if (stepProblems.length > 0)
            {
                throw new TaskInputFormException(stepProblems);
            }

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
            if (stores !is null)
            {
                stores.projects.put(project);
            }
        }
        catch (TaskInputFormException e)
        {
            res.statusCode = HTTPStatus.badRequest;
            renderTaskEditor(res, project, task, inputRows, e.msg);
            return;
        }
        catch (Exception e)
        {
            // Nothing was saved (for example the task graph is cyclic): say so, and keep the edits.
            logError("Failed to save task: %s", e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            renderTaskEditor(res, project, task, inputRows, "Failed to save task: " ~ e.msg);
            return;
        }

        res.redirect("/projects/details?id=" ~ projId);
    });

    router.post("/projects/tasks/delete", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("project_id", "");
        string taskId = req.form.get("task_id", "");
        try
        {
            ProjectRecord project;
            if (stores !is null && projId.length > 0 && stores.projects.get(projId).tryValue(project))
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
                stores.projects.put(project);
            }
        }
        catch (Exception e)
        {
            logError("Failed to delete task: %s", e.msg);
        }
        res.redirect("/projects/details?id=" ~ projId);
    });

    // Execute Project Task Graph. A build that cannot be started (for example an input that
    // cannot be resolved) is reported on the error page rather than logged and ignored.
    router.post("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("id", "");
        if (projId.length == 0) projId = req.form.get("project_id", "");
        string targetTaskId = req.form.get("target_task_id", "");
        if (targetTaskId.length == 0) targetTaskId = req.form.get("taskId", "");
        if (targetTaskId.length == 0) targetTaskId = req.form.get("task_id", "");

        ProjectRecord proj;
        if (stores is null || !stores.projects.get(projId).tryValue(proj))
        {
            throw new HTTPStatusException(HTTPStatus.notFound, format("Cannot run project '%s': it does not exist", projId));
        }
        if (coordinator is null)
        {
            throw new HTTPStatusException(HTTPStatus.internalServerError,
                format("Cannot run project '%s': the build coordinator is not configured", proj.id));
        }

        string buildId;
        try
        {
            buildId = coordinator.startBuild(proj, targetTaskId.length > 0 ? targetTaskId : null, false, "dashboard", ".");
        }
        catch (Exception e)
        {
            logError("Failed to start build of project '%s': %s", proj.id, e.msg);
            throw new HTTPStatusException(
                cast(InputResolutionException) e !is null ? HTTPStatus.badRequest : HTTPStatus.internalServerError,
                format("Could not start a build of project '%s': %s", proj.id, e.msg));
        }
        res.redirect("/builds/details?id=" ~ buildId);
    });

    // Tasks List (Task-Centric View). Queued tasks will be shown by the build queue view (bead
    // confector-z7z.31.21); the dispatch queue is never read for display.
    router.get("/tasks/", (HTTPServerRequest req, HTTPServerResponse res) {
        string statusFilter = req.query.get("status", "");
        string projectFilter = req.query.get("project_id", "");
        auto recentTasks = stores !is null ? stores.legacyBuilds.listRecentTaskExecutions(50, statusFilter, projectFilter) : [];
        res.render!("task/tasks.dt", recentTasks, statusFilter, projectFilter);
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

        if (stores !is null)
        {
            if (projectId.length > 0 && stores.projects.get(projectId).tryValue(project))
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
                foreach (p; stores.projects.list())
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

        TaskExecutionRecord[] history = stores !is null ? stores.legacyBuilds.listTaskExecutionsForTask(projectId, taskId, 50) : [];
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
        bool foundRecord = stores !is null && stores.legacyBuilds.getTaskExecution(buildId, taskId, taskRecord);
        if (!foundRecord)
        {
            taskRecord.buildId = buildId;
            taskRecord.taskId = taskId;
            taskRecord.status = "unknown";
        }

        string[] logs = stores !is null ? stores.logs.getTaskLogs(buildId, taskId) : [];
        if (logs.length == 0 && stores !is null && buildId.length > 0)
        {
            auto bLogs = stores.logs.getBuildLogs(buildId);
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
        if (stores !is null && buildId.length > 0)
        {
            stores.legacyBuilds.getBuild(buildId, build);
        }

        string projectId = taskRecord.projectId.length > 0 ? taskRecord.projectId : build.projectId;
        ProjectRecord project;
        TaskNode taskNode;
        bool foundTask = false;

        if (stores !is null)
        {
            if (projectId.length > 0 && stores.projects.get(projectId).tryValue(project))
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
                foreach (p; stores.projects.list())
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

    // Builds List. Queued tasks will be shown by the build queue view (bead confector-z7z.31.21);
    // the dispatch queue is never read for display.
    router.get("/builds/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto builds = stores !is null ? stores.legacyBuilds.listBuilds(50) : [];
        auto recentTasks = stores !is null ? stores.legacyBuilds.listRecentTaskExecutions(25) : [];
        res.render!("build/builds.dt", builds, recentTasks);
    });

    // Build Details & Task Graph Visualization
    router.get("/builds/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string buildId = req.query.get("id", "");
        BuildRecord build;
        bool found = stores !is null && stores.legacyBuilds.getBuild(buildId, build);
        string[] logs = stores !is null ? stores.logs.getBuildLogs(buildId) : [];

        if (!found)
        {
            build.buildId = buildId;
            build.status = "unknown";
            build.projectName = "default";
        }

        TaskNode[] tasks;
        ProjectRecord project;
        if (stores !is null && build.projectId.length > 0 && stores.projects.get(build.projectId).tryValue(project))
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
        auto recordedStatuses = stores !is null ? stores.legacyBuilds.getTaskStatusesForBuild(build.buildId) : (TaskStatus[string]).init;
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
    import confector.core.test_storage : InMemoryArtifactStorage;
    import confector.core.memory_document_store : InMemoryDocumentStore;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto storage = new InMemoryArtifactStorage();
    auto engine = new TaskEngine(storage);

    auto router = dashboardRouter(engine, stores);
    assert(router !is null);

    // Populate dummy build & trigger
    BuildRecord b;
    b.buildId = "b_dash_1";
    b.projectName = "main_project";
    b.status = "succeeded";
    b.startedAt = "2026-10-15T14:02:00Z";
    stores.legacyBuilds.createBuild(b);

    TriggerRuleRecord t;
    t.id = "t_dash_1";
    t.name = "Weekly Nightly";
    t.triggerType = "cron";
    t.criteria = "0 0 * * 0";
    stores.triggerRules.save(t);

    assert(stores.legacyBuilds.listBuilds().length == 1);
    assert(stores.triggerRules.list().length == 1);

    // Populate and verify Project & Task state
    ProjectRecord p;
    p.id = "proj_dash_1";
    p.name = "Dashboard Project";
    TaskNode tNode1;
    tNode1.id = "test_node_1";
    tNode1.steps = [BuildStep("Echo", "bash", null, "echo dashboard test 1")];
    tNode1.inputs["repo_main"] = repositoryInput("repo_main", "main");
    tNode1.triggers = [TriggerRule(TriggerType.gitPush, ["main", "feature/*"])];
    TaskNode tNode2;
    tNode2.id = "test_node_2";
    tNode2.inputs["test_node_1"] = taskOutputInput("test_node_1");
    tNode2.steps = [BuildStep("Echo", "bash", null, "echo dashboard test 2")];
    tNode2.triggers = [TriggerRule(TriggerType.webhook, null, null, "/api/v1/deploy")];
    p.tasks = [tNode1, tNode2];
    stores.projects.put(p);
    assert(stores.projects.list().length == 1);

    RepositoryRecord rRecord;
    rRecord.name = "repo_main";
    rRecord.address = "https://github.com/example/repo_main.git";
    stores.repositories.put(rRecord);
    assert(stores.repositories.list().length == 1);

    ProjectRecord fetchedProj;
    assert(stores.projects.get("proj_dash_1").tryValue(fetchedProj));
    assert(fetchedProj.tasks.length == 2);
    assert(fetchedProj.tasks[0].id == "test_node_1");
    assert(fetchedProj.tasks[0].inputs == ["repo_main": repositoryInput("repo_main", "main")]);
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
    b2.startedAt = "2026-10-15T15:00:00Z";
    stores.legacyBuilds.createBuild(b2);
    stores.legacyBuilds.setTaskStatus("b_dash_2", "test_node_1", TaskStatus.cached);
    stores.legacyBuilds.setTaskStatus("b_dash_2", "test_node_2", TaskStatus.succeeded);

    TaskStatus st1, st2;
    assert(stores.legacyBuilds.getTaskStatus("b_dash_2", "test_node_1", st1) && st1 == TaskStatus.cached);
    assert(stores.legacyBuilds.getTaskStatus("b_dash_2", "test_node_2", st2) && st2 == TaskStatus.succeeded);

    // Test task execution record and task-scoped log queries
    stores.legacyBuilds.updateTaskExecution("b_dash_2", "test_node_2", (ref TaskExecutionRecord taskRec) {
        taskRec.durationMs = 45;
        taskRec.fingerprint = "0123456789abcdef";
    });
    stores.logs.appendTaskLog("b_dash_2", "test_node_2", "Task step log line 1");

    auto recentTasks = stores.legacyBuilds.listRecentTaskExecutions();
    assert(recentTasks.length >= 1);
    assert(stores.logs.getTaskLogs("b_dash_2", "test_node_2") == ["Task step log line 1"]);

    // Test listTaskExecutionsForTask
    auto taskExecs = stores.legacyBuilds.listTaskExecutionsForTask("proj_dash_1", "test_node_2");
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
    foreach (proj; stores.projects.list())
    {
        DashboardProjectViewModel pvm;
        pvm.project = proj;
        pvm.totalTasks = proj.tasks.length;

        foreach (task; proj.tasks)
        {
            DashboardTaskViewModel tvm;
            tvm.id = task.id;
            tvm.name = task.name.length > 0 ? task.name : task.id;
            tvm.upstreamTasks = upstreamTaskIds(task);

            TaskExecutionRecord latestExec;
            auto execs = stores.legacyBuilds.listTaskExecutionsForTask(proj.id, task.id, 1);
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
    // A status set on a build's task records it under the build's project
    assert(testDashboardProjects[0].tasks[0].changeStatus == "up_to_date");
    assert(testDashboardProjects[0].tasks[0].lastStatus == "cached");
    assert(testDashboardProjects[0].tasks[1].id == "test_node_2");
    assert(testDashboardProjects[0].tasks[1].changeStatus == "up_to_date");
    assert(testDashboardProjects[0].tasks[1].lastStatus == "succeeded");
    assert(testDashboardProjects[0].successfulTasks == 2);

    // Test Task Details definition resolution and execution history retrieval
    ProjectRecord detailProj;
    TaskNode detailTask;
    bool foundDetailTask = false;
    assert(stores.projects.get("proj_dash_1").tryValue(detailProj));
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
    assert(upstreamTaskIds(detailTask) == ["test_node_1"]);

    auto node2History = stores.legacyBuilds.listTaskExecutionsForTask("proj_dash_1", "test_node_2");
    assert(node2History.length == 1);
    assert(node2History[0].buildId == "b_dash_2");
    assert(node2History[0].status == "succeeded");
    assert(node2History[0].durationMs == 45);
    assert(node2History[0].fingerprint == "0123456789abcdef");

    // Test Task Execution instance lookup and log retrieval
    TaskExecutionRecord execRec;
    assert(stores.legacyBuilds.getTaskExecution("b_dash_2", "test_node_2", execRec));
    assert(execRec.status == "succeeded");
    assert(execRec.durationMs == 45);
    auto execLogs = stores.logs.getTaskLogs("b_dash_2", "test_node_2");
    assert(execLogs.length == 1);
    assert(execLogs[0] == "Task step log line 1");

    import std.file : exists, rmdirRecurse;
    if (exists("test_dashboard_storage")) rmdirRecurse("test_dashboard_storage");
}
