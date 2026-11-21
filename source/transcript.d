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

// "every line of every session goes from ground, through the sky, to k"
// A kept line is an attestation, transcript:line, like every other row a hook
// writes, so the sky streams it to the node (stream.d). Its id is its file and
// byte offset: keeping it twice, here or at the node, is the same row.
enum LINE_PREDICATE = "transcript:line";

// The lines of one file, by where each ends, read through
// idx_attestations_transcript (db.d).
enum LINES_OF = "json_extract(predicates, '$[0]') = 'transcript:line' AND json_extract(attributes, '$.path') = ?1";

// Where the kept lines of `path` end: the byte offset the next walk reads from.
long keptUpTo(sqlite3* db, const(char)[] path) {
    enum q = "SELECT COALESCE(MAX(json_extract(attributes, '$.end')), 0) FROM attestations WHERE " ~ LINES_OF ~ "\0";
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

    // At the moment the line says it was written; a line that says none, at
    // the moment it was kept.
    enum ins = "INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ("
        ~ "'ground:transcript:' || ?1 || ':' || ?2, json_array('session:' || ?4), '[\"transcript:line\"]', "
        ~ "json_array('session:' || ?4), '[\"ground\"]', "
        ~ "COALESCE(CASE WHEN json_valid(?5) THEN strftime('%Y-%m-%dT%H:%M:%SZ', json_extract(?5, '$.timestamp')) END, "
        ~ "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')), 'ground', "
        ~ "json_object('path', ?1, 'offset', ?2, 'end', ?3, 'line', ?5))\0";
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

// The lines kept, and what is read out of them: the prompts typed while a
// turn ran (queued.d) and each CLAUDE.md given partway through (policy.d).
// Asked from where this walk began, so each line is read for them once.
Kept keepAndRead(sqlite3* db, const(char)[] path, const(char)[] session, const(char)[] cwd,
                 bool agent = false) {
    auto from = keptUpTo(db, path);
    auto k = agent ? keepAgentTranscript(db, path, session) : keepTranscript(db, path, session);
    if (from < 0) return k;
    import queued : queuedFrom;
    import policy : nestedFrom;
    queuedFrom(db, path, from, session, cwd);
    nestedFrom(db, path, from, session);
    return k;
}

// A hook's walk: the transcript it was handed, and the subagent's when it is a
// SubagentStop. What stops one is said, never dropped (ERROR.md).
void keepFromHook(sqlite3* db, const(char)[] input, const(char)[] session, const(char)[] cwd) {
    import parse : extractTranscriptPath, extractJsonString;
    import errors : sayAside;

    void said(Kept k) {
        if (k.ok) return;
        sayAside("transcript.keep", "a transcript's lines were not kept", -1,
                 session, "", k.why);
    }

    auto main = extractTranscriptPath(input);
    if (main !is null && main.length > 0) said(keepAndRead(db, main, session, cwd));

    __gshared char[4096] agentBuf = 0;
    auto agent = extractJsonString(input, `"agent_transcript_path"`, &agentBuf[0], agentBuf.length);
    if (agent !is null && agent.length > 0) said(keepAndRead(db, agent, session, cwd, true));
}

// The session a transcript's lines belong to, from where Claude Code keeps it:
// <session>.jsonl, and <session>/subagents/agent-<id>.jsonl for a subagent,
// whose lines are the session's that started it.
const(char)[] sessionOfPath(const(char)[] path) {
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    auto file = path[slash .. $];
    if (file.length > 6 && file[$ - 6 .. $] == ".jsonl") file = file[0 .. $ - 6];
    if (slash == 0) return file;

    auto dir = path[0 .. slash - 1];
    size_t ds = dir.length;
    while (ds > 0 && dir[ds - 1] != '/') ds--;
    if (dir[ds .. $] != "subagents" || ds == 0) return file;

    auto owner = dir[0 .. ds - 1];
    size_t os = owner.length;
    while (os > 0 && owner[os - 1] != '/') os--;
    return owner[os .. $];
}

// How often a sky sweeps every transcript (sky.d).
enum SWEEP_EVERY = 60;

struct Swept {
    bool ok = true;
    size_t files;
    size_t lines;
    size_t failed;
}

// "i dont want to come back, and find out i missed something"
// Every transcript under each root, main and subagent, read to its end: what
// was written before ground kept lines, and after a session's last hook. The
// sky sweeps ~/.claude/projects (sky.d); `ground keep` does it once, by hand.
// Codex's transcripts are not swept yet: "Codex can be deferred clearly marked not done yet".
Swept keepAll(sqlite3* db, const(char)[][] roots, size_t cap = WALK_BYTES) {
    Swept sw;
    foreach (root; roots) walkDir(db, root, cap, sw, 0);
    return sw;
}

private void walkDir(sqlite3* db, const(char)[] dir, size_t cap, ref Swept sw, int depth) {
    import core.sys.posix.dirent : opendir, readdir, closedir, DT_DIR, DT_REG;
    import errors : sayAside;
    if (depth > 8) return;

    char[4096] z = 0;
    if (dir.length + 1 >= z.length) return;
    z[0 .. dir.length] = dir[];
    auto d = opendir(z.ptr);
    if (d is null) return;
    scope (exit) closedir(d);

    for (auto e = readdir(d); e !is null; e = readdir(d)) {
        size_t n = 0;
        while (e.d_name[n] != 0) n++;
        auto name = e.d_name[0 .. n];
        if (name == "." || name == "..") continue;
        if (dir.length + 1 + name.length >= 4096) continue;

        char[4096] child = 0;
        size_t cl = 0;
        foreach (c; dir) child[cl++] = c;
        child[cl++] = '/';
        foreach (c; name) child[cl++] = c;
        auto path = child[0 .. cl];

        if (e.d_type == DT_DIR) { walkDir(db, path, cap, sw, depth + 1); continue; }
        if (e.d_type != DT_REG) continue;
        if (name.length < 6 || name[$ - 6 .. $] != ".jsonl") continue;

        sw.files++;
        auto session = sessionOfPath(path);
        // Read to the end, a walk's worth at a time.
        while (true) {
            auto k = keepAndRead(db, path, session, "");
            if (!k.ok) {
                sw.ok = false;
                sw.failed++;
                sayAside("transcript.sweep", "a transcript's lines were not kept", -1,
                         session, "", k.why);
                break;
            }
            sw.lines += k.lines;
            if (k.lines == 0) break;
        }
    }
}

// ~/.claude/projects, where Claude Code keeps every session's transcript.
const(char)[] projectsRoot() {
    import core.stdc.stdlib : getenv;
    __gshared char[4096] buf = 0;
    auto h = getenv("HOME\0".ptr);
    if (h is null) return null;
    size_t n = 0;
    while (h[n] && n < 4000) { buf[n] = h[n]; n++; }
    foreach (c; "/.claude/projects") buf[n++] = c;
    return buf[0 .. n];
}

struct Proven {
    size_t same;
    size_t differ;
    // The first files that differ, for whoever reads it.
    const(char)[][16] paths;
    size_t shown;
    __gshared char[4096][16] held;
}

// "the data upon which we continue needs to be rock solid"
// Each file against what was kept of it: the kept lines, in order, each where
// the last ended, joined by their newlines, are the file's bytes up to where
// the kept lines end; and past that is no whole line, only one still being written.
Proven provenAll(sqlite3* db, const(char)[][] roots) {
    Proven p;
    foreach (root; roots) proveDir(db, root, p, 0);
    return p;
}

private void proveDir(sqlite3* db, const(char)[] dir, ref Proven p, int depth) {
    import core.sys.posix.dirent : opendir, readdir, closedir, DT_DIR, DT_REG;
    if (depth > 8) return;
    char[4096] z = 0;
    if (dir.length + 1 >= z.length) return;
    z[0 .. dir.length] = dir[];
    auto d = opendir(z.ptr);
    if (d is null) return;
    scope (exit) closedir(d);

    for (auto e = readdir(d); e !is null; e = readdir(d)) {
        size_t n = 0;
        while (e.d_name[n] != 0) n++;
        auto name = e.d_name[0 .. n];
        if (name == "." || name == "..") continue;
        if (dir.length + 1 + name.length >= 4096) continue;
        char[4096] child = 0;
        size_t cl = 0;
        foreach (c; dir) child[cl++] = c;
        child[cl++] = '/';
        foreach (c; name) child[cl++] = c;
        auto path = child[0 .. cl];

        if (e.d_type == DT_DIR) { proveDir(db, path, p, depth + 1); continue; }
        if (e.d_type != DT_REG) continue;
        if (name.length < 6 || name[$ - 6 .. $] != ".jsonl") continue;

        if (proveFile(db, path)) { p.same++; continue; }
        p.differ++;
        if (p.shown < p.paths.length) {
            auto slot = Proven.held[p.shown][];
            auto k = path.length < slot.length ? path.length : slot.length;
            slot[0 .. k] = path[0 .. k];
            p.paths[p.shown++] = slot[0 .. k];
        }
    }
}

// True when what was kept of `path` is the file, byte for byte.
bool proveFile(sqlite3* db, const(char)[] path) {
    import core.stdc.stdio : fopen, fclose, fread, fseek, ftell, SEEK_END, SEEK_SET;
    import sha256 : Sha256;
    import db : sqlite3_column_text, sqlite3_column_bytes;

    char[4096] z = 0;
    if (path.length + 1 >= z.length) return false;
    z[0 .. path.length] = path[];
    auto f = fopen(z.ptr, "rb");
    if (f is null) return false;
    scope (exit) fclose(f);
    fseek(f, 0, SEEK_END);
    auto size = ftell(f);

    // The kept lines, in order, each starting where the last ended.
    enum q = "SELECT json_extract(attributes, '$.offset'), json_extract(attributes, '$.end'), "
        ~ "json_extract(attributes, '$.line') FROM attestations WHERE " ~ LINES_OF
        ~ " ORDER BY json_extract(attributes, '$.end')\0";
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &s, null) != SQLITE_OK) return false;
    sqlite3_bind_text(s, 1, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
    Sha256 kept;
    long at = 0;
    bool contiguous = true;
    while (sqlite3_step(s) == SQLITE_ROW) {
        auto off = sqlite3_column_int64(s, 0);
        auto end = sqlite3_column_int64(s, 1);
        auto t = sqlite3_column_text(s, 2);
        auto tl = sqlite3_column_bytes(s, 2);
        if (off != at || end != off + tl + 1) { contiguous = false; break; }
        if (tl > 0) kept.put((cast(const(ubyte)*) t)[0 .. tl]);
        static immutable ubyte[1] nl = ['\n'];
        kept.put(nl[]);
        at = end;
    }
    sqlite3_finalize(s);
    if (!contiguous || at > size) return false;

    // The file's bytes up to there, hashed; and the rest holds no newline.
    Sha256 disk;
    __gshared ubyte[1 << 20] chunk;
    fseek(f, 0, SEEK_SET);
    long left = at;
    while (left > 0) {
        auto want = left < chunk.length ? cast(size_t) left : chunk.length;
        auto got = fread(chunk.ptr, 1, want, f);
        if (got == 0) return false;
        disk.put(chunk[0 .. got]);
        left -= got;
    }
    while (true) {
        auto got = fread(chunk.ptr, 1, chunk.length, f);
        if (got == 0) break;
        foreach (b; chunk[0 .. got]) if (b == '\n') return false;
    }

    char[64] a, b;
    kept.hexInto(a);
    disk.hexInto(b);
    return a == b;
}
