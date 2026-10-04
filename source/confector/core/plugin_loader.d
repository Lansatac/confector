module confector.core.plugin_loader;

import confector.core.plugin;
import std.string : toStringz, strip, toLower;
import std.path : isAbsolute, absolutePath;
import std.file : exists, isFile, isDir, dirEntries, SpanMode, DirEntry;
import std.format : format;
import std.conv : to;
import std.algorithm.searching : endsWith, canFind;

version (Windows)
{
    import core.runtime : Runtime;
    import core.sys.windows.windows;
    import std.utf : toUTF16z;
}
else version (Posix)
{
    import core.sys.posix.dlfcn;
}

/**
 * Standard C-ABI export symbol name for plugin factories.
 */
enum string CONFECTOR_PLUGIN_FACTORY_SYMBOL = "confector_create_plugin";

/**
 * Function pointer type for plugin instantiation factory.
 */
alias PluginFactoryFn = extern(C) Plugin function();

/**
 * Exception thrown when dynamic plugin loading fails.
 */
class PluginLoadException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) pure nothrow @safe
    {
        super(msg, file, line, next);
    }
}

/**
 * Record holding state for a dynamically loaded plugin library.
 */
struct LoadedPluginRecord
{
    string path;
    void* handle;
    Plugin plugin;
    bool isBundled;
}

/**
 * Subsystem responsible for dynamically loading, resolving, tracking, and unloading plugin shared libraries.
 */
final class PluginLoader
{
    private static PluginLoader _instance;
    private LoadedPluginRecord[string] _loadedPlugins; // Keyed by plugin.name
    private string[string] _pathToPluginName; // Keyed by absolute library path
    private LoadedPluginRecord[string] _allPathRecords; // Keyed by absolute library path (including filtered)
    private string[] _loadOrder; // Chronological order of loading for LIFO unloading
    private void*[] _allLoadedHandles; // Chronological list of all opened dynamic library handles for POSIX LIFO closing

    public static PluginLoader instance()
    {
        if (_instance is null)
        {
            _instance = new PluginLoader();
        }
        return _instance;
    }

    public static void resetInstance()
    {
        if (_instance !is null)
        {
            _instance.unloadAll();
            _instance = null;
        }
    }

    public @property LoadedPluginRecord[string] loadedPlugins()
    {
        return _loadedPlugins.dup;
    }

    public @property LoadedPluginRecord[] allLoadedRecords()
    {
        return _loadedPlugins.values;
    }

    public Plugin getLoadedPlugin(string name)
    {
        if (auto p = name in _loadedPlugins)
        {
            return p.plugin;
        }
        return null;
    }

    public bool isPluginBundled(string name)
    {
        if (auto p = name in _loadedPlugins)
        {
            return p.isBundled;
        }
        return false;
    }

    public @property LoadedPluginRecord[] bundledPluginRecords()
    {
        LoadedPluginRecord[] records;
        foreach (rec; _loadedPlugins.values)
        {
            if (rec.isBundled)
            {
                records ~= rec;
            }
        }
        return records;
    }

    /**
     * Loads a shared dynamic library plugin from the given path, resolves its factory entrypoint,
     * instantiates the plugin, and registers it with PluginRegistry.
     */
    public Plugin loadPlugin(string libraryPath, bool isBundled = false, const(PluginCategory)[] allowedCategories = null)
    {
        string trimmedPath = libraryPath.strip;
        if (trimmedPath.length == 0)
        {
            throw new PluginLoadException("Plugin library path cannot be empty");
        }

        if (!exists(trimmedPath))
        {
            throw new PluginLoadException(format("Plugin library file does not exist: %s", trimmedPath));
        }

        if (!isFile(trimmedPath))
        {
            throw new PluginLoadException(format("Plugin library path is not a file: %s", trimmedPath));
        }

        string absPath = absolutePath(trimmedPath);

        // Check if already loaded by this path
        if (auto rec = absPath in _allPathRecords)
        {
            if (allowedCategories !is null && allowedCategories.length > 0)
            {
                if (!allowedCategories.canFind(rec.plugin.category))
                {
                    return null;
                }
            }
            if (rec.plugin.name !in _loadedPlugins)
            {
                PluginRegistry.instance.registerPlugin(rec.plugin);
                _loadedPlugins[rec.plugin.name] = *rec;
                _pathToPluginName[absPath] = rec.plugin.name;
                _loadOrder ~= rec.plugin.name;
            }
            return rec.plugin;
        }

        void* handle = null;

        version (Windows)
        {
            handle = Runtime.loadLibrary(absPath);
            if (handle is null)
            {
                enum DWORD LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
                handle = cast(void*) LoadLibraryExW(absPath.toUTF16z(), null, LOAD_WITH_ALTERED_SEARCH_PATH);
            }
            if (handle is null)
            {
                handle = cast(void*) LoadLibraryW(absPath.toUTF16z());
            }
            if (handle is null)
            {
                DWORD err = GetLastError();
                throw new PluginLoadException(format("Failed to load dynamic library '%s' (Win32 error %d)", absPath, err));
            }
        }
        else version (Posix)
        {
            handle = dlopen(absPath.toStringz(), RTLD_NOW | RTLD_GLOBAL);
            if (handle is null)
            {
                handle = dlopen(absPath.toStringz(), RTLD_NOW | RTLD_LOCAL);
            }
            if (handle is null)
            {
                const(char)* err = dlerror();
                throw new PluginLoadException(format("Failed to load dynamic library '%s': %s", absPath, err ? to!string(err) : "unknown error"));
            }
            _allLoadedHandles ~= handle;
        }
        else
        {
            static assert(0, "Unsupported platform for dynamic plugin loading");
        }

        void* sym = null;
        version (Windows)
        {
            sym = cast(void*) GetProcAddress(cast(HMODULE) handle, CONFECTOR_PLUGIN_FACTORY_SYMBOL.toStringz());
        }
        else version (Posix)
        {
            sym = dlsym(handle, CONFECTOR_PLUGIN_FACTORY_SYMBOL.toStringz());
        }

        if (sym is null)
        {
            unloadHandle(handle);
            throw new PluginLoadException(format("Dynamic library '%s' does not export entrypoint '%s'", trimmedPath, CONFECTOR_PLUGIN_FACTORY_SYMBOL));
        }

        auto factory = cast(PluginFactoryFn) sym;
        Plugin plugin = null;
        try
        {
            plugin = factory();
        }
        catch (Throwable t)
        {
            unloadHandle(handle);
            throw new PluginLoadException(format("Exception invoking plugin factory in '%s': %s", trimmedPath, t.msg), __FILE__, __LINE__, t);
        }

        if (plugin is null)
        {
            unloadHandle(handle);
            throw new PluginLoadException(format("Plugin factory '%s' in '%s' returned null", CONFECTOR_PLUGIN_FACTORY_SYMBOL, trimmedPath));
        }

        LoadedPluginRecord record;
        record.path = absPath;
        record.handle = handle;
        record.plugin = plugin;
        record.isBundled = isBundled;

        _allPathRecords[absPath] = record;

        if (allowedCategories !is null && allowedCategories.length > 0)
        {
            if (!allowedCategories.canFind(plugin.category))
            {
                return null;
            }
        }

        // Register with PluginRegistry
        PluginRegistry.instance.registerPlugin(plugin);

        _loadedPlugins[plugin.name] = record;
        _pathToPluginName[absPath] = plugin.name;
        _loadOrder ~= plugin.name;

        return plugin;
    }

    /**
     * Loads multiple plugin dynamic libraries from an array of file paths.
     */
    public Plugin[] loadPlugins(in string[] libraryPaths, bool isBundled = false, const(PluginCategory)[] allowedCategories = null)
    {
        Plugin[] loaded;
        foreach (path; libraryPaths)
        {
            string trimmed = path.strip;
            if (trimmed.length > 0)
            {
                auto p = loadPlugin(trimmed, isBundled, allowedCategories);
                if (p !is null)
                {
                    loaded ~= p;
                }
            }
        }
        return loaded;
    }

    /**
     * Scans a directory (defaulting to "./plugins") for plugin dynamic libraries,
     * automatically loading and registering them as bundled plugins.
     */
    public Plugin[] loadBundledPlugins(string directory = "./plugins", const(PluginCategory)[] allowedCategories = null)
    {
        Plugin[] loaded;
        if (!exists(directory) || !isDir(directory))
        {
            return loaded;
        }

        foreach (DirEntry entry; dirEntries(directory, SpanMode.depth))
        {
            if (entry.isFile)
            {
                string lowerName = entry.name.toLower;
                bool isLib = false;

                version (Windows)
                {
                    isLib = lowerName.endsWith(".dll");
                }
                else version (OSX)
                {
                    isLib = lowerName.endsWith(".dylib") || lowerName.endsWith(".so");
                }
                else
                {
                    isLib = lowerName.endsWith(".so") || lowerName.canFind(".so.");
                }

                if (isLib)
                {
                    try
                    {
                        auto p = loadPlugin(entry.name, true, allowedCategories);
                        if (p !is null)
                        {
                            loaded ~= p;
                        }
                    }
                    catch (Throwable e)
                    {
                        // Non-plugin libraries or incompatible binaries in directory are skipped
                    }
                }
            }
        }

        return loaded;
    }

    /**
     * Unloads a loaded plugin by its name, calling plugin shutdown, unregistering from PluginRegistry,
     * and releasing the dynamic library handle.
     */
    public void unloadPlugin(string name)
    {
        if (auto rec = name in _loadedPlugins)
        {
            auto record = *rec;
            _loadedPlugins.remove(name);
            _pathToPluginName.remove(record.path);

            import std.algorithm.mutation : remove;
            import std.algorithm.searching : countUntil;
            auto idx = _loadOrder.countUntil(name);
            if (idx >= 0)
            {
                _loadOrder = _loadOrder.remove(idx);
            }

            PluginRegistry.instance.unregisterPlugin(name);
            version (Windows)
            {
                _allPathRecords.remove(record.path);
                unloadHandle(record.handle);
            }
        }
    }

    /**
     * Unloads all dynamically loaded plugins in reverse chronological order (LIFO)
     * and releases their library handles.
     */
    public void unloadAll()
    {
        for (ptrdiff_t i = cast(ptrdiff_t)_loadOrder.length - 1; i >= 0; --i)
        {
            if (i < _loadOrder.length)
            {
                unloadPlugin(_loadOrder[i]);
            }
        }
        auto remainingNames = _loadedPlugins.keys;
        foreach (name; remainingNames)
        {
            unloadPlugin(name);
        }
        _loadedPlugins.clear();
        _pathToPluginName.clear();
        _loadOrder.length = 0;
        _allPathRecords.clear();

        version (Posix)
        {
            for (ptrdiff_t i = cast(ptrdiff_t)_allLoadedHandles.length - 1; i >= 0; --i)
            {
                if (_allLoadedHandles[i] !is null)
                {
                    dlclose(_allLoadedHandles[i]);
                }
            }
            _allLoadedHandles.length = 0;
        }
    }

    private static void unloadHandle(void* handle)
    {
        if (handle is null) return;
        version (Windows)
        {
            try
            {
                if (!Runtime.unloadLibrary(handle))
                {
                    FreeLibrary(cast(HMODULE) handle);
                }
            }
            catch (Throwable t)
            {
                FreeLibrary(cast(HMODULE) handle);
            }
        }
        else version (Posix)
        {
            dlclose(handle);
        }
    }
}

unittest
{
    auto loader = PluginLoader.instance;
    scope(exit) loader.unloadAll();

    // 1. Negative test: Empty path
    bool caughtEmpty = false;
    try
    {
        loader.loadPlugin("");
    }
    catch (PluginLoadException e)
    {
        caughtEmpty = true;
    }
    assert(caughtEmpty, "Should throw PluginLoadException for empty path");

    // 2. Negative test: Non-existent file
    bool caughtNonExistent = false;
    try
    {
        loader.loadPlugin("non_existent_plugin_file_12345.dll");
    }
    catch (PluginLoadException e)
    {
        caughtNonExistent = true;
    }
    assert(caughtNonExistent, "Should throw PluginLoadException for non-existent file");

    // 3. Negative test: Path is a directory
    bool caughtDir = false;
    try
    {
        loader.loadPlugin(".");
    }
    catch (PluginLoadException e)
    {
        caughtDir = true;
    }
    assert(caughtDir, "Should throw PluginLoadException when path is a directory");

    // 4. Negative test: Library without confector_create_plugin export
    version (Windows)
    {
        string systemLib = "C:\\Windows\\System32\\kernel32.dll";
        if (exists(systemLib))
        {
            bool caughtMissingSymbol = false;
            try
            {
                loader.loadPlugin(systemLib);
            }
            catch (PluginLoadException e)
            {
                caughtMissingSymbol = true;
            }
            assert(caughtMissingSymbol, "Should throw PluginLoadException when library lacks factory symbol");
        }
    }
    else version (Posix)
    {
        string systemLib = "/lib/x86_64-linux-gnu/libc.so.6";
        if (!exists(systemLib)) systemLib = "/usr/lib/libc.dylib";
        if (exists(systemLib))
        {
            bool caughtMissingSymbol = false;
            try
            {
                loader.loadPlugin(systemLib);
            }
            catch (PluginLoadException e)
            {
                caughtMissingSymbol = true;
            }
            assert(caughtMissingSymbol, "Should throw PluginLoadException when library lacks factory symbol");
        }
    }

    // 5. Array loading with empty/whitespace items
    assert(loader.loadPlugins(["", "   "]).length == 0);

    // 6. Loaded tracking methods
    assert(loader.loadedPlugins.length == 0);
    assert(loader.allLoadedRecords.length == 0);
    assert(loader.getLoadedPlugin("non_existent") is null);
    assert(!loader.isPluginBundled("non_existent"));
    assert(loader.bundledPluginRecords.length == 0);

    // 7. Bundled directory loader tests
    assert(loader.loadBundledPlugins("non_existent_plugins_dir_99999").length == 0);

    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    string testPluginsDir = buildPath(".test_confector_plugins_tmp");
    if (exists(testPluginsDir)) rmdirRecurse(testPluginsDir);
    mkdirRecurse(testPluginsDir);
    scope(exit) { if (exists(testPluginsDir)) rmdirRecurse(testPluginsDir); }

    // Directory without libs
    assert(loader.loadBundledPlugins(testPluginsDir).length == 0);

    // Directory with non-lib files
    write(buildPath(testPluginsDir, "readme.txt"), "some docs");
    assert(loader.loadBundledPlugins(testPluginsDir).length == 0);

    // 8. Unload non-existent plugin does not throw
    loader.unloadPlugin("non_existent");
    loader.unloadAll();
}
