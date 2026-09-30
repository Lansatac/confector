module confector.core.vcs;

import confector.core.plugin;
import confector.core.executor : LogDelegate;

/**
 * Abstract repository provider interface for version control operations.
 */
interface RepositoryProvider : Plugin
{
    @property string providerType() const;
    bool canHandle(string repositoryAddress) const;
    void cloneRepository(string address, string targetDirectory, LogDelegate logCallback = null);
}
