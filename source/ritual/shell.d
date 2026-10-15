module ritual.shell;

// BOOK_GLOSSARY **Held shell**: The nix dev shell of a performance's tree, entered once and sourced by every rite.

// "One nix shell held across a ritual's rites, re-entered only when flake.nix or flake.lock changed."

import ritual.run : SpawnScript, put;
import db : ZBuf;

// One quoted word made of a path and what follows it, so `.sh.new` is inside
// the quotes rather than glued on after them.
private void quoted(ref SpawnScript s, const(char)[] path, const(char)[] suffix = "") {
    s.put("'");
    escaped(s, path);
    escaped(s, suffix);
    s.put("'");
}

private void escaped(ref SpawnScript s, const(char)[] part) {
    foreach (i; 0 .. part.length) {
        if (part[i] == '\'') s.put(`'\''`);
        else s.put(part[i .. i + 1]);
    }
}

// --profile roots what the shell points at, as the Makefile roots ground's own
// toolchain, so a garbage collection cannot take it while a rite runs.
SpawnScript enterScript(const(char)[] tree, const(char)[] profile) {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\ncd ");
    s.quoted(tree);
    s.put(" || exit 125\nnix print-dev-env --profile ");
    s.quoted(profile);
    s.put(" > ");
    s.quoted(profile, ".sh.new");
    s.put("\nmv ");
    s.quoted(profile, ".sh.new");
    s.put(" ");
    s.quoted(profile, ".sh");
    s.put("\nenv -0 > ");
    s.quoted(profile, ".before");
    s.put("\nsource ");
    s.quoted(profile, ".sh");
    s.put("\nenv -0 > ");
    s.quoted(profile, ".after");
    s.put("\n");
    return s;
}

struct EnvLines {
    char[65536] buf = 0;
    size_t len;
    bool over;
    const(char)[] text() const return { return buf[0 .. len]; }
    void put(const(char)[] t) {
        foreach (c; t) { if (len < buf.length) buf[len++] = c; else over = true; }
    }
}

private bool assignable(const(char)[] name) {
    if (name.length == 0 || name == "_") return false;
    foreach (i, c; name) {
        bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        if (!letter && !(i > 0 && c >= '0' && c <= '9')) return false;
    }
    return true;
}

private bool holds(const(char)[] env, const(char)[] entry) {
    size_t start = 0;
    foreach (i; 0 .. env.length + 1) {
        if (i < env.length && env[i] != 0) continue;
        if (env[start .. i] == entry) return true;
        start = i + 1;
    }
    return false;
}

// Every variable `after` holds that `before` does not hold the same, as an
// export a zsh or a bash reads alike.
EnvLines envLines(const(char)[] before, const(char)[] after) {
    EnvLines e;
    size_t start = 0;
    foreach (i; 0 .. after.length + 1) {
        if (i < after.length && after[i] != 0) continue;
        auto entry = after[start .. i];
        start = i + 1;
        size_t eq = 0;
        while (eq < entry.length && entry[eq] != '=') eq++;
        if (eq >= entry.length || !assignable(entry[0 .. eq])) continue;
        if (holds(before, entry)) continue;
        e.put("export ");
        e.put(entry[0 .. eq]);
        e.put("='");
        foreach (j; eq + 1 .. entry.length) {
            if (entry[j] == '\'') e.put(`'\''`);
            else e.put(entry[j .. j + 1]);
        }
        e.put("'\n");
    }
    return e;
}

// Every generation the profile made, the script, and the key go together.
SpawnScript forgetScript(const(char)[] profile) {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\nrm -f ");
    s.quoted(profile);
    s.put(" ");
    s.quoted(profile);
    s.put("-*-link ");
    s.quoted(profile, ".sh");
    s.put(" ");
    s.quoted(profile, ".key");
    s.put(" ");
    s.quoted(profile, ".env");
    s.put(" ");
    s.quoted(profile, ".before");
    s.put(" ");
    s.quoted(profile, ".after");
    s.put("\n");
    return s;
}

SpawnScript sessionLine(const(char)[] profile) {
    SpawnScript s;
    s.put("source ");
    s.quoted(profile, ".env");
    s.put("\n");
    return s;
}

// The session carrying this performance runs every Bash command after the
// line above. No guard: a command run before the shell is entered says so.
void sessionSources(const(char)[] perfId, const(char)[] tree) {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : fopen, fwrite, fclose;
    import exec : emitError;
    if (flakeKey(tree) == 0) return;
    auto envFile = getenv("CLAUDE_ENV_FILE\0".ptr);
    if (envFile is null) {
        emitError("ritual.shell.session", "SessionStart had no CLAUDE_ENV_FILE, so the session's commands run outside the held nix shell",
                  0, 1, "", "", "", cast(string) perfId, "");
        return;
    }
    auto line = sessionLine(profileOf(perfId));
    auto f = fopen(envFile, "a");
    if (f is null) {
        emitError("ritual.shell.session", "CLAUDE_ENV_FILE could not be opened, so the session's commands run outside the held nix shell",
                  0, 1, "", "", "", cast(string) perfId, "");
        return;
    }
    fwrite(line.text().ptr, 1, line.text().length, f);
    fclose(f);
}

// Never entered, a changed flake.nix or flake.lock, or a script gone from
// under it. Nothing else re-enters.
bool mustEnter(ulong held, ulong now, bool scriptThere) {
    return held != now || !scriptThere;
}

// FNV-1a over flake.nix, a separator, then flake.lock. Zero means the tree has
// no flake.nix, and there is no shell to hold.
ulong flakeKey(const(char)[] tree) {
    ulong h = 14_695_981_039_346_656_037UL;
    if (!fold(h, tree, "/flake.nix")) return 0;
    h ^= 0xFF;
    h *= 1_099_511_628_211UL;
    cast(void) fold(h, tree, "/flake.lock");
    return h == 0 ? 1 : h;
}

private bool fold(ref ulong h, const(char)[] dir, const(char)[] leaf) {
    import core.stdc.stdio : fopen, fread, fclose;
    __gshared ZBuf p;
    p.reset();
    p.put(dir);
    p.put(leaf);
    auto f = fopen(p.ptr(), "r");
    if (f is null) return false;
    ubyte[4096] chunk;
    for (;;) {
        auto got = fread(&chunk[0], 1, chunk.length, f);
        if (got == 0) break;
        foreach (b; chunk[0 .. got]) {
            h ^= b;
            h *= 1_099_511_628_211UL;
        }
    }
    fclose(f);
    return true;
}

private const(char)* beside(const(char)[] profile, const(char)[] suffix) {
    __gshared ZBuf p;
    p.reset();
    p.put(profile);
    p.put(suffix);
    return p.ptr();
}

// The key the held shell was entered under. Zero when none was.
ulong heldKey(const(char)[] profile) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto f = fopen(beside(profile, ".key"), "r");
    if (f is null) return 0;
    char[24] buf = 0;
    auto got = fread(&buf[0], 1, buf.length, f);
    fclose(f);
    ulong v = 0;
    foreach (c; buf[0 .. got]) {
        if (c < '0' || c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

void holdKey(const(char)[] profile, ulong key) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    __gshared ZBuf v;
    v.reset();
    v.putUint(key);
    auto f = fopen(beside(profile, ".key"), "w");
    if (f is null) return;
    fwrite(v.ptr(), 1, v.len, f);
    fclose(f);
}

extern (C) private int access(const(char)* path, int mode);

private bool scriptThere(const(char)[] profile) {
    return access(beside(profile, ".sh"), 0) == 0;
}

// <store>/shell/<performance>, its directory made on the way.
const(char)[] profileOf(const(char)[] perfId) {
    import db : storeDir, mkdirP;
    __gshared ZBuf p;
    p.reset();
    p.put(storeDir());
    p.put("/shell");
    mkdirP(p.slice());
    p.put("/");
    p.put(perfId);
    return p.slice();
}

struct Held {
    bool ok;
    // What every rite sources. Empty for a tree with no flake.nix.
    const(char)[] script;
    int code;
    const(char)[] output;
}

// The held shell for this performance's tree, entered first when it must be.
Held hold(const(char)[] tree, const(char)[] perfId) {
    import rite : runRite;
    Held h;
    auto key = flakeKey(tree);
    if (key == 0) { h.ok = true; return h; }

    auto profile = profileOf(perfId);
    __gshared ZBuf script;
    script.reset();
    script.put(profile);
    script.put(".sh");

    if (mustEnter(heldKey(profile), key, scriptThere(profile))) {
        auto entered = runRite(enterScript(tree, profile).text(), "held-shell", "");
        if (!entered.ran || entered.code != 0) {
            h.code = entered.code;
            h.output = entered.output();
            return h;
        }
        auto exported = writeExports(profile);
        if (exported.length > 0) {
            h.code = 1;
            h.output = exported;
            return h;
        }
        holdKey(profile, key);
    }
    h.ok = true;
    h.script = script.slice();
    return h;
}

private size_t slurp(const(char)[] profile, const(char)[] suffix, char[] into) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto f = fopen(beside(profile, suffix), "r");
    if (f is null) return size_t.max;
    auto got = fread(into.ptr, 1, into.length, f);
    fclose(f);
    return got;
}

// <profile>.env from the two env dumps the enter script left. Empty when it
// was written, otherwise why it was not.
const(char)[] writeExports(const(char)[] profile) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    __gshared char[262144] before;
    __gshared char[262144] after;
    auto b = slurp(profile, ".before", before[]);
    auto a = slurp(profile, ".after", after[]);
    if (b == size_t.max || a == size_t.max)
        return "the enter script left no .before or .after env dump";
    if (b == before.length || a == after.length)
        return "an env dump is larger than the 256 KiB read for it";
    __gshared EnvLines lines;
    lines = envLines(before[0 .. b], after[0 .. a]);
    if (lines.over)
        return "the shell's exports are larger than the 64 KiB written for them";
    auto f = fopen(beside(profile, ".env"), "w");
    if (f is null) return "the .env file could not be opened for writing";
    fwrite(lines.buf.ptr, 1, lines.len, f);
    fclose(f);
    return "";
}

// The performance is over: its shell, and the store paths the profile roots.
void forget(const(char)[] perfId) {
    import rite : runRite;
    import exec : emitError;
    auto gone = runRite(forgetScript(profileOf(perfId)).text(), "held-shell", "");
    if (gone.ran && gone.code == 0) return;
    emitError("ritual.shell.forget", "the performance's held nix shell could not be removed",
              0, gone.code, "", "", "", cast(string) perfId, cast(string) gone.output());
}
