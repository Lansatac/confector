module confector.config;

import vibe.data.json : Json, serializeToJson, deserializeJson, parseJsonString;
import std.conv : to, ConvException;
import std.process : environment;
import std.string : split, join, toUpper, replace, strip;
import std.traits : isIntegral, isFloatingPoint, isBoolean, isSomeString, isArray, isAssociativeArray, isBasicType;
import core.time : Duration, dur;
import std.file : exists, readText;

/**
 * Supported primitive / structured configuration types.
 */
enum ConfigType
{
    string_,
    integer,
    boolean,
    floating,
    array,
    object
}

/**
 * Metadata definition for a configuration key.
 */
struct ConfigDefinition
{
    string key;                 // e.g. "runnerBinary" or "server.port"
    string envVar;              // e.g. "CONFECTOR_RUNNER_BIN"
    Json defaultValue;          // Default JSON-compatible value
    string description;         // Human-readable documentation
    bool required = false;
}

/**
 * Interface for querying resolved configuration values.
 */
interface ConfigAccessor
{
    bool has(string key) const;
    Json getJson(string key) const;
    string getString(string key, string defaultValue = null) const;
    long getInt(string key, long defaultValue = 0) const;
    bool getBool(string key, bool defaultValue = false) const;
    double getDouble(string key, double defaultValue = 0.0) const;

    // Type-safe struct / primitive binding via template final methods
    final T get(T)(string key) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.undefined)
        {
            throw new Exception("Configuration key '" ~ key ~ "' not found.");
        }
        return coerceJson!T(val);
    }

    final T get(T)(string key, T defaultValue) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.undefined)
        {
            return defaultValue;
        }
        try
        {
            return coerceJson!T(val);
        }
        catch (Exception)
        {
            return defaultValue;
        }
    }

    final T bind(T)() const
    {
        static if (is(T == struct))
        {
            T result;
            // Build resolved object for struct members
            foreach (member; __traits(allMembers, T))
            {
                static if (!is(typeof(__traits(getMember, T, member)) == function) &&
                           !is(typeof(__traits(getMember, T, member)) == delegate))
                {
                    alias MemberType = typeof(__traits(getMember, result, member));
                    string memberKey = member;
                    Json resolved = getJson(memberKey);
                    if (resolved.type != Json.Type.undefined)
                    {
                        try
                        {
                            __traits(getMember, result, member) = coerceJson!MemberType(resolved);
                        }
                        catch (Exception e)
                        {
                            // Keep default value on coercion error
                        }
                    }
                }
            }
            return result;
        }
        else
        {
            static assert(false, "bind!T can only be called with struct types");
        }
    }
}

/**
 * Interface for configuration registry and scoped accessors.
 */
interface ConfigRegistryInterface
{
    void registerDefinition(in ConfigDefinition def);
    ConfigAccessor getScope(string namespacePrefix);
}

/**
 * Helper to convert hierarchical key (e.g. "server.http.port" or "plugins.local_process.maxConcurrency")
 * into a default environment variable name:
 * "server.http.port" -> "CONFECTOR_SERVER_HTTP_PORT"
 * "plugins.local_process.maxConcurrency" -> "CONFECTOR_LOCAL_PROCESS_MAX_CONCURRENCY"
 */
string keyToDefaultEnvVar(string key)
{
    // If key starts with "plugins.", convert "plugins.foo.bar" to "CONFECTOR_FOO_BAR"
    // or standard "CONFECTOR_KEY_PATH"
    string transformedKey = key;
    if (transformedKey.length >= 8 && transformedKey[0 .. 8] == "plugins.")
    {
        transformedKey = transformedKey[8 .. $];
    }
    
    // Replace dots and hyphens with underscores, convert camelCase/mixed to upper snake
    string result = "CONFECTOR_";
    foreach (size_t i, dchar c; transformedKey)
    {
        if (c == '.' || c == '-')
        {
            result ~= '_';
        }
        else if (c >= 'A' && c <= 'Z')
        {
            if (i > 0 && transformedKey[i - 1] != '.' && transformedKey[i - 1] != '-' && transformedKey[i - 1] != '_')
            {
                result ~= '_';
            }
            result ~= cast(char)c;
        }
        else if (c >= 'a' && c <= 'z')
        {
            result ~= cast(char)(c - 32);
        }
        else
        {
            result ~= cast(char)c;
        }
    }
    return result;
}

/**
 * Helper to traverse nested Json by dot-separated path (e.g. "plugins.local_process.maxConcurrency").
 */
Json getNestedJson(in Json root, string dotPath)
{
    if (dotPath.length == 0)
        return root;

    string[] parts = dotPath.split(".");
    Json current = root;
    foreach (part; parts)
    {
        if (current.type != Json.Type.object)
        {
            return Json.undefined;
        }
        if (const(Json)* val = part in current)
        {
            current = *val;
        }
        else
        {
            return Json.undefined;
        }
    }
    return current;
}

/**
 * Core resolution engine evaluating precedence:
 * 1. Environment Variable (Explicit mapping or automatic CONFECTOR_* mapping)
 * 2. Unified Config File (JSON)
 * 3. Registered Default Value
 */
class ResolutionEngine
{
    private Json m_fileConfig;
    private ConfigDefinition[string] m_definitions;

    this(Json fileConfig = Json.emptyObject)
    {
        m_fileConfig = fileConfig;
    }

    void setFileConfig(Json fileConfig)
    {
        m_fileConfig = fileConfig;
    }

    const(Json) getFileConfig() const
    {
        return m_fileConfig;
    }

    void registerDefinition(in ConfigDefinition def)
    {
        m_definitions[def.key] = def;
    }

    const(ConfigDefinition[string]) getDefinitions() const
    {
        return m_definitions;
    }

    bool hasDefinition(string key) const
    {
        return (key in m_definitions) !is null;
    }

    /**
     * Resolves a key into a Json value by checking env, file config, and default schema.
     */
    Json resolveKey(string fullKey) const
    {
        // 1. Check Environment Variables
        // A. Explicit envVar from registered definition
        if (auto def = fullKey in m_definitions)
        {
            if (def.envVar.length > 0)
            {
                string envVal = environment.get(def.envVar, null);
                if (envVal !is null)
                {
                    return parseEnvValue(envVal, def.defaultValue);
                }
            }
        }

        // B. Default convention env var
        string defaultEnv = keyToDefaultEnvVar(fullKey);
        string envVal = environment.get(defaultEnv, null);
        if (envVal !is null)
        {
            Json hint = Json.undefined;
            if (auto def = fullKey in m_definitions)
            {
                hint = def.defaultValue;
            }
            return parseEnvValue(envVal, hint);
        }

        // 2. Check File Config (hierarchical lookup)
        Json fileVal = getNestedJson(m_fileConfig, fullKey);
        if (fileVal.type != Json.Type.undefined)
        {
            return fileVal;
        }

        // 3. Check Default Schema
        if (auto def = fullKey in m_definitions)
        {
            if (def.defaultValue.type != Json.Type.undefined)
            {
                return def.defaultValue;
            }
        }

        return Json.undefined;
    }

    /**
     * Convert an environment variable string into typed Json, with optional type hint.
     */
    private static Json parseEnvValue(string val, in Json hint)
    {
        if (hint.type == Json.Type.int_)
        {
            try { return Json(val.to!long); } catch (ConvException) {}
        }
        else if (hint.type == Json.Type.float_)
        {
            try { return Json(val.to!double); } catch (ConvException) {}
        }
        else if (hint.type == Json.Type.bool_)
        {
            if (val == "true" || val == "1" || val == "yes" || val == "TRUE") return Json(true);
            if (val == "false" || val == "0" || val == "no" || val == "FALSE") return Json(false);
        }
        else if (hint.type == Json.Type.array || hint.type == Json.Type.object)
        {
            try { return parseJsonString(val); } catch (Exception) {}
        }

        // Fallback dynamic inference
        if (val == "true" || val == "TRUE") return Json(true);
        if (val == "false" || val == "FALSE") return Json(false);
        try
        {
            long num = val.to!long;
            return Json(num);
        }
        catch (ConvException)
        {
            try
            {
                double d = val.to!double;
                return Json(d);
            }
            catch (ConvException)
            {
                // Try JSON parsing for arrays/objects
                if ((val.length >= 2 && val[0] == '[' && val[$ - 1] == ']') ||
                    (val.length >= 2 && val[0] == '{' && val[$ - 1] == '}'))
                {
                    try { return parseJsonString(val); } catch (Exception) {}
                }
                return Json(val);
            }
        }
    }
}

/**
 * Concrete ConfigAccessor implementation bound to a ResolutionEngine and optional namespace prefix.
 */
class ScopedConfigAccessor : ConfigAccessor
{
    private const(ResolutionEngine) m_engine;
    private string m_prefix;

    this(const(ResolutionEngine) engine, string prefix = null)
    {
        m_engine = engine;
        m_prefix = prefix;
    }

    private string qualifyKey(string key) const
    {
        if (m_prefix.length == 0) return key;
        if (key.length == 0) return m_prefix;
        return m_prefix ~ "." ~ key;
    }

    override bool has(string key) const
    {
        Json val = getJson(key);
        return val.type != Json.Type.undefined;
    }

    override Json getJson(string key) const
    {
        string fullKey = qualifyKey(key);
        return m_engine.resolveKey(fullKey);
    }

    override string getString(string key, string defaultValue = null) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.string) return val.get!string;
        if (val.type != Json.Type.undefined && val.type != Json.Type.null_) return val.to!string;
        return defaultValue;
    }

    override long getInt(string key, long defaultValue = 0) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.int_) return val.get!long;
        if (val.type == Json.Type.float_) return cast(long)val.get!double;
        if (val.type == Json.Type.string)
        {
            try { return val.get!string.to!long; } catch (ConvException) {}
        }
        return defaultValue;
    }

    override bool getBool(string key, bool defaultValue = false) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.bool_) return val.get!bool;
        if (val.type == Json.Type.string)
        {
            string s = val.get!string;
            if (s == "true" || s == "1" || s == "yes") return true;
            if (s == "false" || s == "0" || s == "no") return false;
        }
        return defaultValue;
    }

    override double getDouble(string key, double defaultValue = 0.0) const
    {
        Json val = getJson(key);
        if (val.type == Json.Type.float_) return val.get!double;
        if (val.type == Json.Type.int_) return cast(double)val.get!long;
        if (val.type == Json.Type.string)
        {
            try { return val.get!string.to!double; } catch (ConvException) {}
        }
        return defaultValue;
    }
}

/**
 * Coerce a vibe.data.json.Json value into a strongly-typed D value.
 */
T coerceJson(T)(in Json val)
{
    static if (is(T == Json))
    {
        return val;
    }
    else static if (is(T == string))
    {
        if (val.type == Json.Type.string) return val.get!string;
        return val.to!string;
    }
    else static if (isBoolean!T)
    {
        if (val.type == Json.Type.bool_) return val.get!bool;
        if (val.type == Json.Type.string)
        {
            string s = val.get!string;
            if (s == "true" || s == "1" || s == "yes") return true;
            if (s == "false" || s == "0" || s == "no") return false;
        }
        return val.get!bool;
    }
    else static if (isIntegral!T)
    {
        if (val.type == Json.Type.int_) return cast(T)val.get!long;
        if (val.type == Json.Type.float_) return cast(T)val.get!double;
        if (val.type == Json.Type.string) return val.get!string.to!T;
        return cast(T)val.get!long;
    }
    else static if (isFloatingPoint!T)
    {
        if (val.type == Json.Type.float_) return cast(T)val.get!double;
        if (val.type == Json.Type.int_) return cast(T)val.get!long;
        if (val.type == Json.Type.string) return val.get!string.to!T;
        return cast(T)val.get!double;
    }
    else static if (is(T == Duration))
    {
        if (val.type == Json.Type.int_) return dur!"msecs"(val.get!long);
        if (val.type == Json.Type.string)
        {
            // Simple parsing e.g. "10s", "5m", "100ms"
            string s = val.get!string.strip();
            if (s.length > 2 && s[$ - 2 .. $] == "ms") return dur!"msecs"(s[0 .. $ - 2].to!long);
            if (s.length > 1 && s[$ - 1] == 's') return dur!"seconds"(s[0 .. $ - 1].to!long);
            if (s.length > 1 && s[$ - 1] == 'm') return dur!"minutes"(s[0 .. $ - 1].to!long);
            if (s.length > 1 && s[$ - 1] == 'h') return dur!"hours"(s[0 .. $ - 1].to!long);
            return dur!"msecs"(s.to!long);
        }
        return dur!"msecs"(val.get!long);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        alias ElementType = typeof(T.init[0]);
        if (val.type == Json.Type.array)
        {
            ElementType[] result;
            foreach (elem; val)
            {
                result ~= coerceJson!ElementType(elem);
            }
            return result;
        }
        throw new Exception("Expected JSON array for " ~ T.stringof);
    }
    else static if (is(T == struct))
    {
        return deserializeJson!T(val);
    }
    else
    {
        return deserializeJson!T(val);
    }
}

/**
 * Main Central Configuration Registry.
 */
class ConfigRegistry : ConfigRegistryInterface
{
    private ResolutionEngine m_engine;

    this(Json fileConfig = Json.emptyObject)
    {
        m_engine = new ResolutionEngine(fileConfig);
    }

    void loadConfigFile(string path)
    {
        if (exists(path))
        {
            string content = readText(path);
            Json fileJson = parseJsonString(content);
            m_engine.setFileConfig(fileJson);
        }
    }

    void setFileConfig(Json fileConfig)
    {
        m_engine.setFileConfig(fileConfig);
    }

    void registerDefinition(in ConfigDefinition def)
    {
        m_engine.registerDefinition(def);
    }

    Json resolveKey(string fullKey) const
    {
        return m_engine.resolveKey(fullKey);
    }

    ConfigAccessor getScope(string namespacePrefix)
    {
        return new ScopedConfigAccessor(m_engine, namespacePrefix);
    }

    ConfigAccessor rootAccessor()
    {
        return new ScopedConfigAccessor(m_engine, "");
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest
{
    // Test 1: Precedence Hierarchy Verification
    // Default schema ("server.port": 8080)
    auto registry = new ConfigRegistry();
    registry.registerDefinition(ConfigDefinition("server.port", "CONFECTOR_SERVER_PORT", Json(8080), "Server HTTP port"));

    auto serverConfig = registry.getScope("server");
    assert(serverConfig.getInt("port") == 8080);
    assert(registry.rootAccessor().getInt("server.port") == 8080);

    // Set key in JSON config ("server.port": 9000)
    string jsonStr = `{"server": {"port": 9000}}`;
    registry.setFileConfig(parseJsonString(jsonStr));
    assert(serverConfig.getInt("port") == 9000);

    // Set key in environment variable (CONFECTOR_SERVER_PORT=9999)
    environment["CONFECTOR_SERVER_PORT"] = "9999";
    assert(serverConfig.getInt("port") == 9999);

    // Unset environment variable; assert returns 9000
    environment.remove("CONFECTOR_SERVER_PORT");
    assert(serverConfig.getInt("port") == 9000);

    // Remove JSON config entry; assert returns 8080
    registry.setFileConfig(Json.emptyObject);
    assert(serverConfig.getInt("port") == 8080);
}

unittest
{
    // Test 2: Scoped Plugin Configuration Lookup & Convention Env Vars
    string jsonStr = `{
        "plugins": {
            "local_process": {
                "maxConcurrency": 8,
                "runnerBinary": "bin/custom-runner"
            }
        }
    }`;
    auto registry = new ConfigRegistry(parseJsonString(jsonStr));
    auto pluginScope = registry.getScope("plugins.local_process");

    assert(pluginScope.get!size_t("maxConcurrency") == 8);
    assert(pluginScope.get!string("runnerBinary") == "bin/custom-runner");
    assert(pluginScope.getInt("maxConcurrency") == 8);
    assert(pluginScope.getString("runnerBinary") == "bin/custom-runner");

    // Test 3: Environment Variable Override for Plugins (via automatic CONFECTOR_LOCAL_PROCESS_MAX_CONCURRENCY mapping)
    environment["CONFECTOR_LOCAL_PROCESS_MAX_CONCURRENCY"] = "16";
    assert(pluginScope.get!size_t("maxConcurrency") == 16);
    environment.remove("CONFECTOR_LOCAL_PROCESS_MAX_CONCURRENCY");
    assert(pluginScope.get!size_t("maxConcurrency") == 8);
}

unittest
{
    // Test 4: Struct Binding (bind!T)
    struct LocalProcessProvisionerConfig
    {
        size_t maxConcurrency = 4;
        string runnerBinary = "bin/confector-runner";
        bool enabled = true;
    }

    string jsonStr = `{
        "plugins": {
            "local_process": {
                "maxConcurrency": 12,
                "runnerBinary": "bin/alt-runner"
            }
        }
    }`;
    auto registry = new ConfigRegistry(parseJsonString(jsonStr));
    auto pluginScope = registry.getScope("plugins.local_process");

    auto cfg = pluginScope.bind!LocalProcessProvisionerConfig();
    assert(cfg.maxConcurrency == 12);
    assert(cfg.runnerBinary == "bin/alt-runner");
    assert(cfg.enabled == true); // Default preserved when absent
}

unittest
{
    // Test 5: Type coercion (strings, ints, doubles, booleans, arrays, Duration)
    string jsonStr = `{
        "test": {
            "str": "hello",
            "intStr": "42",
            "boolVal": true,
            "boolStr": "false",
            "floatVal": 3.14,
            "arr": ["a", "b", "c"],
            "timeoutSec": "10s",
            "timeoutMs": "500ms"
        }
    }`;
    auto registry = new ConfigRegistry(parseJsonString(jsonStr));
    auto scope_ = registry.getScope("test");

    assert(scope_.get!string("str") == "hello");
    assert(scope_.get!int("intStr") == 42);
    assert(scope_.get!bool("boolVal") == true);
    assert(scope_.get!bool("boolStr") == false);
    assert(scope_.get!double("floatVal") == 3.14);
    assert(scope_.get!(string[])("arr") == ["a", "b", "c"]);
    assert(scope_.get!Duration("timeoutSec") == dur!"seconds"(10));
    assert(scope_.get!Duration("timeoutMs") == dur!"msecs"(500));

    // Fallbacks
    assert(scope_.get!int("nonExistent", 99) == 99);
    assert(scope_.getString("nonExistent", "defaultVal") == "defaultVal");
    assert(!scope_.has("nonExistent"));
    assert(scope_.has("str"));
}
