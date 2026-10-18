module confector.plugin_api.scheduler;

import std.datetime : SysTime;

/**
 * Header that carries the scheduler secret on every callback the scheduler fires. The server
 * rejects a callback whose header does not match its configured secret, and the scheduler
 * sends the configured secret in this header.
 */
enum string schedulerSecretHeader = "X-Confector-Scheduler-Secret";

/**
 * When a scheduled call fires: repeatedly on a cron expression, or once at a point in time.
 * Exactly one of the two is set. Minimum resolution is 1 minute (serverless-compatible:
 * CloudWatch Events cannot go finer). The scheduler parses and evaluates the cron expression.
 */
struct Schedule
{
    string cronExpression;  /// Cron expression (e.g. "*/5 * * * *"); set for a recurring call
    SysTime at;             /// Point in time of a one-shot call; set when cronExpression is empty

    /// A call repeated on `cronExpression`.
    static Schedule recurring(string cronExpression)
    {
        Schedule schedule;
        schedule.cronExpression = cronExpression;
        return schedule;
    }

    /// A call made once, at `at`. A time already past fires on the next scheduler pass.
    static Schedule once(SysTime at)
    {
        Schedule schedule;
        schedule.at = at;
        return schedule;
    }

    /// Whether this is a repeating schedule rather than a one-shot one.
    bool isRecurring() const pure nothrow @safe
    {
        return cronExpression.length > 0;
    }
}

/**
 * One scheduled call: WHAT to call (an endpoint path on the server and the body to POST there)
 * and WHEN. The scheduler decides HOW to fire it (a thread making HTTP requests, CloudWatch
 * Events, a Kubernetes CronJob, ...).
 */
struct ScheduleEntry
{
    string id;        /// Unique identifier of the entry
    Schedule when;
    string path;      /// Server endpoint path to POST to (e.g. "/api/v1/sweeps/retention")
    string jsonBody;  /// JSON body to POST; empty for none
}

/**
 * Scheduler interface that decouples the server from the scheduling mechanism.
 *
 * The server tells the scheduler what to call and when; the scheduler POSTs to the endpoint
 * path on the server at the scheduled times, carrying the callback secret in
 * `schedulerSecretHeader`. Calls go over HTTP, never in-process, so the scheduler and the
 * server may run in separate processes (serverless deployment).
 *
 * The scheduler owns whatever drives it (the local one runs its own thread, started when there
 * is an entry and stopped when none remain), so the server has no lifecycle calls to make. A
 * scheduler keeps nothing the server could not rebuild from the state store by upserting again.
 * Calls may be duplicated or missed; every endpoint a scheduler calls must tolerate that.
 */
interface Scheduler
{
    /**
     * Create the entry `entry.id`, or replace it if it exists. Idempotent: upserting the same
     * entry again leaves exactly one entry and one trigger. Throws if the id or path is empty,
     * the schedule is neither a cron expression nor a one-shot time, or the cron expression is
     * invalid.
     */
    void upsert(ScheduleEntry entry);

    /**
     * Remove the entry `id` and its trigger. Removing an id that does not exist is a no-op, so
     * that callers need not know whether an entry exists (a one-shot entry that has already
     * fired is gone).
     */
    void remove(string id);

    /**
     * Every entry currently held, ordered by id.
     */
    ScheduleEntry[] list();
}
