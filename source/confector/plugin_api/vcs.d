module confector.plugin_api.vcs;

import confector.plugin_api.plugin;
import confector.plugin_api.executor : LogDelegate;

/**
 * Abstract repository provider interface for version control operations.
 */
interface RepositoryProvider : Plugin
{
    @property string providerType() const;
    bool canHandle(string repositoryAddress) const;
    void cloneRepository(string address, string targetDirectory, LogDelegate logCallback = null);
}
