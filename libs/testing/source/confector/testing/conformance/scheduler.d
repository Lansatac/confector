module confector.testing.conformance.scheduler;

/**
 * Conformance suite for Scheduler backends (design record: bead confector-z7z.4). Every backend
 * must pass it. It only stores and lists entries, far in the future, so nothing fires:
 *
 *     checkScheduler(new LocalScheduler("secret", "http://127.0.0.1:8080"));
 *
 * Pass a new scheduler with no entries; the suite leaves it empty.
 */

import confector.plugin_api.scheduler;
import core.time : days;
import std.datetime : Clock;
import std.exception : collectException;
import std.format : format;

/// A backend broke the Scheduler contract.
class SchedulerConformanceException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

private void require(bool condition, lazy string message, string file = __FILE__, size_t line = __LINE__)
{
    if (!condition)
        throw new SchedulerConformanceException(message, file, line);
}

private ScheduleEntry recurringEntry(string id, string cron, string path, string body = null)
{
    return ScheduleEntry(id, Schedule.recurring(cron), path, body);
}

/// Runs every check against `scheduler`. Throws SchedulerConformanceException on the first failure.
void checkScheduler(Scheduler scheduler)
{
    require(scheduler.list().length == 0, "A new scheduler lists entries");

    // Upserting the same entry twice leaves one entry
    auto entry = recurringEntry("a", "0 0 1 1 *", "/api/v1/a", `{"x": 1}`);
    scheduler.upsert(entry);
    scheduler.upsert(entry);
    require(scheduler.list() == [entry], format("Upserting twice must keep one entry, got %s", scheduler.list()));

    // Upserting an existing id replaces its cron expression, endpoint and body
    auto changed = recurringEntry("a", "30 2 * * *", "/api/v1/other", `{"x": 2}`);
    scheduler.upsert(changed);
    require(scheduler.list() == [changed], format("Upsert must replace the entry, got %s", scheduler.list()));

    // ... and can turn a recurring entry into a one-shot one
    auto oneShot = ScheduleEntry("a", Schedule.once(Clock.currTime + 3650.days), "/api/v1/other", null);
    scheduler.upsert(oneShot);
    require(scheduler.list() == [oneShot], format("Upsert must replace the schedule, got %s", scheduler.list()));

    // list holds every entry, ordered by id
    auto b = recurringEntry("b", "0 0 1 1 *", "/api/v1/b");
    auto c = ScheduleEntry("0-first", Schedule.once(Clock.currTime + 3650.days), "/api/v1/c", null);
    scheduler.upsert(b);
    scheduler.upsert(c);
    require(scheduler.list() == [c, oneShot, b], format("list must hold all entries ordered by id, got %s", scheduler.list()));

    // Removing an unknown id is a no-op
    scheduler.remove("unknown");
    require(scheduler.list().length == 3, "Removing an unknown id changed the entries");

    // Removing an entry leaves the others, and removing it again is a no-op
    scheduler.remove("a");
    scheduler.remove("a");
    require(scheduler.list() == [c, b], format("remove must delete only the named entry, got %s", scheduler.list()));

    // An entry with no id, no path, or no schedule is refused, and refused entries are not kept
    foreach (bad; [recurringEntry("", "0 0 1 1 *", "/p"), recurringEntry("bad", "0 0 1 1 *", ""),
        ScheduleEntry("bad", Schedule.init, "/p", null)])
    {
        require(collectException(scheduler.upsert(bad)) !is null, format("Upsert must refuse %s", bad));
    }
    require(collectException(scheduler.upsert(recurringEntry("bad", "not a cron expression", "/p"))) !is null,
        "Upsert must refuse an invalid cron expression");
    require(scheduler.list() == [c, b], format("A refused entry was kept: %s", scheduler.list()));

    scheduler.remove("b");
    scheduler.remove("0-first");
    require(scheduler.list().length == 0, "Removing every entry must leave the scheduler empty");
}
