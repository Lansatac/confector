module confector.plugin_api.scheduler;

/**
 * Represents a scheduled job entry. The server registers these with the scheduler
 * to define WHAT to run and WHEN. The scheduler plugin decides HOW to fire them
 * (thread loop making HTTP requests, CloudWatch Events, Kubernetes CronJob, etc.).
 *
 * The scheduler fires HTTP POST requests to the registered URI — not in-process
 * delegate callbacks — making it fully compatible with serverless deployment where
 * the scheduler and server may run in completely separate processes.
 *
 * All scheduling uses cron expressions. The plugin is responsible for parsing and
 * evaluating cron. Minimum resolution is 1 minute (serverless-compatible — CloudWatch
 * Events minimum rate is 1 minute). The `recurring` flag supports one-time triggers.
 */
struct ScheduleEntry
{
    string id;                    // Unique identifier for the scheduled job
    string name;                  // Human-readable name
    string uri;                   // HTTP URI to call (e.g., "http://localhost:8080/api/v1/scheduler/capacity-evaluate")
    string httpMethod;            // HTTP method (default: "POST")
    string jsonBody;              // JSON body to send with the request (e.g., `{"repositoryUrl": "..."}`)
    string cronExpression;        // Cron expression (e.g., "*/5 * * * *" for every 5 min, "* * * * *" for every minute)
    bool recurring;               // Whether the job repeats (false = one-time trigger)
}

/**
 * Scheduler interface that decouples the server from the scheduling mechanism.
 *
 * The server tells the scheduler what to run and when by calling schedule().
 * The scheduler plugin fires HTTP POST requests to the registered URIs at the
 * configured times.
 *
 * Key design decisions:
 * - schedule() is idempotent: calling with the same entryId must not create duplicate triggers.
 * - The plugin reconciles actual trigger state with the desired state on schedule().
 * - unschedule() removes the external trigger (e.g., CloudWatch rule).
 * - reconcile() is optional for full audit of all triggers.
 */
interface Scheduler
{
    /**
     * Register or update a schedule entry. Idempotent: calling with the same entryId
     * must not create duplicate triggers. The plugin reconciles actual trigger state
     * with the desired state described by the entry.
     *
     * @param entry The schedule entry defining what to run, when, and where (URI).
     */
    void schedule(ScheduleEntry entry);

    /**
     * Remove a schedule entry and its corresponding trigger.
     * The plugin must delete the external trigger (e.g., CloudWatch rule).
     *
     * @param entryId The unique identifier of the entry to remove.
     */
    void unschedule(string entryId);

    /**
     * Start the scheduler (begin firing triggers).
     */
    void start();

    /**
     * Stop the scheduler (stop firing triggers).
     */
    void stop();

    /**
     * Whether the scheduler is currently running.
     */
    @property bool isRunning() const;

    /**
     * Optional: perform a full reconciliation of all triggers.
     * The plugin audits actual triggers against registered entries and removes
     * orphaned triggers. The LocalSchedulerPlugin doesn't need it (in-memory state
     * is always consistent). A CloudWatch plugin uses this to remove orphaned rules.
     */
    void reconcile();
}
