module rite;

// A rite's exit code is a verdict with three readings, not a boolean.
enum Verdict {
    Advance,  // the declared pass code — this rite is answered
    Hold,     // a declared catch code — not yet, run it again
    Halt,     // undeclared — the rite cannot read this, so it stops
}

// Two readings has nowhere to put "the command did not run": 127, 130 and 2
// all flatten to false, which the caller reads as a finding. Halt is the
// refusal to guess — the number goes in front of the operator instead.
Verdict classify(R)(int code, const R r) {
    if (code == r.pass) return Verdict.Advance;
    foreach (i; 0 .. r.catchCount)
        if (code == r.catches[i]) return Verdict.Hold;
    return Verdict.Halt;
}

// The whole rite as one readable script: the flags, the params, the command.
// Printable, pasteable, runnable by hand — the rite has no hidden half.
struct RiteScript {
    char[4096] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref RiteScript s, const(char)[] t) {
    foreach (c; t) {
        if (s.len >= s.buf.length) return;
        s.buf[s.len++] = c;
    }
}

private void putNum(ref RiteScript s, int v) {
    char[12] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) s.put(d[n - 1 - i .. n - i]);
}

// Single-quote a value and end the quoting around any quote inside it, so no
// part of a param is ever read as shell.
private void putQuoted(ref RiteScript s, const(char)[] v) {
    s.put("'");
    foreach (c; v) {
        if (c == '\'') s.put(`'\''`);
        else { if (s.len >= s.buf.length) return; s.buf[s.len++] = c; }
    }
    s.put("'");
}

// envSubst hands back an unknown ${key} unchanged, which is harmless in a
// message and a hole in a command. A rite carrying one does not run.
bool hasUnresolved(const(char)[] cmd) {
    foreach (i; 0 .. cmd.length)
        if (i + 1 < cmd.length && cmd[i] == '$' && cmd[i + 1] == '{') return true;
    return false;
}

// Why a rite never reached a process. Not an exit code — nothing exited.
enum RunFailure { None, Mkstemp, Write, Chmod, Popen, Pclose }

// A rite that could not reach its tree never evaluated its condition. Silence
// about catch means 1, so a failed cd read as "not yet"; this code is outside
// what a condition returns, and CTFE refuses a rite that declares it.
enum RITE_UNREACHED = 125;

// RunFailure is "nothing exited". This is the third category: a process ran
// and exited, but the condition never did.
bool unreached(int code) { return code == RITE_UNREACHED; }

// What one run of a rite produced. `ran` is the gate: a code is only the
// verdict's input when a process actually produced it.
struct RiteRun {
    bool ran;
    int code;
    RunFailure failure;
    char[4096] out_ = 0;
    size_t outLen;
    const(char)[] output() const return { return out_[0 .. outLen]; }
}

// pclose hands back a wait status. -1 means it could not wait at all, and
// shifting that yields 255 — a code no process returned.
struct Waited { bool valid; int code; }

Waited fromPclose(int status) {
    if (status < 0) return Waited(false, 0);
    return Waited(true, (status >> 8) & 0xFF);
}

RiteScript buildRiteScript(const(char)[] cwd, const(char)[] cmd,
                           const(char[])[] keys, const(char[])[] values) {
    RiteScript s;
    // pipefail is not POSIX. /bin/sh is dash on Debian, which rejects the
    // whole `set` line, so the rite fails before its command runs.
    s.put("#!/usr/bin/env bash\nset -euo pipefail\n");

    // Whoever runs the rite is not standing in the performance's tree. The cd
    // is in the script so the whole rite is still one readable thing.
    if (cwd.length > 0) {
        s.put("cd ");
        s.putQuoted(cwd);
        s.put(" || exit ");
        s.putNum(RITE_UNREACHED);
        s.put("\n");
    }
    foreach (i; 0 .. keys.length) {
        if (keys[i].length == 0) continue;
        s.put(keys[i]);
        s.put("=");
        s.putQuoted(i < values.length ? values[i] : "");
        s.put("\n");
    }
    s.put(cmd);
    s.put("\n");
    return s;
}

// A rite ready to run, or the reason it is not.
struct PreparedRite {
    RiteScript script;
    bool ready;
    const(char)[] cmd;
}

// Both halves of a rite are prepared the same way — `run` and `eval` differ in
// when they fire and how their code is read, not in how they are built.
PreparedRite prepareCmd(const(char)[] cmd, const(char)[] cwd,
                        const(char[])[] keys = [], const(char[])[] values = []) {
    import matcher : envSubst;
    PreparedRite p;
    p.cmd = envSubst(cmd, cwd);
    p.ready = !hasUnresolved(p.cmd);
    if (p.ready) p.script = buildRiteScript(cwd, p.cmd, keys, values);
    return p;
}

PreparedRite prepareRite(R)(const R r, const(char)[] cwd,
                            const(char[])[] keys = [], const(char[])[] values = []) {
    return prepareCmd(r.eval, cwd, keys, values);
}

extern (C) {
    int mkstemp(char* templ);
    long write(int fd, const(void)* buf, size_t count);
    int close(int fd);
    int unlink(const(char)* path);
    int chmod(const(char)* path, uint mode);
}

// Run the script and keep the exit code. cwd is inherited: a ritual only
// fires where scopeMatches already put us, so the rite runs in the project
// it names by construction, not by a cd nobody can see.
RiteRun runRite(const(char)[] script, string riteName = "", string sessionId = "") {
    import core.stdc.stdio : FILE, fread;
    import core.stdc.errno : errno;
    import db : popen, pclose;
    import exec : emitError;

    RiteRun r;

    RiteRun fail(RunFailure f, string origin, string message) {
        r.failure = f;
        emitError(origin, message, errno(), 0, sessionId, riteName, "", "", "");
        return r;
    }

    char[64] path = 0;
    enum templ = "/tmp/ground-rite-XXXXXX";
    foreach (i, c; templ) path[i] = c;
    int fd = mkstemp(&path[0]);
    if (fd < 0)
        return fail(RunFailure.Mkstemp, "rite.mkstemp", "could not create the rite script");
    if (write(fd, script.ptr, script.length) != cast(long) script.length) {
        close(fd);
        unlink(&path[0]);
        return fail(RunFailure.Write, "rite.write", "wrote fewer bytes than the rite script");
    }
    close(fd);
    if (chmod(&path[0], 0x1C0) != 0) {
        unlink(&path[0]);
        return fail(RunFailure.Chmod, "rite.chmod", "could not make the rite script executable");
    }

    // Executed directly so the script's own shebang picks the interpreter.
    char[128] cmd = 0;
    size_t n;
    foreach (c; path) { if (c == 0) break; cmd[n++] = c; }
    foreach (c; " 2>&1") cmd[n++] = c;

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) {
        unlink(&path[0]);
        return fail(RunFailure.Popen, "rite.popen", "could not start the rite script");
    }

    // Keep the tail. A rite that halts is read by a person, and the last
    // lines are where the reason is.
    char[1024] chunk;
    for (;;) {
        auto got = fread(&chunk[0], 1, chunk.length, pipe);
        if (got == 0) break;
        tailAppend(&r.out_[0], r.outLen, r.out_.length, chunk[0 .. got]);
    }

    auto waited = fromPclose(pclose(pipe));
    unlink(&path[0]);
    if (!waited.valid)
        return fail(RunFailure.Pclose, "rite.pclose", "could not collect the rite's exit status");
    r.ran = true;
    r.code = waited.code;
    return r;
}

private void tailAppend(char* buf, ref size_t len, size_t cap, const(char)[] chunk) {
    if (chunk.length >= cap) {
        foreach (i; 0 .. cap) buf[i] = chunk[chunk.length - cap + i];
        len = cap;
        return;
    }
    if (len + chunk.length > cap) {
        auto drop = len + chunk.length - cap;
        for (size_t i = 0; i < len - drop; i++) buf[i] = buf[i + drop];
        len -= drop;
    }
    foreach (i; 0 .. chunk.length) buf[len + i] = chunk[i];
    len += chunk.length;
}
