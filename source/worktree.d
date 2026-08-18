module worktree;

// WorktreeCreate replaces git's own behaviour: the hook makes the tree and
// prints where it is. Printing nothing fails the creation, so this event is
// the one place main.d's unhandled-event fallthrough is wrong.

import core.stdc.stdio : stdout, stderr, fputs, fwrite;
import db : ZBuf;

struct Path {
    char[512] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

// A truncated path is not a shorter path, it is a different one, and it reads
// as valid all the way to git. Overflow answers like the empty case does.
private bool put(ref Path p, const(char)[] s) {
    if (s.length > p.buf.length - p.len) return false;
    foreach (c; s) p.buf[p.len++] = c;
    return true;
}

// popen is /bin/sh, so an interpolated value is sh source until it is quoted.
// `'\''` closes the quote, emits a literal one, and reopens. That is total over
// any byte string, so no value is refused for what it contains — only for size.
bool addQuoted(char[] buf, ref size_t n, const(char)[] s) {
    bool one(char c) {
        if (n >= buf.length - 1) return false;
        buf[n++] = c;
        return true;
    }
    if (!one('\'')) return false;
    foreach (c; s) {
        if (c == '\'') {
            if (!one('\'') || !one('\\') || !one('\'') || !one('\'')) return false;
        } else if (!one(c)) return false;
    }
    return one('\'');
}

// A command and whether all of it fit.
struct TreeCmd {
    char[1400] buf = 0;
    size_t len;
    bool ok = true;
    const(char)[] text() const return { return ok ? buf[0 .. len] : null; }
}

private void put(ref TreeCmd c, const(char)[] s) {
    foreach (ch; s) { if (c.len < c.buf.length - 1) c.buf[c.len++] = ch; else c.ok = false; }
}

private void putQ(ref TreeCmd c, const(char)[] s) {
    if (!addQuoted(c.buf[], c.len, s)) c.ok = false;
}

// A worktree holding nothing. git 2.28 has no `worktree add --orphan`, so the
// empty tree is named directly and a commit is built onto it — no parent, no
// files. The checkout that results holds `.git` and nothing else.
TreeCmd emptyTreeCmd(const(char)[] repo, const(char)[] path, const(char)[] branch) {
    TreeCmd c;
    if (repo.length == 0 || path.length == 0 || branch.length == 0) {
        c.ok = false;
        return c;
    }

    c.put("git -C ");
    c.putQ(repo);
    c.put(" branch ");
    c.putQ(branch);
    c.put(" $(git -C ");
    c.putQ(repo);
    c.put(" commit-tree $(git -C ");
    c.putQ(repo);
    c.put(" hash-object -t tree /dev/null) -m 'ground stage') 2>&1");

    c.put(" && git -C ");
    c.putQ(repo);
    c.put(" worktree add ");
    c.putQ(path);
    c.put(" ");
    c.putQ(branch);
    c.put(" 2>&1");
    return c;
}

// A sibling of the repo, so `git worktree list` names something a person can
// cd into. An empty result is a refusal — an empty stdout reads to Claude Code
// as no path at all, and fails the creation without saying why.
Path worktreePath(const(char)[] cwd, const(char)[] name) {
    Path p;
    if (cwd.length == 0 || name.length == 0) return p;

    auto root = cwd;
    while (root.length > 1 && root[$ - 1] == '/') root = root[0 .. $ - 1];
    if (root.length == 0) return p;

    if (!p.put(root) || !p.put("-") || !p.put(name)) {
        Path refused;
        return refused;
    }
    return p;
}

// `git worktree add <path>` is run below without -b, so git takes the branch
// name from the path's last segment.
const(char)[] branchOf(const(char)[] path) {
    size_t start;
    foreach (i, c; path) if (c == '/') start = i + 1;
    return path[start .. $];
}

extern (C) {
    import core.stdc.stdio : FILE;
    FILE* popen(const(char)* command, const(char)* mode);
    int pclose(FILE* stream);
}

// Which kind of tree this path is for. The ritual says, and the row is what
// connects the path back to the ritual that named it.
private bool wantsEmptyTree(const(char)[] path) {
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import ritual.store : readPositionAt;

    auto db = openDb();
    if (db is null) return false;
    auto found = readPositionAt(db, path);
    sqlite3_close(db);
    if (!found.valid) return false;

    static immutable parsed = allParsed;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != found.p.ritual) continue;
        return parsed.rituals[i].tree == "empty";
    }
    return false;
}

int handleWorktreeCreate(const(char)[] input, const(char)[] cwd) {
    import parse : extractJsonString;
    import exec : emitError;

    char[256] nameBuf = 0;
    auto name = extractJsonString(input, `"name"`, &nameBuf[0], nameBuf.length);
    if (name is null) name = "";

    auto path = worktreePath(cwd, name);
    if (path.len == 0) {
        emitError("worktree.path", "no cwd or no name, so there is nowhere to put the tree",
                  0, 1, "", "worktree", "", "", "");
        fputs("ground: WorktreeCreate got no name to build a path from\n", stderr);
        return 1;
    }

    __gshared char[1400] cmd = 0;
    size_t n;
    bool ok = true;
    void add(const(char)[] s) {
        foreach (c; s) { if (n < cmd.length - 1) cmd[n++] = c; else ok = false; }
    }

    // The row is written before the agent spawns and already carries the path,
    // so the performance is findable here even though the tree is not there.
    if (wantsEmptyTree(path.text())) {
        auto e = emptyTreeCmd(cwd, path.text(), branchOf(path.text()));
        ok = e.ok;
        add(e.text());
    } else {
        add("git -C ");
        ok = addQuoted(cmd[], n, cwd) && ok;
        add(" worktree add ");
        ok = addQuoted(cmd[], n, path.text()) && ok;
        add(" 2>&1");
    }
    cmd[n] = 0;

    // A command that did not fit is a different command. sh would still run it.
    if (!ok) {
        emitError("worktree.cmd", "the git command did not fit, so it was not run",
                  0, 1, "", "worktree", "", "", "");
        fputs("ground: WorktreeCreate could not build a command that fits\n", stderr);
        return 1;
    }

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) {
        emitError("worktree.popen", "could not run git worktree add",
                  0, 1, "", "worktree", "", "", "");
        return 1;
    }

    import core.stdc.stdio : fread;
    char[2048] outBuf = 0;
    size_t outLen;
    for (;;) {
        auto got = fread(&outBuf[outLen], 1, outBuf.length - outLen - 1, pipe);
        if (got == 0) break;
        outLen += got;
        if (outLen >= outBuf.length - 1) break;
    }
    auto status = pclose(pipe);

    if (status != 0) {
        emitError("worktree.git", "git worktree add failed",
                  0, (status >> 8) & 0xFF, "", "worktree", "",
                  cast(string) outBuf[0 .. outLen], "");
        fwrite(&outBuf[0], 1, outLen, stderr);
        return 1;
    }

    // Creation was silent until now: a directory and a branch appeared and the
    // only way to learn of either was git worktree list.
    {
        import parse : extractSessionId;
        import db : openDb, sqlite3_close;
        import immediate : writeNote;
        auto sid = extractSessionId(input);
        if (sid !is null && sid.length > 0) {
            auto db = openDb();
            if (db !is null) {
                __gshared ZBuf note;
                note.reset();
                note.put("ground made a worktree at ");
                note.put(path.text());
                writeNote(db, sid, "worktree-create", note.slice());
                sqlite3_close(db);
            }
        }
    }

    fwrite(path.buf.ptr, 1, path.len, stdout);
    fputs("\n", stdout);
    return 0;
}

// Ground cannot refuse the removal and gets no say in it, so all it can do is
// write down that the route is gone. The record outlives the tree because the
// performance is keyed on itself, not on where it happened.
int handleWorktreeRemove(const(char)[] input, const(char)[] cwd) {
    import parse : extractSessionId, extractJsonString;
    import db : openDb, sqlite3_close;
    import immediate : writeNote;
    import ritual : readPositionAt, writePosition;

    char[512] pathBuf = 0;
    auto gone = extractJsonString(input, `"path"`, &pathBuf[0], pathBuf.length);
    if (gone is null || gone.length == 0) gone = cwd;

    auto db = openDb();
    if (db is null) return 0;

    auto found = readPositionAt(db, gone);
    if (found.valid) {
        // The path is an index, and this one no longer resolves. Clearing it
        // is the difference between a record with a stale route and a record
        // that claims a directory which is not there.
        auto p = found.p;
        p.worktree = "";
        writePosition(db, p);
    }

    auto sid = extractSessionId(input);
    if (sid !is null && sid.length > 0) {
        __gshared ZBuf note;
        note.reset();
        note.put("a worktree went away: ");
        note.put(gone);
        if (found.valid) note.put(" — a performance was being done there");
        writeNote(db, sid, "worktree-remove", note.slice());
    }

    sqlite3_close(db);
    return 0;
}

// A tree ground made for a performance is ground's to remove. Nothing else
// will: no WorktreeRemove fires for one ground created, measured on a probe
// tree that is still on disk.
bool removeWorktree(const(char)[] repo, const(char)[] tree) {
    import exec : emitError;
    if (repo.length == 0 || tree.length == 0) return false;

    __gshared char[1400] cmd = 0;
    size_t n;
    bool ok = true;
    void add(const(char)[] s) {
        foreach (c; s) { if (n < cmd.length - 1) cmd[n++] = c; else ok = false; }
    }
    add("git -C ");
    ok = addQuoted(cmd[], n, repo) && ok;
    add(" worktree remove --force ");
    ok = addQuoted(cmd[], n, tree) && ok;
    add(" 2>&1");
    cmd[n] = 0;

    if (!ok) {
        emitError("worktree.remove.cmd", "the git command did not fit, so it was not run",
                  0, 1, "", "worktree", "", "", "");
        return false;
    }

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) {
        emitError("worktree.remove.popen", "could not run git worktree remove",
                  0, 1, "", "worktree", "", "", "");
        return false;
    }

    import core.stdc.stdio : fread;
    char[1024] outBuf = 0;
    size_t outLen;
    for (;;) {
        auto got = fread(&outBuf[outLen], 1, outBuf.length - outLen - 1, pipe);
        if (got == 0) break;
        outLen += got;
        if (outLen >= outBuf.length - 1) break;
    }
    auto status = pclose(pipe);

    if (status != 0) {
        emitError("worktree.remove.git", "git worktree remove failed",
                  0, (status >> 8) & 0xFF, "", "worktree", "",
                  cast(string) outBuf[0 .. outLen], "");
        return false;
    }
    return true;
}
