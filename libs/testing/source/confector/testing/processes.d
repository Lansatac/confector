module confector.testing.processes;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.algorithm.searching : canFind;
import std.format : format;
import std.process : execute;

/// The argument list that runs `command` through the platform shell, for a test step.
string[] shellArgs(string command)
{
    version (Windows) return ["cmd", "/c", command];
    else return ["sh", "-c", command];
}

/// A command that runs for longer than any test waits, so a test can stop it. On Windows it is
/// PowerShell under cmd, which does not end on the Ctrl+Break a stop request sends, so a test that
/// stops it waits out the stop grace unless it passes a short one.
version (Windows) enum sleepingCommand = "powershell -NoProfile -Command Start-Sleep -Seconds 30";
else enum sleepingCommand = "sleep 30";

/// A command that prints `count` lines and then sleeps for longer than any test waits.
string[] manyLinesThenSleep(size_t count)
{
    version (Windows) return ["powershell", "-NoProfile", "-Command", format("1..%d | ForEach-Object { 'line' + $_ }; Start-Sleep -Seconds 120", count)];
    else return ["sh", "-c", format("i=0; while [ $i -lt %d ]; do echo line$i; i=$((i+1)); done; sleep 120", count)];
}

/// A shell command that starts a long-running helper that shares the shell's output, and returns
/// at once. The helper holds the output open after the shell has exited.
version (Windows) enum backgroundHelperCommand = "start /b ping -n 30 127.0.0.1";
else enum backgroundHelperCommand = "sleep 30 &";

/**
 * A command that starts a child process and then sleeps, both for longer than a test waits. Once
 * both are running it writes "<root pid> <child pid>" to `pidFile`, and then prints "started".
 */
string[] chattyProcessTree(string pidFile)
{
    version (Windows)
    {
        return ["powershell", "-NoProfile", "-Command", format(
            "$child = Start-Process -PassThru -WindowStyle Hidden powershell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120'; " ~
            "[IO.File]::WriteAllText('%s', [string]$PID + ' ' + [string]$child.Id); 'started'; Start-Sleep -Seconds 120", pidFile)];
    }
    else
    {
        return ["sh", "-c", format("sleep 120 & echo $$ $! > '%s'; echo started; wait", pidFile)];
    }
}

/// Whether a process with `pid` is running.
bool processRunning(int pid)
{
    version (Windows)
        return execute(["tasklist", "/FI", format("PID eq %d", pid), "/FO", "CSV", "/NH"]).output.canFind(format("\"%d\"", pid));
    else
        return execute(["ps", "-p", format("%d", pid)]).status == 0;
}

/// Waits up to `timeout` for the process `pid` to stop; true once it has.
bool waitForStop(int pid, Duration timeout)
{
    const deadline = MonoTime.currTime + timeout;
    while (processRunning(pid))
    {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(100.msecs);
    }
    return true;
}
