module main;

// Hook output reference — ground responds via exit code and optional JSON on stdout.
//
// Exit codes:
//   0     — action proceeds, stdout parsed for JSON
//   2     — action blocked, stderr fed to Claude as error
//   other — non-blocking error, action proceeds
//
// Top-level response fields:
//   continue           — (Stop) true makes Claude continue instead of stopping
//   suppressOutput     — suppress hook output from display
//   decision           — "approve" or "block"
//   reason             — explanation for the decision
//   systemMessage      — injected as system message to Claude
//   permissionDecision — "allow", "deny", or "ask"
//
// hookSpecificOutput (PreToolUse, UserPromptSubmit, PostToolUse):
//   hookEventName            — must match the event
//   permissionDecision       — (PreToolUse) "allow", "deny", or "ask"
//   permissionDecisionReason — (PreToolUse) shown to user (allow/ask) or Claude (deny)
//   updatedInput             — (PreToolUse) replaces tool input before execution
//   additionalContext        — (UserPromptSubmit required, PostToolUse optional) injected into context
//   sessionTitle             — (UserPromptSubmit) sets session title, same as /rename
//
// TODO: output fields ground doesn't emit yet:
//   suppressOutput  — could silence verbose hooks (e.g. build-timing)
//   continue:false + stopReason — halt Claude entirely, stronger than decision:block
//   systemMessage   — warning shown to user, separate from context injected to Claude
//
// Common input fields ground doesn't use yet:
//   permission_mode — "default", "plan", "acceptEdits", "auto", "dontAsk", "bypassPermissions"
//   tool_use_id     — unique per tool call, could track tool call chains

import parse : extractCwd, extractSessionId, extractHookEventName, extractSource;
import controls : HookEvent;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fwrite, FILE;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : isatty;

extern (C) {
    struct timeval { long tv_sec; long tv_usec; }
    int gettimeofday(timeval* tv, void* tz);
}

long usecNow() {
    timeval tv;
    gettimeofday(&tv, null);
    return tv.tv_sec * 1_000_000 + tv.tv_usec;
}

// Parse hook_event_name string to HookEvent. CTFE-unrolled.
bool parseHookEvent(const(char)[] name, ref HookEvent event) {
    static foreach (member; __traits(allMembers, HookEvent)) {
        if (name == member) {
            event = __traits(getMember, HookEvent, member);
            return true;
        }
    }
    return false;
}

// Reads all of stdin into a static buffer.
// Returns the filled slice, or null on failure/empty.
const(char)[] readStdin() {
    __gshared char[262144] buf = 0; // 256KB — Edit payloads can exceed 64KB
    size_t total = 0;

    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return null;
    return buf[0 .. total];
}


enum VERSION = import(".version");
enum BUILDDATE = import(".builddate");

void printVersion() {
    fputs("ground ", stderr);
    foreach (c; VERSION)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
    fputs(" built ", stderr);
    foreach (c; BUILDDATE)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
}

size_t argLen(const(char)* ptr) {
    size_t len = 0;
    while (ptr[len] != 0) len++;
    return len;
}

void printDuration(long t0) {
    auto elapsed = usecNow() - t0;
    auto ms = elapsed / 1000;
    auto us = elapsed % 1000;
    // Write "ground: XXms" to stderr
    char[32] buf = 0;
    int pos = 0;
    // ms part
    if (ms == 0) { buf[pos++] = '0'; }
    else {
        char[10] digits = 0;
        int dLen = 0;
        auto v = ms;
        while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. dLen) buf[pos++] = digits[dLen - 1 - i];
    }
    buf[pos++] = '.';
    // us part — zero-padded to 3 digits
    buf[pos++] = cast(char)('0' + us / 100);
    buf[pos++] = cast(char)('0' + (us / 10) % 10);
    buf[pos++] = cast(char)('0' + us % 10);
    buf[pos++] = 'm';
    buf[pos++] = 's';
    fputs("ground: ", stderr);
    fwrite(&buf[0], 1, pos, stderr);
    fputs("\n", stderr);
}

// Phase breakdown string — handlers write here, main persists it.
__gshared char[512] g_phasesBuf = 0;
__gshared size_t g_phasesLen = 0;

void setPhases(const(char)[] s) {
    auto n = s.length < g_phasesBuf.length ? s.length : g_phasesBuf.length;
    foreach (i; 0 .. n) g_phasesBuf[i] = s[i];
    g_phasesLen = n;
}

const(char)[] getPhases() {
    return g_phasesBuf[0 .. g_phasesLen];
}

void recordTiming(long elapsedUs, const(char)[] hookEvent, const(char)[] project) {
    import db : openDb, sqlite3_exec, sqlite3_prepare_v2, sqlite3_bind_int64,
                    sqlite3_bind_text, sqlite3_step, sqlite3_finalize, sqlite3_close,
                    sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    auto db = openDb();
    if (db is null) return;

    enum createSql = "CREATE TABLE IF NOT EXISTS timing (id INTEGER PRIMARY KEY, duration_us INTEGER NOT NULL, hook_event TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    // Migrate: add hook_event column if missing
    enum migrateSql = "ALTER TABLE timing ADD COLUMN hook_event TEXT\0";
    sqlite3_exec(db, migrateSql.ptr, null, null, null);

    // Migrate: add project column for per-project timing
    enum migrateProject = "ALTER TABLE timing ADD COLUMN project TEXT\0";
    sqlite3_exec(db, migrateProject.ptr, null, null, null);

    // Migrate: add phases column for per-call breakdown
    enum migratePhases = "ALTER TABLE timing ADD COLUMN phases TEXT\0";
    sqlite3_exec(db, migratePhases.ptr, null, null, null);

    enum idxTiming = "CREATE INDEX IF NOT EXISTS idx_timing_event_project ON timing(hook_event, project, id)\0";
    sqlite3_exec(db, idxTiming.ptr, null, null, null);

    enum sql = "INSERT INTO timing (duration_us, hook_event, project, phases) VALUES (?1, ?2, ?3, ?4)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, elapsedUs);
        if (hookEvent.length > 0)
            sqlite3_bind_text(stmt, 2, hookEvent.ptr, cast(int) hookEvent.length, SQLITE_TRANSIENT);
        if (project.length > 0)
            sqlite3_bind_text(stmt, 3, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
        auto phases = getPhases();
        if (phases.length > 0)
            sqlite3_bind_text(stmt, 4, phases.ptr, cast(int) phases.length, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

extern (C) int main(int argc, const(char)** argv) {
    // CLI subcommand dispatch — ground shovel <event> <pattern>
    if (argc >= 2) {
        import shovel : handleShovel;
        const(char)[] cmd = argv[1][0 .. argLen(argv[1])];
        if (cmd == "shovel")
            return handleShovel(argc, argv);
        if (cmd == "attest") {
            import attest : handleAttest;
            return handleAttest();
        }
        if (cmd == "profile") {
            import profile : handleProfile;
            return handleProfile(argc, argv);
        }
        if (cmd == "decay") {
            import decay : decayDb;
            import db : openDb, sqlite3_close;
            auto db = openDb();
            if (db is null) { fputs("ground decay: cannot open db\n", stderr); return 1; }
            auto rc = decayDb(db);
            sqlite3_close(db);
            return rc;
        }
    }

    if (isatty(0)) {
        printVersion();
        fputs(" — Ground Control for Claude Code\n", stderr);
        return 0;
    }

    auto t0 = usecNow();
    const(char)[] eventName;
    const(char)[] project;
    bool skipTiming;
    auto rc = run(eventName, project, skipTiming);
    auto elapsed = usecNow() - t0;
    printDuration(t0);
    if (!skipTiming)
        recordTiming(elapsed, eventName, project);
    return rc;
}

int run(ref const(char)[] outEventName, ref const(char)[] outProject, ref bool outSkipTiming) {

    auto input = readStdin();
    if (input is null) {
        fputs("ground: empty stdin\n", stderr);
        return 1;
    }
    // Common fields
    auto cwd = extractCwd(input);
    if (cwd is null) cwd = "";
    auto sessionId = extractSessionId(input);
    if (sessionId is null) sessionId = "";

    import db : cwdTail;
    outProject = cwdTail(cwd);

    auto eventName = extractHookEventName(input);
    if (eventName is null) return 0;
    outEventName = eventName;

    // Attest every event — even ones we don't handle yet
    {
        import db : openDb, attestEvent, sqlite3_close;
        auto db = openDb();
        if (db !is null) {
            attestEvent(db, eventName, cwd, sessionId, input);
            sqlite3_close(db);
        }
    }

    HookEvent event;
    if (!parseHookEvent(eventName, event)) return 0;

    if (event == HookEvent.PreToolUse) {
        import pretooluse : handlePreToolUse;
        return handlePreToolUse(input, cwd, sessionId);
    }

    // PermissionRequest — auto-allow/deny permission dialogs
    if (event == HookEvent.PermissionRequest) {
        import permissionrequest : handlePermissionRequest;
        return handlePermissionRequest(input, cwd, sessionId);
    }

    // UserPromptSubmit — keyword controls
    if (event == HookEvent.UserPromptSubmit) {
        import userprompt : handleUserPromptSubmit;
        return handleUserPromptSubmit(input, cwd, sessionId);
    }

    // Stop — trail controls, deferred messages, lazy-verify
    if (event == HookEvent.Stop) {
        import stop : handleStop;
        auto stopRc = handleStop(input, cwd, sessionId);
        if (stopRc == 2) { outSkipTiming = true; return 0; }
        return stopRc;
    }

    // SessionStart — emit arch context on startup/clear
    if (event == HookEvent.SessionStart) {
        auto source = extractSource(input);
        import sessionstart : handleSessionStart;
        return handleSessionStart(source, cwd, sessionId);
    }

    if (event == HookEvent.PreCompact) {
        import precompact : handlePreCompact;
        return handlePreCompact(input, cwd, sessionId);
    }

    // PostToolUse — controls + CI deferral
    if (event == HookEvent.PostToolUse) {
        import posttooluse : handlePostToolUse;
        return handlePostToolUse(input, cwd, sessionId);
    }

    if (event == HookEvent.PostToolUseFailure) {
        import posttoolusefailure : handlePostToolUseFailure;
        return handlePostToolUseFailure(input, cwd, sessionId);
    }

    // Unknown/unhandled events — exit 0, no output
    return 0;
}
