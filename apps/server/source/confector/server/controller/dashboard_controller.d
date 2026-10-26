module confector.server.controller.dashboard_controller;

import vibe.vibe;
import vibe.core.log : logError;
import confector.core.builtin_steps : builtinStepTypes, checkoutConfigIssues, checkoutStepType;
import confector.api.model;
import confector.core.definition_store : currentDefinition;
import confector.core.document_collection : tryValue;
import confector.core.intake : IntakeException, IntakeFailure, IntakeRequest, RequestIntake, repositoryDefaults;
import confector.core.state_stores : StateStores;
import confector.core.dag;
import confector.server.authenticator : Authenticator;
import confector.server.route_access : AuthorizedRoutes;

import std.algorithm : all, canFind;
import std.ascii : isDigit;
import std.conv : to;
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

// One repository's ref field in the build form
struct BuildFormRow
{
    string repository;
    /// What was entered; empty means the build's own ref for the repository, else the default.
    string ref_;
    /// The ref the repository's inputs default to, shown as a hint; empty when they have none or disagree.
    string defaultRef;

    /// The placeholder of the field.
    string hint() const
    {
        return defaultRef.length > 0 ? defaultRef : "default";
    }
}

// What the project page's build form shows: its fields, the error of a refused build, and the
// number ("#12") of the build just created
struct BuildForm
{
    string error;
    string created;
    string[] targets;
    string chainNumber;
    BuildFormRow[] refs;
    // Set when the build was recorded but not yet reconciled
    string warning;
}

// The build form of `project` before anything is entered: an empty ref field for each repository its
// tasks use, with the ref its inputs default to as a hint
BuildForm buildFormFor(in ProjectRecord project)
{
    BuildForm form;
    foreach (entry; repositoryDefaults(currentDefinition(project))) form.refs ~= BuildFormRow(entry.repositoryId, "", entry.defaultRef);
    return form;
}

// The tasks no other task of `tasks` depends on: building them all builds every task
string[] leafTaskIds(in TaskNode[] tasks)
{
    bool[string] upstream;
    foreach (ref task; tasks)
    {
        foreach (id; upstreamTaskIds(task)) upstream[id] = true;
    }
    string[] leaves;
    foreach (ref task; tasks)
    {
        if (task.id !in upstream) leaves ~= task.id;
    }
    return leaves;
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
    /// A repository input's visibility filter and default ref spec, in their text forms
    /// (`BranchFilter`, `RefSpec`); both optional.
    string branches;
    string defaultRef;
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
        row.branches = decl.spec.branches.toString();
        row.defaultRef = decl.spec.defaultRef.toString();
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
    in string[] names, in string[] kinds, in string[] repositories, in string[] branches, in string[] defaultRefs,
    in string[] values, in string[] tasks, in string[] artifacts
) pure @safe
{
    foreach (fieldLength; [kinds.length, repositories.length, branches.length, defaultRefs.length, values.length, tasks.length,
        artifacts.length])
    {
        if (fieldLength != names.length)
        {
            throw new TaskFormException("The input fields of the form are inconsistent; reload the editor and try again");
        }
    }
    TaskInputRow[] rows;
    foreach (i; 0 .. names.length)
    {
        rows ~= TaskInputRow(names[i], kinds[i], repositories[i], branches[i], defaultRefs[i], values[i], tasks[i], artifacts[i]);
    }
    return rows;
}

/**
 * Validates the editor's input rows and turns them into the task's declared inputs.
 *
 * Rows with no content at all are ignored. Every other row must have a unique name and the
 * fields its kind needs: a repository input must name a registered repository, and its optional
 * branch filter and default ref spec must be well formed (the input does not choose the ref: a
 * trigger or request does); a value input a value; a task output input another task of the
 * project. All problems are reported together, one per line.
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
        const branches = row.branches.strip();
        const defaultRef = row.defaultRef.strip();
        const value = row.value.strip();
        const task = row.task.strip();
        const artifact = row.artifact.strip();

        if (name.length == 0 && repository.length == 0 && branches.length == 0 && defaultRef.length == 0
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
                RefSpec parsedDefault;
                BranchFilter parsedBranches;
                try parsedBranches = BranchFilter.fromString(branches);
                catch (InvalidRefSpecException e) fail(e.msg);
                try parsedDefault = RefSpec.fromString(defaultRef);
                catch (InvalidRefSpecException e) fail(e.msg);
                if (parsedDefault.kind == RefSpecKind.event)
                {
                    fail(format("the default ref spec '%s' cannot be an event spec (only a trigger fires on events); use a ref such as main, or same else main",
                        defaultRef));
                }
                decl = repositoryInput(repository, parsedDefault, parsedBranches);
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
            shown[row.name.strip()] = repositoryInput(row.repository);
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

/**
 * Validates the editor's form and returns `task` with the form's inputs, steps, outputs,
 * environment and timeout. `task` supplies the id and name, which the form does not hold. This is
 * the task editor's whole validation; a project's saved task graph is checked with it too
 * (`validateTaskGraph`), so both accept and refuse the same tasks.
 *
 * Throws: TaskFormException listing every problem.
 */
TaskNode parseTaskForm(TaskNode task, in TaskEditorForm form, in string[] registeredRepositories, in string[] otherTaskIds) @safe
{
    import std.array : join;

    string[] problems;
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
    if (problems.length > 0) throw new TaskFormException(problems.join("\n"));
    return task;
}

/**
 * Parses a project's submitted task graph: a JSON array of task definitions. This checks the
 * structure only; `validateTaskGraph` checks what the tasks say.
 *
 * Throws: TaskFormException if the text is not a JSON array of tasks.
 */
TaskNode[] parseTaskGraphJson(string text) @trusted
{
    Json parsed;
    try parsed = parseJsonString(text);
    catch (Exception e) throw new TaskFormException(format("The task graph is not valid JSON (%s)", e.msg));
    if (parsed.type != Json.Type.array) throw new TaskFormException("The task graph must be a JSON array of tasks");
    try return deserializeJson!(TaskNode[])(parsed);
    catch (Exception e) throw new TaskFormException(format("The task graph does not match the task format (%s)", e.msg));
}

/**
 * Validates a project's task graph with the task editor's rules (`parseTaskForm`): every task
 * needs an id and passes the editor's checks, against the project's other tasks and the registered
 * repositories. The tasks must then form a graph with unique ids and no cycles. Every problem is
 * reported, labelled by task.
 *
 * Throws: TaskFormException listing every problem.
 */
TaskNode[] validateTaskGraph(TaskNode[] tasks, in string[] registeredRepositories) @trusted
{
    import std.array : join;
    import std.string : lineSplitter;

    string[] problems;
    TaskNode[] validated;
    foreach (i, task; tasks)
    {
        if (task.id.length == 0)
        {
            problems ~= format("Task %s needs an id", i + 1);
            continue;
        }
        string[] otherTaskIds;
        foreach (other; tasks)
        {
            if (other.id != task.id) otherTaskIds ~= other.id;
        }
        try validated ~= parseTaskForm(task, taskEditorForm(task), registeredRepositories, otherTaskIds);
        catch (TaskFormException e)
        {
            foreach (line; e.msg.lineSplitter) problems ~= format("Task '%s': %s", task.id, line);
        }
    }
    if (problems.length == 0)
    {
        try new TaskGraph(validated);
        catch (DAGValidationException e) problems ~= e.msg;
    }
    if (problems.length > 0) throw new TaskFormException(problems.join("\n"));
    return validated;
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
    task.inputs["src"] = repositoryInput("game", RefSpec.fromString("same else main"));
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

    // Round trip: declared inputs of every kind survive rendering and saving the form, a
    // repository input's filter and default ref spec included.
    InputDecl[string] existing = [
        "src": repositoryInput("game", RefSpec.fromString("same else main"), BranchFilter.fromString("+:* -:experimental/*")),
        "lib": repositoryInput("game"),
        "flavor": valueInput("external"),
        "eng": taskOutputInput("build-engine", "engine.zip"),
        "setup": taskOutputInput("setup"),
    ];
    auto rows = taskInputRows(existing);
    assert(rows.length == 5 && rows[0].name == "eng");
    assert(rows[4].name == "src" && rows[4].branches == "+:* -:experimental/*" && rows[4].defaultRef == "same else main");
    assert(rows[2].name == "lib" && rows[2].branches == "" && rows[2].defaultRef == "");
    assert(parseTaskInputRows("package", rows, ["game"], ["build-engine", "setup"]) == existing);
    assert(shownRepositoryInputs(rows) == ["src": repositoryInput("game"), "lib": repositoryInput("game")]);

    // Fully blank rows are ignored; removed rows are gone.
    assert(parseTaskInputRows("package", [TaskInputRow("", "value", "", "", "", "", "", "")], [], []).length == 0);
    assert(parseTaskInputRows("package", rows[0 .. 1], [], ["build-engine"]).length == 1);

    // Form fields zip into rows; mismatched lengths are rejected.
    assert(taskInputRowsFromForm(["a"], ["value"], [""], [""], [""], ["v"], [""], [""]) == [TaskInputRow("a", "value", "", "", "", "v", "", "")]);
    assertThrown!TaskFormException(taskInputRowsFromForm(["a"], [], [""], [""], [""], ["v"], [""], [""]));
    assertThrown!TaskFormException(taskInputRowsFromForm(["a"], ["value"], [""], [""], [], ["v"], [""], [""]));

    // A repository input needs no default ref spec or filter: the trigger or request chooses
    // the ref. Spaces are trimmed and the text forms normalized.
    assert(parseTaskInputRows("t", [TaskInputRow("src", "repository", "game", "  ", "", "", "", "")], ["game"], [])
        == ["src": repositoryInput("game")]);
    assert(parseTaskInputRows("t", [TaskInputRow("src", "repository", "game", " +:release/*  ", " same  else  main ", "", "", "")], ["game"], [])
        == ["src": repositoryInput("game", RefSpec.fromString("same else main"), BranchFilter.fromString("+:release/*"))]);

    // A malformed filter or default ref spec is rejected on save, naming the input and the text.
    auto badSpecs = collectExceptionMsg!TaskFormException(parseTaskInputRows("t", [
        TaskInputRow("src", "repository", "game", "release/*", "", "", "", ""),
        TaskInputRow("lib", "repository", "game", "", "same else", "", "", ""),
        TaskInputRow("doc", "repository", "game", "-:experimental/*", "main develop", "", "", ""),
        TaskInputRow("evt", "repository", "game", "", "event +:*", "", "", ""),
    ], ["game"], []));
    foreach (fragment; ["Input 'src': Branch filter 'release/*'", "Input 'lib': Ref spec 'same else'",
        "Input 'evt': the default ref spec 'event +:*' cannot be an event spec",
        "Input 'doc': Branch filter '-:experimental/*'", "Input 'doc': Ref spec 'main develop'"])
    {
        assert(badSpecs.canFind(fragment), fragment ~ "\n" ~ badSpecs);
    }

    // An empty or unknown repository is rejected, not defaulted.
    auto noRepo = collectExceptionMsg!TaskFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "", "", "main", "", "", "")], ["game"], []));
    assert(noRepo.canFind("choose a repository"));
    assert(collectExceptionMsg!TaskFormException(parseTaskInputRows("t",
        [TaskInputRow("src", "repository", "gone", "", "main", "", "", "")], ["game"], [])).canFind("not registered"));

    // Other mistakes, all reported together.
    auto many = collectExceptionMsg!TaskFormException(parseTaskInputRows("t", [
        TaskInputRow("", "value", "", "", "", "x", "", ""),
        TaskInputRow("v", "value", "", "", "", "", "", ""),
        TaskInputRow("o", "task_output", "", "", "", "", "t", ""),
        TaskInputRow("p", "task_output", "", "", "", "", "ghost", ""),
        TaskInputRow("q", "nonsense", "", "", "", "", "", ""),
        TaskInputRow("v", "value", "", "", "", "dup", "", ""),
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
        "src": repositoryInput("game"),
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

unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectExceptionMsg;

    TaskNode engineTask()
    {
        TaskNode task;
        task.id = "engine";
        task.inputs["src"] = repositoryInput("game");
        task.steps = [BuildStep("Fetch", "checkout", Json(["input": Json("src")]))];
        task.outputs.artifacts = [OutputArtifactDecl("engine", "out/engine.zip")];
        task.timeoutSeconds = 600;
        return task;
    }

    TaskNode appTask()
    {
        TaskNode task;
        task.id = "app";
        task.inputs["eng"] = taskOutputInput("engine", "engine");
        task.steps = [BuildStep("Run", "bash", Json(["script": Json("make")]))];
        return task;
    }

    string rejection(TaskNode[] tasks, string[] repositories = ["game"])
    {
        return collectExceptionMsg!TaskFormException(validateTaskGraph(tasks, repositories));
    }

    // A valid graph passes unchanged, and survives its JSON text
    TaskNode[] graph = [engineTask(), appTask()];
    assert(validateTaskGraph(graph, ["game"]) == graph);
    assert(parseTaskGraphJson(serializeToJson(graph).toString()) == graph);

    // The graph text must be a JSON array of tasks
    assert(collectExceptionMsg!TaskFormException(parseTaskGraphJson("[")).canFind("not valid JSON"));
    assert(collectExceptionMsg!TaskFormException(parseTaskGraphJson(`{"id": "app"}`)).canFind("must be a JSON array of tasks"));
    assert(collectExceptionMsg!TaskFormException(parseTaskGraphJson(`[{"name": "no id"}]`)).canFind("does not match the task format"));

    // Each task is checked with the editor's rules: a step type, a step config, an output id, an
    // output path, an upstream task, a repository, a timeout and an environment variable
    TaskNode docker = appTask();
    docker.steps = [BuildStep("Image", "docker:build", Json.emptyObject)];
    assert(rejection([engineTask(), docker]).canFind("Task 'app': Step 1 (Image): step type 'docker:build' is not a built-in step type"));

    TaskNode scalarConfig = appTask();
    scalarConfig.steps = [BuildStep("Run", "bash", Json("make"))];
    assert(rejection([engineTask(), scalarConfig]).canFind("Task 'app': Step 1 (Run): the config must be a JSON object"));

    TaskNode noOutputId = engineTask();
    noOutputId.outputs.artifacts = [OutputArtifactDecl("", "out/engine.zip")];
    assert(rejection([noOutputId, appTask()]).canFind("Task 'engine': Output line 1"));

    TaskNode escapingOutput = engineTask();
    escapingOutput.outputs.artifacts = [OutputArtifactDecl("engine", "../engine.zip")];
    assert(rejection([escapingOutput, appTask()]).canFind("the path must be relative to the working directory"));

    TaskNode unknownUpstream = appTask();
    unknownUpstream.inputs["eng"] = taskOutputInput("ghost", "engine");
    assert(rejection([engineTask(), unknownUpstream]).canFind("Task 'app': Input 'eng': task 'ghost' is not in this project"));

    assert(rejection(graph, ["other"]).canFind("Task 'engine': Input 'src': repository 'game' is not registered"));

    TaskNode zeroTimeout = engineTask();
    zeroTimeout.timeoutSeconds = 0;
    assert(rejection([zeroTimeout, appTask()]).canFind("Task 'engine': Timeout: '0' is not a positive whole number"));

    TaskNode badVariable = engineTask();
    badVariable.environment = ["A B": "1"];
    assert(rejection([badVariable, appTask()]).canFind("Task 'engine': Environment line 1"));

    // Graph-level problems: a missing id, a duplicated id and a cycle
    TaskNode anonymous = appTask();
    anonymous.id = "";
    assert(rejection([engineTask(), anonymous]).canFind("Task 2 needs an id"));
    assert(rejection([engineTask(), engineTask()]).canFind("Duplicate task id defined in graph: 'engine'"));

    TaskNode second = appTask();
    second.id = "second";
    second.inputs["back"] = taskOutputInput("app");
    TaskNode cyclic = engineTask();
    cyclic.inputs["loop"] = taskOutputInput("second");
    assert(rejection([cyclic, second, appTask()]).canFind("Cyclic dependency detected"));

    // Every problem is reported together, labelled by task
    auto both = rejection([noOutputId, docker]);
    assert(both.canFind("Task 'engine': Output line 1") && both.canFind("Task 'app': Step 1 (Image)"), both);
}

/**
 * Creates the routes for the dashboard pages. Viewing a page needs the viewer role; the editor
 * pages and every action that changes a project, task or build need member.
 */
AuthorizedRoutes dashboardRouter(Authenticator authenticator, StateStores stores, RequestIntake intake = null)
{
    auto router = new AuthorizedRoutes(authenticator);

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

    // Renders the project page with `buildForm`: empty fields, or what was entered when a build was
    // refused, or the number of the build just created.
    void renderProjectDetails(HTTPServerResponse res, ProjectRecord project, BuildForm buildForm)
    {
        string tasksJson = serializeToJson(project.tasks).toString();
        res.render!("project/project-details.dt", project, tasksJson, buildForm);
    }

    // Renders the project editor with the task graph text as submitted, or as stored. `formError`
    // is shown at the top when a save was rejected.
    void renderProjectEditor(HTTPServerResponse res, ProjectRecord project, string tasksJson, string formError)
    {
        res.render!("project/project-editor.dt", project, tasksJson, formError);
    }

    // Home / Dashboard
    router.get("/", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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
    router.get("/projects/", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
        auto projects = stores !is null ? stores.projects.list() : [];
        res.render!("project/projects.dt", projects);
    });

    router.get("/projects/add", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        res.render!("project/add-project.dt");
    });

    router.post("/projects/add", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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
            // Nothing was saved: say so rather than redirecting as if the project exists
            logError("Failed to add project: %s", e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            res.writeBody("Failed to add project: " ~ e.msg, "text/plain");
            return;
        }

        res.redirect("/projects/details?id=" ~ projId);
    });

    router.get("/projects/details", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        bool found = stores !is null && stores.projects.get(projId).tryValue(project);
        if (!found)
        {
            project.id = projId;
            project.name = "Unknown Project";
        }

        auto buildForm = buildFormFor(project);
        const created = req.query.get("build", "");
        if (created.length > 0 && created.all!isDigit) buildForm.created = "#" ~ created;
        if (req.query.get("warning", "").length > 0) buildForm.warning = "Reconcile is pending; the sweep will retry it.";
        renderProjectDetails(res, project, buildForm);
    });

    router.get("/projects/edit", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("id", "");
        ProjectRecord project;
        if (stores !is null)
        {
            stores.projects.get(projId).tryValue(project);
        }
        string tasksJson = serializeToJson(project.tasks).toString();
        renderProjectEditor(res, project, tasksJson, "");
    });

    router.post("/projects/save", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.form.get("id", "");
        string tasksJsonText = req.form.get("tasks_json", "");
        ProjectRecord project;
        try
        {
            if (stores !is null && projId.length > 0)
            {
                stores.projects.get(projId).tryValue(project);
            }

            project.id = projId;
            project.name = req.form.get("name", project.name.length > 0 ? project.name : "Project");
            project.description = req.form.get("description", project.description);

            // Checked with the task editor's rules, against the repositories registered now
            string[] registeredRepositories;
            if (stores !is null)
            {
                foreach (r; stores.repositories.list()) registeredRepositories ~= r.name;
            }
            project.tasks = validateTaskGraph(parseTaskGraphJson(tasksJsonText), registeredRepositories);

            project.updatedAt = Clock.currTime.toISOString();
            if (stores !is null)
            {
                stores.projects.put(project);
            }
        }
        catch (TaskFormException e)
        {
            // Nothing was saved: show the problems, with the submitted text kept
            res.statusCode = HTTPStatus.badRequest;
            renderProjectEditor(res, project, tasksJsonText, e.msg);
            return;
        }
        catch (Exception e)
        {
            logError("Failed to save project: %s", e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            renderProjectEditor(res, project, tasksJsonText, "Failed to save project: " ~ e.msg);
            return;
        }

        res.redirect("/projects/details?id=" ~ projId);
    });

    router.post("/projects/delete", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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
            logError("Failed to delete project: %s", e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            res.writeBody("Failed to delete project: " ~ e.msg, "text/plain");
            return;
        }
        res.redirect("/projects/");
    });

    // Task Editor within Project
    router.get("/projects/tasks/add", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        string projId = req.query.get("project_id", "");
        if (projId.length == 0) projId = req.query.get("id", "");
        res.redirect("/projects/tasks/edit?project_id=" ~ projId);
    });

    router.get("/projects/tasks/edit", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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

    router.post("/projects/tasks/save", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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
                req.form.getAll("input_branches"),
                req.form.getAll("input_default"),
                req.form.getAll("input_value"),
                req.form.getAll("input_task"),
                req.form.getAll("input_artifact")
            );
            form.stepRows = taskStepRowsFromForm(req.form.getAll("step_name"), req.form.getAll("step_type"), req.form.getAll("step_config"));

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
            task = parseTaskForm(task, form, registeredRepositories, otherTaskIds);

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

    router.post("/projects/tasks/delete", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
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
            res.statusCode = HTTPStatus.internalServerError;
            res.writeBody("Failed to delete task: " ~ e.msg, "text/plain");
            return;
        }
        res.redirect("/projects/details?id=" ~ projId);
    });

    // Starts a build of the project (`id`) through the same intake as the API: the tasks to build
    // (`target_task_id`, repeated; or `all` for every task), a ref for each repository
    // (`ref_repository` and `ref_name`, repeated in step; an empty name means the build's own ref, else the inputs' defaults) and
    // optionally the number of an existing build (`chain_number`). A refused build shows the project
    // page again with the message and what was entered; a recorded one redirects to the project page,
    // which shows the build's number.
    router.post("/projects/run", Role.member, (HTTPServerRequest req, HTTPServerResponse res) {
        const projectId = req.form.get("id", "");
        ProjectRecord project;
        if (stores is null || !stores.projects.get(projectId).tryValue(project))
        {
            throw new HTTPStatusException(HTTPStatus.notFound, format("Project '%s' does not exist", projectId));
        }
        if (intake is null) throw new HTTPStatusException(HTTPStatus.internalServerError, "Request intake is not configured");

        auto form = buildFormFor(project);
        foreach (target; req.form.getAll("target_task_id")) form.targets ~= target;
        form.chainNumber = req.form.get("chain_number", "").strip;
        const repositories = req.form.getAll("ref_repository");
        const names = req.form.getAll("ref_name");
        HTTPStatus refused = HTTPStatus.ok;
        if (repositories.length != names.length)
        {
            form.error = "The form has a different number of repository fields and ref fields";
            refused = HTTPStatus.badRequest;
        }
        else if (repositories.length > 0)
        {
            // Keep the default hints of the repositories shown, and what was entered for each
            string[string] hints;
            foreach (row; form.refs) hints[row.repository] = row.defaultRef;
            form.refs = null;
            foreach (i; 0 .. repositories.length) form.refs ~= BuildFormRow(repositories[i], names[i].strip, hints.get(repositories[i], ""));
        }
        const buildAll = req.form.get("all", "").length > 0;
        if (buildAll && form.targets.length > 0)
        {
            form.error = "Choose tasks to build, or all of them, not both";
            refused = HTTPStatus.badRequest;
        }

        IntakeRequest request;
        request.projectId = projectId;
        request.targets = buildAll ? leafTaskIds(project.tasks) : form.targets;
        foreach (row; form.refs)
        {
            if (row.ref_.length > 0) request.refs[row.repository] = row.ref_;
        }
        auto caller = authenticator.authenticate(req);
        request.requestedBy = caller.isNull ? "" : caller.get.subject;

        if (refused == HTTPStatus.ok && form.chainNumber.length > 0)
        {
            if (form.chainNumber.all!isDigit && form.chainNumber != "0") request.chainNumber = form.chainNumber.to!ulong;
            else
            {
                form.error = "The build number must be a positive whole number";
                refused = HTTPStatus.badRequest;
            }
        }
        if (refused == HTTPStatus.ok)
        {
            try
            {
                const result = intake.intake(request);
                res.redirect(format("/projects/details?id=%s&build=%s", urlEncode(projectId), result.chainNumber));
                return;
            }
            catch (IntakeException e)
            {
                if (e.failure == IntakeFailure.reconcileFailed)
                {
                    // Recorded: an error page would invite a duplicate request
                    logError("[dashboard] %s", e.msg);
                    res.redirect(format("/projects/details?id=%s&build=%s&warning=1", urlEncode(projectId), e.recorded.chainNumber));
                    return;
                }
                final switch (e.failure)
                {
                    case IntakeFailure.notFound: refused = HTTPStatus.notFound; break;
                    case IntakeFailure.invalid: refused = HTTPStatus.badRequest; break;
                    case IntakeFailure.refused: refused = HTTPStatus.unprocessableEntity; break;
                    case IntakeFailure.conflict: refused = HTTPStatus.conflict; break;
                    case IntakeFailure.reconcileFailed: assert(false, "handled above");
                }
                form.error = e.msg;
            }
        }
        res.statusCode = refused;
        renderProjectDetails(res, project, form);
    });

    // Task Details View (Static definition, configuration, steps and dependencies)
    router.get("/tasks/details", Role.viewer, (HTTPServerRequest req, HTTPServerResponse res) {
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
    import confector.testing.memory_document_store : InterleavingDocumentStore;

    auto documents = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto stores = new StateStores(documents);
    import confector.server.authenticator : FixedAuthenticator, testIdentity;
    auto router = dashboardRouter(new FixedAuthenticator(testIdentity(Role.admin)), stores);

    ProjectRecord p;
    p.id = "proj_dash_1";
    p.name = "Dashboard Project";
    TaskNode tNode1;
    tNode1.id = "test_node_1";
    tNode1.steps = [BuildStep("Echo", "bash", Json(["script": Json("echo dashboard test 1")]))];
    tNode1.inputs["repo_main"] = repositoryInput("repo_main", RefSpec.fromString("main"));
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
    assert(taskPage.body.canFind("repo_main: repo_main (default: main)"), "A repository input shows its default ref spec");
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
                ["input_branches", row.branches], ["input_default", row.defaultRef], ["input_value", row.value], ["input_task", row.task],
                ["input_artifact", row.artifact]];
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
        ["input_name", "src"], ["input_kind", "repository"], ["input_repository", "repo_main"], ["input_branches", "+:* -:experimental/*"],
        ["input_default", "same else main"], ["input_value", ""], ["input_task", ""], ["input_artifact", ""],
        ["input_name", "bin"], ["input_kind", "task_output"], ["input_repository", ""], ["input_branches", ""], ["input_default", ""],
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
    assert(stored.inputs == ["src": repositoryInput("repo_main", RefSpec.fromString("same else main"), BranchFilter.fromString("+:* -:experimental/*")),
        "bin": taskOutputInput("test_node_1")]);
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

    // Saving the project's task graph checks every task with the editor's rules. A valid graph is
    // stored and redirected to; a rejected one stores nothing, reports the problem and keeps the
    // submitted text.
    string[2][] graphFields(string tasksJson)
    {
        return [["id", "proj_dash_1"], ["name", "Dashboard Project"], ["description", ""], ["tasks_json", tasksJson]];
    }

    auto storedProjectTasks = stores.projects.get("proj_dash_1").get.tasks;
    auto graphSaved = request(HTTPMethod.POST, "/projects/save", graphFields(serializeToJson(storedProjectTasks).toString()));
    assert(graphSaved.status == HTTPStatus.found, format("HTTP %s: %s", graphSaved.status, graphSaved.body));
    assert(stores.projects.get("proj_dash_1").get.tasks == storedProjectTasks);

    auto notAnArray = request(HTTPMethod.POST, "/projects/save", graphFields(`{"id": "lone"}`));
    assert(notAnArray.status == HTTPStatus.badRequest && notAnArray.body.canFind("must be a JSON array of tasks"), notAnArray.body);

    auto unknownStep = request(HTTPMethod.POST, "/projects/save",
        graphFields(`[{"id": "lone", "steps": [{"name": "Image", "type": "docker:build"}]}]`));
    assert(unknownStep.status == HTTPStatus.badRequest, format("HTTP %s", unknownStep.status));
    assert(unknownStep.body.canFind("Step 1 (Image)")
        && unknownStep.body.canFind("is not a built-in step type"), unknownStep.body);
    assert(unknownStep.body.canFind("docker:build"), "The submitted text is shown again");

    auto missingOutputId = request(HTTPMethod.POST, "/projects/save",
        graphFields(`[{"id": "lone", "outputs": {"artifacts": [{"id": "", "path": "out/lone.zip"}]}}]`));
    assert(missingOutputId.status == HTTPStatus.badRequest && missingOutputId.body.canFind("write each output as id: path"),
        missingOutputId.body);

    auto invalidJson = request(HTTPMethod.POST, "/projects/save", graphFields("[{"));
    assert(invalidJson.status == HTTPStatus.badRequest && invalidJson.body.canFind("not valid JSON"), invalidJson.body);

    TaskNode loopA;
    loopA.id = "loop_a";
    loopA.inputs["b"] = taskOutputInput("loop_b");
    TaskNode loopB;
    loopB.id = "loop_b";
    loopB.inputs["a"] = taskOutputInput("loop_a");
    auto cyclic = request(HTTPMethod.POST, "/projects/save", graphFields(serializeToJson([loopA, loopB]).toString()));
    assert(cyclic.status == HTTPStatus.badRequest && cyclic.body.canFind("Cyclic dependency detected"), cyclic.body);

    assert(stores.projects.get("proj_dash_1").get.tasks == storedProjectTasks, "Nothing was saved by a rejected graph");
    auto editPage = request(HTTPMethod.GET, "/projects/edit?id=proj_dash_1");
    assert(editPage.status == HTTPStatus.ok && editPage.body.canFind("Edit Project"), editPage.body);

    // A failed write is a server error that names the failure, and nothing is changed
    documents.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failedAdd = request(HTTPMethod.POST, "/projects/add", [["id", "proj_failed"], ["name", "Failed"]]);
    assert(failedAdd.status == HTTPStatus.internalServerError && failedAdd.body.canFind("Failed to add project: store unavailable"),
        failedAdd.body);
    assert(stores.projects.get("proj_failed").isNull, "A project that failed to save does not exist");

    documents.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failedDelete = request(HTTPMethod.POST, "/projects/delete", [["id", "proj_dash_1"]]);
    assert(failedDelete.status == HTTPStatus.internalServerError
        && failedDelete.body.canFind("Failed to delete project: store unavailable"), failedDelete.body);
    assert(!stores.projects.get("proj_dash_1").isNull, "A project that failed to delete still exists");

    documents.beforeNextWrite = () { throw new Exception("store unavailable"); };
    auto failedTaskDelete = request(HTTPMethod.POST, "/projects/tasks/delete",
        [["project_id", "proj_dash_1"], ["task_id", "test_node_1"]]);
    assert(failedTaskDelete.status == HTTPStatus.internalServerError
        && failedTaskDelete.body.canFind("Failed to delete task: store unavailable"), failedTaskDelete.body);
    assert(stores.projects.get("proj_dash_1").get.tasks == storedProjectTasks, "A task that failed to delete is kept");
}

unittest
{
    // The project page's build form: what it shows, what it starts, and how a refused build is shown
    import confector.core.definition_store : currentDefinition;
    import confector.core.intake : RequestIntake;
    import confector.server.authenticator : FixedAuthenticator, testIdentity;
    import confector.testing.fake_repository_resolver : FakeRepositoryResolver;
    import confector.testing.memory_document_store : InMemoryDocumentStore, InterleavingDocumentStore;
    import std.algorithm.searching : canFind;
    import std.uri : encodeComponent;
    import vibe.inet.message : InetHeaderMap;
    import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;

    auto documents = new InterleavingDocumentStore(new InMemoryDocumentStore());
    auto stores = new StateStores(documents);
    RepositoryRecord game;
    game.name = "game";
    game.address = "https://example.test/game.git";
    stores.repositories.put(game);
    TaskNode compile;
    compile.id = "compile";
    compile.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
    compile.steps = [BuildStep("Compile", "bash", Json(["script": Json("make")]))];
    TaskNode test;
    test.id = "test";
    test.inputs["bin"] = taskOutputInput("compile");
    TaskNode lint;
    lint.id = "lint";
    lint.inputs["src"] = repositoryInput("game", RefSpec.fromString("main"));
    ProjectRecord project;
    project.id = "game";
    project.name = "The Game";
    project.tasks = [compile, test, lint];
    stores.projects.put(project);

    auto resolver = new FakeRepositoryResolver();
    resolver.add("game", "main", "aaa111");
    resolver.add("game", "release", "rel111");
    auto intake = new RequestIntake(stores, resolver);

    // Runs `action` just before the `n`th write (1 for the next one) through `store`
    void beforeWrite(InterleavingDocumentStore store, size_t n, void delegate() action)
    {
        store.beforeNextWrite = n == 1 ? action : () { beforeWrite(store, n - 1, action); };
    }

    struct Answer { int status; string body; }
    Answer askAs(AuthorizedRoutes router, HTTPMethod method, string path, string[2][] form = null)
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
    auto router = dashboardRouter(new FixedAuthenticator(testIdentity(Role.member)), stores, intake);
    Answer ask(HTTPMethod method, string path, string[2][] form = null) { return askAs(router, method, path, form); }

    // The form lists the tasks and an empty ref field for each repository, with the default as a hint
    auto page = ask(HTTPMethod.GET, "/projects/details?id=game");
    assert(page.status == HTTPStatus.ok && page.body.canFind(`action="/projects/run"`) && page.body.canFind(`name="target_task_id" value="lint"`), page.body);
    assert(page.body.canFind(`name="ref_repository" value="game"`) && page.body.canFind(`name="ref_name" value=""`) && page.body.canFind(`placeholder="main"`), page.body);
    assert(page.body.canFind(`name="chain_number"`) && !page.body.canFind("build-created") && !page.body.canFind("build-error"));

    // A build starts through intake, and the page redirected to shows its number
    auto started = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["ref_repository", "game"], ["ref_name", "main"], ["chain_number", ""]]);
    assert(started.status == HTTPStatus.found && started.body.canFind("/projects/details?id=game&build=1"), started.body);
    assert(stores.chains.findByNumber("game", 1).get.pins.length == 1);
    const requests = stores.requests.listForProject("game", 10);
    assert(requests.length == 1 && requests[0].targets == ["test"] && requests[0].requestedBy == "test-user");
    assert(ask(HTTPMethod.GET, "/projects/details?id=game&build=1").body.canFind("Created build #1."));

    // Another request on that build, with another ref for the repository; a button that names only a
    // task still works, and `all` builds every task
    auto onBuild = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "compile"], ["ref_repository", "game"], ["ref_name", "release"], ["chain_number", "1"]]);
    assert(onBuild.status == HTTPStatus.found && onBuild.body.canFind("build=1"), onBuild.body);
    assert(stores.chains.findByNumber("game", 1).get.pins.length == 2, "The other ref is another pin of the same build");
    assert(ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "lint"]]).body.canFind("build=2"));
    assert(ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["all", "1"]]).body.canFind("build=3"));
    auto everything = stores.requests.listForChain(stores.chains.findByNumber("game", 3).get.id);
    assert(everything.length == 1 && everything[0].targets == ["test", "lint"], "The tasks nothing depends on");

    // A refused build shows the page again with the message and what was entered
    auto unresolvable = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["target_task_id", "lint"], ["ref_repository", "game"], ["ref_name", "missing"]]);
    assert(unresolvable.status == HTTPStatus.unprocessableEntity && unresolvable.body.canFind("build-error") && unresolvable.body.canFind("game/missing"), unresolvable.body);
    assert(unresolvable.body.canFind(`name="ref_name" value="missing"`) && unresolvable.body.canFind(`placeholder="main"`), "What was entered is kept");
    assert(stores.chains.listForProject("game", 10).length == 3, "A refused build creates no build");
    auto noTarget = ask(HTTPMethod.POST, "/projects/run", [["id", "game"]]);
    assert(noTarget.status == HTTPStatus.badRequest && noTarget.body.canFind("no target"), noTarget.body);
    auto badNumber = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["chain_number", "abc"]]);
    assert(badNumber.status == HTTPStatus.badRequest && badNumber.body.canFind("positive whole number") && badNumber.body.canFind(`value="abc"`), badNumber.body);
    auto noSuchBuild = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["chain_number", "99"]]);
    assert(noSuchBuild.status == HTTPStatus.notFound && noSuchBuild.body.canFind("Build #99"), noSuchBuild.body);

    // Fields that disagree are a 400
    auto mismatched = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["ref_repository", "game"]]);
    assert(mismatched.status == HTTPStatus.badRequest && mismatched.body.canFind("different number"), mismatched.body);
    auto bothWays = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["all", "1"]]);
    assert(bothWays.status == HTTPStatus.badRequest && bothWays.body.canFind("not both"), bothWays.body);

    // A build recorded but not reconciled redirects with a warning, not an error that invites a repeat
    const before = stores.requests.listForProject("game", 100).length;
    beforeWrite(documents, 3, () { throw new Exception("store unavailable"); });
    auto pending = ask(HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"], ["chain_number", "1"]]);
    assert(pending.status == HTTPStatus.found && pending.body.canFind("build=1&warning=1"), pending.body);
    assert(stores.requests.listForProject("game", 100).length == before + 1);
    assert(ask(HTTPMethod.GET, "/projects/details?id=game&build=1&warning=1").body.canFind("build-warning"));

    // An unknown project is a 404, and a viewer may not build
    bool notFound = false;
    try ask(HTTPMethod.POST, "/projects/run", [["id", "nope"], ["target_task_id", "test"]]);
    catch (HTTPStatusException e) notFound = e.status == HTTPStatus.notFound;
    assert(notFound);
    auto viewer = dashboardRouter(new FixedAuthenticator(testIdentity(Role.viewer)), stores, intake);
    assert(askAs(viewer, HTTPMethod.POST, "/projects/run", [["id", "game"], ["target_task_id", "test"]]).status == HTTPStatus.forbidden);
    assert(askAs(viewer, HTTPMethod.GET, "/projects/details?id=game").status == HTTPStatus.ok);
    assert(stores.chains.listForProject("game", 10).length == 3);
}
