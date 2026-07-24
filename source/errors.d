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
    long write(int fd, const(void)* buf, size_t count);
    int close(int fd);
    int mkdir(const(char)* path, uint mode);
}

enum O_WRONLY = 1;
enum O_CREAT  = 0x0200; // macOS
enum O_APPEND = 8;
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

// octal! helper mirrored from exec.d — small and self-contained.
private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}
