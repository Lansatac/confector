module confector.mongo_helpers;

import std.format;
import std.stdio : stderr;
import std.json : JSONValue, parseJSON;
import std.conv;
import std.uuid : randomUUID;
import vibe.data.json : serializeToJson, deserializeJson;

public import kaleidic.mongo_standalone;
import confector.plugin_api.model : ArtifactMetadata;

/**
 * Serialize a struct to a JSON string for MongoDB storage.
 */
string toJsonString(T)(T value)
{
    return serializeToJson(value).toString();
}

/**
 * Deserialize a JSON string back to a struct.
 */
T fromJsonString(T)(string jsonStr)
{
    return deserializeJson!T(jsonStr);
}

/**
 * MongoDB helper operations for plugin implementations.
 */
struct MongoHelpers
{
    MongoConnection connection;
    string dbName;

    this(MongoConnection conn, string db)
    {
        connection = conn;
        dbName = db;
    }

    private string col(string name) { return dbName ~ "." ~ name; }

    /// Insert a single document with the JSON stored in a "json_data" field.
    void insertOne(string collection, string jsonDoc)
    {
        auto docs = [document([
            bson_value("_id", randomUUID().toString()),
            bson_value("json_data", jsonDoc)
        ])];
        connection.insert(false, col(collection), docs);
    }

    /// Insert a document with an additional key field.
    void insertOneWithKey(string collection, string keyField, string keyValue, string jsonDoc)
    {
        auto docs = [document([
            bson_value("_id", randomUUID().toString()),
            bson_value(keyField.idup, keyValue.idup),
            bson_value("json_data", jsonDoc)
        ])];
        connection.insert(false, col(collection), docs);
    }

    /// Find one document by a single key field, returns the json_data string.
    string findOne(string collection, string keyField, string keyValue)
    {
        auto query = document([bson_value(keyField.idup, keyValue.idup)]);
        auto reply = connection.query(col(collection), 0, 1, query);
        if (reply.documents.length == 0) return null;
        auto doc = reply.documents[0];
        auto jsonField = doc["json_data"];
        if (jsonField is bson_value.init) return null;
        return jsonField.toString();
    }

    /// Find one document by build_id and task_id, returns the json_data string.
    string findOneByKeys(string collection, string buildId, string taskId)
    {
        auto query = document([
            bson_value("build_id", buildId.idup),
            bson_value("task_id", taskId.idup)
        ]);
        auto reply = connection.query(col(collection), 0, 1, query);
        if (reply.documents.length == 0) return null;
        auto doc = reply.documents[0];
        auto jsonField = doc["json_data"];
        if (jsonField is bson_value.init) return null;
        return jsonField.toString();
    }

    /// Find all documents matching a filter, returns json_data strings.
    string[] findMany(string collection, document filter, int limit = 0)
    {
        string[] results;
        auto reply = connection.query(col(collection), 0, limit > 0 ? limit : 0, filter);
        foreach (doc; reply.documents)
        {
            auto jsonField = doc["json_data"];
            if (jsonField !is bson_value.init)
                results ~= jsonField.toString();
        }
        return results;
    }

    /// Upsert by key field — stores JSON in json_data field.
    void upsert(string collection, string keyField, string keyValue, string jsonDoc)
    {
        auto query = document([bson_value(keyField.idup, keyValue.idup)]);
        auto reply = connection.query(col(collection), 0, 1, query);

        if (reply.documents.length == 0)
        {
            insertOneWithKey(collection, keyField, keyValue, jsonDoc);
        }
        else
        {
            auto updateDoc = document([bson_value("$set", document([bson_value("json_data", jsonDoc)]))]);
            connection.update(col(collection), false, false, query, updateDoc);
        }
    }

    /// Delete by key field.
    bool deleteOne(string collection, string keyField, string keyValue)
    {
        auto query = document([bson_value(keyField.idup, keyValue.idup)]);
        connection.delete_(col(collection), true, query);
        return true;
    }
}

/**
 * Simple log entry for task/build logs.
 */
struct LogEntry
{
    string buildId;
    string taskId;
    string line;
    string timestamp;
}

/**
 * Fingerprint cache entry for artifact caching.
 */
struct FingerprintCacheEntry
{
    string taskId;
    string fingerprint;
    ArtifactMetadata[] artifacts;
    string cachedAt;
}
