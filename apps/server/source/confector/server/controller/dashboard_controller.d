module confector.server.controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError;
import confector.core.builtin_steps : builtinStepTypes, checkoutConfigIssues, checkoutStepType;
import confector.plugin_api.model;
import confector.core.document_collection : tryValue;
import confector.core.state_stores : StateStores;
import confector.core.dag;
import confector.server.controller.api_controller : buildsNotImplemented;

import std.algorithm : canFind;
import std.datetime.systime : Clock;
import std.format : format;
import std.string : strip;
import std.uuid : randomUUID;

// View model for task summary on dashboard
struct DashboardTaskViewModel
{
    string id;
    string name;
    string[] upstreamTasks;
}

// View model for collapsible project panel on dashboard
struct DashboardProjectViewModel
{
    ProjectRecord project;
    DashboardTaskViewModel[] tasks;
    ulong totalTasks;
}

/**
 * Thrown when the task editor's form cannot be turned into a task: its inputs, steps or output
 * declarations are invalid, for example two inputs with the same name or a step config that is
 * not a JSON object. The message lists every problem, one per line.
 */
class TaskFormException : Exception
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
 * Throws: TaskFormException if the fields do not all have the same length.
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
            throw new TaskFormException("The input fields of the form are inconsistent; reload the editor and try again");
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
 * Throws: TaskFormException listing every problem.
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

    if (errors.length > 0) throw new TaskFormException(errors.join("\n"));
    return result;
}

/**
 * The repository inputs among the editor's input rows, by name, as far as the rows say:
 * what checkout steps are checked against when the rows themselves have problems or were not
 * saved yet.
 */
InputDecl[string] shownRepositoryInputs(in TaskInputRow[] rows) pure @safe
{
    InputDecl[string] shown;
    foreach (row; rows)
    {
        if (row.kind == InputKind.repository && row.name.strip().length > 0)
        {
            shown[row.name.strip()] = repositoryInput(row.repository, row.refSelector);
        }
    }
    return shown;
}

/**
 * One row of the task editor's Steps tab, as the form submits it: the step's display name, its
 * type, and its config as JSON text. The text is kept as typed, so a rejected save shows it
 * again unchanged.
 */
struct TaskStepRow
{
    string name;
    string type;
    string config;
}

/// The editor rows for a task's steps. A step without config shows an empty object.
TaskStepRow[] taskStepRows(in BuildStep[] steps) @trusted
{
    TaskStepRow[] rows;
    foreach (step; steps)
    {
        const config = step.config.type == Json.Type.undefined ? Json.emptyObject : step.config;
        rows ~= TaskStepRow(step.name, step.type, config.toPrettyString());
    }
    return rows;
}

/**
 * Zips the parallel `step_*` form fields into rows.
 *
 * Throws: TaskFormException if the fields do not all have the same length.
 */
TaskStepRow[] taskStepRowsFromForm(in string[] names, in string[] types, in string[] configs) pure @safe
{
    if (types.length != names.length || configs.length != names.length)
    {
        throw new TaskFormException("The step fields of the form are inconsistent; reload the editor and try again");
    }
    TaskStepRow[] rows;
    foreach (i; 0 .. names.length) rows ~= TaskStepRow(names[i], types[i], configs[i]);
    return rows;
}

/**
 * Problems with a checkout step's `config`: those the runner would refuse it for
 * (`checkoutConfigIssues`: its keys and their value types), and an `input` that does not name
 * one of `inputs`' repository inputs.
 */
string[] checkoutStepIssues(in Json config, in InputDecl[string] inputs) @trusted
{
    string[] issues = checkoutConfigIssues(config);
    if (config.type != Json.Type.object) return issues;
    auto input = "input" in config;
    if (input !is null && input.type == Json.Type.string && input.get!string.length > 0)
    {
        auto decl = input.get!string in inputs;
        if (decl is null || decl.kind != InputKind.repository)
        {
            issues ~= format("input '%s' is not a repository input declared on this task", input.get!string);
        }
    }
    return issues;
}

/**
 * Problems with each of the editor's step rows, aligned with `rows` (empty for a row without
 * problems): the type must be a built-in step type, the config must be a JSON object, and a
 * checkout step's config must pass `checkoutStepIssues` against `inputs`.
 */
string[][] taskStepRowIssues(in TaskStepRow[] rows, in InputDecl[string] inputs) @trusted
{
    string[][] issues;
    issues.length = rows.length;
    foreach (i, row; rows)
    {
        const type = row.type.strip();
        if (!builtinStepTypes.canFind(type))
        {
            issues[i] ~= format("step type '%s' is not a built-in step type (%-(%s, %)); step programs are bead confector-z7z.35.1",
                type, builtinStepTypes);
        }
        Json config;
        try config = parseJsonString(row.config.strip());
        catch (Exception e)
        {
            issues[i] ~= format("the config is not valid JSON (%s); write a JSON object, {} for none", e.msg);
            continue;
        }
        if (config.type != Json.Type.object)
        {
            issues[i] ~= "the config must be a JSON object; write {} for none";
            continue;
        }
        if (type == checkoutStepType) issues[i] ~= checkoutStepIssues(config, inputs);
    }
    return issues;
}

/// Formats step issues for the error banner of a rejected save.
string formatStepIssues(in TaskStepRow[] rows, in string[][] issues) pure @safe
{
    import std.array : join;

    string[] lines;
    foreach (i, stepIssues; issues)
    {
        const label = rows[i].name.strip().length > 0 ? rows[i].name.strip() : rows[i].type.strip();
        foreach (issue; stepIssues)
        {
            lines ~= format("Step %s (%s): %s", i + 1, label, issue);
        }
    }
    return lines.join("\n");
}

/**
 * Validates the editor's step rows (see `taskStepRowIssues`) and turns them into the task's
 * steps, in order.
 *
 * Throws: TaskFormException listing every problem.
 */
BuildStep[] parseTaskStepRows(in TaskStepRow[] rows, in InputDecl[string] inputs) @trusted
{
    const problems = formatStepIssues(rows, taskStepRowIssues(rows, inputs));
    if (problems.length > 0) throw new TaskFormException(problems);
    BuildStep[] steps;
    foreach (row; rows)
    {
        steps ~= BuildStep(row.name.strip(), row.type.strip(), parseJsonString(row.config.strip()));
    }
    return steps;
}

/// True if `path` is absolute (a leading `/` or `\`), drive-qualified (`C:`) or has a `..` segment.
private bool escapesWorkingDirectory(string path) pure @safe
{
    import std.algorithm.iteration : splitter;
    import std.ascii : isAlpha;

    if (path.length > 0 && (path[0] == '/' || path[0] == '\\')) return true;
    if (path.length >= 2 && isAlpha(path[0]) && path[1] == ':') return true;
    foreach (segment; path.splitter!(c => c == '/' || c == '\\'))
    {
        if (segment == "..") return true;
    }
    return false;
}

/// The Outputs tab's text for `artifacts`: one `id: path` line per declared output.
string outputDeclarationsText(in OutputArtifactDecl[] artifacts) pure @safe
{
    import std.array : join;

    string[] lines;
    foreach (artifact; artifacts) lines ~= artifact.id ~ ": " ~ artifact.path;
    return lines.join("\n");
}

/**
 * Parses the Outputs tab's text: one `id: path` line per declared output (the id ends at the
 * first colon). Blank lines are ignored. Each line needs both an id and a path, ids must be
 * unique, and a path must stay inside the working directory: not absolute, not drive-qualified
 * and without `..` segments.
 *
 * Throws: TaskFormException listing every problem.
 */
OutputArtifactDecl[] parseOutputDeclarations(string text) @safe
{
    import std.array : join;
    import std.string : indexOf, lineSplitter;

    OutputArtifactDecl[] artifacts;
    string[] errors;
    bool[string] seen;
    size_t lineNumber;
    foreach (line; text.lineSplitter)
    {
        ++lineNumber;
        const s = line.strip();
        if (s.length == 0) continue;
        const colon = s.indexOf(':');
        const id = colon < 0 ? "" : s[0 .. colon].strip();
        const path = colon < 0 ? "" : s[colon + 1 .. $].strip();
        if (id.length == 0 || path.length == 0)
        {
            errors ~= format("Output line %s ('%s'): write each output as id: path; both are required", lineNumber, s);
            continue;
        }
        if (escapesWorkingDirectory(path))
        {
            errors ~= format("Output line %s ('%s'): the path must be relative to the working directory, without a drive, a leading slash or '..'",
                lineNumber, s);
            continue;
        }
        if (id in seen)
        {
            errors ~= format("Output line %s: the id '%s' is used by another output", lineNumber, id);
            continue;
        }
        seen[id] = true;
        artifacts ~= OutputArtifactDecl(id, path);
    }
    if (errors.length > 0) throw new TaskFormException(errors.join("\n"));
    return artifacts;
}

/// The Environment field's text for `environment`: one `KEY=VALUE` line per variable, by key.
string environmentText(in string[string] environment) pure @safe
{
    import std.algorithm.sorting : sort;
    import std.array : join;

    string[] keys;
    foreach (key; environment.byKey) keys ~= key;
    keys.sort();
    string[] lines;
    foreach (key; keys) lines ~= key ~ "=" ~ environment[key];
    return lines.join("\n");
}

/**
 * Parses the Environment field's text: one `KEY=VALUE` line per variable (the key ends at the
 * first `=`; the value is the rest of the line as typed, possibly empty). Blank lines are
 * ignored. A key must be non-empty without whitespace, and keys must be unique.
 *
 * Throws: TaskFormException listing every problem.
 */
string[string] parseEnvironment(string text) @safe
{
    import std.algorithm.searching : any;
    import std.array : join;
    import std.ascii : isWhite;
    import std.string : indexOf, lineSplitter;

    string[string] environment;
    string[] errors;
    size_t lineNumber;
    foreach (line; text.lineSplitter)
    {
        ++lineNumber;
        if (line.strip().length == 0) continue;
        const eq = line.indexOf('=');
        const key = eq < 0 ? "" : line[0 .. eq];
        if (eq < 0 || key.length == 0 || key.any!isWhite)
        {
            errors ~= format("Environment line %s ('%s'): write each variable as KEY=VALUE, with a key and no spaces around it",
                lineNumber, line);
            continue;
        }
        if (key in environment)
        {
            errors ~= format("Environment line %s: the variable '%s' is set more than once", lineNumber, key);
            continue;
        }
        environment[key] = line[eq + 1 .. $];
    }
    if (errors.length > 0) throw new TaskFormException(errors.join("\n"));
    return environment;
}

/**
 * Parses the Timeout field: a positive whole number of seconds. There is no default: a blank
 * field is refused.
 *
 * Throws: TaskFormException if it is not one.
 */
size_t parseTimeout(string text) @safe
{
    import std.conv : to;

    const s = text.strip();
    size_t seconds;
    try seconds = s.to!size_t;
    catch (Exception) seconds = 0;
    if (seconds == 0)
    {
        throw new TaskFormException(format("Timeout: '%s' is not a positive whole number of seconds", s));
    }
    return seconds;
}

/**
 * Everything the task editor's form shows beyond the task's id and name, as text and rows the
 * user edits. Built from the task to edit it (`taskEditorForm`), or from what was submitted, so
 * a rejected save shows the user's edits unchanged.
 */
struct TaskEditorForm
{
    TaskInputRow[] inputRows;
    TaskStepRow[] stepRows;
    string outputsText;
    string environmentText;
    string timeoutText;
}

/// The editor form for `task`. Saving it unchanged stores `task` unchanged.
TaskEditorForm taskEditorForm(in TaskNode task) @trusted
{
    TaskEditorForm form;
    form.inputRows = taskInputRows(task.inputs);
    form.stepRows = taskStepRows(task.steps);
    form.outputsText = outputDeclarationsText(task.outputs.artifacts);
    form.environmentText = environmentText(task.environment);
    form.timeoutText = format("%d", task.timeoutSeconds);
    return form;
}

unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm.searching : canFind;

    // Environment: KEY=VALUE lines round-trip, values as typed (spaces, '=' and empty values kept)
    string[string] environment = ["MODE": "release", "FLAGS": "-O2 -g", "EMPTY": "", "URL": "a=b"];
    const text = environmentText(environment);
    assert(text == "EMPTY=\nFLAGS=-O2 -g\nMODE=release\nURL=a=b");
    assert(parseEnvironment(text) == environment);
    assert(parseEnvironment("\n  \nA=1\r\n").length == 1 && parseEnvironment("A=1\r\n")["A"] == "1");
    assert(parseEnvironment("").length == 0);

    auto problems = collectExceptionMsg!TaskFormException(parseEnvironment("NOVALUE\n=x\nA B=1\nA=1\nA=2"));
    foreach (fragment; ["Environment line 1 ('NOVALUE')", "Environment line 2", "Environment line 3",
        "Environment line 5: the variable 'A' is set more than once"])
    {
        assert(problems.canFind(fragment), fragment ~ "\n" ~ problems);
    }
    assert(!problems.canFind("Environment line 4"), problems);

    // Timeout: a positive whole number of seconds, never defaulted
    assert(parseTimeout(" 1200 ") == 1200);
    foreach (bad; ["", "0", "-5", "1.5", "ten", "99999999999999999999999"])
    {
        assert(collectExceptionMsg!TaskFormException(parseTimeout(bad)).canFind("positive whole number"), bad);
    }

    // A task's form holds every field of the task the editor edits
    TaskNode task;
    task.id = "package";
    task.inputs["src"] = repositoryInput("game", "main");
    task.steps = [BuildStep("Fetch", "checkout", Json(["input": Json("src")]))];
    task.outputs.artifacts = [OutputArtifactDecl("game", "out/game.zip")];
    task.environment = ["MODE": "release"];
    task.timeoutSeconds = 3600;
    auto form = taskEditorForm(task);
    assert(form.inputRows == taskInputRows(task.inputs) && form.stepRows == taskStepRows(task.steps));
    assert(form.outputsText == "game: out/game.zip" && form.environmentText == "MODE=release" && form.timeoutText == "3600");
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
    assert(shownRepositoryInputs(rows) == ["src": repositoryInput("game", "main"), "lib": repositoryInput("game", "release")]);

    // Fully blank rows are ignored; removed rows are gone.
    assert(parseTaskInputRows("package", [TaskInputRow("", "value", "", "", "", "", "")], [], []).length == 0);
    assert(parseTaskInputRows("package", rows[0 .. 1], [], ["build-engine"]).length == 1);

    // Form fields zip into rows; mismatched lengths are rejected.
    assert(taskInputRowsFromForm(["a"], ["value"], [""], [""], ["v"], [""], [""]) == [TaskInputRow("a", "value", "", "", "v", "", "")]);
    assertThrown!TaskFormException(taskInputRowsFromForm(["a"], [], [""], [""], ["v"], [""], [""]));

    // An empty ref selector or repository is rejected, not defaulted.
    auto noRef = collectExceptionMsg!TaskFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "game", "  ", "", "", "")], ["game"], []));
    assert(noRef.canFind("src") && noRef.canFind("ref selector"));
    auto noRepo = collectExceptionMsg!TaskFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "", "main", "", "", "")], ["game"], []));
    assert(noRepo.canFind("choose a repository"));
    assert(collectExceptionMsg!TaskFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "gone", "main", "", "", "")], ["game"], [])).canFind("not registered"));

    // Other mistakes, all reported together.
    auto many = collectExceptionMsg!TaskFormException(parseTaskInputRows("t", [
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
}

unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import std.algorithm.searching : canFind;

    InputDecl[string] inputs = [
        "src": repositoryInput("game", "main"),
        "flavor": valueInput("external"),
    ];

    // Round trip: canonical steps survive rendering and saving the form, configs included; a step
    // saved without config comes back with an empty one
    BuildStep[] steps = [
        BuildStep("Fetch", "checkout", Json(["input": Json("src"), "target_dir": Json("game"), "depth": Json(1), "submodules": Json(false)])),
        BuildStep("Compile", "bash", Json(["script": Json("make"), "working_directory": Json("game"), "environment": Json(["MODE": Json("release")])])),
        BuildStep("", "powershell"),
    ];
    auto rows = taskStepRows(steps);
    assert(rows.length == 3 && rows[2].config == "{}");
    auto saved = parseTaskStepRows(rows, inputs);
    assert(saved.length == 3 && saved[0] == steps[0] && saved[1] == steps[1]);
    assert(saved[2].name == "" && saved[2].type == "powershell" && saved[2].config == Json.emptyObject);

    // Form fields zip into rows; mismatched lengths are rejected
    assert(taskStepRowsFromForm(["a"], ["bash"], ["{}"]) == [TaskStepRow("a", "bash", "{}")]);
    assertThrown!TaskFormException(taskStepRowsFromForm(["a"], ["bash"], []));

    // The config is validated on save: it must be a JSON object
    auto invalid = collectExceptionMsg!TaskFormException(parseTaskStepRows([
        TaskStepRow("Broken", "bash", `{"script": `),
        TaskStepRow("Blank", "bash", "  "),
        TaskStepRow("Array", "bash", `["make"]`),
        TaskStepRow("Text", "bash", `"make"`),
    ], inputs));
    assert(invalid.canFind("Step 1 (Broken): the config is not valid JSON"), invalid);
    assert(invalid.canFind("Step 2 (Blank): the config is not valid JSON"), invalid);
    assert(invalid.canFind("Step 3 (Array): the config must be a JSON object"), invalid);
    assert(invalid.canFind("Step 4 (Text): the config must be a JSON object"), invalid);

    // Only the built-in step types are offered and accepted
    auto unknownType = collectExceptionMsg!TaskFormException(parseTaskStepRows([TaskStepRow("Image", "docker:build", "{}")], inputs));
    assert(unknownType.canFind("'docker:build' is not a built-in step type") && unknownType.canFind("confector-z7z.35.1"), unknownType);
    assert(collectExceptionMsg!TaskFormException(parseTaskStepRows([TaskStepRow("", "", "{}")], inputs)).canFind("Step 1 ()"));

    // A checkout step's config may have only its own keys, and must name a declared repository
    // input; every problem is reported, labelled by step
    auto checkout = collectExceptionMsg!TaskFormException(parseTaskStepRows([
        TaskStepRow("Legacy", "checkout", `{"input": "src", "repository": "https://example.test/game.git", "branch": "main"}`),
        TaskStepRow("Nothing", "checkout", `{}`),
        TaskStepRow("Empty", "checkout", `{"input": ""}`),
        TaskStepRow("Number", "checkout", `{"input": 1}`),
        TaskStepRow("Value", "checkout", `{"input": "flavor"}`),
        TaskStepRow("Ghost", "checkout", `{"input": "tools"}`),
    ], inputs));
    assert(checkout.canFind("Step 1 (Legacy): config key 'branch' is not supported"), checkout);
    assert(checkout.canFind("Step 1 (Legacy): config key 'repository' is not supported"), checkout);
    assert(checkout.canFind("input, target_dir, depth, submodules"), checkout);
    assert(checkout.canFind("Step 2 (Nothing): a checkout step's config has no 'input'"), checkout);
    assert(checkout.canFind("Step 3 (Empty): a checkout step's config has no 'input'"), checkout);
    assert(checkout.canFind("Step 4 (Number): 'input' must be a string"), checkout);
    assert(!checkout.canFind("Step 4 (Number): input"), "No declared-input check on an input that is not a string");
    assert(checkout.canFind("Step 5 (Value): input 'flavor' is not a repository input declared on this task"), checkout);
    assert(checkout.canFind("Step 6 (Ghost): input 'tools' is not a repository input"), checkout);

    // Value types are checked on save exactly as the runner checks them
    auto types = collectExceptionMsg!TaskFormException(parseTaskStepRows([
        TaskStepRow("Depth", "checkout", `{"input": "src", "depth": "1"}`),
        TaskStepRow("Submodules", "checkout", `{"input": "src", "submodules": "false"}`),
        TaskStepRow("Target", "checkout", `{"input": "src", "target_dir": ["a"]}`),
    ], inputs));
    assert(types.canFind("Step 1 (Depth): 'depth' must be a positive integer"), types);
    assert(types.canFind("Step 2 (Submodules): 'submodules' must be true or false"), types);
    assert(types.canFind("Step 3 (Target): 'target_dir' must be a string"), types);

    // Other step types' configs belong to their step type and are not checked here
    assert(parseTaskStepRows([TaskStepRow("Compile", "bash", `{"input": "anything", "x": [1, 2]}`)], inputs).length == 1);

    // Issues are aligned with the rows, for the editor to show beside each step
    auto issues = taskStepRowIssues([TaskStepRow("ok", "checkout", `{"input": "src"}`), TaskStepRow("bad", "checkout", `{}`)], inputs);
    assert(issues.length == 2 && issues[0].length == 0 && issues[1].length == 1);
}

unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm.searching : canFind;

    // Output declarations: one id: path per line, both required, ids unique
    auto artifacts = [OutputArtifactDecl("game", "out/game.zip"), OutputArtifactDecl("symbols", "out/sym/*.pdb")];
    const text = outputDeclarationsText(artifacts);
    assert(text == "game: out/game.zip\nsymbols: out/sym/*.pdb");
    assert(parseOutputDeclarations(text) == artifacts);
    assert(parseOutputDeclarations("\n  game :  out/game.zip  \n\n") == artifacts[0 .. 1]);
    assert(parseOutputDeclarations("logs: build/logs:old/*.txt") == [OutputArtifactDecl("logs", "build/logs:old/*.txt")],
        "The id ends at the first colon");
    assert(parseOutputDeclarations("dots: out/..hidden/a..b").length == 1, "Only a whole '..' segment escapes");
    assert(parseOutputDeclarations("").length == 0);

    // A path must stay inside the working directory
    auto escaping = collectExceptionMsg!TaskFormException(parseOutputDeclarations(
        "a: C:\\build\\out.zip\nb: /etc/passwd\nc: \\\\server\\share\\x\nd: ../sibling/out.zip\ne: out/../../x\nf: out\\..\\x\ng: c:out.zip\nok: out/ok.zip"));
    foreach (line; 1 .. 8)
    {
        assert(escaping.canFind(format("Output line %s (", line)), format("line %s: %s", line, escaping));
    }
    assert(escaping.canFind("Output line 1 ('a: C:\\build\\out.zip'): the path must be relative"), escaping);
    assert(!escaping.canFind("Output line 8"), escaping);

    auto problems = collectExceptionMsg!TaskFormException(parseOutputDeclarations("out/game.zip\n: out/x\ngame:\ngame: a\ngame: b"));
    assert(problems.canFind("Output line 1 ('out/game.zip'): write each output as id: path"), problems);
    assert(problems.canFind("Output line 2"), problems);
    assert(problems.canFind("Output line 3"), problems);
    assert(problems.canFind("Output line 5: the id 'game' is used by another output"), problems);
    assert(!problems.canFind("Output line 4"), problems);
}

URLRouter dashboardRouter(StateStores stores)
{
    auto router = new URLRouter();

    // Renders the task editor showing `form`: the task's own fields, or what was submitted when
    // the editor is shown again after a rejected save. `formError` is shown at the top of the
    // editor; steps with problems are flagged in the Steps tab.
    void renderTaskEditor(HTTPServerResponse res, ProjectRecord project, TaskNode task, TaskEditorForm form,
        string formError)
    {
        auto repositories = stores !is null ? stores.repositories.list() : [];
        // Checked against the rows being shown, which may include edits that were not saved.
        string[][] stepIssues = taskStepRowIssues(form.stepRows, shownRepositoryInputs(form.inputRows));
        const stepTypes = builtinStepTypes;
        res.render!("project/task-editor.dt", project, task, repositories, form, stepIssues, stepTypes, formError);
    }

    // Home / Dashboard
    router.get("/", (HTTPServerRequest req, HTTPServerResponse res) {
        auto projects = stores !is null ? stores.projects.list() : [];

        DashboardProjectViewModel[] dashboardProjects;
        ulong totalProjects = projects.length;
        ulong totalTasksAll = 0;

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
                pvm.tasks ~= tvm;
            }

            dashboardProjects ~= pvm;
        }

        res.render!("dashboard/home.dt", dashboardProjects, totalProjects, totalTasksAll);
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

        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-details.dt", project, tasksJson);
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

        renderTaskEditor(res, project, task, taskEditorForm(task), "");
    });

    router.post("/projects/tasks/save", (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("project_id", "");
        ProjectRecord project;
        TaskNode task;
        TaskEditorForm form;
        form.outputsText = req.form.get("output_artifacts", "");
        form.environmentText = req.form.get("environment", "");
        form.timeoutText = req.form.get("timeout_seconds", "");
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

            // Validated here, on the server: the editor's own checks are a convenience. The
            // submitted rows are kept so a rejected save shows the editor with the user's edits,
            // and every problem in every tab is reported at once.
            form.inputRows = taskInputRowsFromForm(
                req.form.getAll("input_name"),
                req.form.getAll("input_kind"),
                req.form.getAll("input_repository"),
                req.form.getAll("input_ref"),
                req.form.getAll("input_value"),
                req.form.getAll("input_task"),
                req.form.getAll("input_artifact")
            );
            form.stepRows = taskStepRowsFromForm(req.form.getAll("step_name"), req.form.getAll("step_type"), req.form.getAll("step_config"));

            string[] problems;
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
            bool inputsValid = true;
            try task.inputs = parseTaskInputRows(task.id, form.inputRows, registeredRepositories, otherTaskIds);
            catch (TaskFormException e)
            {
                problems ~= e.msg;
                inputsValid = false;
            }
            // Checkout steps are checked against the declared inputs, or as far as the rows say
            // when the inputs have problems of their own
            try task.steps = parseTaskStepRows(form.stepRows, inputsValid ? task.inputs : shownRepositoryInputs(form.inputRows));
            catch (TaskFormException e) problems ~= e.msg;
            try task.outputs.artifacts = parseOutputDeclarations(form.outputsText);
            catch (TaskFormException e) problems ~= e.msg;
            try task.environment = parseEnvironment(form.environmentText);
            catch (TaskFormException e) problems ~= e.msg;
            try task.timeoutSeconds = parseTimeout(form.timeoutText);
            catch (TaskFormException e) problems ~= e.msg;
            if (problems.length > 0)
            {
                import std.array : join;

                throw new TaskFormException(problems.join("\n"));
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
        catch (TaskFormException e)
        {
            res.statusCode = HTTPStatus.badRequest;
            renderTaskEditor(res, project, task, form, e.msg);
            return;
        }
        catch (Exception e)
        {
            // Nothing was saved (for example the task graph is cyclic): say so, and keep the edits.
            logError("Failed to save task: %s", e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            renderTaskEditor(res, project, task, form, "Failed to save task: " ~ e.msg);
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

    // Run a project, or a task and its upstream tasks. Not implemented until request intake
    // (see buildsNotImplemented): the request fails loudly.
    router.post("/projects/run", (HTTPServerRequest req, HTTPServerResponse res) {
        throw new HTTPStatusException(HTTPStatus.notImplemented, buildsNotImplemented().msg);
    });

    // Task Details View (Static definition, configuration, steps and dependencies)
    router.get("/tasks/details", (HTTPServerRequest req, HTTPServerResponse res) {
        string projectId = req.query.get("project_id", "");
        if (projectId.length == 0) projectId = req.query.get("project", "");
        string taskId = req.query.get("task_id", "");
        if (taskId.length == 0) taskId = req.query.get("id", "");

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

        res.render!("task/task-details.dt", project, taskNode);
    });

    return router;
}


unittest
{
    import confector.testing.memory_document_store : InMemoryDocumentStore;
    import std.algorithm.searching : canFind;
    import std.uri : encodeComponent;
    import vibe.inet.message : InetHeaderMap;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    auto stores = new StateStores(new InMemoryDocumentStore());
    auto router = dashboardRouter(stores);

    ProjectRecord p;
    p.id = "proj_dash_1";
    p.name = "Dashboard Project";
    TaskNode tNode1;
    tNode1.id = "test_node_1";
    tNode1.steps = [BuildStep("Echo", "bash", Json(["script": Json("echo dashboard test 1")]))];
    tNode1.inputs["repo_main"] = repositoryInput("repo_main", "main");
    TaskNode tNode2;
    tNode2.id = "test_node_2";
    tNode2.inputs["test_node_1"] = taskOutputInput("test_node_1");
    tNode2.steps = [BuildStep("Echo", "bash", Json(["script": Json("echo dashboard test 2")]))];
    p.tasks = [tNode1, tNode2];
    stores.projects.put(p);

    RepositoryRecord rRecord;
    rRecord.name = "repo_main";
    rRecord.address = "https://github.com/example/repo_main.git";
    stores.repositories.put(rRecord);

    // Status and body of a request to the dashboard
    struct Answer { int status; string body; }
    Answer request(HTTPMethod method, string path, string[2][] form = null)
    {
        import std.array : join;

        string[] pairs;
        foreach (field; form) pairs ~= encodeComponent(field[0]) ~ "=" ~ encodeComponent(field[1]);
        InetHeaderMap headers;
        headers["Content-Type"] = "application/x-www-form-urlencoded";
        auto req = createTestHTTPServerRequest(URL("http://localhost" ~ path), method, headers,
            createMemoryStream(cast(ubyte[]) pairs.join("&").dup, false));
        auto sink = createMemoryOutputStream();
        auto res = createTestHTTPServerResponse(sink);
        router.handleRequest(req, res);
        res.finalize();
        return Answer(res.statusCode, cast(string) sink.data.idup);
    }

    // The project, task and editor pages render the canonical model
    auto details = request(HTTPMethod.GET, "/projects/details?id=proj_dash_1");
    assert(details.status == HTTPStatus.ok && details.body.canFind("test_node_2"), details.body);
    auto taskPage = request(HTTPMethod.GET, "/tasks/details?project_id=proj_dash_1&task_id=test_node_1");
    assert(taskPage.status == HTTPStatus.ok && taskPage.body.canFind("echo dashboard test 1"), taskPage.body);
    auto editor = request(HTTPMethod.GET, "/projects/tasks/edit?project_id=proj_dash_1&task_id=test_node_1");
    assert(editor.status == HTTPStatus.ok && editor.body.canFind("echo dashboard test 1"), editor.body);
    assert(!editor.body.canFind("trigger"), "The editor has no triggers tab");

    // The form fields the editor submits for `task` when the user changes nothing
    string[2][] editorFields(in TaskNode task)
    {
        auto form = taskEditorForm(task);
        string[2][] fields = [["project_id", "proj_dash_1"], ["task_id", task.id], ["name", task.name]];
        foreach (row; form.inputRows)
        {
            fields ~= [["input_name", row.name], ["input_kind", row.kind], ["input_repository", row.repository],
                ["input_ref", row.refSelector], ["input_value", row.value], ["input_task", row.task], ["input_artifact", row.artifact]];
        }
        foreach (row; form.stepRows)
        {
            fields ~= [["step_name", row.name], ["step_type", row.type], ["step_config", row.config]];
        }
        fields ~= [["output_artifacts", form.outputsText], ["environment", form.environmentText], ["timeout_seconds", form.timeoutText]];
        return fields;
    }

    TaskNode storedTask(string id)
    {
        foreach (t; stores.projects.get("proj_dash_1").get.tasks) if (t.id == id) return t;
        assert(false, "No task " ~ id);
    }

    // Saving a task from the editor: canonical step rows (name, built-in type, JSON config),
    // named inputs, id: path outputs, the environment and the timeout are stored as the task's
    // definition
    string[2][] checkoutTask = [
        ["project_id", "proj_dash_1"], ["task_id", "package"], ["name", "Package"],
        ["input_name", "src"], ["input_kind", "repository"], ["input_repository", "repo_main"], ["input_ref", "main"],
        ["input_value", ""], ["input_task", ""], ["input_artifact", ""],
        ["input_name", "bin"], ["input_kind", "task_output"], ["input_repository", ""], ["input_ref", ""],
        ["input_value", ""], ["input_task", "test_node_1"], ["input_artifact", ""],
        ["step_name", "Fetch"], ["step_type", "checkout"], ["step_config", `{"input": "src", "target_dir": "game", "depth": 1}`],
        ["step_name", "Zip"], ["step_type", "bash"], ["step_config", `{"script": "zip -r out/game.zip game"}`],
        ["output_artifacts", "game: out/game.zip"],
        ["environment", "MODE=release\nFLAGS=-O2 -g"],
        ["timeout_seconds", "1234"],
    ];
    auto saved = request(HTTPMethod.POST, "/projects/tasks/save", checkoutTask);
    assert(saved.status == HTTPStatus.found, format("HTTP %s: %s", saved.status, saved.body));
    auto stored = storedTask("package");
    assert(stored.name == "Package");
    assert(stored.inputs == ["src": repositoryInput("repo_main", "main"), "bin": taskOutputInput("test_node_1")]);
    assert(stored.steps == [
        BuildStep("Fetch", "checkout", Json(["input": Json("src"), "target_dir": Json("game"), "depth": Json(1)])),
        BuildStep("Zip", "bash", Json(["script": Json("zip -r out/game.zip game")])),
    ]);
    assert(stored.outputs.artifacts == [OutputArtifactDecl("game", "out/game.zip")]);
    assert(stored.environment == ["MODE": "release", "FLAGS": "-O2 -g"] && stored.timeoutSeconds == 1234);

    // The editor shows the saved task again, and saving it unchanged stores it unchanged: its
    // environment, its non-default timeout and its definition hash are kept
    {
        import confector.core.definition_hash : computeDefinitionHash;

        auto reopened = request(HTTPMethod.GET, "/projects/tasks/edit?project_id=proj_dash_1&task_id=package");
        assert(reopened.status == HTTPStatus.ok && reopened.body.canFind("target_dir"), reopened.body);
        assert(reopened.body.canFind(`value="1234"`) && reopened.body.canFind("FLAGS=-O2 -g&#10;MODE=release"), reopened.body);
        auto resaved = request(HTTPMethod.POST, "/projects/tasks/save", editorFields(stored));
        assert(resaved.status == HTTPStatus.found, format("HTTP %s: %s", resaved.status, resaved.body));
        auto again = storedTask("package");
        assert(again == stored, format("%s\n%s", again, stored));
        assert(computeDefinitionHash(again) == computeDefinitionHash(stored));

        // Tasks stored without going through the editor keep their default timeout too
        auto echoForm = editorFields(storedTask("test_node_1"));
        assert(request(HTTPMethod.POST, "/projects/tasks/save", echoForm).status == HTTPStatus.found);
        assert(storedTask("test_node_1") == tNode1);
    }

    // A rejected save stores nothing and shows every problem in the editor, with the edits kept:
    // a checkout config key the step does not support, an undeclared input, a config value of the
    // wrong type, an invalid config, a step without a type, an output without a path, a duplicated
    // variable and a zero timeout
    string[2][] broken = [
        ["project_id", "proj_dash_1"], ["task_id", "package"], ["name", "Package (edited)"],
        ["step_name", "Fetch"], ["step_type", "checkout"], ["step_config", `{"input": "src", "url": "https://example.test/x.git", "depth": "1"}`],
        ["step_name", "Zip"], ["step_type", "bash"], ["step_config", `{"script": `],
        ["step_name", "Typeless"], ["step_type", ""], ["step_config", `{}`],
        ["output_artifacts", "out/game.zip"],
        ["environment", "A=1\nA=2"],
        ["timeout_seconds", "0"],
    ];
    auto rejected = request(HTTPMethod.POST, "/projects/tasks/save", broken);
    assert(rejected.status == HTTPStatus.badRequest, format("HTTP %s", rejected.status));
    foreach (fragment; ["Step 1 (Fetch): config key", "is not supported; a checkout step", "is not a repository input declared",
        "must be a positive integer", "Step 2 (Zip): the config is not valid JSON", "Step 3 (Typeless): step type",
        "write each output as id: path", "Environment line 2", "Timeout:"])
    {
        assert(rejected.body.canFind(fragment), fragment ~ "\n" ~ rejected.body);
    }
    // The edits are shown again as typed: the name, the invalid config text, the empty type
    // (which the editor leaves unselected rather than replacing it with the first type)
    assert(rejected.body.canFind(`value="Package (edited)"`), rejected.body);
    assert(rejected.body.canFind(`"config":"{\"script\": "`), rejected.body);
    assert(rejected.body.canFind(`"type":""`) && rejected.body.canFind(`"name":"Typeless"`), rejected.body);
    assert(rejected.body.canFind(`value="0"`), rejected.body);
    assert(storedTask("package") == stored, "Nothing was saved");

    // Running a project fails loudly until request intake lands
    auto runReq = createTestHTTPServerRequest(URL("http://localhost/projects/run"), HTTPMethod.POST);
    auto runRes = createTestHTTPServerResponse();
    bool notImplemented = false;
    try router.handleRequest(runReq, runRes);
    catch (HTTPStatusException e) notImplemented = e.status == HTTPStatus.notImplemented && e.msg == buildsNotImplemented().msg;
    assert(notImplemented);
}
