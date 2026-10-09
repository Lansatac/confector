module confector.storage.configured_storage;

import confector.core.plugin : PluginRegistry;
import confector.plugin_api.model : ArtifactStorage;
import std.json : JSONValue;

/**
 * Meta-storage that forwards all ArtifactStorage calls to the currently configured
 * storage from the PluginRegistry. Throws when no storage is configured.
 */
class ConfiguredArtifactStorage : ArtifactStorage
{
    private PluginRegistry m_registry;

    this(PluginRegistry registry)
    {
        m_registry = registry;
    }

    private ArtifactStorage activeStorage()
    {
        if (m_registry is null)
            throw new Exception("ConfiguredArtifactStorage: no PluginRegistry configured");

        auto storage = m_registry.getDefaultArtifactStorage();
        if (storage is null)
            throw new Exception("ConfiguredArtifactStorage: no default artifact storage configured in PluginRegistry");

        return storage;
    }

    override void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
    {
        activeStorage().storeArtifactStream(taskFingerprint, artifactId, writer);
    }

    override void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
    {
        activeStorage().retrieveArtifactStream(taskFingerprint, artifactId, sink);
    }

    override bool artifactExists(string taskFingerprint, string artifactId)
    {
        try
        {
            return activeStorage().artifactExists(taskFingerprint, artifactId);
        }
        catch (Exception)
        {
            return false;
        }
    }

    override void deleteArtifact(string taskFingerprint, string artifactId)
    {
        activeStorage().deleteArtifact(taskFingerprint, artifactId);
    }

    @property string backendType() const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().backendType;
        }
        catch (Exception)
        {
            return "configured";
        }
    }

    @property string displayName() const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().displayName;
        }
        catch (Exception)
        {
            return "Configured Storage";
        }
    }

    @property string description() const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().description;
        }
        catch (Exception)
        {
            return "Meta-storage forwarding to the currently configured artifact storage backend.";
        }
    }

    JSONValue defaultConfig() const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().defaultConfig();
        }
        catch (Exception)
        {
            return JSONValue(string[string].init);
        }
    }

    string[] validateConfig(in JSONValue config) const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().validateConfig(config);
        }
        catch (Exception)
        {
            return ["No artifact storage configured"];
        }
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        try
        {
            auto self = cast(ConfiguredArtifactStorage)this;
            return self.activeStorage().renderConfigFormHtml(currentConfig);
        }
        catch (Exception)
        {
            return "<p>No artifact storage configured. Please configure one in the Artifacts tab.</p>";
        }
    }

    override string presignUpload(string taskFingerprint, string artifactId)
    {
        return activeStorage().presignUpload(taskFingerprint, artifactId);
    }

    override string presignDownload(string taskFingerprint, string artifactId)
    {
        return activeStorage().presignDownload(taskFingerprint, artifactId);
    }
}
