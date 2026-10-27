module confector.runner_core.steps.process;

import confector.runner_core.logging : LogDelegate, logError, logWarn;
import confector.runner_core.steps.step : StepTimeoutException, StopLimits;

import core.sync.event : Event;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.format : format;
import std.string : indexOf, split;

/// How often the supervising thread looks at the process and its output.
private enum Duration pollInterval = 10.msecs;

/// The most output that waits for the supervising thread; a reader that is ahead of it blocks,
/// and the child with it once the pipe is full.
private enum size_t maxPendingOutput = 1 << 20;

/**
 * Runs `args` in `dir` with exactly `env`, sending each line of its output to `log`, and returns
 * its exit code. The process runs in its own containment (a job object on Windows, a process
 * group on POSIX), and everything it started that is still running when it exits is killed, so
 * nothing outlives the call.
 *
 * At `deadline` the process is asked to stop (Ctrl+Break on Windows, SIGTERM on POSIX), given
 * `limits.stopGrace` to do so, and then its whole tree is killed; the call then throws
 * StepTimeoutException. See `postDeadlineBudget` (confector.runner_core.steps.step) for how long
 * that takes at most. Output is read on its own thread, with a bounded backlog, and a slow `log`
 * delays neither the stop nor the kill. It ends the call at most `limits.drainLimit` after the
 * process has gone: a process that escaped the containment and still holds the output open is
 * abandoned with an error in the runner's log.
 *
 * Steps must run every process through this function, so that the task's timeout reaches it.
 *
 * Throws: StepTimeoutException if `deadline` has passed already (nothing is started), or if the
 * process ran past it. Exception if `log` is null, `deadline` was never set or the process
 * cannot be started. Anything `log` throws stops the process and is rethrown.
 */
int runProcess(string[] args, string dir, string[string] env, MonoTime deadline, StopLimits limits, LogDelegate log)
{
    if (args.length == 0) throw new Exception("Cannot run a process without a command");
    if (log is null) throw new Exception(format("Running '%s' needs a log for its output (the log delegate is null)", args[0]));
    if (deadline == MonoTime.init)
    {
        throw new Exception(format("Running '%s' needs the task's deadline, and none was set (StepContext.deadline)", args[0]));
    }
    if (MonoTime.currTime >= deadline)
    {
        throw new StepTimeoutException(format("'%s' was not started: the task's deadline had passed", args[0]));
    }

    auto child = new ChildProcess;
    child.start(args, dir, env);
    auto pump = new OutputPump;
    auto reader = new Thread({
        string failure;
        try
        {
            auto buffer = new ubyte[4096];
            for (;;)
            {
                const count = child.readOutput(buffer);
                if (count == 0) break;
                pump.put(cast(const(char)[]) buffer[0 .. count]);
            }
        }
        catch (Exception e) failure = e.msg;
        pump.finish(failure);
    });
    reader.isDaemon = true;
    reader.start();

    char[] partial;
    // Hands the lines that have arrived to `log` one at a time, and stops delivering at `due`
    // (a slow `log` must not hold up the stop or the kill). True once the output has ended and
    // every line has been delivered.
    bool forward(MonoTime due)
    {
        bool ended = false;
        if (partial.length < maxPendingOutput)
        {
            const(char)[] chunk;
            string failure;
            ended = pump.take(chunk, failure);
            partial ~= chunk;
            if (failure.length > 0) logError("[process] Reading the output of '%s' failed: %s", args[0], failure);
        }
        for (;;)
        {
            const newline = partial.indexOf('\n');
            if (newline < 0) break;
            if (MonoTime.currTime >= due) return false;
            auto line = partial[0 .. newline];
            if (line.length > 0 && line[$ - 1] == '\r') line = line[0 .. $ - 1];
            log(line.idup);
            partial = partial[newline + 1 .. $];
        }
        return ended;
    }

    bool timedOut = false;
    bool abandoned = false;
    int exitCode = -1;
    try
    {
        bool stopRequested = false;
        MonoTime killAt;
        while (!child.exited)
        {
            forward(stopRequested ? killAt : deadline);
            const now = MonoTime.currTime;
            if (!stopRequested && now >= deadline)
            {
                timedOut = true;
                stopRequested = true;
                if (child.requestStop()) killAt = now + limits.stopGrace;
                else
                {
                    // Without a console the startup warning has said so already
                    if (stopCanBeSent) logWarn("[process] Could not ask '%s' to stop (%s); killing it", args[0], child.stopFailure);
                    killAt = now;
                }
            }
            if (stopRequested && now >= killAt) break;
            pump.activity.wait(pollInterval);
        }

        // Total: whatever of the tree is left goes, whether the root stopped or not
        if (!child.killTree()) logError("[process] Could not kill the processes of '%s'", args[0]);
        if (child.waitExit(limits.reapLimit)) exitCode = child.exitCode;
        else logError("[process] '%s' did not exit within %s of being killed", args[0], limits.reapLimit);

        const drainEnd = MonoTime.currTime + limits.drainLimit;
        while (!forward(drainEnd))
        {
            if (MonoTime.currTime >= drainEnd)
            {
                abandoned = true;
                logError("[process] The output of '%s' did not end within %s of its process exiting, or the log was too slow to take it;"
                    ~ " a process that escaped containment may still hold it open. The rest of its output is dropped.", args[0], limits.drainLimit);
                break;
            }
            pump.activity.wait(pollInterval);
        }
        if (!abandoned && partial.length > 0) log(partial.idup);
    }
    catch (Throwable t)
    {
        // Whatever went wrong (the log among it), the process must not be left running
        if (!child.killTree()) logError("[process] Could not kill the processes of '%s' after a failure", args[0]);
        if (!child.waitExit(limits.reapLimit)) logError("[process] '%s' did not exit after a failure", args[0]);
        const drainEnd = MonoTime.currTime + limits.drainLimit;
        while (!pump.ended && MonoTime.currTime < drainEnd) pump.activity.wait(pollInterval);
        throw t;
    }
    finally
    {
        if (pump.ended)
        {
            reader.join();
            child.closeOutput();
        }
        else logError("[process] The output reader for '%s' is still blocked and is abandoned", args[0]);
        child.release();
    }

    if (timedOut)
    {
        throw new StepTimeoutException(format("'%s' ran past the task's deadline; its processes were stopped", args[0]));
    }
    return exitCode;
}

/// Output passed from the reader thread to the supervising thread.
private final class OutputPump
{
    /// Signalled whenever output arrives or ends.
    Event activity;
    /// Signalled whenever the supervising thread has taken output.
    private Event space;

    private char[] pending;
    private bool done;
    private string failure;

    this()
    {
        activity.initialize(false, false);
        space.initialize(false, false);
    }

    /// Adds output, waiting while `maxPendingOutput` is already waiting to be taken.
    void put(const(char)[] chunk)
    {
        for (;;)
        {
            synchronized (this)
            {
                if (pending.length < maxPendingOutput)
                {
                    pending ~= chunk;
                    break;
                }
            }
            space.wait(pollInterval);
        }
        activity.setIfInitialized();
    }

    /// The reader has stopped, with `failure` set if it stopped on an error.
    void finish(string failure)
    {
        synchronized (this)
        {
            this.failure = failure;
            done = true;
        }
        activity.setIfInitialized();
    }

    /// Takes the output that has arrived; true once the output has ended and none is left.
    bool take(out const(char)[] chunk, out string failure)
    {
        bool ended;
        synchronized (this)
        {
            chunk = pending;
            pending = null;
            failure = this.failure;
            this.failure = null;
            ended = done;
        }
        space.setIfInitialized();
        return ended;
    }

    bool ended()
    {
        synchronized (this) return done;
    }
}

/// Whether the platform can ask a process to stop before it is killed.
bool stopCanBeSent()
{
    version (Windows) return consoleAttached;
    else return true;
}

/// Logs once, for the worker's startup, if processes can only be killed and not asked to stop.
void warnIfStopCannotBeSent()
{
    if (!stopCanBeSent)
    {
        logWarn("[process] The runner has no console, so a build process cannot be asked to stop at a timeout; "
            ~ "it is killed at once");
    }
}

version (Windows)
{
    import core.sys.windows.windows;
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array, join;
    import std.process : escapeWindowsArgument;
    import std.utf : toUTF16, toUTF16z;
    import std.windows.syserror : sysErrorString;

    // Not in core.sys.windows
    private enum DWORD jobObjectLimitKillOnJobClose = 0x2000;
    extern (Windows) private DWORD GetConsoleProcessList(LPDWORD, DWORD);

    private bool consoleAttached()
    {
        DWORD process;
        return GetConsoleProcessList(&process, 1) != 0;
    }

    /**
     * A child process on Windows. It is created suspended, put in a job object, and only then
     * resumed, so nothing it starts can be outside the job. The job kills its processes when the
     * last handle to it closes, so they do not outlive a runner that dies. The child leads its
     * own process group so that it alone can be sent Ctrl+Break.
     */
    private final class ChildProcess
    {
        private HANDLE process, job, output;
        private DWORD processId;
        /// Why the last stop request failed.
        string stopFailure;

        void start(string[] args, string dir, string[string] env)
        {
            SECURITY_ATTRIBUTES inheritable = SECURITY_ATTRIBUTES(SECURITY_ATTRIBUTES.sizeof, null, TRUE);
            HANDLE writeEnd;
            if (!CreatePipe(&output, &writeEnd, &inheritable, 0)) throw windowsError("create the output pipe");
            scope (exit) CloseHandle(writeEnd);
            scope (failure) CloseHandle(output);
            // Only the child's end is inheritable
            if (!SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0)) throw windowsError("make the output pipe private");

            HANDLE nul = CreateFileW("NUL"w.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &inheritable, OPEN_EXISTING, 0, null);
            if (nul == INVALID_HANDLE_VALUE) throw windowsError("open standard input");
            scope (exit) CloseHandle(nul);

            job = CreateJobObjectW(null, null);
            if (job is null) throw windowsError("create a job object");
            scope (failure) CloseHandle(job);
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
            limits.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose;
            if (!SetInformationJobObject(job, JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation, &limits, limits.sizeof))
                throw windowsError("limit the job object");

            auto commandLine = (args.map!(arg => escapeWindowsArgument(arg)).join(" ").toUTF16 ~ "\0"w).dup;
            wstring block;
            foreach (entry; env.byKeyValue.map!(pair => pair.key ~ "=" ~ pair.value).array.sort!((a, b) => a < b))
            {
                block ~= entry.toUTF16 ~ "\0"w;
            }
            block ~= "\0"w;
            if (env.length == 0) block ~= "\0"w;

            STARTUPINFOW startup;
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdInput = nul;
            startup.hStdOutput = writeEnd;
            startup.hStdError = writeEnd;
            PROCESS_INFORMATION info;
            if (!CreateProcessW(null, commandLine.ptr, null, null, TRUE,
                    CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT,
                    cast(void*) block.ptr, dir.length > 0 ? toUTF16z(dir) : null, &startup, &info))
            {
                throw windowsError(format("start '%s'", args[0]));
            }
            scope (exit) CloseHandle(info.hThread);
            if (!AssignProcessToJobObject(job, info.hProcess) || ResumeThread(info.hThread) == cast(DWORD) -1)
            {
                auto failure = windowsError("put the new process in its job object");
                TerminateProcess(info.hProcess, 1);
                CloseHandle(info.hProcess);
                throw failure;
            }
            process = info.hProcess;
            processId = info.dwProcessId;
        }

        /// Reads available output; 0 at its end.
        size_t readOutput(ubyte[] buffer)
        {
            for (;;)
            {
                DWORD count;
                if (!ReadFile(output, buffer.ptr, cast(DWORD) buffer.length, &count, null))
                {
                    if (GetLastError() == ERROR_BROKEN_PIPE) return 0;
                    throw windowsError("read the output");
                }
                if (count > 0) return count;
            }
        }

        bool exited()
        {
            const result = WaitForSingleObject(process, 0);
            if (result == WAIT_FAILED) throw windowsError(format("wait for process %d", processId));
            return result == WAIT_OBJECT_0;
        }

        bool waitExit(Duration limit)
        {
            const waitUntil = MonoTime.currTime + limit;
            while (!exited)
            {
                if (MonoTime.currTime >= waitUntil) return false;
                Thread.sleep(pollInterval);
            }
            return true;
        }

        int exitCode()
        {
            DWORD code;
            if (!GetExitCodeProcess(process, &code)) throw windowsError("read the exit code");
            return cast(int) code;
        }

        /// Sends Ctrl+Break to the child's process group. That needs the runner to have a
        /// console, as it has when started from one; false if the event could not be sent.
        bool requestStop()
        {
            if (GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, processId)) return true;
            const code = GetLastError();
            stopFailure = format("Windows error %d: %s", code, sysErrorString(code));
            return false;
        }

        bool killTree()
        {
            return TerminateJobObject(job, 1) != 0;
        }

        void closeOutput()
        {
            CloseHandle(output);
        }

        /// Closes the job, which kills anything still in it, and the process handle.
        void release()
        {
            CloseHandle(job);
            CloseHandle(process);
        }
    }

    private Exception windowsError(string action)
    {
        return new Exception(format("Could not %s: %s", action, sysErrorString(GetLastError())));
    }
}
else version (Posix)
{
    import core.stdc.errno : EINTR, ESRCH, errno;
    import core.sys.posix.signal : SIGKILL, SIGTERM, kill, siginfo_t;
    import core.sys.posix.sys.wait : WEXITED, WNOHANG, WNOWAIT, idtype_t, waitid;
    import core.sys.posix.unistd : read, setsid;
    import std.process : Config, ProcessPipes, Redirect, pipeProcess, wait;
    import std.string : fromStringz;
    import core.stdc.string : strerror;

    /**
     * A child process on POSIX. It is started as the leader of a new session, so its process
     * group (named by its process ID) holds everything it starts, and signalling `-pid` reaches
     * all of it. Its group is killed before the child is reaped, while its ID cannot be reused.
     */
    private final class ChildProcess
    {
        private ProcessPipes pipes;
        private int processId;
        private bool reaped;
        private int status;
        /// Why the last stop request failed.
        string stopFailure;

        void start(string[] args, string dir, string[string] env)
        {
            Config config;
            config.flags = Config.Flags.newEnv;
            config.preExecFunction = () @trusted @nogc nothrow => setsid() != -1;
            pipes = pipeProcess(args, Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout, env, config, dir);
            pipes.stdin.close();
            processId = pipes.pid.processID;
        }

        /// Reads available output; 0 at its end.
        size_t readOutput(ubyte[] buffer)
        {
            for (;;)
            {
                const count = read(pipes.stdout.fileno, buffer.ptr, buffer.length);
                if (count >= 0) return count;
                if (errno != EINTR) throw new Exception(format("Could not read the output: %s", strerror(errno).fromStringz));
            }
        }

        /// Whether the child has exited, without reaping it.
        bool exited()
        {
            if (reaped) return true;
            siginfo_t info;
            info.si_pid = 0;
            if (waitid(idtype_t.P_PID, processId, &info, WEXITED | WNOHANG | WNOWAIT) != 0)
            {
                throw new Exception(format("Could not wait for process %d: %s", processId, strerror(errno).fromStringz));
            }
            return info.si_pid != 0;
        }

        bool waitExit(Duration limit)
        {
            const waitUntil = MonoTime.currTime + limit;
            while (!exited)
            {
                if (MonoTime.currTime >= waitUntil) return false;
                Thread.sleep(pollInterval);
            }
            return true;
        }

        /// The exit code; reaps the child.
        int exitCode()
        {
            if (!reaped)
            {
                status = wait(pipes.pid);
                reaped = true;
            }
            return status;
        }

        bool requestStop()
        {
            if (kill(-processId, SIGTERM) == 0 || errno == ESRCH) return true;
            stopFailure = format("errno %d: %s", errno, strerror(errno).fromStringz);
            return false;
        }

        bool killTree()
        {
            return kill(-processId, SIGKILL) == 0 || errno == ESRCH;
        }

        void closeOutput()
        {
            pipes.stdout.close();
        }

        /// Reaps the child if it has exited and nobody has yet.
        void release()
        {
            if (!reaped && exited) exitCode();
        }
    }
}
else static assert(false, "Running contained processes is not implemented on this platform");

version (unittest)
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse;
    import std.path : absolutePath, buildPath;
    import std.process : environment;
    import confector.testing.processes : backgroundHelperCommand, chattyProcessTree, manyLinesThenSleep, shellArgs, sleepingCommand, waitForStop;

    /// An empty directory for one test, removed again by `cleanup`.
    private string freshDir(string name)
    {
        if (exists(name)) rmdirRecurse(name);
        mkdirRecurse(name);
        return name;
    }

    private void cleanup(string dir)
    {
        if (exists(dir)) rmdirRecurse(dir);
    }

    private StopLimits quickLimits()
    {
        return StopLimits(1.seconds, 5.seconds, 5.seconds);
    }
}

unittest
{
    // A process that runs past the deadline is stopped with the process it started: the call
    // throws, and both processes are gone
    string testDir = freshDir("test_runner_core_process_tree");
    scope(exit) cleanup(testDir);

    // The process writes this file from its own working directory, so the path is absolute
    string pidFile = absolutePath(buildPath(testDir, "pids.txt"));
    bool stopped = false;
    string[] logged;
    const started = MonoTime.currTime;
    try runProcess(chattyProcessTree(pidFile), testDir, environment.toAA, MonoTime.currTime + 6.seconds,
        quickLimits(), (string line) { logged ~= line; });
    catch (StepTimeoutException e) stopped = true;
    assert(stopped, "A process past its deadline is not stopped");
    assert(MonoTime.currTime - started < 60.seconds, "The call did not return promptly");
    assert(exists(pidFile), "The process tree had not started by the deadline; the test needs a longer one");

    auto pids = readText(pidFile).split;
    assert(pids.length == 2, pidFile);
    foreach (pid; pids)
    {
        assert(waitForStop(pid.to!int, 10.seconds), format("Process %s survived its deadline", pid));
    }
}

unittest
{
    // A process within its deadline runs to completion: its output and exit code are returned
    string testDir = freshDir("test_runner_core_process_exit");
    scope(exit) cleanup(testDir);

    string[] logged;
    auto code = runProcess(shellArgs("echo finished & exit 3"), testDir, environment.toAA,
        MonoTime.currTime + 60.seconds, quickLimits(), (string line) { logged ~= line; });
    assert(code == 3, format("Exit code %d", code));
    assert(logged.canFind!(line => line.canFind("finished")), format("Logged %s", logged));

    // A deadline that has passed starts nothing
    bool refused = false;
    try runProcess(shellArgs("echo never > ran.txt"), testDir, environment.toAA, MonoTime.currTime - 1.seconds, quickLimits(), (string line) {});
    catch (StepTimeoutException e) refused = true;
    assert(refused && !exists(buildPath(testDir, "ran.txt")), "A process started after its deadline");

    // A deadline that was never set is an error, not a deadline that has passed
    bool unset = false;
    try runProcess(shellArgs("echo never > ran.txt"), testDir, environment.toAA, MonoTime.init, quickLimits(), (string line) {});
    catch (StepTimeoutException e) assert(false, "An unset deadline is not a timeout");
    catch (Exception e) unset = e.msg.canFind("deadline");
    assert(unset && !exists(buildPath(testDir, "ran.txt")));
}

unittest
{
    // A process the root left behind holds the output open after the root has exited: the call
    // still returns promptly, with the root's output and exit code, and the helper is killed
    string testDir = freshDir("test_runner_core_process_helper");
    scope(exit) cleanup(testDir);

    string[] logged;
    const started = MonoTime.currTime;
    const code = runProcess(shellArgs("echo root done & " ~ backgroundHelperCommand), testDir, environment.toAA,
        MonoTime.currTime + 60.seconds, quickLimits(), (string line) { logged ~= line; });
    assert(code == 0, format("Exit code %d", code));
    assert(MonoTime.currTime - started < 25.seconds, "A helper holding the output kept the call waiting");
    assert(logged.canFind!(line => line.canFind("root done")), format("Logged %s", logged));
}

unittest
{
    // A log that throws stops the process and its tree instead of leaking them
    string testDir = freshDir("test_runner_core_process_log_throws");
    scope(exit) cleanup(testDir);

    string pidFile = absolutePath(buildPath(testDir, "pids.txt"));
    bool rethrown = false;
    try runProcess(chattyProcessTree(pidFile), testDir, environment.toAA, MonoTime.currTime + 120.seconds,
        quickLimits(), (string line) { throw new Exception("log is full"); });
    catch (Exception e) rethrown = e.msg == "log is full";
    assert(rethrown, "The log's exception was not rethrown");

    assert(exists(pidFile));
    foreach (pid; readText(pidFile).split)
    {
        assert(waitForStop(pid.to!int, 10.seconds), format("Process %s was left running", pid));
    }
}

version (Posix)
{
    unittest
    {
        // A process is asked to stop before it is killed: one that handles SIGTERM gets to finish
        string testDir = freshDir("test_runner_core_process_graceful");
        scope(exit) cleanup(testDir);

        string marker = absolutePath(buildPath(testDir, "stopped.txt"));
        bool stopped = false;
        try runProcess(["sh", "-c", format("trap 'echo stopped > %s; exit 0' TERM; echo ready; while true; do sleep 1; done", marker)],
            testDir, environment.toAA, MonoTime.currTime + 3.seconds, StopLimits(10.seconds, 5.seconds, 5.seconds), (string line) {});
        catch (StepTimeoutException e) stopped = true;
        assert(stopped && exists(marker), "The process was killed without being asked to stop");
    }
}

unittest
{
    // The sleeping command is a real process that outlasts a short deadline
    string testDir = freshDir("test_runner_core_process_sleep");
    scope(exit) cleanup(testDir);

    bool stopped = false;
    const started = MonoTime.currTime;
    try runProcess(shellArgs(sleepingCommand), testDir, environment.toAA, MonoTime.currTime + 5.seconds,
        quickLimits(), (string line) {});
    catch (StepTimeoutException e) stopped = true;
    assert(stopped && MonoTime.currTime - started < 25.seconds);
}

unittest
{
    // A log that is slower than the output arrives delays neither the stop nor the kill: the
    // process is stopped near its deadline, not after its backlog has been delivered
    string testDir = freshDir("test_runner_core_process_slow_log");
    scope(exit) cleanup(testDir);

    size_t delivered = 0;
    bool stopped = false;
    const started = MonoTime.currTime;
    try runProcess(manyLinesThenSleep(5000), testDir, environment.toAA, MonoTime.currTime + 4.seconds,
        quickLimits(), (string line) { ++delivered; Thread.sleep(20.msecs); });
    catch (StepTimeoutException e) stopped = true;
    assert(stopped);
    // Delivering all the lines would take 100 s; the budget is the deadline plus the limits
    assert(MonoTime.currTime - started < 25.seconds, "A slow log held up the stop");
    assert(delivered < 5000, "The whole backlog was delivered");
}

unittest
{
    // A reader that gets ahead of the supervising thread waits for it instead of piling up output
    auto pump = new OutputPump;
    auto chunk = new char[maxPendingOutput];
    chunk[] = 'x';
    auto writer = new Thread({
        pump.put(chunk);
        pump.put(chunk);
        pump.finish(null);
    });
    writer.start();
    Thread.sleep(300.msecs);
    assert(!pump.ended, "The reader was not held back by a full backlog");

    const(char)[] taken;
    string failure;
    size_t total = 0;
    while (!pump.take(taken, failure))
    {
        total += taken.length;
        Thread.sleep(10.msecs);
    }
    total += taken.length;
    writer.join();
    assert(total == 2 * maxPendingOutput);
}

version (Windows) version (unittest)
{
    private enum breakChildVariable = "CONFECTOR_TEST_BREAK_CHILD";
    private __gshared char[512] breakMarkerPath;

    extern (Windows) private BOOL onBreak(DWORD type) nothrow @nogc
    {
        if (type != CTRL_BREAK_EVENT) return FALSE;
        HANDLE marker = CreateFileA(breakMarkerPath.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (marker != INVALID_HANDLE_VALUE) CloseHandle(marker);
        ExitProcess(0);
        return TRUE;
    }

    // The test executable doubles as a child that stops on Ctrl+Break: when started with the
    // variable set, it handles the event by creating the file the variable names, and exits
    shared static this()
    {
        import std.process : environment;
        import core.stdc.stdlib : exit;

        const path = environment.get(breakChildVariable);
        if (path is null) return;
        breakMarkerPath[0 .. path.length] = path[];
        breakMarkerPath[path.length] = 0;
        SetConsoleCtrlHandler(&onBreak, TRUE);
        Thread.sleep(60.seconds);
        exit(1);
    }

    unittest
    {
        // A child that honours Ctrl+Break is stopped by the request, long before the grace ends:
        // its handler runs, which a kill would not allow. Without a console no request can be sent
        import std.file : thisExePath;

        string testDir = freshDir("test_runner_core_process_break");
        scope(exit) cleanup(testDir);

        string marker = absolutePath(buildPath(testDir, "stopped.txt"));
        auto env = environment.toAA;
        env[breakChildVariable] = marker;
        bool stopped = false;
        const started = MonoTime.currTime;
        try runProcess([thisExePath], testDir, env, MonoTime.currTime + 8.seconds,
            StopLimits(40.seconds, 5.seconds, 5.seconds), (string line) {});
        catch (StepTimeoutException e) stopped = true;
        assert(stopped);
        assert(MonoTime.currTime - started < 30.seconds, "The child waited out the grace");
        if (stopCanBeSent) assert(exists(marker), "The child was killed instead of being asked to stop");
    }
}
