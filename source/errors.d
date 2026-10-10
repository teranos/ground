module errors;

// The ERROR AXIOM (CLAUDE.md): an Error is a first-class primitive, a
// typed value that crosses every layer of the system unchanged. Never
// collapsed, dropped, swallowed, or suppressed. Lands in front of the
// user, contextually, at the exact point of interaction.
//
// This module defines the typed Error and the delivery contract that
// satisfies "never dropped." Any code that would previously `return`
// silently on failure must instead construct a GroundError and call
// deliverError. The delivery function tries the primary channel and
// falls back through progressively cheaper channels until one succeeds.
// If ALL fail, that itself is a bug — never a swallow.

struct GroundError {
    string origin;       // e.g. "exec.mkstemp", "exec.wrapper.write", "exec.script"
    string message;      // human-readable description
    int    errnoVal;     // OS errno, 0 when not applicable
    int    exitCode;     // -1 when not applicable
    string sessionId;    // routing to the session that triggered
    string controlName;  // which control produced the Error
    string toolUseId;    // tool call that triggered
    long   timestamp;    // unix seconds
    string stdout;       // captured stdout (may be empty)
    string stderr;       // captured stderr (may be empty) — primary error content
}

extern (C) {
    // Variadic, as libc declares it. On arm64 macOS a variadic argument is
    // passed on the stack; declared as a plain third parameter the mode went
    // in a register open never reads, and every file was created mode 000.
    int open(const(char)* path, int flags, ...);
    long read(int fd, void* buf, size_t count);
    long write(int fd, const(void)* buf, size_t count);
    int close(int fd);
    int mkdir(const(char)* path, uint mode);
    int unlink(const(char)* path);
    void* fopen(const(char)* path, const(char)* mode);
    int fclose(void* f);
    size_t fread(void* ptr, size_t size, size_t nmemb, void* stream);
    void* popen(const(char)* command, const(char)* mode);
    int pclose(void* stream);
    char* getenv(const(char)* name);
}

// The flags are the platform's, from druntime's headers, not numbers copied
// off one machine. O_CREAT is 0x200 on macOS and 0x40 on Linux; with the
// macOS number, Linux never created the file and every fallback write failed.
public import core.sys.posix.fcntl : O_WRONLY, O_RDONLY, O_CREAT, O_TRUNC, O_APPEND;
enum STDERR_FD = 2;

// Deliver an Error through progressively cheaper channels. Returns the
// name of the channel that succeeded, or empty if ALL channels failed
// (which is itself a bug per the axiom — caller should log this too).
//
// Channel order:
//   1. Primary: immediate:exec-result attestation via db → watch → session.
//      Structured, styled delivery. Requires db + watch both healthy.
//   2. Fallback 1: append to ~/.local/share/ground/errors/<session>.log.
//      Survives db outages. Watch can be extended to pick these up.
//   3. Fallback 2: write to stderr (fd 2). If ground was invoked by a
//      hook and stderr is still open, Claude Code will render it. If
//      the process was orphaned, likely goes nowhere — but still tried.
//
// The intent: SOMETHING succeeds. If none do, the calling site is
// responsible for its own diagnostic (e.g. abort with a message).
const(char)[] deliverError(const ref GroundError err) {
    // Primary: db write. writeExecResult retries on SQLITE_BUSY and
    // returns true only if the row was persisted. If it returns false
    // (retries exhausted, or non-busy step error), we escalate.
    bool opened = false;
    {
        import db : openDb, sqlite3_close;
        import immediate : writeExecResult;
        auto db = openDb();
        opened = db !is null;
        if (db !is null) {
            auto result = formatResult(err);
            auto ok = writeExecResult(db, err.sessionId, err.controlName, result, err.stdout, err.stderr);
            // The same error, left for the watcher to post. Every error ground
            // raises reaches sentry this way, and this hook posts nothing.
            leaveForSentry(db, err, result);
            sqlite3_close(db);
            if (ok) return "db";
        }
    }

    // "errors should go to sentry as errors"
    // The store would not open, so nothing can be left for the sky to post:
    // the same item goes to sentry now, from a child that has let go of the
    // hook's pipes, so the hook waits on no network. The dsn is the top
    // level's; a store that will not open is nobody's project. A store that
    // opened has the item in its outbox already.
    if (!opened) {
        import sentry : logEnvelope, reportDetached;
        import controls : dsnHere;
        auto dsn = dsnHere("");
        if (dsn.length > 0) {
            auto it = errorItem(err, formatResult(err));
            reportDetached(dsn, logEnvelope(dsn, it), err.sessionId, err.origin);
        }
    }

    // Fallback 1: filesystem breadcrumb. Append to a per-session error log.
    if (writeBreadcrumb(err)) return "breadcrumb";

    // Fallback 2: stderr. May or may not reach anywhere, but tried.
    if (writeStderr(err)) return "stderr";

    // ALL channels failed — the axiom is violated at this level. The
    // caller must handle (e.g. abort loudly). We return empty so the
    // caller knows nothing landed.
    return "";
}

/// A worker's own failure, which no session is made to read. Sentry is told
/// and nothing is delivered: the courier carries what other writers left, and
/// a step inside its own retry was never a failure of intention.
void leaveQuietly(void* db, const ref GroundError err) {
    if (db is null) return;
    leaveForSentry(db, err, formatResult(err));
}

/// The same, against ground's own store, with sentry told directly when the
/// store will not open — the one case that can reach no outbox.
void reportQuietly(const ref GroundError err) {
    import db : openDb, sqlite3_close;
    auto handle = openDb();
    if (handle !is null) {
        leaveQuietly(handle, err);
        sqlite3_close(handle);
        return;
    }

    import sentry : logEnvelope, reportDetached;
    import controls : dsnHere;
    auto dsn = dsnHere("");
    if (dsn.length == 0) return;
    auto it = errorItem(err, formatResult(err));
    reportDetached(dsn, logEnvelope(dsn, it), err.sessionId, err.origin);
}

/// The quiet path, spelled the way emitError is: a worker says what went
/// wrong in its own ask, sentry is told, and no session is woken for it.
void sayQuietly(string origin, string message, int exitCode,
                const(char)[] sessionId, const(char)[] controlName, const(char)[] detail) {
    import core.stdc.time : time;
    GroundError err;
    err.origin      = origin;
    err.message     = message;
    err.exitCode    = exitCode;
    err.sessionId   = cast(string) sessionId;
    err.controlName = cast(string) controlName;
    err.timestamp   = cast(long) time(null);
    err.stderr      = cast(string) detail;
    reportQuietly(err);
}

import sentry : Item;

// One item per error: origin, control, the result line and the tail of
// stderr. Never stdout, which is what a rite printed, and never a path.
private Item errorItem(const ref GroundError err, const(char)[] result) {
    import sentry : openItem;

    __gshared char[256] body_ = 0;
    size_t n;
    void say(const(char)[] s) { foreach (c; s) if (n < body_.length) body_[n++] = c; }
    say(err.origin);
    say(": ");
    say(err.message);

    // A stderr tail, bounded so the item stays an item. The reason is in the
    // last lines more often than the first.
    auto tail = err.stderr.length > 600 ? err.stderr[$ - 600 .. $] : err.stderr;

    auto it = openItem(err.timestamp, err.sessionId, "error", body_[0 .. n]);
    it.str("origin", err.origin);
    it.str("control", err.controlName);
    it.str("result", result);
    it.num("exit", err.exitCode);
    it.num("errno", err.errnoVal);
    it.str("stderr", tail);
    it.close();
    return it;
}

// Left in the store for the sky to post with the session's next batch.
private void leaveForSentry(void* db, const ref GroundError err, const(char)[] result) {
    import db : sqlite3;
    import outbox : leave;
    auto it = errorItem(err, result);
    cast(void) leave(cast(sqlite3*) db, err.sessionId, "error", it, err.timestamp);
}

// Format an Error into the compact result string used by the primary
// delivery path. Shape mirrors the exec-result convention:
//   "exit <N>"                         — script ran and exited
//   "start-failed <origin> errno <N>"  — pre-execv failure
//   "<origin>: <message>"              — anything else (timeout, etc.)
//
// Uses a shared static buffer — no GC, no allocations. Caller must copy
// the returned slice before the next call if it needs to retain it.
const(char)[] formatResult(const ref GroundError err) {
    // As wide as the row it lands in, which is a ZBuf too.
    import zbuf : ZBuf;
    __gshared ZBuf buf;
    buf.reset();

    void appendStr(const(char)[] s) { buf.put(s); }
    void appendInt(long v) {
        if (v < 0) { appendStr("-"); v = -v; }
        buf.putUint(cast(ulong) v);
    }

    if (err.exitCode >= 0) {
        appendStr("exit ");
        appendInt(cast(long) err.exitCode);
    } else if (err.errnoVal != 0) {
        appendStr("start-failed ");
        appendStr(err.origin);
        appendStr(" errno ");
        appendInt(cast(long) err.errnoVal);
    } else {
        appendStr(err.origin);
    }
    // The message is ground's own word on what broke, never dropped for a code.
    if (err.message.length > 0) {
        appendStr(": ");
        appendStr(err.message);
    }
    return buf.slice();
}

// Append the Error to ~/.local/share/ground/errors/<sessionId>.log as a
// simple one-line record. Best-effort — returns true if the write
// completed, false if any step failed (mkdir/open/write). No exception
// on failure (would itself be a swallow).
// <home>/.local/share/ground/errors, NUL-ended; 0 with no HOME.
size_t breadcrumbDirInto(ref char[512] dirBuf) {
    size_t p = 0;
    version (unittest) {
        import db : storeDir;
        auto dir = storeDir();
        if (dir is null) return 0;
        foreach (c; dir) { if (p < dirBuf.length - 1) dirBuf[p++] = c; }
        foreach (c; "/errors") { if (p < dirBuf.length - 1) dirBuf[p++] = c; }
    } else {
        import core.stdc.stdlib : getenv;
        auto home = getenv("HOME\0".ptr);
        if (home is null) return 0;
        size_t hlen = 0;
        while (home[hlen] != 0) hlen++;
        foreach (i; 0 .. hlen) { if (p < dirBuf.length - 1) dirBuf[p++] = home[i]; }
        foreach (c; "/.local/share/ground/errors") { if (p < dirBuf.length - 1) dirBuf[p++] = c; }
    }
    dirBuf[p] = 0;
    return p;
}

private bool writeBreadcrumb(const ref GroundError err) {
    char[512] dirBuf = 0;
    auto p = breadcrumbDirInto(dirBuf);
    if (p == 0) return false;

    // mkdir (idempotent-ish; may fail because it already exists — fine).
    mkdir(&dirBuf[0], octal!755);

    // Build file path: <dir>/<sessionId>.log
    char[768] pathBuf = 0;
    size_t q = 0;
    foreach (i; 0 .. p) { if (q < pathBuf.length - 1) pathBuf[q++] = dirBuf[i]; }
    if (q < pathBuf.length - 1) pathBuf[q++] = '/';
    foreach (c; err.sessionId) { if (q < pathBuf.length - 1) pathBuf[q++] = c; }
    foreach (c; ".log") { if (q < pathBuf.length - 1) pathBuf[q++] = c; }
    pathBuf[q] = 0;

    int fd = open(&pathBuf[0], O_WRONLY | O_CREAT | O_APPEND, octal!644);
    if (fd < 0) return false;

    // Format one line: "<ts>\t<origin>\t<control>\t<exit>\terrno=<n>\t<message>\n"
    char[2048] line = 0;
    size_t lp = 0;
    void append(const(char)[] s) {
        foreach (c; s) { if (lp < line.length - 1) line[lp++] = c; }
    }
    void appendInt(long v) {
        if (v == 0) { append("0"); return; }
        bool neg = v < 0;
        if (neg) v = -v;
        char[24] nb = 0;
        int nl = 0;
        while (v > 0 && nl < 23) { nb[nl++] = cast(char)('0' + v % 10); v /= 10; }
        if (neg) { append("-"); }
        foreach_reverse (i; 0 .. nl) { if (lp < line.length - 1) line[lp++] = nb[i]; }
    }

    appendInt(err.timestamp); append("\t");
    append(err.origin); append("\t");
    append(err.controlName); append("\t");
    append("exit="); appendInt(err.exitCode); append("\t");
    append("errno="); appendInt(err.errnoVal); append("\t");
    append(err.message); append("\n");
    // Preserve BOTH streams in the breadcrumb — the fallback must carry
    // the same information as the primary would have. Labeled, indented
    // for readability. Empty streams are simply omitted.
    if (err.stdout.length > 0) {
        append("  stdout:\n");
        // indent each line
        bool startOfLine = true;
        foreach (c; err.stdout) {
            if (startOfLine) { append("    "); startOfLine = false; }
            if (lp < line.length - 1) line[lp++] = c;
            if (c == '\n') startOfLine = true;
        }
        if (!startOfLine) append("\n");
    }
    if (err.stderr.length > 0) {
        append("  stderr:\n");
        bool startOfLine = true;
        foreach (c; err.stderr) {
            if (startOfLine) { append("    "); startOfLine = false; }
            if (lp < line.length - 1) line[lp++] = c;
            if (c == '\n') startOfLine = true;
        }
        if (!startOfLine) append("\n");
    }

    auto n = write(fd, &line[0], lp);
    close(fd);
    return n == cast(long) lp;
}

// Fallback 2: write to stderr. Grandchild inherits fd 2 from wrapper
// which inherits from ground which inherits from Claude Code's Bash
// dispatch. If any of those chains still has a live consumer, the
// message reaches somewhere.
private bool writeStderr(const ref GroundError err) {
    char[1024] line = 0;
    size_t lp = 0;
    void append(const(char)[] s) {
        foreach (c; s) { if (lp < line.length - 1) line[lp++] = c; }
    }
    append("ground error: ");
    append(err.origin);
    append(": ");
    append(err.message);
    append("\n");
    auto n = write(STDERR_FD, &line[0], lp);
    return n == cast(long) lp;
}

// --- Exec inflight markers ---
//
// Under the ERROR AXIOM: dispatchExec's parent forks a wrapper and returns
// immediately so it doesn't block the hook. Every wrapper end-path calls
// deliverError, so a clean wrapper always announces itself. The hole: if
// the wrapper dies BEFORE reaching its terminal emitError — SIGKILL, OOM,
// segfault, kernel panic recovery, anything — nothing lands and the axiom
// is silently violated.
//
// The marker closes the hole:
//   - parent writes a marker at ~/.local/share/ground/exec-inflight/<sid>__<pid>.mark
//     containing startTs, timeoutSec, controlName, toolUseId, cwd
//   - wrapper unlinks its own marker before every terminal emitError
//   - each pass of the session's sky calls scanVanishedWrappers, which says
//     every marker whose pid the kernel has no process for, and unlinks it
//
// Every PostToolUse and Stop ran this through popen(ls), 66ms at the median.

private const(char)[] getHomeStr() {
    auto h = getenv("HOME\0".ptr);
    if (h is null) return null;
    size_t n = 0;
    while (h[n] != 0) n++;
    return h[0 .. n];
}

// Fill buf with "<home>/.local/share/ground/exec-inflight" and return length
// (excluding the trailing NUL that is also written). Zero on failure.
package size_t buildInflightDir(ref char[512] buf) {
    size_t p = 0;
    version (unittest) {
        import db : storeDir;
        auto dir = storeDir();
        if (dir is null) return 0;
        foreach (c; dir) { if (p < buf.length - 1) buf[p++] = c; }
        foreach (c; "/exec-inflight") { if (p < buf.length - 1) buf[p++] = c; }
    } else {
        auto home = getHomeStr();
        if (home is null) return 0;
        foreach (c; home) { if (p < buf.length - 1) buf[p++] = c; }
        foreach (c; "/.local/share/ground/exec-inflight") { if (p < buf.length - 1) buf[p++] = c; }
    }
    buf[p] = 0;
    return p;
}

// Fill buf with "<inflight-dir>/<sid>__<pid>.mark". Zero on failure.
package size_t buildInflightPath(ref char[512] buf, const(char)[] sessionId, int pid) {
    auto p = buildInflightDir(buf);
    if (p == 0) return 0;
    if (p >= buf.length - 1) return 0;
    buf[p++] = '/';
    foreach (c; sessionId) { if (p < buf.length - 1) buf[p++] = c; }
    if (p >= buf.length - 3) return 0;
    buf[p++] = '_'; buf[p++] = '_';
    // pid as decimal
    if (pid < 0) return 0;
    char[16] db = 0;
    int dl = 0;
    if (pid == 0) { db[0] = '0'; dl = 1; }
    else { int v = pid; while (v > 0 && dl < 15) { db[dl++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach_reverse (i; 0 .. dl) { if (p < buf.length - 1) buf[p++] = db[i]; }
    foreach (c; ".mark") { if (p < buf.length - 1) buf[p++] = c; }
    buf[p] = 0;
    return p;
}

// Parent-side: called by dispatchExec after fork() returns wrapperPid > 0.
// Best-effort — a failure to write the marker is itself an Error, but
// emitting one here (before returning to the hook) would violate the
// "return immediately" contract. Instead, if we can't write the marker
// we degrade to "wrapper is on its own"; the wrapper's own terminal
// emit still lands. The marker exists ONLY to catch wrapper-vanished.
void writeInflightMarker(
    string sessionId, string controlName, string toolUseId,
    int wrapperPid, long startTs, int timeoutSec, const(char)[] cwd,
) {
    if (sessionId.length == 0 || wrapperPid <= 0) return;

    char[512] dirBuf = 0;
    if (buildInflightDir(dirBuf) == 0) return;
    mkdir(&dirBuf[0], octal!755);

    char[512] pathBuf = 0;
    if (buildInflightPath(pathBuf, sessionId, wrapperPid) == 0) return;

    int fd = open(&pathBuf[0], O_WRONLY | O_CREAT | O_TRUNC, octal!644);
    if (fd < 0) return;

    char[4096] cbuf = 0;
    size_t cp = 0;
    void put(const(char)[] s) { foreach (c; s) if (cp < cbuf.length - 1) cbuf[cp++] = c; }
    void putI(long v) {
        if (v == 0) { put("0"); return; }
        bool neg = v < 0;
        if (neg) v = -v;
        char[24] nb = 0;
        int nl = 0;
        while (v > 0 && nl < 23) { nb[nl++] = cast(char)('0' + v % 10); v /= 10; }
        if (neg) put("-");
        foreach_reverse (i; 0 .. nl) { if (cp < cbuf.length - 1) cbuf[cp++] = nb[i]; }
    }
    putI(startTs);    put("\n");
    putI(timeoutSec); put("\n");
    put(controlName); put("\n");
    put(toolUseId);   put("\n");
    put(cwd);         put("\n");
    cast(void) write(fd, &cbuf[0], cp);
    close(fd);
}

// Wrapper-side: called before every terminal emitError (normal exit,
// non-zero exit, timeout, pre-execv failure inside wrapper). Unlinks
// its own marker so the next scan doesn't false-positive.
void clearInflightMarker(string sessionId, int wrapperPid) {
    if (sessionId.length == 0 || wrapperPid <= 0) return;
    char[512] pathBuf = 0;
    if (buildInflightPath(pathBuf, sessionId, wrapperPid) == 0) return;
    unlink(&pathBuf[0]);
}

// This session's markers whose wrapper the kernel says is gone, each said as
// exec.wrapper.vanished and unlinked so it is said once. Run by sky's pass.
size_t scanVanishedWrappers(string sessionId, bool function(long) alive) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    import core.stdc.time : time;

    if (sessionId.length == 0) return 0;

    char[512] dirBuf = 0;
    if (buildInflightDir(dirBuf) == 0) return 0;
    auto dir = opendir(&dirBuf[0]);
    if (dir is null) return 0;
    scope (exit) closedir(dir);

    size_t found;
    for (auto e = readdir(dir); e !is null; e = readdir(dir)) {
        size_t len;
        while (e.d_name[len] != 0) len++;
        auto name = e.d_name[0 .. len];

        // <sid>__<pid>.mark, and only this session's.
        if (len < sessionId.length + 2 + 5) continue;
        if (name[0 .. sessionId.length] != sessionId) continue;
        if (name[sessionId.length .. sessionId.length + 2] != "__") continue;
        if (name[$ - 5 .. $] != ".mark") continue;
        int wrapperPid = 0;
        bool digits = true;
        foreach (c; name[sessionId.length + 2 .. $ - 5]) {
            if (c < '0' || c > '9') { digits = false; break; }
            wrapperPid = wrapperPid * 10 + (c - '0');
        }
        if (!digits || wrapperPid <= 0) continue;
        if (alive(wrapperPid)) continue;

        char[512] path = 0;
        if (buildInflightPath(path, sessionId, wrapperPid) == 0) continue;

        // startTs\ntimeoutSec\ncontrolName\ntoolUseId\ncwd
        int fd = open(&path[0], O_RDONLY, 0);
        if (fd < 0) continue;
        char[4096] cbuf = 0;
        auto n = read(fd, &cbuf[0], cbuf.length - 1);
        close(fd);
        auto body_ = n > 0 ? cast(const(char)[]) cbuf[0 .. cast(size_t) n] : "";
        const(char)[][4] fields;
        {
            size_t f, s;
            foreach (i, c; body_) {
                if (c != '\n') continue;
                if (f < fields.length) fields[f++] = body_[s .. i];
                s = i + 1;
            }
        }

        GroundError err;
        err.origin      = "exec.wrapper.vanished";
        err.message     = "wrapper process died before delivering result";
        err.exitCode    = -1;
        err.sessionId   = sessionId;
        err.controlName = cast(string) fields[2];
        err.toolUseId   = cast(string) fields[3];
        err.timestamp   = cast(long) time(null);
        cast(void) deliverError(err);

        unlink(&path[0]);
        found++;
    }
    return found;
}

unittest {
    // A wrapper is gone when the kernel says its pid is, not when its marker is
    // old: the fresh marker of a dead wrapper is the error, and the ancient
    // marker of a live one is a run still going.
    import core.stdc.time : time;
    import db : openDb, sqlite3_close, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_column_int64, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

    writeInflightMarker("sess-vanish", "ctl-dead", "toolu_dead", 4242, cast(long) time(null), 500, "/tmp");
    writeInflightMarker("sess-vanish", "ctl-live", "toolu_live", 4343, 0, 1, "/tmp");
    writeInflightMarker("sess-other", "ctl-dead", "toolu_x", 4242, cast(long) time(null), 500, "/tmp");

    static bool onlyFourThreeFourThree(long pid) { return pid == 4343; }
    assert(scanVanishedWrappers("sess-vanish", &onlyFourThreeFourThree) == 1,
           "the dead wrapper is found at once, and the live one is left");

    static bool exists(string sid, int pid) {
        import core.sys.posix.unistd : access, F_OK;
        char[512] p = 0;
        if (buildInflightPath(p, sid, pid) == 0) return false;
        return access(&p[0], F_OK) == 0;
    }
    assert(!exists("sess-vanish", 4242), "the dead wrapper's marker is gone, so it is said once");
    assert(exists("sess-vanish", 4343), "a run still going keeps its marker");
    assert(exists("sess-other", 4242), "another session's markers are its own sky's");

    auto db = openDb();
    assert(db !is null);
    scope (exit) sqlite3_close(db);
    enum sql = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'immediate:exec-result' "
        ~ "AND contexts = '[\"session:sess-vanish\"]' AND attributes LIKE '%exec ctl-dead: exec.wrapper.vanished%'\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
    scope (exit) sqlite3_finalize(stmt);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(sqlite3_column_int64(stmt, 0) == 1, "the session is handed the error as a row");

    assert(scanVanishedWrappers("sess-vanish", &onlyFourThreeFourThree) == 0, "said once");
}

// --- Watch health / delivery-pipeline check ---
//
// Under the ERROR AXIOM: if the watch daemon dies mid-cycle or fails to
// spawn, rows written by dispatchExec's wrapper sit in the db forever and
// no one sees them. That's a silent violation.
//
// The signal is the work itself: an exec result still undelivered past the
// watcher's worst-case poll gap. Nothing else is asked and nothing is
// inferred — no pid, no liveness probe, no rendezvous file.
//
// This replaced a pid-liveness check that was wrong in both directions. It
// read watch-<sid>.pid, which stop.d had already invalidated by SIGTERMing
// that very pid twenty-one lines earlier, and which no code path ever
// unlinks. So it reported a dead pipeline for a healthy one on every Stop
// that followed a push, and it would equally have reported a live pipeline
// for a watcher that had lost its claim to another session.
//
// An Error must be true, not merely delivered. A false Error spends the
// user's attention and teaches them to discount the channel, which costs
// the axiom exactly what a swallowed Error would.
//
// Callers: at Stop, use immediateBacklogMessage to prepend the warning to
// the Stop response so it surfaces at point of interaction. At PostToolUse,
// use writeImmediateBacklogStderr as best-effort visibility (stderr from
// PostToolUse shows in Claude Code's transcript-mode view).

// Returns the number of exec results this session has left undelivered past
// the grace window, or 0 when delivery is keeping up.
long detectImmediateBacklog(string sessionId) {
    import db : openDb, sqlite3_close;
    import immediate : countStaleExecForSession;

    if (sessionId.length == 0) return 0;

    auto db = openDb();
    if (db is null) return 0;
    auto n = countStaleExecForSession(db, sessionId);
    sqlite3_close(db);
    return n > 0 ? n : 0;
}

// Format the backlog warning into a fixed __gshared buffer. Slice is stable
// until the next call. Empty result means "no backlog, nothing to report."
const(char)[] immediateBacklogMessage(string sessionId) {
    auto n = detectImmediateBacklog(sessionId);
    if (n <= 0) return null;

    __gshared char[256] buf = 0;
    size_t pos = 0;
    void put(const(char)[] s) { foreach (c; s) if (pos < buf.length - 1) buf[pos++] = c; }
    void putI(long v) {
        if (v == 0) { put("0"); return; }
        char[24] nb = 0; int nl = 0;
        while (v > 0 && nl < 23) { nb[nl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. nl) if (pos < buf.length - 1) buf[pos++] = nb[i];
    }
    // State what was measured, not a guess at the cause. "watch daemon is not
    // running" was an inference from a pid file; this is the observation.
    put("ground error: ");
    putI(n);
    put(" exec result(s) undelivered for over 60s — nothing is draining the queue");
    return buf[0 .. pos];
}

// Best-effort stderr emission for PostToolUse — shows in Claude Code's
// transcript-mode view. Also writes a breadcrumb line so the record is
// durable even if stderr goes unseen.
void writeImmediateBacklogStderr(string sessionId) {
    auto msg = immediateBacklogMessage(sessionId);
    if (msg.length == 0) return;

    // stderr
    char[300] line = 0;
    size_t lp = 0;
    foreach (c; msg) { if (lp < line.length - 1) line[lp++] = c; }
    if (lp < line.length - 1) line[lp++] = '\n';
    cast(void) write(STDERR_FD, &line[0], lp);

    // breadcrumb — reuse the errors/<sid>.log so history persists
    GroundError err;
    err.origin      = "sky.dead";
    err.message     = cast(string) msg;
    err.sessionId   = sessionId;
    err.controlName = "";
    err.toolUseId   = "";
    import core.stdc.time : time;
    err.timestamp   = cast(long) time(null);
    cast(void) writeBreadcrumb(err);
}

unittest {
    // Sentry is told and the session is not. The exec-result row is what the
    // courier reads back out as a system reminder, so it is the one that must
    // not exist for a worker's own retry.
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
                sqlite3_column_int64, SQLITE_ROW;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    GroundError err;
    err.origin = "sky.stream";
    err.message = "the stream to qntx stopped at a row: HTTP 502";
    err.exitCode = -1;
    err.sessionId = "sess-q";
    err.controlName = "sky";
    err.timestamp = 1000;

    leaveQuietly(db, err);

    long count(string sql) {
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return -1;
        long n = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : -1;
        sqlite3_finalize(stmt);
        return n;
    }

    assert(count("SELECT COUNT(*) FROM outbox\0") == 1, "sentry is told");
    assert(count("SELECT COUNT(*) FROM attestations\0") == 0,
           "nothing is left for the courier to read into a session");

    sqlite3_close(db);
}

// octal! helper mirrored from exec.d — small and self-contained.
private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}

unittest {
    // A file open creates carries the mode it was asked for. The curl config
    // holds a token and is written 0600, then read back by curl.
    import core.sys.posix.sys.stat : stat_t, stat;
    enum path = "/tmp/ground-open-mode-test\0";
    unlink(path.ptr);
    auto fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, octal!600);
    assert(fd >= 0, "open could not create the file");
    close(fd);
    stat_t st;
    assert(stat(path.ptr, &st) == 0);
    unlink(path.ptr);
    assert((st.st_mode & octal!777) == octal!600, "the file carries the mode open was given");
}

