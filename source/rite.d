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

// What one run of a rite produced. The code is the verdict's input; the
// output is what goes on screen when the verdict is Halt.
struct RiteRun {
    int code;
    char[4096] out_ = 0;
    size_t outLen;
    const(char)[] output() const return { return out_[0 .. outLen]; }
}

RiteScript buildRiteScript(const(char)[] cmd,
                           const(char[])[] keys, const(char[])[] values) {
    RiteScript s;
    s.put("set -euo pipefail\n");
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

PreparedRite prepareRite(R)(const R r, const(char)[] cwd,
                            const(char[])[] keys = [], const(char[])[] values = []) {
    import matcher : envSubst;
    PreparedRite p;
    p.cmd = envSubst(r.cmd, cwd);
    p.ready = !hasUnresolved(p.cmd);
    if (p.ready) p.script = buildRiteScript(p.cmd, keys, values);
    return p;
}

extern (C) {
    int mkstemp(char* templ);
    long write(int fd, const(void)* buf, size_t count);
    int close(int fd);
    int unlink(const(char)* path);
}

// Run the script and keep the exit code. cwd is inherited: a ritual only
// fires where scopeMatches already put us, so the rite runs in the project
// it names by construction, not by a cd nobody can see.
RiteRun runRite(const(char)[] script) {
    import core.stdc.stdio : FILE, fread;
    import db : popen, pclose;

    RiteRun r;
    r.code = -1;

    char[64] path = 0;
    enum templ = "/tmp/ground-rite-XXXXXX";
    foreach (i, c; templ) path[i] = c;
    int fd = mkstemp(&path[0]);
    if (fd < 0) return r;
    if (write(fd, script.ptr, script.length) != cast(long) script.length) {
        close(fd);
        unlink(&path[0]);
        return r;
    }
    close(fd);

    char[128] cmd = 0;
    size_t n;
    foreach (c; "/bin/sh ") cmd[n++] = c;
    foreach (c; path) { if (c == 0) break; cmd[n++] = c; }
    foreach (c; " 2>&1") cmd[n++] = c;

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) { unlink(&path[0]); return r; }

    // Keep the tail. A rite that halts is read by a person, and the last
    // lines are where the reason is.
    char[1024] chunk;
    for (;;) {
        auto got = fread(&chunk[0], 1, chunk.length, pipe);
        if (got == 0) break;
        tailAppend(&r.out_[0], r.outLen, r.out_.length, chunk[0 .. got]);
    }

    auto status = pclose(pipe);
    unlink(&path[0]);
    r.code = (status >> 8) & 0xFF;
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
