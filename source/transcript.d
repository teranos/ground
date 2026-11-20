module transcript;

// "where the principle is we get all of it."

// The transcript is the session's whole record: what no hook carries, a slash
// command, a mode change, a line type nobody has named yet, is there. Every line
// is kept as written, so nothing waits on a matcher being written for it.

import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
            sqlite3_step, sqlite3_finalize, sqlite3_reset, sqlite3_exec, sqlite3_changes, sqlite3_errmsg,
            sqlite3_column_int64, SQLITE_OK, SQLITE_ROW, SQLITE_DONE, SQLITE_TRANSIENT;

struct Kept {
    bool ok;
    size_t lines;      // newly kept by this walk
    long end;          // where the next walk starts
    const(char)[] why; // what stopped it, when !ok
}

// Where the kept lines of `path` end: the byte offset the next walk reads from.
long keptUpTo(sqlite3* db, const(char)[] path) {
    enum q = "SELECT COALESCE(MAX(end), 0) FROM transcript_line WHERE path = ?1\0";
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &s, null) != SQLITE_OK) return -1;
    sqlite3_bind_text(s, 1, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

private const(char)[] sqliteWhy(sqlite3* db) {
    auto m = sqlite3_errmsg(db);
    if (m is null) return "sqlite gave no message";
    size_t n = 0;
    while (m[n]) n++;
    return m[0 .. n];
}

// Every complete line of `content`, which starts at byte `base` of `path`. A
// line with no newline yet is still being written and waits for the next walk.
Kept keepLines(sqlite3* db, const(char)[] path, const(char)[] session,
               const(char)[] content, long base) {
    Kept k;
    k.end = base;

    if (sqlite3_exec(db, "BEGIN IMMEDIATE\0".ptr, null, null, null) != SQLITE_OK) {
        k.why = sqliteWhy(db);
        return k;
    }

    enum ins = "INSERT OR IGNORE INTO transcript_line (path, offset, end, session, line) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5)\0";
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, ins.ptr, -1, &s, null) != SQLITE_OK) {
        k.why = sqliteWhy(db);
        sqlite3_exec(db, "ROLLBACK\0".ptr, null, null, null);
        return k;
    }
    sqlite3_bind_text(s, 1, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 4, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);

    size_t i = 0;
    size_t added = 0;
    while (i < content.length) {
        size_t e = i;
        while (e < content.length && content[e] != '\n') e++;
        if (e == content.length) break;

        auto line = content[i .. e];
        sqlite3_bind_int64(s, 2, base + cast(long) i);
        sqlite3_bind_int64(s, 3, base + cast(long) e + 1);
        sqlite3_bind_text(s, 5, line.length ? line.ptr : "".ptr, cast(int) line.length, SQLITE_TRANSIENT);
        if (sqlite3_step(s) != SQLITE_DONE) {
            k.why = sqliteWhy(db);
            sqlite3_finalize(s);
            sqlite3_exec(db, "ROLLBACK\0".ptr, null, null, null);
            return k;
        }
        added += sqlite3_changes(db);
        sqlite3_reset(s);
        i = e + 1;
    }
    sqlite3_finalize(s);

    if (sqlite3_exec(db, "COMMIT\0".ptr, null, null, null) != SQLITE_OK) {
        k.why = sqliteWhy(db);
        sqlite3_exec(db, "ROLLBACK\0".ptr, null, null, null);
        return k;
    }

    k.ok = true;
    k.lines = added;
    k.end = base + cast(long) i;
    return k;
}

// How much one walk reads. The first walk of a live session met a 204 MB
// transcript (2026-11-20); read whole, it is one hook holding the write lock
// for all of it. The walks after it catch up.
enum WALK_BYTES = 4 * 1024 * 1024;

// The file from where the store left off, up to `cap` bytes of it, kept. A line
// longer than `cap` is read to its end.
Kept keepTranscript(sqlite3* db, const(char)[] path, const(char)[] session,
                    size_t cap = WALK_BYTES) {
    import core.stdc.stdio : FILE, fopen, fclose, fread, fseek, ftell, SEEK_END, SEEK_SET;
    import core.stdc.stdlib : malloc, free;

    Kept k;
    if (path.length == 0) { k.why = "no transcript path"; return k; }

    __gshared char[4096] pathBuf = 0;
    if (path.length + 1 > pathBuf.length) { k.why = "transcript path longer than 4095 bytes"; return k; }
    foreach (j, c; path) pathBuf[j] = c;
    pathBuf[path.length] = 0;

    auto from = keptUpTo(db, path);
    if (from < 0) { k.why = sqliteWhy(db); return k; }
    k.end = from;

    auto f = fopen(&pathBuf[0], "rb");
    if (f is null) {
        import core.stdc.errno : errno;
        import core.stdc.string : strerror;
        auto e = strerror(errno);
        size_t el = 0;
        while (e !is null && e[el]) el++;
        __gshared char[4200] whyBuf = 0;
        size_t n = 0;
        void put(const(char)[] s) { foreach (c; s) if (n < whyBuf.length) whyBuf[n++] = c; }
        put("transcript would not open: ");
        put(path);
        put(": ");
        put(e[0 .. el]);
        k.why = whyBuf[0 .. n];
        return k;
    }

    fseek(f, 0, SEEK_END);
    auto size = ftell(f);
    if (size < from) {
        fclose(f);
        k.why = "transcript is shorter than what was kept of it";
        return k;
    }
    if (size == from) { fclose(f); k.ok = true; return k; }

    import core.stdc.stdlib : realloc;
    auto unread = cast(size_t)(size - from);
    auto want = unread < cap ? unread : cap;
    char* buf = null;
    size_t got = 0;
    fseek(f, from, SEEK_SET);
    while (true) {
        auto grown = cast(char*) realloc(buf, want);
        if (grown is null) {
            free(buf);
            fclose(f);
            k.why = "no memory for the transcript's unread bytes";
            return k;
        }
        buf = grown;
        got += fread(buf + got, 1, want - got, f);
        bool ended = false;
        foreach (j; 0 .. got) if (buf[j] == '\n') { ended = true; break; }
        if (ended || got < want || want == unread) break;
        // Not one whole line yet: read on until one ends.
        want = want * 2 < unread ? want * 2 : unread;
    }
    fclose(f);

    k = keepLines(db, path, session, buf[0 .. got], from);
    free(buf);
    return k;
}

// Claude Code names an agent_transcript_path on every SubagentStop and writes
// the file for only some agents: 454 of 454 named from 2026-11-19 to 2026-11-20,
// all with an empty agent_type, were never written. A file that does not exist
// holds nothing to keep; every other failure is one.
Kept keepAgentTranscript(sqlite3* db, const(char)[] path, const(char)[] session) {
    import core.sys.posix.sys.stat : stat_t, stat;
    import core.stdc.errno : errno, ENOENT;
    __gshared char[4096] pathBuf = 0;
    if (path.length > 0 && path.length + 1 <= pathBuf.length) {
        foreach (j, c; path) pathBuf[j] = c;
        pathBuf[path.length] = 0;
        stat_t st;
        if (stat(&pathBuf[0], &st) != 0 && errno == ENOENT) {
            Kept nothing;
            nothing.ok = true;
            return nothing;
        }
    }
    return keepTranscript(db, path, session);
}

// A hook's walk: the transcript it was handed, and the subagent's when it is a
// SubagentStop. What stops one is said, never dropped (ERROR.md).
void keepFromHook(sqlite3* db, const(char)[] input, const(char)[] session) {
    import parse : extractTranscriptPath, extractJsonString;
    import errors : sayAside;

    void said(Kept k) {
        if (k.ok) return;
        sayAside("transcript.keep", "a transcript's lines were not kept", -1,
                 session, "", k.why);
    }

    auto main = extractTranscriptPath(input);
    if (main !is null && main.length > 0) said(keepTranscript(db, main, session));

    __gshared char[4096] agentBuf = 0;
    auto agent = extractJsonString(input, `"agent_transcript_path"`, &agentBuf[0], agentBuf.length);
    if (agent !is null && agent.length > 0) said(keepAgentTranscript(db, agent, session));
}
