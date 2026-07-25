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
    int open(const(char)* path, int flags, uint mode);
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

enum O_WRONLY = 1;
enum O_RDONLY = 0;
enum O_CREAT  = 0x0200; // macOS
enum O_TRUNC  = 0x0400; // macOS
enum O_APPEND = 8;
enum STDERR_FD = 2;

// Grace period added to a control's timeoutSec before scanVanishedWrappers
// treats a marker as stale. The wrapper's timeout path SIGTERM→wait2s→SIGKILL
// →waitpid→clearMarker→emitError. Worst case is timeoutSec + ~2s to reach
// the clear. 5s covers that comfortably without making user wait long
// after a genuinely-vanished wrapper.
enum GRACE_SEC = 5;

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
    {
        import db : openDb, sqlite3_close;
        import immediate : writeExecResult;
        auto db = openDb();
        if (db !is null) {
            auto result = formatResult(err);
            auto ok = writeExecResult(db, err.sessionId, err.controlName, result, err.stdout, err.stderr);
            sqlite3_close(db);
            if (ok) return "db";
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

// Format an Error into the compact result string used by the primary
// delivery path. Shape mirrors the exec-result convention:
//   "exit <N>"                         — script ran and exited
//   "start-failed <origin> errno <N>"  — pre-execv failure
//   "<origin>: <message>"              — anything else (timeout, etc.)
//
// Uses a shared static buffer — no GC, no allocations. Caller must copy
// the returned slice before the next call if it needs to retain it.
private const(char)[] formatResult(const ref GroundError err) {
    __gshared char[256] buf = 0;
    size_t pos = 0;

    void appendStr(const(char)[] s) {
        foreach (c; s) { if (pos < buf.length - 1) buf[pos++] = c; }
    }
    void appendInt(long v) {
        if (v == 0) { appendStr("0"); return; }
        bool neg = v < 0;
        if (neg) v = -v;
        char[24] nb = 0;
        int nl = 0;
        while (v > 0 && nl < 23) { nb[nl++] = cast(char)('0' + v % 10); v /= 10; }
        if (neg) appendStr("-");
        foreach_reverse (i; 0 .. nl) { if (pos < buf.length - 1) buf[pos++] = nb[i]; }
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
        appendStr(": ");
        appendStr(err.message);
    }
    return buf[0 .. pos];
}

// Append the Error to ~/.local/share/ground/errors/<sessionId>.log as a
// simple one-line record. Best-effort — returns true if the write
// completed, false if any step failed (mkdir/open/write). No exception
// on failure (would itself be a swallow).
private bool writeBreadcrumb(const ref GroundError err) {
    import core.stdc.stdlib : getenv;
    auto home = getenv("HOME\0".ptr);
    if (home is null) return false;

    size_t hlen = 0;
    while (home[hlen] != 0) hlen++;

    // Build directory: <home>/.local/share/ground/errors
    char[512] dirBuf = 0;
    size_t p = 0;
    foreach (i; 0 .. hlen) { if (p < dirBuf.length - 1) dirBuf[p++] = home[i]; }
    foreach (c; "/.local/share/ground/errors") { if (p < dirBuf.length - 1) dirBuf[p++] = c; }
    dirBuf[p] = 0;

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
//   - every hook cycle calls scanVanishedWrappers(sessionId), which finds
//     markers older than startTs + timeoutSec + GRACE_SEC, emits a
//     GroundError with origin="exec.wrapper.vanished", and unlinks
//
// Two ways a marker can be stale:
//   (a) wrapper died silently — the case this exists for
//   (b) the scanning hook fired before the wrapper cleared — impossible
//       within timeoutSec+GRACE_SEC, since the wrapper's timeout branch
//       clears+emits after SIGTERM+SIGKILL sequence which takes ≤2s

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
    auto home = getHomeStr();
    if (home is null) return 0;
    size_t p = 0;
    foreach (c; home) { if (p < buf.length - 1) buf[p++] = c; }
    foreach (c; "/.local/share/ground/exec-inflight") { if (p < buf.length - 1) buf[p++] = c; }
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

// Every-hook: scan this session's inflight markers. For any older than
// startTs + timeoutSec + GRACE_SEC, emit a GroundError via deliverError
// (origin "exec.wrapper.vanished") and unlink so we don't re-emit on
// subsequent hooks. Best-effort — failure to enumerate is itself silent
// (there's no meaningful Error to raise about a missing HOME).
void scanVanishedWrappers(string sessionId) {
    import core.stdc.time : time;

    if (sessionId.length == 0) return;

    auto home = getHomeStr();
    if (home is null) return;

    // Enumerate via popen(ls) — same pattern as watch.d. readdir on macOS
    // links against the 32-bit-inode struct which D's core.stdc.dirent
    // doesn't match, so shell-out is the portable path.
    char[1024] cmd = 0;
    size_t cp = 0;
    void put(const(char)[] s) { foreach (c; s) if (cp < cmd.length - 1) cmd[cp++] = c; }
    put("ls ");
    put(home);
    put("/.local/share/ground/exec-inflight/");
    put(sessionId);
    put("__*.mark 2>/dev/null");
    cmd[cp] = 0;

    auto pipe = popen(&cmd[0], "r\0".ptr);
    if (pipe is null) return;

    auto now = cast(long) time(null);

    char[512] line = 0;
    while (true) {
        size_t ll = 0;
        while (ll < line.length - 1) {
            char[1] ch;
            if (fread(&ch[0], 1, 1, pipe) != 1) break;
            if (ch[0] == '\n') break;
            line[ll++] = ch[0];
        }
        if (ll == 0) break;
        line[ll] = 0;

        // Read the marker file's own content for its metadata.
        int fd = open(&line[0], O_RDONLY, 0);
        if (fd < 0) continue;
        char[4096] cbuf = 0;
        auto n = read(fd, &cbuf[0], cbuf.length - 1);
        close(fd);
        if (n <= 0) continue;
        auto body_ = cast(const(char)[]) cbuf[0 .. cast(size_t) n];

        // Parse: startTs\ntimeoutSec\ncontrolName\ntoolUseId\ncwd
        long startTs = 0;
        int timeoutSec = 0;
        const(char)[] controlName;
        const(char)[] toolUseId;
        {
            size_t i = 0;
            // startTs
            while (i < body_.length && body_[i] >= '0' && body_[i] <= '9') {
                startTs = startTs * 10 + (body_[i] - '0'); i++;
            }
            if (i < body_.length && body_[i] == '\n') i++;
            // timeoutSec
            while (i < body_.length && body_[i] >= '0' && body_[i] <= '9') {
                timeoutSec = timeoutSec * 10 + (body_[i] - '0'); i++;
            }
            if (i < body_.length && body_[i] == '\n') i++;
            // controlName up to next \n
            auto cs = i;
            while (i < body_.length && body_[i] != '\n') i++;
            controlName = body_[cs .. i];
            if (i < body_.length) i++;
            // toolUseId up to next \n
            auto ts = i;
            while (i < body_.length && body_[i] != '\n') i++;
            toolUseId = body_[ts .. i];
        }

        auto ageDeadline = startTs + cast(long) timeoutSec + GRACE_SEC;
        if (now < ageDeadline) continue;

        // Extract wrapperPid from the filename tail: <sid>__<pid>.mark
        int wrapperPid = 0;
        {
            // scan from end backwards past ".mark"
            size_t e = ll;
            if (e > 5) e -= 5; // skip ".mark"
            size_t s = e;
            while (s > 0 && line[s - 1] >= '0' && line[s - 1] <= '9') s--;
            foreach (i; s .. e) wrapperPid = wrapperPid * 10 + (line[i] - '0');
        }

        // Copy fields so the strings survive after we unlink the file /
        // reuse cbuf. cbuf is stack; copy into __gshared bufs.
        __gshared char[256] cnBuf = 0;
        __gshared char[128] tuBuf = 0;
        size_t cnl = controlName.length < cnBuf.length ? controlName.length : cnBuf.length - 1;
        foreach (i; 0 .. cnl) cnBuf[i] = controlName[i];
        size_t tul = toolUseId.length < tuBuf.length ? toolUseId.length : tuBuf.length - 1;
        foreach (i; 0 .. tul) tuBuf[i] = toolUseId[i];

        GroundError err;
        err.origin      = "exec.wrapper.vanished";
        err.message     = "wrapper process died before delivering result";
        err.errnoVal    = 0;
        err.exitCode    = -1;
        err.sessionId   = sessionId;
        err.controlName = cast(string) cnBuf[0 .. cnl];
        err.toolUseId   = cast(string) tuBuf[0 .. tul];
        err.timestamp   = now;
        err.stdout      = "";
        err.stderr      = "";
        cast(void) deliverError(err);

        unlink(&line[0]);
    }

    pclose(pipe);
}

// --- Watch health / delivery-pipeline check ---
//
// Under the ERROR AXIOM: if the watch daemon dies mid-cycle or fails to
// spawn, rows written by dispatchExec's wrapper sit in the db forever and
// no one sees them. That's a silent violation.
//
// The check combines two signals to avoid false positives:
//   - isWatchAlive: pid file exists and its pid is still running
//   - countPendingImmediateForSession: undelivered immediate:* rows for
//     this session
//
// Watch dead + no pending: normal state between Stops (watch exits 2 after
// delivering). Pending + watch alive: normal wait for next 2s poll. Only
// BOTH together indicate a broken pipeline.
//
// Callers: at Stop, use immediateBacklogMessage to prepend the warning to
// the Stop response so it surfaces at point of interaction. At PostToolUse,
// use writeImmediateBacklogStderr as best-effort visibility (stderr from
// PostToolUse shows in Claude Code's transcript-mode view).

// Returns the number of pending immediate:* messages for this session
// when the watch daemon is dead, or 0 otherwise (either watch alive OR
// nothing pending).
long detectImmediateBacklog(string sessionId) {
    import db : openDb, sqlite3_close;
    import immediate : countPendingImmediateForSession;
    import watch : isWatchAlive;

    if (sessionId.length == 0) return 0;
    if (isWatchAlive(sessionId)) return 0;

    auto db = openDb();
    if (db is null) return 0;
    auto n = countPendingImmediateForSession(db, sessionId);
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
    put("ground error: ");
    putI(n);
    put(" undelivered exec message(s) — watch daemon is not running for this session");
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
    err.origin      = "watch.dead";
    err.message     = cast(string) msg;
    err.sessionId   = sessionId;
    err.controlName = "";
    err.toolUseId   = "";
    import core.stdc.time : time;
    err.timestamp   = cast(long) time(null);
    cast(void) writeBreadcrumb(err);
}

// octal! helper mirrored from exec.d — small and self-contained.
private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}

