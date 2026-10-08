module plugins.artifact.local;

import std.format;
import std.file : exists, isFile, mkdirRecurse, remove, rmdir, rename, dirEntries, SpanMode;
import std.path : buildPath;
import std.process : thisProcessID;
import std.random : unpredictableSeed;
import std.stdio : File;
import std.json : JSONValue, JSONType;

import confector.plugin_api.model : ArtifactStorage;
import confector.plugin_api.plugin : Plugin, PluginContext, PluginCategory, ArtifactStoragePlugin, ConfigDefinition;

/**
 * Local filesystem implementation of the artifact storage plugin.
 * Stores content-addressed artifacts as zip archives under a base directory
 * organized by task fingerprint.
 */
class LocalArtifactStoragePlugin : ArtifactStoragePlugin, ArtifactStorage
{
    private PluginContext m_context;
    private string m_baseStorageDir;

    @property string name() const { return "local-artifact"; }
    @property string versionString() const { return "1.0.0"; }
    @property string description() const { return "Local filesystem artifact storage backend"; }
    @property PluginCategory category() const { return PluginCategory.artifact; }

    ConfigDefinition[] configDefinitions() const
    {
        import vibe.data.json : Json;
        return [
            ConfigDefinition("baseDir", "", Json("/artifacts"), "Base directory for artifact storage", false)
        ];
    }

    void initialize(PluginContext context = null)
    {
        m_context = context;
        if (context !is null)
        {
            m_baseStorageDir = context.config.getString("baseDir", "/artifacts");
        }
        else
        {
            m_baseStorageDir = "/artifacts";
        }

        if (!exists(m_baseStorageDir))
        {
            mkdirRecurse(m_baseStorageDir);
        }
    }

    void shutdown()
    {
    }

    @property string backendType() const pure nothrow @safe
    {
        return "local";
    }

    @property string displayName() const pure nothrow @safe
    {
        return "Local Filesystem";
    }

    override JSONValue defaultConfig() const
    {
        return JSONValue(["baseDir": JSONValue(m_baseStorageDir)]);
    }

    string[] validateConfig(in JSONValue config) const
    {
        string[] errors;
        if (config.type != JSONType.object)
        {
            errors ~= "Configuration must be a JSON object";
            return errors;
        }

        if (auto p = "baseDir" in config)
        {
            if (p.type != JSONType.string || p.str.length == 0)
            {
                errors ~= "baseDir cannot be empty";
            }
        }

        return errors;
    }

    string renderConfigFormHtml(in JSONValue currentConfig) const
    {
        import diet.html : compileHTMLDietFile;
        import std.array : appender;

        auto html = appender!string;

        string baseDir = "/artifacts";
        if (currentConfig.type == JSONType.object)
        {
            if (auto p = "baseDir" in currentConfig)
            {
                if (p.type == JSONType.string) baseDir = p.str;
            }
        }

        compileHTMLDietFile!("config.dt", baseDir)(html);

        return html.data;
    }

    private static void validateStorageKey(string key, string paramName)
    {
        if (key.length == 0)
        {
            throw new Exception(format("Invalid %s: key cannot be empty", paramName));
        }
        import std.algorithm.searching : canFind;
        if (key.canFind("..") || key.canFind('/') || key.canFind('\\') || key.canFind(':') || key.canFind('\0'))
        {
            throw new Exception(format("Invalid %s '%s': contains illegal path characters or traversal sequence", paramName, key));
        }
    }

    /**
     * Stores an artifact by streaming bytes from writer into a local zip file.
     * Uses atomic write via temp file + rename to prevent corruption.
     */
    void storeArtifactStream(string taskFingerprint, string artifactId, void delegate(void delegate(const(ubyte)[])) writer)
    {
        if (writer is null)
        {
            throw new Exception("Writer delegate cannot be null");
        }
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string destDir = buildPath(m_baseStorageDir, taskFingerprint);
        if (!exists(destDir))
        {
            mkdirRecurse(destDir);
        }

        string destPath = buildPath(destDir, artifactId ~ ".zip");

        string tempPath = format("%s.tmp.%d.%d", destPath, thisProcessID, unpredictableSeed());

        {
            auto f = File(tempPath, "wb");
            scope(failure)
            {
                if (exists(tempPath))
                {
                    try { remove(tempPath); } catch (Exception) {}
                }
            }

            writer((const(ubyte)[] chunk) {
                if (chunk.length > 0)
                {
                    f.rawWrite(chunk);
                }
            });
            f.flush();
            f.close();
        }

        if (exists(destPath))
        {
            remove(destPath);
        }
        rename(tempPath, destPath);
    }

    /**
     * Retrieves an artifact from local storage and streams chunks into sink.
     */
    void retrieveArtifactStream(string taskFingerprint, string artifactId, void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
        {
            throw new Exception("Sink delegate cannot be null");
        }
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string sourcePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        if (!exists(sourcePath) || !isFile(sourcePath))
        {
            throw new Exception(format("Artifact not found in storage: fingerprint='%s', artifactId='%s' (looked at %s)", taskFingerprint, artifactId, sourcePath));
        }

        auto f = File(sourcePath, "rb");
        ubyte[64 * 1024] buffer;
        while (!f.eof)
        {
            ubyte[] chunk = f.rawRead(buffer[]);
            if (chunk.length > 0)
            {
                sink(chunk);
            }
        }
    }

    /**
     * Checks if an artifact exists in local storage.
     */
    bool artifactExists(string taskFingerprint, string artifactId)
    {
        if (taskFingerprint.length == 0 || artifactId.length == 0) return false;
        try
        {
            validateStorageKey(taskFingerprint, "taskFingerprint");
            validateStorageKey(artifactId, "artifactId");
        }
        catch (Exception)
        {
            return false;
        }

        string filePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        return exists(filePath) && isFile(filePath);
    }

    /**
     * Deletes an artifact from local storage, cleaning up empty fingerprint directories.
     */
    void deleteArtifact(string taskFingerprint, string artifactId)
    {
        validateStorageKey(taskFingerprint, "taskFingerprint");
        validateStorageKey(artifactId, "artifactId");

        string filePath = buildPath(m_baseStorageDir, taskFingerprint, artifactId ~ ".zip");
        if (exists(filePath))
        {
            remove(filePath);

            string parentDir = buildPath(m_baseStorageDir, taskFingerprint);
            try
            {
                if (exists(parentDir))
                {
                    bool empty = true;
                    foreach (entry; dirEntries(parentDir, SpanMode.shallow))
                    {
                        empty = false;
                        break;
                    }
                    if (empty)
                    {
                        rmdir(parentDir);
                    }
                }
            }
            catch (Exception) {}
        }
    }
}

/**
 * Exported factory function for dynamic plugin loading.
 */
extern(C) export Plugin confector_create_plugin()
{
    return new LocalArtifactStoragePlugin();
}
