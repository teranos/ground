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

// Where the performance said its tree goes, decided once when the row was
// written. Empty when this name names no performance — a worktree asked for
// by anything other than a ritual.
Path plannedTree(const(char)[] name) {
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import ritual.store : byPerformanceId;

    Path p;
    if (__ctfe || name.length == 0) return p;

    auto db = openDb();
    if (db is null) return p;
    auto found = byPerformanceId(db, name);
    sqlite3_close(db);
    if (!found.valid) return p;

    if (!p.put(found.p.worktree)) {
        Path refused;
        return refused;
    }
    return p;
}

// Which kind of tree this path is for. The ritual says, and the row is what
// connects the path back to the ritual that named it.
private bool wantsEmptyTree(const(char)[] name) {
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import ritual.store : byPerformanceId;

    auto db = openDb();
    if (db is null) return false;
    auto found = byPerformanceId(db, name);
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

    // The row decided this when the performance was written. Deriving a second
    // path from cwd is what let the two disagree: the tree was made under one
    // name and the driver waited on the other, forever.
    auto path = plannedTree(name);
    if (path.len == 0) path = worktreePath(cwd, name);
    if (path.len == 0) {
        emitError("worktree.path", "no cwd or no name, so there is nowhere to put the tree",
                  0, 1, "", "worktree", "", "", "");
        fputs("ground: WorktreeCreate got no name to build a path from\n", stderr);
        return 1;
    }

    // Made in this process by libgit2. The row is written before the agent
    // spawns, so the performance answers for its own tree here even though
    // the tree is not there yet.
    import libgit2 : Repo;
    __gshared Repo g;
    bool made = g.open(cwd);
    if (made) {
        made = wantsEmptyTree(name) ? g.addEmptyWorktree(path.text(), branchOf(path.text()))
                                    : g.addWorktree(path.text());
        g.close();
    }
    if (!made) {
        emitError("worktree.git", "the worktree was not made",
                  0, 1, "", "worktree", "", cast(string) g.why(), "");
        fwrite(g.why().ptr, 1, g.why().length, stderr);
        fputs("\n", stderr);
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

// A tree ground made for a performance is ground's to remove. WorktreeRemove
// fires for a tree a person made.
bool removeWorktree(const(char)[] repo, const(char)[] tree) {
    import exec : emitError;
    if (repo.length == 0 || tree.length == 0) return false;
    import libgit2 : Repo;
    __gshared Repo g;
    bool removed = g.open(repo) && g.removeWorktree(tree);
    g.close();
    if (!removed) {
        emitError("worktree.remove.git", "the worktree was not removed",
                  0, 1, "", "worktree", "", cast(string) g.why(), "");
        return false;
    }
    return true;
}
