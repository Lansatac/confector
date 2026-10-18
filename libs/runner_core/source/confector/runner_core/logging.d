module confector.runner_core.logging;

import std.stdio : stderr;

/**
 * Log helper functions for runner_core without vibe-d dependencies.
 */
void logInfo(Args...)(string fmt, Args args)
{
    stderr.writefln("[INFO] " ~ fmt, args);
}

void logDebug(Args...)(string fmt, Args args)
{
    stderr.writefln("[DEBUG] " ~ fmt, args);
}

void logWarn(Args...)(string fmt, Args args)
{
    stderr.writefln("[WARN] " ~ fmt, args);
}

void logError(Args...)(string fmt, Args args)
{
    stderr.writefln("[ERROR] " ~ fmt, args);
}
