module confector.plugin_api.vcs;

import confector.plugin_api.plugin;
import confector.plugin_api.executor : LogDelegate;
import confector.plugin_api.model : VcsRepositoryState;
import std.json : JSONValue;

/**
 * Abstract repository provider interface for version control operations.
 */
interface RepositoryProvider : Plugin
{
    @property string providerType() const;
    bool canHandle(string repositoryAddress) const;
    void cloneRepository(string address, string targetDirectory, LogDelegate logCallback = null);
}

/**
 * VCS plugin interface for querying remote repository state and parsing provider webhooks.
 * Implements this interface to enable Confector to probe revisions, parse webhooks, and
 * invalidate DAG caches for a specific VCS provider (Git, Perforce, Plastic SCM, etc.).
 */
interface VcsStateResolver : Plugin
{
    /**
     * Returns the VCS provider type identifier (e.g., "git", "perforce", "plastic").
     */
    @property string providerType() const;

    /**
     * Returns true if this resolver can handle the given repository URL.
     */
    bool canHandle(string repositoryUrl) const;

    /**
     * Fetches the latest revision state for a repository and optional target ref.
     * Performs a remote query (e.g., `git ls-remote`) to resolve the current head revision.
     */
    VcsRepositoryState fetchLatestState(string repositoryUrl, string targetRef = null);

    /**
     * Returns true if this resolver can handle the incoming webhook payload
     * based on HTTP headers and payload structure.
     */
    bool canHandleWebhook(in string[string] headers, in JSONValue payload) const;

    /**
     * Parses a webhook payload into a resolved `VcsRepositoryState`.
     *
     * Returns true if parsing succeeded and populated `resolvedState`.
     */
    bool parseWebhookPayload(
        in string[string] headers,
        in JSONValue payload,
        out VcsRepositoryState resolvedState
    );
}
