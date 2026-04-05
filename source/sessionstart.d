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

    auto pipe = popen("curl -sf https://api.github.com/repos/teranos/ground/releases/latest 2>/dev/null", "r");
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

// Grounded Types — QNTX Attestation Schema
//
// Attested on every SessionStart so QNTX knows what to do with the data.
// ID: ground:type:<name>:<version> — re-attested when ground updates.
// INSERT OR IGNORE prevents duplicates within the same version.
//
// Event types — attributes contain the raw Claude Code hook payload, verbatim.
// Type definitions specify rich_string_fields so QNTX knows which fields are long text.
//
// Grounded types — when ground acts on an event, a separate attestation records
// only ground's own decisions. Claude's payload stays in the event attestation.
//   GroundedPreToolUse: control, decision
//   GroundedStop:       control
//   GroundedUserPromptSubmit: control
//
// Schema: see sqlite.d attestType / attestEvent.
//
void attestTypes() {
    import db : openDb, attestType, walCheckpoint, sqlite3_close;
    auto db = openDb();
    if (db is null) return;

    // Event types — <Type> is type of ClaudeCode
    static foreach (name; [
        "SessionStart", "UserPromptSubmit", "PermissionRequest",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Notification", "SubagentStart", "SubagentStop",
        "Stop", "TeammateIdle", "TaskCompleted",
        "ConfigChange", "WorktreeCreate", "WorktreeRemove",
        "PreCompact", "Setup", "InstructionsLoaded", "SessionEnd"
    ])
        attestType(db, name, "ClaudeCode", `{}`);

    // Grounded types — <Type> is type of Grounded
    attestType(db, "GroundedPreToolUse", "Grounded", `{}`);
    attestType(db, "GroundedStop", "Grounded", `{}`);
    attestType(db, "GroundedUserPromptSubmit", "Grounded", `{}`);
    attestType(db, "GroundedSessionStart", "Grounded", `{}`);
    attestType(db, "GroundedPreCompact", "Grounded", `{}`);
    attestType(db, "GroundedPostToolUse", "Grounded", `{}`);
    attestType(db, "GroundedPostToolUseFailure", "Grounded", `{}`);
    attestType(db, "GroundedPostToolUseDeferred", "Grounded", `{}`);

    walCheckpoint(db);
    sqlite3_close(db);
}

// TODO: extract and attest `model` field — track which model worked on what
// TODO: extract `agent_type` field — adjust controls for agent vs interactive sessions
int handleSessionStart(const(char)[] source, const(char)[] cwd, const(char)[] sessionId) {
    attestTypes();

    // Cache project part of subject for this session (avoids cwd drift when Claude cd's)
    if (sessionId !is null && cwd !is null) {
        import db : openDb, sqlite3_close, sqlite3_prepare_v2, sqlite3_bind_text,
                        sqlite3_step, sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT,
                        cwdTail, ZBuf;
        auto db = openDb();
        if (db !is null) {
            enum sql = "INSERT OR IGNORE INTO session_project (session_id, project) VALUES (?1, ?2)\0";
            sqlite3_stmt* stmt;
            if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
                __gshared ZBuf sidBuf;
                __gshared ZBuf projBuf;
                sidBuf.reset();
                sidBuf.put(sessionId);
                projBuf.reset();
                projBuf.put(cwdTail(cwd));
                sqlite3_bind_text(stmt, 1, sidBuf.ptr(), cast(int) sidBuf.len, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, projBuf.ptr(), cast(int) projBuf.len, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
            sqlite3_close(db);
        }
    }

    // Check for project-scoped deferred messages (from QNTX)
    const(char)[] projectNews = null;
    {
        import db : openDb, sqlite3_close;
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

    const(char)[] newerTag = isStartup ? checkTagStaleness() : null;

    // Iterate sessionstart controls
    import controls : sessionStartScopes;
    import hooks : scopeMatches;
    import db : ZBuf;

    __gshared ZBuf ctx;
    ctx.reset();
    bool any = false;

    if (isStartup) {
        ctx.put("arch: " ~ ARCH);
        any = true;

        foreach (ref sc; sessionStartScopes) {
            if (!scopeMatches(sc, cwd))
                continue;
            foreach (ref c; sc.controls) {
                if (c.sessionstart.check !is null && !c.sessionstart.check(cwd))
                    continue;

                // Interval check — skip if fired too recently
                if (c.interval > 0) {
                    import db : openDb, sqlite3_close, sqlite3_prepare_v2,
                                    sqlite3_step, sqlite3_finalize, sqlite3_stmt,
                                    sqlite3_bind_text, sqlite3_bind_int64,
                                    SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
                    auto idb = openDb();
                    if (idb !is null) {
                        enum intervalSql = "SELECT 1 FROM attestations WHERE json_extract(attributes, '$.control') = ?1 AND json_extract(predicates, '$[0]') = 'GroundedSessionStart' AND timestamp > datetime('now', '-' || ?2 || ' seconds') LIMIT 1\0";
                        sqlite3_stmt* istmt;
                        if (sqlite3_prepare_v2(idb, intervalSql.ptr, -1, &istmt, null) == SQLITE_OK) {
                            sqlite3_bind_text(istmt, 1, c.name.ptr, cast(int) c.name.length, SQLITE_TRANSIENT);
                            sqlite3_bind_int64(istmt, 2, c.interval);
                            bool fresh = sqlite3_step(istmt) == SQLITE_ROW;
                            sqlite3_finalize(istmt);
                            sqlite3_close(idb);
                            if (fresh) continue; // fired recently, skip
                        } else {
                            sqlite3_close(idb);
                        }
                    }
                }

                if (c.sessionstart.deliver !is null) {
                    auto delivered = c.sessionstart.deliver(cwd);
                    if (delivered is null) continue;
                    if (any) ctx.put(" | ");
                    ctx.put(delivered);
                } else {
                    if (any) ctx.put(" | ");
                    ctx.put(c.msg.value);
                }
                any = true;

                // Attest the fire
                {
                    import db : attestControlFire;
                    attestControlFire(null, "GroundedSessionStart", c.name, cwd, sessionId);
                }
            }
        }
    }

    if (newerTag !is null) {
        if (any) ctx.put(" | ");
        ctx.put("ground ");
        ctx.put(newerTag);
        ctx.put(" is available at https://github.com/teranos/ground/releases/latest");
        any = true;
    }

    if (projectNews !is null) {
        import parse : writeJsonString;
        if (any) ctx.put(" | ");
        // projectNews needs JSON escaping — write directly
        fputs(`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"`, stdout);
        fwrite(&ctx.data[0], 1, ctx.len, stdout);
        writeJsonString(projectNews);
        fputs(`"}}` ~ "\n", stdout);
        return 0;
    }

    if (any) {
        fputs(`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"`, stdout);
        fwrite(&ctx.data[0], 1, ctx.len, stdout);
        fputs(`"}}` ~ "\n", stdout);
        return 0;
    }

    // TODO: compact — compaction summary may lose session-specific context ground injected.
    //   Re-inject reminders and session state that got lost.
    // TODO: resume — happens after time away. Merges may have landed on main, branch may be stale.
    //   Check branch staleness against main, surface recent upstream changes.
    return 0;
}
