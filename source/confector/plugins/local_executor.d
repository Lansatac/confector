module confector.plugins.local_executor;

import std.format;
import std.process;
import std.stdio;
import std.file : exists, mkdirRecurse;
import std.parallelism : totalCPUs;
import std.path : buildPath, isAbsolute;
import core.sync.mutex : Mutex;
import core.time : Duration, seconds, msecs, MonoTime;
import core.thread : Thread;

import vibe.data.json : Json;
import vibe.core.log;
import vibe.core.sync : TaskCondition;

import confector.core.model;
import confector.core.plugin : Plugin;
import confector.core.executor : ExecutorProvider, TaskExecutor, ExecutorRecord, ExecutionRequest, ExecutionResult, LogDelegate;

/**
 * Concrete TaskExecutor executing commands locally on host infrastructure.
 */
class LocalTaskExecutor : TaskExecutor
{
    private ExecutorRecord m_record;

    this(in ExecutorRecord record)
    {
        m_record = cast()record;
    }

    @property string id() const
    {
        return m_record.id;
    }

    @property string providerType() const
    {
        return m_record.providerType;
    }

    @property bool isEnabled() const
    {
        return m_record.enabled;
    }

    @property string[] supportedStepTypes() const
    {
        if (m_record.configuration.type == Json.Type.object)
        {
            auto pSteps = "allowedStepTypes" in m_record.configuration;
            if (pSteps !is null && pSteps.type == Json.Type.array)
            {
                string[] types;
                foreach (step; *pSteps)
                {
                    if (step.type == Json.Type.string)
                    {
                        types ~= step.get!string;
                    }
                }
                if (types.length > 0)
                {
                    return types;
                }
            }
        }
        return ["process", "bash", "powershell", "git"];
    }

    ExecutionResult execute(in ExecutionRequest request, LogDelegate logCallback = null)
    {
        ExecutionResult result;

        if (!m_record.enabled)
        {
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = format("Executor '%s' is disabled. Enable it in the Executors dashboard to run tasks.", m_record.name.length > 0 ? m_record.name : m_record.id);
            if (logCallback !is null)
            {
                logCallback(format("Execution error: %s", result.errorMessage));
            }
            return result;
        }

        string effectiveWorkDir = request.workingDirectory;
        if (effectiveWorkDir.length == 0 && m_record.configuration.type == Json.Type.object)
        {
            auto pWork = "workspaceDir" in m_record.configuration;
            if (pWork !is null && pWork.type == Json.Type.string && pWork.get!string.length > 0)
            {
                effectiveWorkDir = pWork.get!string;
            }
        }

        if (effectiveWorkDir.length > 0 && !exists(effectiveWorkDir))
        {
            try
            {
                mkdirRecurse(effectiveWorkDir);
            }
            catch (Exception e)
            {
            }
        }

        static class ExecState
        {
            Mutex mutex;
            TaskCondition condition;
            string[] pendingLines;
            bool finished;
            int exitCode = -1;
            bool success;
            string errorMessage;
            Pid processPid;

            this()
            {
                mutex = new Mutex();
                condition = new TaskCondition(mutex);
            }
        }

        auto state = new ExecState();
        string cmd = request.command;
        string[string] envVars = request.environmentVariables.length > 0 ? cast(string[string])request.environmentVariables.dup : null;
        string workDir = effectiveWorkDir.length > 0 ? effectiveWorkDir : null;

        auto worker = new Thread({
            try
            {
                auto pipe = pipeShell(cmd,
                    Redirect.stdout | Redirect.stderrToStdout,
                    envVars,
                    Config.retainStderr,
                    workDir);

                synchronized (state.mutex)
                {
                    state.processPid = pipe.pid;
                }

                foreach (line; pipe.stdout.byLineCopy)
                {
                    synchronized (state.mutex)
                    {
                        state.pendingLines ~= line.idup;
                        state.condition.notifyAll();
                    }
                }

                int code = wait(pipe.pid);
                synchronized (state.mutex)
                {
                    state.exitCode = code;
                    state.success = (code == 0);
                    if (!state.success)
                    {
                        state.errorMessage = format("Process exited with code %d", code);
                    }
                    state.finished = true;
                    state.condition.notifyAll();
                }
            }
            catch (Exception e)
            {
                synchronized (state.mutex)
                {
                    state.exitCode = -1;
                    state.success = false;
                    state.errorMessage = e.msg;
                    state.finished = true;
                    state.condition.notifyAll();
                }
            }
        });
        worker.isDaemon = true;
        worker.start();

        auto startTime = MonoTime.currTime;
        Duration timeout = request.timeoutSeconds > 0 ? request.timeoutSeconds.seconds : Duration.max;

        while (true)
        {
            string[] linesToProcess;
            bool isFinished;

            synchronized (state.mutex)
            {
                if (state.pendingLines.length > 0)
                {
                    linesToProcess = state.pendingLines;
                    state.pendingLines = null;
                }
                isFinished = state.finished;

                if (!isFinished && linesToProcess.length == 0)
                {
                    if (timeout != Duration.max)
                    {
                        auto elapsed = MonoTime.currTime - startTime;
                        if (elapsed >= timeout)
                        {
                            // Timed out
                            if (state.processPid !is null)
                            {
                                try { kill(state.processPid); } catch (Exception) {}
                            }
                            state.finished = true;
                            state.exitCode = -1;
                            state.success = false;
                            state.errorMessage = format("Execution timed out after %d seconds", request.timeoutSeconds);
                            isFinished = true;
                        }
                        else
                        {
                            auto remaining = timeout - elapsed;
                            state.condition.wait(remaining > 100.msecs ? 100.msecs : remaining);
                        }
                    }
                    else
                    {
                        state.condition.wait();
                    }

                    if (state.pendingLines.length > 0)
                    {
                        linesToProcess = state.pendingLines;
                        state.pendingLines = null;
                    }
                    isFinished = state.finished;
                }
            }

            foreach (line; linesToProcess)
            {
                result.outputLines ~= line;
                if (logCallback !is null)
                {
                    logCallback(line);
                }
            }

            if (isFinished && linesToProcess.length == 0)
            {
                break;
            }
        }

        synchronized (state.mutex)
        {
            result.exitCode = state.exitCode;
            result.success = state.success;
            result.errorMessage = state.errorMessage;
        }

        if (!result.success && result.errorMessage.length > 0 && logCallback !is null && result.outputLines.length == 0)
        {
            logCallback(format("Execution error: %s", result.errorMessage));
        }

        return result;
    }
}

/**
 * Local process executor plugin.
 * Exposes host OS execution capabilities with sub-template UI configuration rendering.
 */
class LocalExecutorPlugin : Plugin, ExecutorProvider
{
    @property string name() const { return "local-executor-plugin"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Local process executor provider running build tasks on host infrastructure"; }
    @property string providerType() const { return "local"; }
    @property string displayName() const { return "Local Process Executor"; }
    @property string[] supportedStepTypes() const { return ["process", "bash", "powershell", "git"]; }

    void initialize() {}
    void shutdown() {}

    Json defaultConfig() const
    {
        Json conf = Json.emptyObject;
        conf["maxConcurrency"] = cast(int) totalCPUs;
        conf["workspaceDir"] = ".confector/workspaces";

        version(Windows)
        {
            conf["defaultShell"] = "powershell";
        }
        else
        {
            conf["defaultShell"] = "sh";
        }

        Json steps = Json.emptyArray;
        foreach (s; supportedStepTypes)
        {
            steps ~= Json(s);
        }
        conf["allowedStepTypes"] = steps;

        return conf;
    }

    string[] validateConfig(in Json config) const
    {
        string[] errors;
        if (config.type != Json.Type.object)
        {
            errors ~= "Configuration must be a JSON object";
            return errors;
        }

        auto pConcurrency = "maxConcurrency" in config;
        if (pConcurrency !is null)
        {
            if (pConcurrency.type != Json.Type.int_ && pConcurrency.type != Json.Type.bigInt)
            {
                errors ~= "Max Concurrency must be an integer";
            }
            else if (pConcurrency.get!int <= 0)
            {
                errors ~= "Max Concurrency must be a positive integer (at least 1)";
            }
        }

        auto pWorkspace = "workspaceDir" in config;
        if (pWorkspace !is null && pWorkspace.type != Json.Type.string)
        {
            errors ~= "Workspace Directory must be a string";
        }

        return errors;
    }

    string renderConfigFormHtml(in Json currentConfig) const
    {
        import std.array : appender;
        import std.conv : to;

        auto html = appender!string;

        int concurrency = cast(int) totalCPUs;
        string workspaceDir = ".confector/workspaces";
        string defaultShell = "powershell";
        string allowedStepsStr = "process, bash, powershell, git";

        if (currentConfig.type == Json.Type.object)
        {
            auto pC = "maxConcurrency" in currentConfig;
            if (pC !is null && (pC.type == Json.Type.int_ || pC.type == Json.Type.bigInt))
            {
                concurrency = pC.get!int;
            }

            auto pW = "workspaceDir" in currentConfig;
            if (pW !is null && pW.type == Json.Type.string)
            {
                workspaceDir = pW.get!string;
            }

            auto pS = "defaultShell" in currentConfig;
            if (pS !is null && pS.type == Json.Type.string)
            {
                defaultShell = pS.get!string;
            }

            auto pSteps = "allowedStepTypes" in currentConfig;
            if (pSteps !is null && pSteps.type == Json.Type.array)
            {
                string[] sArr;
                foreach (step; *pSteps)
                {
                    if (step.type == Json.Type.string) sArr ~= step.get!string;
                }
                if (sArr.length > 0)
                {
                    import std.string : join;
                    allowedStepsStr = sArr.join(", ");
                }
            }
        }

        html.put("<div class=\"executor-config-subform\">\n");
        html.put("  <div class=\"form-group\">\n");
        html.put("    <label for=\"config_maxConcurrency\">Max Concurrency (Worker Threads)</label>\n");
        html.put(format("    <input type=\"number\" id=\"config_maxConcurrency\" name=\"config_maxConcurrency\" min=\"1\" max=\"128\" value=\"%d\" class=\"form-control\" required />\n", concurrency));
        html.put(format("    <small class=\"form-help-text\">Maximum parallel build tasks permitted on this host (Host CPU cores detected: %d).</small>\n", totalCPUs));
        html.put("  </div>\n\n");

        html.put("  <div class=\"form-group\">\n");
        html.put("    <label for=\"config_workspaceDir\">Working Directory / Workspace Base</label>\n");
        html.put(format("    <input type=\"text\" id=\"config_workspaceDir\" name=\"config_workspaceDir\" value=\"%s\" class=\"form-control\" required />\n", workspaceDir));
        html.put("    <small class=\"form-help-text\">Local directory path where repositories and task workspaces are provisioned.</small>\n");
        html.put("  </div>\n\n");

        html.put("  <div class=\"form-group\">\n");
        html.put("    <label for=\"config_defaultShell\">Default Shell</label>\n");
        html.put("    <select id=\"config_defaultShell\" name=\"config_defaultShell\" class=\"form-control\">\n");
        html.put(format("      <option value=\"powershell\"%s>PowerShell</option>\n", defaultShell == "powershell" ? " selected" : ""));
        html.put(format("      <option value=\"bash\"%s>Bash</option>\n", defaultShell == "bash" ? " selected" : ""));
        html.put(format("      <option value=\"sh\"%s>POSIX Shell (sh)</option>\n", defaultShell == "sh" ? " selected" : ""));
        html.put(format("      <option value=\"cmd\"%s>Windows Command Prompt (cmd.exe)</option>\n", defaultShell == "cmd" ? " selected" : ""));
        html.put("    </select>\n");
        html.put("    <small class=\"form-help-text\">Primary shell invoked for generic script and command build steps.</small>\n");
        html.put("  </div>\n\n");

        html.put("  <div class=\"form-group\">\n");
        html.put("    <label for=\"config_allowedStepTypes\">Allowed Step Types (comma-separated)</label>\n");
        html.put(format("    <input type=\"text\" id=\"config_allowedStepTypes\" name=\"config_allowedStepTypes\" value=\"%s\" class=\"form-control\" />\n", allowedStepsStr));
        html.put("    <small class=\"form-help-text\">Supported build step types (e.g. process, bash, powershell, git).</small>\n");
        html.put("  </div>\n");
        html.put("</div>\n");

        return html.data;
    }

    TaskExecutor createExecutor(in ExecutorRecord record) const
    {
        return new LocalTaskExecutor(record);
    }
}

unittest
{
    auto plugin = new LocalExecutorPlugin();
    assert(plugin.name == "local-executor-plugin");
    assert(plugin.providerType == "local");
    assert(plugin.displayName == "Local Process Executor");
    assert(plugin.supportedStepTypes.length >= 4);

    auto defConfig = plugin.defaultConfig();
    assert(defConfig["maxConcurrency"].get!int >= 1);
    assert(defConfig["workspaceDir"].get!string.length > 0);
    assert(defConfig["allowedStepTypes"].get!(Json[]).length > 0);

    // Validation testing
    assert(plugin.validateConfig(defConfig).length == 0);

    Json invalidConf = Json.emptyObject;
    invalidConf["maxConcurrency"] = -2;
    auto errors = plugin.validateConfig(invalidConf);
    assert(errors.length > 0);

    // HTML sub-template generation testing
    string formHtml = plugin.renderConfigFormHtml(defConfig);
    assert(formHtml.length > 0);
    import std.algorithm : canFind;
    assert(formHtml.canFind("config_maxConcurrency"));
    assert(formHtml.canFind("config_workspaceDir"));
    assert(formHtml.canFind("config_defaultShell"));

    // Executor creation & execution testing
    ExecutorRecord record;
    record.id = "exec-test-1";
    record.name = "Local Test Runner";
    record.providerType = "local";
    record.enabled = false;
    record.configuration = defConfig;

    auto executor = plugin.createExecutor(record);
    assert(executor.id == "exec-test-1");
    assert(executor.providerType == "local");
    assert(!executor.isEnabled);

    ExecutionRequest req;
    req.command = "echo local_test_exec";

    // Disabled executor rejects execution
    auto resDisabled = executor.execute(req);
    assert(!resDisabled.success);
    assert(resDisabled.exitCode != 0);

    // Enabled executor executes successfully
    record.enabled = true;
    auto enabledExecutor = plugin.createExecutor(record);
    assert(enabledExecutor.isEnabled);

    string[] loggedLines;
    auto resEnabled = enabledExecutor.execute(req, (line) {
        loggedLines ~= line;
    });
    assert(resEnabled.success);
    assert(resEnabled.exitCode == 0);
    assert(resEnabled.outputLines.length > 0);
    assert(loggedLines.length > 0);

    // Timeout testing
    ExecutionRequest timeoutReq;
    version(Windows)
    {
        timeoutReq.command = "powershell -Command \"Start-Sleep -Seconds 5\"";
    }
    else
    {
        timeoutReq.command = "sleep 5";
    }
    timeoutReq.timeoutSeconds = 1;
    auto resTimeout = enabledExecutor.execute(timeoutReq);
    assert(!resTimeout.success);
    assert(resTimeout.exitCode != 0);
    import std.algorithm : canFind;
    assert(resTimeout.errorMessage.canFind("timed out"));
}
