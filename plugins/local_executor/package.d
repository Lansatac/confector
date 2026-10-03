module plugins.local_executor;

import std.format;
import std.process;
import std.stdio;
import std.file : exists, mkdirRecurse;
import std.parallelism : totalCPUs;
import std.path : buildPath, isAbsolute;
import std.json : JSONValue, JSONType, parseJSON;
import core.sync.mutex : Mutex;
import core.time : Duration, seconds, msecs, MonoTime;
import core.thread : Thread;

import confector.plugin_api.model;
import confector.plugin_api.plugin : Plugin, PluginContext, NullPluginContext;
import confector.plugin_api.executor : ExecutorProvider, TaskExecutor, ExecutorRecord, ExecutionRequest, ExecutionResult, LogDelegate;

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
        if (m_record.configuration.type == JSONType.object)
        {
            auto pSteps = "allowedStepTypes" in m_record.configuration;
            if (pSteps !is null && pSteps.type == JSONType.array)
            {
                string[] types;
                foreach (step; pSteps.array)
                {
                    if (step.type == JSONType.string)
                    {
                        types ~= step.str;
                    }
                }
                if (types.length > 0)
                {
                    return types;
                }
            }
        }
        return [];
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
        if (effectiveWorkDir.length == 0 && m_record.configuration.type == JSONType.object)
        {
            auto pWork = "workspaceDir" in m_record.configuration;
            if (pWork !is null && pWork.type == JSONType.string && pWork.str.length > 0)
            {
                effectiveWorkDir = pWork.str;
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
            bool processExited = false;
            int exitCode = -1;
            string[] outputLines;
            string errorMessage = "";
            bool timedOut = false;

            this()
            {
                mutex = new Mutex();
            }
        }

        auto state = new ExecState();

        try
        {
            auto pipe = pipeShell(request.command,
                Redirect.stdout | Redirect.stderrToStdout,
                request.environmentVariables.length > 0 ? request.environmentVariables : null,
                Config.retainStderr,
                effectiveWorkDir.length > 0 ? effectiveWorkDir : null);

            auto readerThread = new Thread({
                try
                {
                    foreach (line; pipe.stdout.byLineCopy)
                    {
                        synchronized (state.mutex)
                        {
                            state.outputLines ~= line;
                        }
                        if (logCallback !is null)
                        {
                            logCallback(line);
                        }
                    }

                    auto ec = wait(pipe.pid);
                    synchronized (state.mutex)
                    {
                        state.exitCode = ec;
                        state.processExited = true;
                    }
                }
                catch (Exception e)
                {
                    synchronized (state.mutex)
                    {
                        state.errorMessage = e.msg;
                        state.processExited = true;
                    }
                }
            });
            readerThread.isDaemon = true;
            readerThread.start();

            if (request.timeoutSeconds > 0)
            {
                auto startTime = MonoTime.currTime();
                auto maxDur = seconds(request.timeoutSeconds);

                while (true)
                {
                    synchronized (state.mutex)
                    {
                        if (state.processExited)
                        {
                            break;
                        }
                    }

                    if ((MonoTime.currTime() - startTime) >= maxDur)
                    {
                        synchronized (state.mutex)
                        {
                            state.timedOut = true;
                        }
                        try
                        {
                            kill(pipe.pid);
                        }
                        catch (Exception) {}
                        break;
                    }

                    Thread.sleep(50.msecs);
                }
            }
            else
            {
                while (true)
                {
                    synchronized (state.mutex)
                    {
                        if (state.processExited)
                        {
                            break;
                        }
                    }
                    Thread.sleep(50.msecs);
                }
            }

            synchronized (state.mutex)
            {
                result.outputLines = state.outputLines;
                if (state.timedOut)
                {
                    result.exitCode = -1;
                    result.success = false;
                    result.errorMessage = format("Command timed out after %d seconds.", request.timeoutSeconds);
                    if (logCallback !is null)
                    {
                        logCallback(format("Execution error: %s", result.errorMessage));
                    }
                }
                else if (state.errorMessage.length > 0)
                {
                    result.exitCode = -1;
                    result.success = false;
                    result.errorMessage = state.errorMessage;
                }
                else
                {
                    result.exitCode = state.exitCode;
                    result.success = (state.exitCode == 0);
                    if (!result.success)
                    {
                        result.errorMessage = format("Command exited with code %d", result.exitCode);
                    }
                }
            }
        }
        catch (Exception e)
        {
            result.exitCode = -1;
            result.success = false;
            result.errorMessage = e.msg;
            if (logCallback !is null)
            {
                logCallback(format("Execution error: %s", e.msg));
            }
        }

        return result;
    }
}

/**
 * Built-in LocalExecutor plugin providing local host process execution.
 */
class LocalExecutorPlugin : Plugin, ExecutorProvider
{
    private PluginContext m_context;

    @property string name() const
    {
        return "local-executor-plugin";
    }

    @property string versionString() const
    {
        return "1.0.0";
    }

    @property string description() const
    {
        return "Provides local child process task execution on host system";
    }

    @property string providerType() const
    {
        return "local";
    }

    @property string displayName() const
    {
        return "Local Process Executor";
    }

    @property string[] supportedStepTypes() const
    {
        return ["process", "bash", "powershell", "git"];
    }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (m_context !is null)
        {
            m_context.info("LocalExecutorPlugin initialized");
        }
    }

    void shutdown()
    {
        if (m_context !is null)
        {
            m_context.info("LocalExecutorPlugin shut down");
        }
    }

    JSONValue defaultConfig() const
    {
        JSONValue[string] configMap;
        configMap["maxConcurrency"] = JSONValue(cast(long) totalCPUs);
        configMap["workspaceDir"] = JSONValue(".confector/workspaces");
        configMap["defaultShell"] = JSONValue("powershell");

        JSONValue[] allowedSteps;
        foreach (st; supportedStepTypes)
        {
            allowedSteps ~= JSONValue(st);
        }
        configMap["allowedStepTypes"] = JSONValue(allowedSteps);

        return JSONValue(configMap);
    }

    string[] validateConfig(in JSONValue config) const
    {
        string[] errors;
        if (config.type != JSONType.object)
        {
            errors ~= "Configuration must be a JSON object";
            return errors;
        }

        auto pConcurrency = "maxConcurrency" in config;
        if (pConcurrency !is null)
        {
            if (pConcurrency.type != JSONType.integer && pConcurrency.type != JSONType.uinteger)
            {
                errors ~= "Max Concurrency must be an integer";
            }
            else if (pConcurrency.integer <= 0)
            {
                errors ~= "Max Concurrency must be a positive integer (at least 1)";
            }
        }

        auto pWorkspace = "workspaceDir" in config;
        if (pWorkspace !is null && pWorkspace.type != JSONType.string)
        {
            errors ~= "Workspace Directory must be a string";
        }

        return errors;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;

        int concurrency = cast(int) totalCPUs;
        int hostCores = cast(int) totalCPUs;
        string workspaceDir = ".confector/workspaces";
        string defaultShell = "powershell";
        string allowedStepsStr = "process, bash, powershell, git";

        if (currentConfig.type == JSONType.object)
        {
            auto pC = "maxConcurrency" in currentConfig;
            if (pC !is null && (pC.type == JSONType.integer || pC.type == JSONType.uinteger))
            {
                concurrency = cast(int) pC.integer;
            }

            auto pW = "workspaceDir" in currentConfig;
            if (pW !is null && pW.type == JSONType.string)
            {
                workspaceDir = pW.str;
            }

            auto pS = "defaultShell" in currentConfig;
            if (pS !is null && pS.type == JSONType.string)
            {
                defaultShell = pS.str;
            }

            auto pSteps = "allowedStepTypes" in currentConfig;
            if (pSteps !is null && pSteps.type == JSONType.array)
            {
                string[] sArr;
                foreach (step; pSteps.array)
                {
                    if (step.type == JSONType.string) sArr ~= step.str;
                }
                if (sArr.length > 0)
                {
                    import std.string : join;
                    allowedStepsStr = sArr.join(", ");
                }
            }
        }

        compileHTMLDietFile!("config.dt", concurrency, hostCores, workspaceDir, defaultShell, allowedStepsStr)(html);

        return html.data;
    }

    TaskExecutor createExecutor(in ExecutorRecord record) const
    {
        return new LocalTaskExecutor(record);
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new LocalExecutorPlugin();
}

unittest
{
    auto plugin = new LocalExecutorPlugin();
    plugin.initialize(new NullPluginContext("local-executor-plugin"));
    assert(plugin.name == "local-executor-plugin");
    assert(plugin.providerType == "local");
    assert(plugin.displayName == "Local Process Executor");
    assert(plugin.supportedStepTypes.length >= 4);

    auto defConfig = plugin.defaultConfig();
    assert(defConfig["maxConcurrency"].integer >= 1);
    assert(defConfig["workspaceDir"].str.length > 0);
    assert(defConfig["allowedStepTypes"].array.length > 0);

    // Validation testing
    assert(plugin.validateConfig(defConfig).length == 0);

    JSONValue invalidConf = JSONValue(["maxConcurrency": JSONValue(-2)]);
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
