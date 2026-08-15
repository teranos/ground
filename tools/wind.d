/// wind — pre-build tool that produces sand for ground's CTFE.
///
/// 1. Concatenates controls/*.pbt and controls/local/*.pbt into .ctfe/sand.
/// 2. Parses project { path: "..." } blocks from sand.
/// 3. Walks project directories, rewrites project blocks with files: [...].

import std.file : dirEntries, read, SpanMode, mkdirRecurse, exists, write, isDir;
import std.algorithm : sort;
import std.array : array;
import std.path : baseName, absolutePath, buildNormalizedPath;
import std.process : executeShell;
import std.stdio : stderr;
import std.string : indexOf, splitLines, strip;

import filelist : renderFileList;

void main() {
    mkdirRecurse(".ctfe");

    // --- Phase 1: concatenate pbt → sand ---
    string sand;

    // Every controls dir already folded into sand, normalised+absolute. Ground
    // is itself a declared project, so without this phase 1b re-reads the two
    // dirs phase 1 just consumed and every control lands in sand twice.
    bool[string] seenDirs;

    foreach (dir; ["controls", "controls/local"]) {
        if (!exists(dir)) continue;
        seenDirs[buildNormalizedPath(absolutePath(dir))] = true;
        sand ~= readPbtDir(dir);
    }

    // --- Phase 1b: pull each declared project's own controls into sand ---
    //
    // A project { path: "..." } block declares a repo ground knows about, and
    // that repo owns its controls: the pbt describing how to react to work in
    // it lives with the code it governs rather than in ground's tree. Same
    // layout as ground's own — <project>/controls/*.pbt and
    // <project>/controls/local/*.pbt.
    //
    // ONE LEVEL ONLY. Controls pulled from a project are not rescanned for
    // further project blocks, so a declared repo cannot drag a third repo's
    // controls in behind you.
    foreach (ref proj; extractProjectPaths(sand)) {
        foreach (sub; ["/controls", "/controls/local"]) {
            auto dir = buildNormalizedPath(absolutePath(proj.path ~ sub));
            if (dir in seenDirs) continue;
            if (!exists(dir) || !isDir(dir)) continue;
            seenDirs[dir] = true;
            auto pulled = readPbtDir(dir);
            if (pulled.length == 0) continue;
            sand ~= pulled;
            stderr.writefln("wind: + %s", dir);
        }
    }

    // --- Phase 1c: fold in directories an `include` names ---
    // A directory that is not a repo still holds pbt worth compiling. Naming it
    // as a project to get it read is what broke the git-tracked rule.
    foreach (dir; extractIncludes(sand)) {
        auto norm = buildNormalizedPath(absolutePath(dir));
        if (norm in seenDirs) continue;
        if (!exists(norm) || !isDir(norm)) {
            stderr.writefln("wind: include not found %s", norm);
            continue;
        }
        seenDirs[norm] = true;
        auto pulled = readPbtDir(norm);
        if (pulled.length == 0) continue;
        sand ~= pulled;
        stderr.writefln("wind: include %s", norm);
    }

    // --- Phase 2: extract project paths, walk dirs, append files ---
    auto projects = extractProjectPaths(sand);
    size_t totalFiles;

    foreach (ref proj; projects) {
        if (proj.envOnly) continue; // env-only projects don't need file lists
        if (!exists(proj.path) || !isDir(proj.path)) {
            stderr.writefln("wind: skip %s (not found)", proj.path);
            continue;
        }

        // git ls-files defers to .gitignore for what counts as a project file.
        // Source of truth lives in each project's gitignore, not in a hardcoded
        // exclusion list here.
        auto gitResult = executeShell("cd " ~ proj.path ~ " && git ls-files");
        if (gitResult.status != 0) {
            stderr.writefln("wind: skip %s (git ls-files exited %d)",
                proj.path, gitResult.status);
            continue;
        }
        string[] paths;
        foreach (line; splitLines(gitResult.output)) {
            if (line.length > 0) paths ~= line.idup;
        }
        auto fileList = renderFileList(paths);
        auto count = paths.length;

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
    bool envOnly;
}

/// Concatenate every *.pbt directly in `dir`, filename-sorted so sand is
/// byte-stable across runs. Shallow on purpose — a controls dir is a flat set
/// of pbt files, and recursing would make what compiles in depend on how
/// someone happened to nest their folders.
string readPbtDir(string dir) {
    string out_;
    auto entries = dirEntries(dir, "*.pbt", SpanMode.shallow)
        .array
        .sort!((a, b) => a.name < b.name);
    foreach (entry; entries) {
        out_ ~= cast(string) read(entry.name);
        if (out_.length > 0 && out_[$ - 1] != '\n')
            out_ ~= '\n';
    }
    return out_;
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

/// `include "/abs/path"` — fold another directory's pbt in. Not a declaration:
/// it adds no project, so the rule that a project path is a git-tracked repo
/// stays intact and repoRoot is untouched.
string[] extractIncludes(string input) {
    string[] dirs;
    foreach (line; input.splitLines()) {
        auto t = line.strip();
        if (t.length < 7 || t[0 .. 7] != "include") continue;
        auto q1 = t.indexOf('"');
        if (q1 < 0) continue;
        auto q2 = t.indexOf('"', q1 + 1);
        if (q2 <= q1) continue;
        dirs ~= t[q1 + 1 .. q2].idup;
    }
    return dirs;
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

        // `include` has no block. Scanning on to the next `{` would swallow
        // whatever declaration follows it.
        if (base == "include") {
            while (pos < input.length && input[pos] != '\n') pos++;
            continue;
        }

        while (pos < input.length && input[pos] != '{') pos++;
        if (pos >= input.length) break;
        pos++;

        if (base == "project") {
            auto blockStart = pos;
            auto path = findPathInBlock(input, pos);
            // Check if block contains "env {" — env-only projects skip file walking
            bool hasEnv = false;
            {
                auto scan = blockStart;
                int d = 1;
                while (scan < input.length && d > 0) {
                    if (input[scan] == '"') { scan++; while (scan < input.length && input[scan] != '"') scan++; if (scan < input.length) scan++; }
                    else if (input[scan] == '{') { d++; scan++; }
                    else if (input[scan] == '}') { d--; scan++; }
                    else {
                        if (scan + 3 < input.length && input[scan .. scan + 3] == "env")
                            hasEnv = true;
                        scan++;
                    }
                }
            }
            if (path.length > 0)
                projects ~= ProjectInfo(path, hasEnv);
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
