module confector.queue.json_compat;

import vibe.data.json : Json;
import vibe.data.bson : Bson;
import std.json : JSONValue, JSONType, parseJSON;

/**
 * Safely extracts a long integer from a BSON value, accommodating int, long, double, or string types.
 */
long getBsonLong(in Bson b, long defaultVal = 0)
{
    switch (b.type)
    {
        case Bson.Type.int_: return cast(long)b.get!int;
        case Bson.Type.long_: return b.get!long;
        case Bson.Type.double_: return cast(long)b.get!double;
        case Bson.Type.string:
            try { import std.conv : to; return b.get!string.to!long; } catch (Exception) { return defaultVal; }
        default: return defaultVal;
    }
}

/**
 * Safely extracts an integer from a BSON value, accommodating int, long, double, or string types.
 */
int getBsonInt(in Bson b, int defaultVal = 0)
{
    switch (b.type)
    {
        case Bson.Type.int_: return b.get!int;
        case Bson.Type.long_: return cast(int)b.get!long;
        case Bson.Type.double_: return cast(int)b.get!double;
        case Bson.Type.string:
            try { import std.conv : to; return b.get!string.to!int; } catch (Exception) { return defaultVal; }
        default: return defaultVal;
    }
}

/**
 * Sanitizes a BSON value by removing fields with Type.undefined and converting
 * legacy object/undefined values to clean representations, enabling backwards
 * compatibility with MongoDB records stored by previous versions.
 */
Bson sanitizeBson(Bson val)
{
    if (val.type == Bson.Type.object)
    {
        Bson clean = Bson.emptyObject;
        foreach (string k, v; val)
        {
            if (v.type == Bson.Type.undefined)
            {
                continue;
            }
            // If properties was stored as a BSON object, null, undefined, or other type, adapt it for string propertiesJson
            if (k == "properties")
            {
                if (v.type == Bson.Type.null_ || v.type == Bson.Type.undefined)
                {
                    continue;
                }
                else if (v.type == Bson.Type.object || v.type == Bson.Type.array)
                {
                    clean[k] = Bson(v.toJson().toString());
                    continue;
                }
                else if (v.type == Bson.Type.string)
                {
                    clean[k] = v;
                    continue;
                }
                else
                {
                    continue;
                }
            }
            clean[k] = sanitizeBson(v);
        }
        return clean;
    }
    else if (val.type == Bson.Type.array)
    {
        Bson[] cleanArr;
        foreach (v; val)
        {
            if (v.type == Bson.Type.undefined)
            {
                cleanArr ~= Bson(null);
            }
            else
            {
                cleanArr ~= sanitizeBson(v);
            }
        }
        return Bson(cleanArr);
    }
    else if (val.type == Bson.Type.undefined)
    {
        return Bson(null);
    }
    return val;
}

/**
 * Converts a vibe.data.json.Json instance into a std.json.JSONValue.
 */
JSONValue toStdJson(in Json vibeJson)
{
    switch (vibeJson.type)
    {
        case Json.Type.undefined:
        case Json.Type.null_:
            return JSONValue(null);
        case Json.Type.bool_:
            return JSONValue(vibeJson.get!bool);
        case Json.Type.int_:
            return JSONValue(vibeJson.get!long);
        case Json.Type.float_:
            return JSONValue(vibeJson.get!double);
        case Json.Type.string:
            return JSONValue(vibeJson.get!string);
        case Json.Type.array:
            JSONValue[] arr;
            foreach (item; vibeJson)
            {
                arr ~= toStdJson(item);
            }
            return JSONValue(arr);
        case Json.Type.object:
            JSONValue[string] obj;
            foreach (string k, item; vibeJson)
            {
                obj[k] = toStdJson(item);
            }
            return JSONValue(obj);
        default:
            return JSONValue(null);
    }
}

/**
 * Parses a JSON string to std.json.JSONValue.
 */
JSONValue toStdJson(string jsonStr)
{
    if (jsonStr.length == 0) return JSONValue(string[string].init);
    return parseJSON(jsonStr);
}

/**
 * Converts a std.json.JSONValue instance into a vibe.data.json.Json.
 */
Json toVibeJson(in JSONValue stdJson)
{
    switch (stdJson.type)
    {
        case JSONType.null_:
            return Json(null);
        case JSONType.true_:
            return Json(true);
        case JSONType.false_:
            return Json(false);
        case JSONType.integer:
            return Json(stdJson.integer);
        case JSONType.uinteger:
            return Json(stdJson.uinteger);
        case JSONType.float_:
            return Json(stdJson.floating);
        case JSONType.string:
            return Json(stdJson.str);
        case JSONType.array:
            Json arr = Json.emptyArray;
            foreach (ref const item; stdJson.array)
            {
                arr ~= toVibeJson(item);
            }
            return arr;
        case JSONType.object:
            Json obj = Json.emptyObject;
            foreach (string k, ref const item; stdJson.object)
            {
                obj[k] = toVibeJson(item);
            }
            return obj;
        default:
            return Json.undefined;
    }
}

/**
 * Parses a JSON string to vibe.data.json.Json.
 */
Json toVibeJson(string jsonStr)
{
    import vibe.data.json : parseJsonString;
    if (jsonStr.length == 0) return Json.emptyObject;
    return parseJsonString(jsonStr);
}

unittest
{
    Json vJson = Json.emptyObject;
    vJson["key"] = "value";
    vJson["num"] = 42;
    vJson["arr"] = Json.emptyArray;
    vJson["arr"] ~= Json(1);
    vJson["arr"] ~= Json(2);

    JSONValue sJson = toStdJson(vJson);
    assert(sJson["key"].str == "value");
    assert(sJson["num"].integer == 42);
    assert(sJson["arr"].array.length == 2);

    Json convertedBack = toVibeJson(sJson);
    assert(convertedBack["key"].get!string == "value");
    assert(convertedBack["num"].get!long == 42);
    assert(convertedBack["arr"].length == 2);
}
