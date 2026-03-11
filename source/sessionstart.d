module sessionstart;

import core.stdc.stdio : stdout, stderr, fputs, fwrite, FILE, fopen, fread, fclose;

extern (C) FILE* popen(const(char)* command, const(char)* mode);
extern (C) int pclose(FILE* stream);
import matcher : contains, indexOf;

// Only arch — Claude already receives Platform and OS Version from the environment.
version (X86_64) enum ARCH = "x86_64";
else version (AArch64) enum ARCH = "aarch64";
else enum ARCH = "unknown";

enum SESSION_CONTEXT = `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"arch: ` ~ ARCH ~ `"}}` ~ "\n";

// FNV-1a hash — works in both CTFE and runtime
uint fnv1a(const(char)[] data) {
    uint h = 2166136261;
    foreach (b; data) {
        h ^= b;
        h *= 16777619;
    }
    return h;
}

// Compile-time hash of controls source
enum CONTROLS_HASH = fnv1a(import("controls/controls.d") ~ import("source/hooks.d"));


// Check if controls source has changed since compilation.
// Hashes controls.d and hooks.d from disk, compares to compile-time hash.
bool controlsAreStale(const(char)[] cwd) {
    if (cwd is null || cwd.length == 0) return false;

    __gshared char[4096] pathBuf;
    __gshared char[131072] concat;
    size_t total = 0;

    static foreach (suffix; ["/source/controls.d", "/source/hooks.d"]) {{
        if (cwd.length + suffix.length + 1 > pathBuf.length) return false;
        foreach (j, c; cwd) pathBuf[j] = c;
        foreach (j, c; suffix) pathBuf[cwd.length + j] = c;
        pathBuf[cwd.length + suffix.length] = 0;

        auto f = fopen(&pathBuf[0], "r");
        if (f is null) return false;
        auto n = fread(&concat[total], 1, concat.length - total, f);
        fclose(f);
        if (n == 0) return false;
        total += n;
    }}

    return fnv1a(concat[0 .. total]) != CONTROLS_HASH;
}

enum VERSION = import(".version");

// Compare two version strings like "0.6.0" lexicographically by numeric segments.
// Returns true if remote > local.
bool isNewerVersion(const(char)[] remote, const(char)[] local) {
    // Strip leading 'v' if present
    if (remote.length > 0 && remote[0] == 'v') remote = remote[1 .. $];
    if (local.length > 0 && local[0] == 'v') local = local[1 .. $];

    // Compare up to 3 numeric segments
    foreach (_; 0 .. 3) {
        int r = 0, l = 0;
        while (remote.length > 0 && remote[0] >= '0' && remote[0] <= '9') {
            r = r * 10 + (remote[0] - '0');
            remote = remote[1 .. $];
        }
        while (local.length > 0 && local[0] >= '0' && local[0] <= '9') {
            l = l * 10 + (local[0] - '0');
            local = local[1 .. $];
        }
        if (r > l) return true;
        if (r < l) return false;
        // Skip '.' separator
        if (remote.length > 0 && remote[0] == '.') remote = remote[1 .. $];
        if (local.length > 0 && local[0] == '.') local = local[1 .. $];
    }
    return false;
}

// Check if a newer release exists on GitHub.
// Returns the newer version string, or null if current is up to date.
const(char)[] checkTagStaleness() {
    // Strip VERSION to just the tag part (e.g. "0.6.0-3-gabcdef\n" → "0.6.0")
    __gshared char[64] localVer;
    size_t localLen = 0;
    foreach (c; VERSION) {
        if (c == '-' || c == '\n' || c == '\r' || c == '+') break;
        if (localLen < localVer.length) localVer[localLen++] = c;
    }
    if (localLen == 0) return null;

    auto pipe = popen("curl -sf https://api.github.com/repos/teranos/graunde/releases/latest 2>/dev/null", "r");
    if (pipe is null) return null;

    __gshared char[16384] buf;
    auto n = fread(&buf[0], 1, buf.length, pipe);
    pclose(pipe);
    if (n == 0) return null;

    // Extract "tag_name":"<value>" from JSON
    auto data = buf[0 .. n];
    auto idx = indexOf(data, `"tag_name"`);
    if (idx < 0) return null;

    // Find the value after the colon and opening quote
    auto start = cast(size_t)idx + 10; // skip "tag_name"
    while (start < data.length && data[start] != '"') start++;
    start++; // skip opening quote
    auto end = start;
    while (end < data.length && data[end] != '"') end++;
    if (end <= start) return null;

    auto remoteTag = data[start .. end];
    __gshared char[64] remoteBuf;
    if (remoteTag.length > remoteBuf.length) return null;
    foreach (j, c; remoteTag) remoteBuf[j] = c;

    if (isNewerVersion(remoteBuf[0 .. remoteTag.length], localVer[0 .. localLen]))
        return remoteBuf[0 .. remoteTag.length];
    return null;
}

// Graunded Types — QNTX Attestation Schema
//
// Attested on every SessionStart so QNTX knows what to do with the data.
// ID: graunde:type:<name>:<version> — re-attested when graunde updates.
// INSERT OR IGNORE prevents duplicates within the same version.
//
// Event types — attributes contain the raw Claude Code hook payload, verbatim.
// Type definitions specify rich_string_fields so QNTX knows which fields are long text.
//
// Grounded types — when graunde acts on an event, a separate attestation records
// only graunde's own decisions. Claude's payload stays in the event attestation.
//   GraundedPreToolUse: control, decision
//   GraundedStop:       control
//   GraundedUserPromptSubmit: control
//
// Schema: see sqlite.d attestType / attestEvent.
//
// TODO: verify every event type's payload fields for rich string eligibility.
// Only UserPromptSubmit (prompt) and Stop (last_assistant_message) confirmed so far.
void attestTypes() {
    import sqlite : openDb, attestType, sqlite3_close;
    auto db = openDb();
    if (db is null) return;

    // Event types — <Type> is type of ClaudeCode
    static foreach (name; [
        "SessionStart", "PermissionRequest", "PreToolUse",
        "PostToolUse", "PostToolUseFailure", "Notification",
        "SubagentStart", "SubagentStop", "TeammateIdle",
        "TaskCompleted", "ConfigChange", "WorktreeCreate",
        "WorktreeRemove", "PreCompact", "Setup", "SessionEnd"
    ])
        attestType(db, name, "ClaudeCode", `{}`);

    attestType(db, "UserPromptSubmit", "ClaudeCode", `{}`);
    attestType(db, "Stop", "ClaudeCode", `{}`);

    // Grounded types — <Type> is type of Graunded
    attestType(db, "GraundedPreToolUse", "Graunded", `{}`);
    attestType(db, "GraundedStop", "Graunded", `{}`);
    attestType(db, "GraundedUserPromptSubmit", "Graunded", `{}`);

    sqlite3_close(db);
}

// TODO: extract and attest `model` field — track which model worked on what
// TODO: extract `agent_type` field — adjust controls for agent vs interactive sessions
int handleSessionStart(const(char)[] source, const(char)[] cwd) {
    attestTypes();

    // Check for project-scoped deferred messages (from QNTX)
    const(char)[] projectNews = null;
    {
        import sqlite : openDb, sqlite3_close;
        import deferred : readProjectDeferredMessage, markProjectDelivered;
        auto db = openDb();
        if (db !is null) {
            auto projDeferred = readProjectDeferredMessage(db, cwd);
            if (projDeferred.message !is null) {
                markProjectDelivered(db, projDeferred.name, projDeferred.projectContext);
                projectNews = projDeferred.message;
            }
            sqlite3_close(db);
        }
    }

    bool isStartup = source is null || contains(source, "startup") || contains(source, "clear");

    bool stale = isStartup && controlsAreStale(cwd);
    const(char)[] newerTag = isStartup ? checkTagStaleness() : null;

    if (isStartup || projectNews !is null || stale || newerTag !is null) {
        import parse : writeJsonString;
        fputs(`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"`, stdout);
        if (isStartup)
            fputs("arch: " ~ ARCH, stdout);
        if (stale)
            fputs(" | graunde binary is out of date with source — recompile with dub test && make install", stdout);
        if (newerTag !is null) {
            fputs(" | graunde ", stdout);
            fwrite(newerTag.ptr, 1, newerTag.length, stdout);
            fputs(" is available at https://github.com/teranos/graunde/releases/latest", stdout);
        }
        if (isStartup && cwd !is null && contains(cwd, "/QNTX"))
            fputs(" | am.toml in the project root has the db path and node configuration. Check it before assuming database locations.", stdout);
        if (isStartup && projectNews !is null)
            fputs(" | ", stdout);
        if (projectNews !is null)
            writeJsonString(projectNews);
        fputs(`"}}` ~ "\n", stdout);
        return 0;
    }

    // TODO: compact — compaction summary may lose session-specific context graunde injected.
    //   Re-inject reminders and session state that got lost.
    // TODO: resume — happens after time away. Merges may have landed on main, branch may be stale.
    //   Check branch staleness against main, surface recent upstream changes.
    return 0;
}
