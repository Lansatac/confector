module confector.core.zip_packager;

import std.zip : ZipArchive, ArchiveMember, CompressionMethod, ZipException;
import std.file : exists, isFile, isDir, mkdirRecurse, read, write, dirEntries, SpanMode;
import std.path : buildPath, buildNormalizedPath, dirName, baseName, relativePath, globMatch, absolutePath, isDirSeparator;
import std.algorithm.searching : canFind, startsWith, endsWith;
import std.algorithm.iteration : filter;
import std.array : Appender, split;
import std.format : format;
import std.string : replace;

/**
 * Exception thrown when zip packaging or extraction fails.
 */
class ZipPackagerException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @safe
    {
        super(msg, file, line, nextInChain);
    }
}

/**
 * Utility for packaging workspace files matching glob patterns into zip archives
 * and safely extracting zip archives into destination directories.
 */
final class ZipPackager
{
    /**
     * Packs files matching the given pattern(s) in baseDir into a zip archive and streams it to sink.
     *
     * Params:
     *   baseDir = The root workspace directory to search and package files from.
     *   patterns = Array of glob patterns or relative file paths (e.g. ["bin/*", "dist/app.js"]).
     *   sink = Chunk sink delegate receiving the zip archive byte chunks.
     */
    static void pack(string baseDir, string[] patterns, void delegate(const(ubyte)[]) sink)
    {
        if (sink is null)
        {
            throw new ZipPackagerException("Output sink delegate cannot be null");
        }
        if (!exists(baseDir) || !isDir(baseDir))
        {
            throw new ZipPackagerException(format("Workspace base directory does not exist or is not a directory: %s", baseDir));
        }
        if (patterns.length == 0)
        {
            throw new ZipPackagerException("At least one file or glob pattern must be specified for packaging");
        }

        bool[string] matchedRelFiles;

        foreach (rawPattern; patterns)
        {
            if (rawPattern.length == 0)
            {
                throw new ZipPackagerException("Pattern cannot be empty");
            }

            string normPattern = normalizePattern(rawPattern);

            // 1. Check if pattern refers directly to an existing file
            string directFilePath = buildPath(baseDir, normPattern);
            if (exists(directFilePath) && isFile(directFilePath))
            {
                string rel = relativePath(absolutePath(directFilePath), absolutePath(baseDir)).replace("\\", "/");
                matchedRelFiles[rel] = true;
                continue;
            }

            // 2. Check if pattern refers directly to an existing directory
            if (exists(directFilePath) && isDir(directFilePath))
            {
                foreach (entry; dirEntries(directFilePath, SpanMode.depth))
                {
                    if (entry.isFile)
                    {
                        string rel = relativePath(absolutePath(entry.name), absolutePath(baseDir)).replace("\\", "/");
                        matchedRelFiles[rel] = true;
                    }
                }
                continue;
            }

            // 3. Glob matching across workspace
            foreach (entry; dirEntries(baseDir, SpanMode.depth))
            {
                if (entry.isFile)
                {
                    string rel = relativePath(absolutePath(entry.name), absolutePath(baseDir)).replace("\\", "/");
                    if (matchesPattern(rel, normPattern))
                    {
                        matchedRelFiles[rel] = true;
                    }
                }
            }
        }

        if (matchedRelFiles.length == 0)
        {
            throw new ZipPackagerException(format("Declared output pattern(s) %s did not match any files in workspace '%s'", patterns, baseDir));
        }

        auto zip = new ZipArchive();
        foreach (relPath; matchedRelFiles.byKey)
        {
            string fullPath = buildPath(baseDir, relPath);
            ubyte[] content = cast(ubyte[]) read(fullPath);

            auto member = new ArchiveMember();
            member.name = relPath;
            member.expandedData = content;
            member.compressionMethod = CompressionMethod.deflate;
            zip.addMember(member);
        }

        void[] zipData = zip.build();
        const(ubyte)[] zipBytes = cast(const(ubyte)[]) zipData;

        // Stream zip payload in 64KB chunks
        enum size_t chunkSize = 64 * 1024;
        size_t offset = 0;
        while (offset < zipBytes.length)
        {
            size_t end = offset + chunkSize;
            if (end > zipBytes.length) end = zipBytes.length;
            sink(zipBytes[offset .. end]);
            offset = end;
        }
    }

    /**
     * Packs files matching a single pattern into a zip archive and streams it to sink.
     */
    static void pack(string baseDir, string pattern, void delegate(const(ubyte)[]) sink)
    {
        pack(baseDir, [pattern], sink);
    }

    /**
     * Packs files matching the given patterns into a zip byte array.
     */
    static ubyte[] packToBytes(string baseDir, string[] patterns)
    {
        Appender!(ubyte[]) app;
        pack(baseDir, patterns, (const(ubyte)[] chunk) {
            app.put(chunk);
        });
        return app.data;
    }

    /**
     * Packs files matching a single pattern into a zip byte array.
     */
    static ubyte[] packToBytes(string baseDir, string pattern)
    {
        return packToBytes(baseDir, [pattern]);
    }

    /**
     * Unpacks a zip archive from raw bytes into the destination directory.
     * Validates entry names against directory traversal (zip-slip) attacks.
     *
     * Params:
     *   zipData = The raw zip archive byte payload.
     *   destinationDir = The target directory where entries will be extracted.
     */
    static void unpack(const(ubyte)[] zipData, string destinationDir)
    {
        if (destinationDir.length == 0)
        {
            throw new ZipPackagerException("Destination directory cannot be empty");
        }
        if (zipData.length == 0)
        {
            throw new ZipPackagerException("Cannot unpack empty zip archive data");
        }

        ZipArchive zip;
        try
        {
            zip = new ZipArchive(cast(void[]) zipData);
        }
        catch (Exception e)
        {
            throw new ZipPackagerException(format("Failed to parse zip archive (corrupt or invalid zip data): %s", e.msg), __FILE__, __LINE__, e);
        }

        if (!exists(destinationDir))
        {
            mkdirRecurse(destinationDir);
        }

        string absDest = absolutePath(destinationDir);

        foreach (name, member; zip.directory)
        {
            string entryName = member.name;
            validateZipEntryName(entryName, destinationDir, absDest);

            string normalizedTarget = buildNormalizedPath(destinationDir, entryName);

            // Expand member data
            try
            {
                zip.expand(member);
            }
            catch (Exception e)
            {
                throw new ZipPackagerException(format("Failed to expand zip entry '%s': %s", entryName, e.msg), __FILE__, __LINE__, e);
            }

            if (entryName.endsWith("/") || entryName.endsWith("\\"))
            {
                if (!exists(normalizedTarget))
                {
                    mkdirRecurse(normalizedTarget);
                }
            }
            else
            {
                string parentDir = dirName(normalizedTarget);
                if (parentDir.length > 0 && !exists(parentDir))
                {
                    mkdirRecurse(parentDir);
                }
                write(normalizedTarget, member.expandedData);
            }
        }
    }

    /**
     * Unpacks a zip stream provided by a chunk supplier into the destination directory.
     */
    static void unpackStream(void delegate(void delegate(const(ubyte)[])) chunkProvider, string destinationDir)
    {
        if (chunkProvider is null)
        {
            throw new ZipPackagerException("Chunk provider delegate cannot be null");
        }
        Appender!(ubyte[]) buffer;
        chunkProvider((const(ubyte)[] chunk) {
            buffer.put(chunk);
        });
        unpack(buffer.data, destinationDir);
    }

    private static string normalizePattern(string rawPattern)
    {
        string p = rawPattern.replace("\\", "/");
        while (p.startsWith("./"))
        {
            p = p[2 .. $];
        }
        return p;
    }

    private static bool matchesPattern(string relPath, string pattern)
    {
        import std.path : dirSeparator;
        import std.string : lastIndexOf;

        string normRel = relPath.replace("\\", "/");
        string normPat = pattern.replace("\\", "/");

        // 1. Exact match
        if (normRel == normPat) return true;

        // 2. Native separator glob match & slash glob match
        string nativeRel = normRel.replace("/", dirSeparator);
        string nativePat = normPat.replace("/", dirSeparator);
        if (globMatch(nativeRel, nativePat)) return true;
        if (globMatch(normRel, normPat)) return true;

        // 3. Match baseName if pattern has no directory separators
        if (!normPat.canFind('/'))
        {
            if (globMatch(baseName(normRel), normPat)) return true;
        }

        // 4. Wildcard prefix directory match: e.g. "bin/*" or "bin/**"
        if (normPat.endsWith("/*"))
        {
            string prefix = normPat[0 .. $ - 2];
            if (normRel.startsWith(prefix ~ "/") || normRel == prefix) return true;
        }
        if (normPat.endsWith("/**"))
        {
            string prefix = normPat[0 .. $ - 3];
            if (normRel.startsWith(prefix ~ "/") || normRel == prefix) return true;
        }

        // 5. Pattern with directory prefix and filename glob (e.g. "config/*.json")
        ptrdiff_t lastSlash = normPat.lastIndexOf('/');
        if (lastSlash >= 0)
        {
            string patDir = normPat[0 .. lastSlash];
            string patFile = normPat[lastSlash + 1 .. $];
            ptrdiff_t relLastSlash = normRel.lastIndexOf('/');
            if (relLastSlash >= 0)
            {
                string rDir = normRel[0 .. relLastSlash];
                string rFile = normRel[relLastSlash + 1 .. $];
                if ((rDir == patDir || globMatch(rDir, patDir)) && globMatch(rFile, patFile))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static void validateZipEntryName(string entryName, string destinationDir, string absDest)
    {
        if (entryName.length == 0)
        {
            return;
        }

        // Reject absolute paths
        if (entryName.startsWith("/") || entryName.startsWith("\\"))
        {
            throw new ZipPackagerException(format("Zip entry contains absolute path: %s", entryName));
        }

        // Reject Windows drive letters like C:
        if (entryName.length >= 2 && entryName[1] == ':')
        {
            throw new ZipPackagerException(format("Zip entry contains drive specification: %s", entryName));
        }

        // Reject directory traversal segments
        string normalized = entryName.replace("\\", "/");
        auto parts = normalized.split("/");
        foreach (part; parts)
        {
            if (part == "..")
            {
                throw new ZipPackagerException(format("Zip entry contains directory traversal ('..'): %s", entryName));
            }
        }

        // Verify resolved path is strictly within destination directory
        string normalizedTarget = buildNormalizedPath(destinationDir, entryName);
        string absTarget = absolutePath(normalizedTarget);

        if (absTarget.length < absDest.length || !absTarget.startsWith(absDest))
        {
            throw new ZipPackagerException(format("Zip slip detected: entry '%s' escapes destination directory '%s'", entryName, destinationDir));
        }
        if (absTarget.length > absDest.length && !isDirSeparator(absTarget[absDest.length]) && !isDirSeparator(absDest[$ - 1]))
        {
            throw new ZipPackagerException(format("Zip slip detected: entry '%s' escapes destination directory '%s'", entryName, destinationDir));
        }
    }
}

unittest
{
    import std.file : rmdirRecurse;

    string testRoot = buildPath(".test_zip_packager_work");
    if (exists(testRoot)) rmdirRecurse(testRoot);
    scope(exit) if (exists(testRoot)) rmdirRecurse(testRoot);

    string wsDir = buildPath(testRoot, "workspace");
    string outDir = buildPath(testRoot, "extracted");
    mkdirRecurse(buildPath(wsDir, "bin"));
    mkdirRecurse(buildPath(wsDir, "config"));
    mkdirRecurse(buildPath(wsDir, "src", "nested"));

    write(buildPath(wsDir, "bin", "app.exe"), "binary data 123");
    write(buildPath(wsDir, "bin", "helper.dll"), "helper dll bytes");
    write(buildPath(wsDir, "config", "settings.json"), "{\"key\": \"value\"}");
    write(buildPath(wsDir, "src", "nested", "main.d"), "void main() {}");

    // Test 1: Pack with multiple glob patterns and unpack
    ubyte[] zipBytes = ZipPackager.packToBytes(wsDir, ["bin/*", "config/*.json"]);
    assert(zipBytes.length > 0);

    ZipPackager.unpack(zipBytes, outDir);
    assert(exists(buildPath(outDir, "bin", "app.exe")));
    assert(exists(buildPath(outDir, "bin", "helper.dll")));
    assert(exists(buildPath(outDir, "config", "settings.json")));
    assert(!exists(buildPath(outDir, "src", "nested", "main.d")));
    assert(cast(string) read(buildPath(outDir, "bin", "app.exe")) == "binary data 123");
    assert(cast(string) read(buildPath(outDir, "config", "settings.json")) == "{\"key\": \"value\"}");

    // Test 2: Pack direct file
    string outDir2 = buildPath(testRoot, "extracted2");
    ubyte[] singleZip = ZipPackager.packToBytes(wsDir, "src/nested/main.d");
    ZipPackager.unpack(singleZip, outDir2);
    assert(exists(buildPath(outDir2, "src", "nested", "main.d")));
    assert(cast(string) read(buildPath(outDir2, "src", "nested", "main.d")) == "void main() {}");

    // Test 3: Empty match throws exception
    bool caughtEmpty = false;
    try
    {
        ZipPackager.packToBytes(wsDir, "nonexistent/*");
    }
    catch (ZipPackagerException e)
    {
        caughtEmpty = true;
    }
    assert(caughtEmpty);

    // Test 4: Corrupt zip data throws exception
    bool caughtCorrupt = false;
    try
    {
        ubyte[] corrupt = [0, 1, 2, 3, 4, 5];
        ZipPackager.unpack(corrupt, outDir);
    }
    catch (ZipPackagerException e)
    {
        caughtCorrupt = true;
    }
    assert(caughtCorrupt);

    // Test 5: Stream-based pack and unpack
    string outDir3 = buildPath(testRoot, "extracted3");
    Appender!(ubyte[]) streamBuffer;
    ZipPackager.pack(wsDir, ["bin/app.exe"], (const(ubyte)[] chunk) {
        streamBuffer.put(chunk);
    });
    ZipPackager.unpackStream((sink) {
        sink(streamBuffer.data);
    }, outDir3);
    assert(exists(buildPath(outDir3, "bin", "app.exe")));
    assert(cast(string) read(buildPath(outDir3, "bin", "app.exe")) == "binary data 123");
}
