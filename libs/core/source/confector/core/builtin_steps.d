module confector.core.builtin_steps;

/**
 * The step types built into the runner (AGENTS.md, "Build steps"), shared by the runner, which
 * runs them, and the task editor, which offers them and validates their configs on save. Step
 * programs with their own manifests are bead confector-z7z.35.1.
 */

import confector.plugin_api.document_store : jsonTypeName;
import vibe.data.json : Json;

import std.algorithm.searching : canFind;
import std.format : format;

/// The built-in checkout step: checks out a declared repository input at its pinned revision.
enum string checkoutStepType = "checkout";

/// Every built-in step type, in the order the task editor offers them.
immutable string[] builtinStepTypes = [checkoutStepType, "bash", "powershell"];

/**
 * The keys a checkout step's config may have:
 *
 * - `input` (a string, required): the name of a declared repository input; the step checks out
 *   exactly that input's pinned commit, never a URL, repository or ref.
 * - `target_dir` (a string): directory to check out into, relative to the step's working
 *   directory (default: the working directory itself).
 * - `depth` (a positive integer): fetch depth (default: full history).
 * - `submodules` (`true` or `false`): whether to update submodules recursively (default: true).
 */
immutable string[] checkoutConfigKeys = ["input", "target_dir", "depth", "submodules"];

/// A checkout step's settings, read from a valid config (see `checkoutConfig`).
struct CheckoutConfig
{
    string input;
    /// Empty: the step's working directory.
    string targetDir;
    /// 0: full history.
    uint depth;
    bool submodules = true;
}

/**
 * Problems with a checkout step's `config`, every one of them: it must be a JSON object (an
 * absent config counts as an empty one) with only the keys in `checkoutConfigKeys`, each of
 * its type, and a non-empty `input`. Whether `input` names one of the task's repository inputs
 * is for the caller to check, against declared inputs (the editor) or the work order's resolved
 * ones (the runner). Pure.
 */
string[] checkoutConfigIssues(in Json config) @trusted
{
    import std.algorithm.sorting : sort;

    if (config.type == Json.Type.undefined) return checkoutConfigIssues(Json.emptyObject);
    if (config.type != Json.Type.object)
    {
        return [format("a checkout step's config must be a JSON object, not %s", jsonTypeName(config.type))];
    }

    string[] issues;
    string[] keys;
    foreach (string key, const(Json) value; config.byKeyValue) keys ~= key;
    keys.sort();
    foreach (key; keys)
    {
        if (!checkoutConfigKeys.canFind(key))
        {
            issues ~= format("config key '%s' is not supported; a checkout step names a declared repository input with 'input' and checks out its pinned commit; supported keys: %-(%s, %)",
                key, checkoutConfigKeys);
        }
    }

    auto input = "input" in config;
    if (input is null || (input.type == Json.Type.string && input.get!string.length == 0))
    {
        issues ~= "a checkout step's config has no 'input' naming the repository input to check out";
    }
    else if (input.type != Json.Type.string)
    {
        issues ~= "'input' must be a string naming the repository input to check out";
    }
    if (auto targetDir = "target_dir" in config)
    {
        if (targetDir.type != Json.Type.string) issues ~= "'target_dir' must be a string";
    }
    if (auto depth = "depth" in config)
    {
        if (depth.type != Json.Type.int_ || depth.get!long < 1 || depth.get!long > uint.max)
        {
            issues ~= format("'depth' must be a positive integer, not %s", depth.toString());
        }
    }
    if (auto submodules = "submodules" in config)
    {
        if (submodules.type != Json.Type.bool_)
        {
            issues ~= format("'submodules' must be true or false, not %s", submodules.toString());
        }
    }
    return issues;
}

/**
 * The settings of a checkout step's `config`. Pure.
 *
 * Throws: Exception listing the problems if `checkoutConfigIssues` finds any.
 */
CheckoutConfig checkoutConfig(in Json config) @trusted
{
    const issues = checkoutConfigIssues(config);
    if (issues.length > 0) throw new Exception(format("Invalid checkout step config: %-(%s; %)", issues));
    CheckoutConfig result;
    if (config.type == Json.Type.undefined) return result;
    result.input = config["input"].get!string;
    if (auto targetDir = "target_dir" in config) result.targetDir = targetDir.get!string;
    if (auto depth = "depth" in config) result.depth = cast(uint) depth.get!long;
    if (auto submodules = "submodules" in config) result.submodules = submodules.get!bool;
    return result;
}

unittest
{
    bool hasIssue(Json config, string fragment)
    {
        foreach (issue; checkoutConfigIssues(config)) if (issue.canFind(fragment)) return true;
        return false;
    }

    // A full config reads back its settings; a minimal one gets the defaults
    auto full = Json(["input": Json("src"), "target_dir": Json("game"), "depth": Json(1), "submodules": Json(false)]);
    assert(checkoutConfigIssues(full).length == 0);
    assert(checkoutConfig(full) == CheckoutConfig("src", "game", 1, false));
    assert(checkoutConfig(Json(["input": Json("src")])) == CheckoutConfig("src", "", 0, true));
    assert(checkoutConfig(Json(["input": Json("src"), "depth": Json(cast(long) uint.max)])).depth == uint.max);

    // Every problem is found: shape, keys, a missing input, and each value's type
    assert(hasIssue(Json("src"), "must be a JSON object, not a string") && checkoutConfigIssues(Json("src")).length == 1);
    assert(hasIssue(Json([Json("src")]), "must be a JSON object, not an array"));
    assert(hasIssue(Json.undefined, "no 'input'"), "An absent config is an empty one");
    assert(hasIssue(Json.emptyObject, "no 'input'"));
    assert(hasIssue(Json(["input": Json("")]), "no 'input'"));
    assert(hasIssue(Json(["input": Json(1)]), "'input' must be a string"));
    auto legacy = Json(["input": Json("src"), "url": Json("https://example.test/x.git"), "branch": Json("main")]);
    assert(hasIssue(legacy, "config key 'branch' is not supported") && hasIssue(legacy, "config key 'url' is not supported"));
    assert(hasIssue(legacy, "input, target_dir, depth, submodules"));
    assert(hasIssue(Json(["input": Json("src"), "target_dir": Json(3)]), "'target_dir' must be a string"));
    foreach (depth; [Json(0), Json(-1), Json(1.5), Json("1"), Json(5_000_000_000L), Json(true)])
    {
        assert(hasIssue(Json(["input": Json("src"), "depth": depth]), "'depth' must be a positive integer"), depth.toString());
    }
    foreach (submodules; [Json("false"), Json("maybe"), Json(0)])
    {
        assert(hasIssue(Json(["input": Json("src"), "submodules": submodules]), "'submodules' must be true or false"), submodules.toString());
    }
    auto many = Json(["input": Json(2), "depth": Json("1"), "submodules": Json("false"), "extra": Json(1)]);
    assert(checkoutConfigIssues(many).length == 4);

    // Reading an invalid config fails loudly, listing its problems
    bool threw = false;
    try checkoutConfig(many);
    catch (Exception e) threw = e.msg.canFind("'depth'") && e.msg.canFind("'submodules'");
    assert(threw);
}
