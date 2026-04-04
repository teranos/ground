/// wind — pre-build tool that produces sand for ground's CTFE.
///
/// 1. Concatenates controls/*.pbt and controls/local/*.pbt into .ctfe/sand.
/// 2. Parses project { path: "..." } blocks from sand.
/// 3. Walks project directories, rewrites project blocks with files: [...].

import std.file : dirEntries, read, SpanMode, mkdirRecurse, exists, write, isDir;
import std.algorithm : sort, canFind;
import std.array : array;
import std.path : baseName, relativePath;
import std.stdio : stderr;
import std.string : indexOf;

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

    // --- Phase 2: extract project paths, walk dirs, append files ---
    auto projects = extractProjectPaths(sand);
    size_t totalFiles;

    foreach (ref proj; projects) {
        if (!exists(proj.path) || !isDir(proj.path)) {
            stderr.writefln("wind: skip %s (not found)", proj.path);
            continue;
        }

        string fileList;
        size_t count;
        foreach (entry; dirEntries(proj.path, SpanMode.depth)) {
            if (entry.isDir) continue;
            auto name = entry.name;
            if (canFind(name, "/.") || canFind(name, "/node_modules/") ||
                canFind(name, "/.dub/"))
                continue;
            if (isBinary(name)) continue;
            auto rel = relativePath(name, proj.path);
            if (count > 0) fileList ~= ",\n";
            fileList ~= "    \"" ~ rel ~ "\"";
            count++;
        }

        if (count > 0) {
            // Rewrite the project block: inject files before closing }
            auto projBlock = findProjectClose(sand, proj.path);
            if (projBlock >= 0) {
                sand = sand[0 .. projBlock] ~
                    "  files: [\n" ~ fileList ~ "\n  ]\n" ~
                    sand[projBlock .. $];
            }
        }
        totalFiles += count;
    }

    write(".ctfe/sand", sand);
    stderr.writefln("wind: .ctfe/sand (%d bytes, %d files from %d projects)",
        sand.length, totalFiles, projects.length);
}

struct ProjectInfo {
    string path;
}

/// Find the closing } of the project block that contains the given path.
/// Returns the index just before the }, or -1 if not found.
long findProjectClose(string input, string path) {
    size_t pos = 0;

    while (pos < input.length) {
        // Skip whitespace
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' ||
               input[pos] == '\n' || input[pos] == '\r'))
            pos++;
        if (pos >= input.length) break;
        if (input[pos] == '#') {
            while (pos < input.length && input[pos] != '\n') pos++;
            continue;
        }

        auto wordStart = pos;
        while (pos < input.length && input[pos] != ' ' && input[pos] != '\t' &&
               input[pos] != '\n' && input[pos] != '{')
            pos++;
        auto word = input[wordStart .. pos];
        auto dot = word.indexOf('.');
        auto base = dot >= 0 ? word[0 .. dot] : word;

        // Skip to {
        while (pos < input.length && input[pos] != '{') pos++;
        if (pos >= input.length) break;
        pos++;

        if (base == "project") {
            // Check if this project has our path
            auto blockPath = findPathInBlock(input, pos);
            if (blockPath == path) {
                // Find the closing } at depth 1
                int depth = 1;
                while (pos < input.length && depth > 0) {
                    if (input[pos] == '"') {
                        pos++;
                        while (pos < input.length && input[pos] != '"') pos++;
                        if (pos < input.length) pos++;
                    } else if (input[pos] == '{') { depth++; pos++; }
                    else if (input[pos] == '}') {
                        depth--;
                        if (depth == 0) return cast(long) pos;
                        pos++;
                    }
                    else pos++;
                }
            } else {
                skipBlock(input, pos);
            }
        } else {
            skipBlock(input, pos);
        }
    }
    return -1;
}

/// Find `path: "..."` inside a block (without consuming past the block).
string findPathInBlock(string input, size_t startPos) {
    auto pos = startPos;
    int depth = 1;
    while (pos < input.length && depth > 0) {
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' ||
               input[pos] == '\n' || input[pos] == '\r'))
            pos++;
        if (pos >= input.length) break;
        if (input[pos] == '}') return null;
        if (input[pos] == '{') { pos++; depth++; continue; }

        auto keyStart = pos;
        while (pos < input.length && input[pos] != ':' && input[pos] != ' ' &&
               input[pos] != '\t' && input[pos] != '\n' && input[pos] != '{')
            pos++;
        auto key = input[keyStart .. pos];

        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t')) pos++;
        if (pos < input.length && input[pos] == ':') pos++;
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t')) pos++;

        if (pos < input.length && input[pos] == '"') {
            pos++;
            auto valStart = pos;
            while (pos < input.length && input[pos] != '"') pos++;
            auto val = input[valStart .. pos];
            if (pos < input.length) pos++;
            if (key == "path") return val;
        }
    }
    return null;
}

/// Extracts project paths from pbt input.
ProjectInfo[] extractProjectPaths(string input) {
    ProjectInfo[] projects;
    size_t pos = 0;

    while (pos < input.length) {
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' ||
               input[pos] == '\n' || input[pos] == '\r'))
            pos++;
        if (pos >= input.length) break;
        if (input[pos] == '#') {
            while (pos < input.length && input[pos] != '\n') pos++;
            continue;
        }

        auto wordStart = pos;
        while (pos < input.length && input[pos] != ' ' && input[pos] != '\t' &&
               input[pos] != '\n' && input[pos] != '{')
            pos++;
        auto word = input[wordStart .. pos];
        auto dot = word.indexOf('.');
        auto base = dot >= 0 ? word[0 .. dot] : word;

        while (pos < input.length && input[pos] != '{') pos++;
        if (pos >= input.length) break;
        pos++;

        if (base == "project") {
            auto path = findPathInBlock(input, pos);
            if (path.length > 0)
                projects ~= ProjectInfo(path);
            skipBlock(input, pos);
        } else {
            skipBlock(input, pos);
        }
    }
    return projects;
}

/// Check if a file is binary by looking for null bytes in the first 512 bytes.
bool isBinary(string path) {
    try {
        auto buf = cast(ubyte[]) read(path, 512);
        foreach (b; buf)
            if (b == 0) return true;
        return false;
    } catch (Exception) {
        return true;
    }
}

/// Skip to matching }.
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
