/// wind — pre-build tool that produces sand for ground's CTFE.
///
/// 1. Concatenates controls/*.pbt and controls/local/*.pbt into .ctfe/sand.
/// 2. Parses project { path: "..." } blocks from sand.
/// 3. Walks project directories, outputs filenames to .ctfe/vocab.

import std.file : dirEntries, read, SpanMode, mkdirRecurse, exists, write, isDir;
import std.algorithm : sort, endsWith, startsWith, canFind;
import std.array : array;
import std.path : baseName;
import std.stdio : stderr;
import std.string : strip, indexOf;

void main() {
    mkdirRecurse(".ctfe");

    // --- Phase 1: concatenate pbt → sand ---
    string sand;

    foreach (dir; ["controls", "controls/local"]) {
        if (!exists(dir)) continue;
        auto entries = dirEntries(dir, "*.pbt", SpanMode.shallow)
            .array
            .sort!((a, b) => a.name < b.name);
        foreach (entry; entries) {
            auto content = cast(string) read(entry.name);
            sand ~= content;
            if (sand.length > 0 && sand[$ - 1] != '\n')
                sand ~= '\n';
        }
    }

    write(".ctfe/sand", sand);
    stderr.writefln("wind: .ctfe/sand (%d bytes)", sand.length);

    // --- Phase 2: extract project paths from sand ---
    auto paths = extractProjectPaths(sand);

    // --- Phase 3: walk project directories → vocab ---
    string vocab;
    size_t fileCount;

    foreach (projectPath; paths) {
        if (!exists(projectPath) || !isDir(projectPath)) {
            stderr.writefln("wind: skip %s (not found)", projectPath);
            continue;
        }

        foreach (entry; dirEntries(projectPath, SpanMode.depth)) {
            if (entry.isDir) continue;
            auto name = entry.name;
            // Skip hidden dirs and build artifacts
            if (canFind(name, "/.") || canFind(name, "/node_modules/") ||
                canFind(name, "/.dub/"))
                continue;
            // Skip binary files — check first 512 bytes for null byte
            if (isBinary(name)) continue;
            vocab ~= name;
            vocab ~= '\n';
            fileCount++;
        }
    }

    write(".ctfe/vocab", vocab);
    stderr.writefln("wind: .ctfe/vocab (%d files from %d projects)", fileCount, paths.length);
}

/// Extracts path values from project { path: "..." } blocks.
/// Minimal parser — just finds project blocks and their path fields.
string[] extractProjectPaths(string input) {
    string[] paths;
    size_t pos = 0;

    while (pos < input.length) {
        // Skip whitespace and comments
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' ||
               input[pos] == '\n' || input[pos] == '\r'))
            pos++;
        if (pos >= input.length) break;
        if (input[pos] == '#') {
            while (pos < input.length && input[pos] != '\n') pos++;
            continue;
        }

        // Read word
        auto wordStart = pos;
        while (pos < input.length && input[pos] != ' ' && input[pos] != '\t' &&
               input[pos] != '\n' && input[pos] != '{')
            pos++;
        auto word = input[wordStart .. pos];

        // Strip mode suffix (project.r etc)
        auto dot = word.indexOf('.');
        auto base = dot >= 0 ? word[0 .. dot] : word;

        if (base == "project") {
            // Skip to {
            while (pos < input.length && input[pos] != '{') pos++;
            if (pos < input.length) pos++;
            // Parse inside project block
            auto path = parseProjectBlock(input, pos);
            if (path.length > 0)
                paths ~= path;
        } else if (input[pos .. $].startsWith("{")) {
            // Skip non-project blocks
            pos++;
            skipBlock(input, pos);
        }
    }
    return paths;
}

/// Parse inside a project { } block, return the path value.
string parseProjectBlock(ref string input, ref size_t pos) {
    string path;
    int depth = 1;

    while (pos < input.length && depth > 0) {
        // Skip whitespace and comments
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' ||
               input[pos] == '\n' || input[pos] == '\r'))
            pos++;
        if (pos >= input.length) break;
        if (input[pos] == '#') {
            while (pos < input.length && input[pos] != '\n') pos++;
            continue;
        }
        if (input[pos] == '}') { pos++; depth--; continue; }
        if (input[pos] == '{') { pos++; depth++; continue; }

        // Read key
        auto keyStart = pos;
        while (pos < input.length && input[pos] != ':' && input[pos] != ' ' &&
               input[pos] != '\t' && input[pos] != '\n' && input[pos] != '{')
            pos++;
        auto key = input[keyStart .. pos];

        // Skip to value
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t')) pos++;
        if (pos < input.length && input[pos] == ':') pos++;
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t')) pos++;

        if (pos < input.length && input[pos] == '"') {
            // Read quoted string
            pos++;
            auto valStart = pos;
            while (pos < input.length && input[pos] != '"') pos++;
            auto val = input[valStart .. pos];
            if (pos < input.length) pos++;

            if (key == "path" && depth == 1)
                path = val;
        } else if (pos < input.length && input[pos] == '[') {
            // Skip list
            while (pos < input.length && input[pos] != ']') pos++;
            if (pos < input.length) pos++;
        } else if (pos < input.length && input[pos] == '{') {
            // Nested block
            pos++;
            depth++;
        }
    }
    return path;
}

/// Check if a file is binary by looking for null bytes in the first 512 bytes.
bool isBinary(string path) {
    try {
        auto buf = cast(ubyte[]) read(path, 512);
        foreach (b; buf)
            if (b == 0) return true;
        return false;
    } catch (Exception) {
        return true; // can't read → skip
    }
}

/// Skip to matching } — handles nested blocks and quoted strings.
void skipBlock(ref string input, ref size_t pos) {
    int depth = 1;
    while (pos < input.length && depth > 0) {
        if (input[pos] == '"') {
            pos++;
            while (pos < input.length && input[pos] != '"') pos++;
            if (pos < input.length) pos++;
        } else if (input[pos] == '`') {
            pos++;
            while (pos < input.length && input[pos] != '`') pos++;
            if (pos < input.length) pos++;
        } else if (input[pos] == '{') { depth++; pos++; }
        else if (input[pos] == '}') { depth--; pos++; }
        else pos++;
    }
}
