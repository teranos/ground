module lineage;

// "maybe i want that session to inherit the name and not you"
//
// A fork starts as a new session, with the parent's messages copied into its
// transcript under their own uuids. Claude Code says only `source: fork`: both
// sides of a /fork start so, and the parent's id is left to nobody. The one
// whose copy holds the parent's last message (the /fork row itself) goes on as
// the parent and takes its key and name; the one that stops before it branched,
// and is kept as having come from the parent, for the name to be given to it.

import zbuf : ZBuf;

// As ground declares it elsewhere (exec.d): one mangled name, one signature.
private extern (C) int chmod(const(char)* path, uint mode);

enum BOOK_COMMAND = q"EOS
# the sessions that branched from the one this ground runs in, by their id:
ground forks
# the same, as the data ag draws:
ground forks json
# this session's key and name go to one of them, and its key comes here:
ground forks give fa8a1589-576c-4ecb-84c8-f7d0f357b448
EOS";

enum Line { none, continues, branches }

// The last message uuid a transcript holds; empty for none.
const(char)[] lastUuid(const(char)[] text) {
    enum key = `"uuid":"`;
    enum UUID = 36;
    const(char)[] found = text[0 .. 0];
    size_t i = 0;
    while (i + key.length + UUID < text.length) {
        if (text[i] == '"' && text[i .. i + key.length] == key && text[i + key.length + UUID] == '"') {
            found = text[i + key.length .. i + key.length + UUID];
            i += key.length + UUID;
        } else i++;
    }
    return found;
}

private bool holds(const(char)[] text, const(char)[] needle) {
    if (needle.length == 0 || needle.length > text.length) return false;
    foreach (i; 0 .. text.length - needle.length + 1)
        if (text[i] == needle[0] && text[i .. i + needle.length] == needle) return true;
    return false;
}

// What own is to parent: a copy of all of it goes on as the parent; a copy
// that stops before its last message branched; none, when parent never held
// what own ends with.
Line lineOf(const(char)[] own, const(char)[] parent) {
    auto mine = lastUuid(own);
    if (mine.length == 0 || !holds(parent, mine)) return Line.none;
    return holds(own, lastUuid(parent)) ? Line.continues : Line.branches;
}

// --- Where sessions are kept: ~/.qntx/sessions/<id>/ ---

private bool sessionsDirInto(ref ZBuf out_) {
    import core.stdc.stdlib : getenv;
    out_.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null) return false;
    size_t n = 0;
    while (home[n] != 0) n++;
    out_.put(home[0 .. n]);
    out_.put("/.qntx/sessions/");
    return true;
}

private void fileInto(ref ZBuf out_, const(char)[] id, const(char)[] file) {
    sessionsDirInto(out_);
    out_.put(id);
    out_.put("/");
    out_.put(file);
}

private bool exists(const(char)* path) {
    import core.sys.posix.sys.stat : stat, stat_t;
    stat_t st;
    return stat(path, &st) == 0;
}

private long mtimeOf(const(char)* path) {
    import core.sys.posix.sys.stat : stat, stat_t;
    stat_t st;
    if (stat(path, &st) != 0) return -1;
    return cast(long) st.st_mtime;
}

// The whole of a file, in memory the caller frees; null when it does not read.
private char[] readWhole(const(char)* path) {
    import core.stdc.stdio : fopen, fread, fclose, fseek, ftell, SEEK_END, SEEK_SET;
    import core.stdc.stdlib : malloc;
    auto f = fopen(path, "rb");
    if (f is null) return null;
    scope (exit) fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return null;
    auto n = ftell(f);
    if (n <= 0 || fseek(f, 0, SEEK_SET) != 0) return null;
    auto buf = cast(char*) malloc(cast(size_t) n);
    if (buf is null) return null;
    auto got = fread(buf, 1, cast(size_t) n, f);
    return buf[0 .. got];
}

private bool writeWhole(const(char)* path, const(char)[] text) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    auto f = fopen(path, "wb");
    if (f is null) return false;
    auto ok = fwrite(text.ptr, 1, text.length, f) == text.length;
    return fclose(f) == 0 && ok;
}

private bool copyFile(const(char)* from, const(char)* to) {
    import core.stdc.stdlib : free;
    auto text = readWhole(from);
    if (text is null) return false;
    scope (exit) free(text.ptr);
    return writeWhole(to, text);
}

// The first line of a session's file; empty for none.
private const(char)[] lineFrom(const(char)[] id, const(char)[] file, char[] buf) {
    import core.stdc.stdio : fopen, fread, fclose;
    __gshared ZBuf at;
    fileInto(at, id, file);
    auto f = fopen(at.ptr(), "rb");
    if (f is null) return buf[0 .. 0];
    auto got = fread(buf.ptr, 1, buf.length, f);
    fclose(f);
    size_t n = 0;
    while (n < got && buf[n] != '\n') n++;
    return buf[0 .. n];
}

// Every session id kept under ~/.qntx/sessions, each given to each.
private void eachSession(scope void delegate(const(char)[] id) each) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    __gshared ZBuf dir;
    if (!sessionsDirInto(dir)) return;
    auto d = opendir(dir.ptr());
    if (d is null) return;
    scope (exit) closedir(d);
    for (auto e = readdir(d); e !is null; e = readdir(d)) {
        size_t n = 0;
        while (e.d_name[n] != 0) n++;
        auto id = cast(const(char)[]) e.d_name[0 .. n];
        if (id.length == 0 || id[0] == '.') continue;
        each(id);
    }
}

// At a fork's start: the session it came from, kept as <session>/from; one
// that goes on as the parent takes its key and name before anything makes it
// one of its own. What happened is said, for the session's context; nothing,
// when this is no fork of a session kept here.
void forkStart(const(char)[] sessionId, const(char)[] transcriptPath, ref ZBuf said) {
    import core.stdc.stdlib : free;
    import core.stdc.time : time;
    import errors : mkdir;
    said.reset();
    if (sessionId.length == 0 || transcriptPath.length == 0) return;
    __gshared ZBuf ownPath;
    ownPath.reset();
    ownPath.put(transcriptPath);
    auto own = readWhole(ownPath.ptr());
    if (own is null) return;
    scope (exit) free(own.ptr);

    // Transcripts sit side by side, one a session.
    size_t slash = transcriptPath.length;
    while (slash > 0 && transcriptPath[slash - 1] != '/') slash--;
    auto dir = transcriptPath[0 .. slash];
    auto now = cast(long) time(null);

    // The parent: of every session a copy of whose messages this holds, the
    // one whose key is oldest, which a session that went on before this one
    // started does not have.
    __gshared char[64] parent;
    size_t parentLen = 0;
    long parentKey = long.max;
    Line line = Line.none;
    eachSession((const(char)[] id) {
        if (id == sessionId || id.length > parent.length) return;
        __gshared ZBuf key, theirs;
        fileInto(key, id, "key");
        auto keyAt = mtimeOf(key.ptr());
        if (keyAt < 0 || keyAt >= parentKey) return;
        theirs.reset();
        theirs.put(dir);
        theirs.put(id);
        theirs.put(".jsonl");
        // A parent was written to as the fork was made.
        if (mtimeOf(theirs.ptr()) < now - 3600) return;
        auto text = readWhole(theirs.ptr());
        if (text is null) return;
        scope (exit) free(text.ptr);
        auto l = lineOf(own, text);
        if (l == Line.none) return;
        foreach (i, c; id) parent[i] = c;
        parentLen = id.length;
        parentKey = keyAt;
        line = l;
    });
    if (parentLen == 0) return;
    auto from = parent[0 .. parentLen];

    __gshared ZBuf at, there, text;
    fileInto(at, sessionId, "");
    mkdir(at.ptr(), 448); // 0700
    fileInto(at, sessionId, "from");
    text.reset();
    text.put(from);
    text.put("\n");
    writeWhole(at.ptr(), text.slice());

    if (line == Line.branches) {
        said.put("This session branched from ");
        said.put(from);
        said.put(", and takes a key and name of its own");
        return;
    }
    fileInto(at, sessionId, "key");
    if (exists(at.ptr())) {
        said.put("This session goes on from ");
        said.put(from);
        said.put(", and holds a key of its own already");
        return;
    }
    fileInto(there, from, "key");
    if (!copyFile(there.ptr(), at.ptr())) {
        said.put("This session goes on from ");
        said.put(from);
        said.put(", and its key was not taken: it takes one of its own");
        return;
    }
    chmod(at.ptr(), 384); // 0600
    fileInto(there, from, "name");
    fileInto(at, sessionId, "name");
    if (exists(there.ptr())) copyFile(there.ptr(), at.ptr());
    fileInto(at, sessionId, "continues");
    writeWhole(at.ptr(), text.slice());
    said.put("This session goes on from ");
    said.put(from);
    said.put(", with its key and name");
}

// The sessions that branched from where this one came from, or from this one,
// and did not go on as it.
private void eachBranch(const(char)[] sessionId, scope void delegate(const(char)[] id) each) {
    char[64] fromBuf;
    auto from = lineFrom(sessionId, "from", fromBuf[]);
    eachSession((const(char)[] id) {
        if (id == sessionId) return;
        char[64] theirsBuf, goesBuf;
        auto theirs = lineFrom(id, "from", theirsBuf[]);
        if (theirs.length == 0 || (theirs != sessionId && theirs != from)) return;
        if (lineFrom(id, "continues", goesBuf[]).length > 0) return;
        each(id);
    });
}

// ground forks [json | give <id>]
int handleForks(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.stdlib : getenv;
    import hookrun : argLen;
    const(char)[] arg(int at) { return argc > at ? argv[at][0 .. argLen(argv[at])] : null; }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground forks: CLAUDE_CODE_SESSION_ID is not set, so this is no session's\n", stderr);
        return 1;
    }
    size_t sn = 0;
    while (sid[sn] != 0) sn++;
    auto self = sid[0 .. sn];
    auto verb = arg(2);
    if (verb == "give") return give(self, arg(3));
    if (verb.length > 0 && verb != "json") {
        fputs("usage: ground forks [json | give <session id>]\n", stderr);
        return 2;
    }
    bool json = verb == "json";
    __gshared ZBuf out_;
    out_.reset();
    if (json) out_.put(`{"forks":[`);
    bool first = true;
    eachBranch(self, (const(char)[] id) {
        char[256] nameBuf;
        auto name = lineFrom(id, "name", nameBuf[]);
        if (json) {
            if (!first) out_.put(",");
            out_.put(`{"session":"`);
            out_.put(id);
            out_.put(`","name":"`);
            foreach (c; name) if (c != '"' && c != '\\') { char[1] one = [c]; out_.put(one[]); }
            out_.put(`"}`);
        } else {
            out_.put(id);
            if (name.length > 0) { out_.put(" "); out_.put(name); }
            out_.put("\n");
        }
        first = false;
    });
    if (json) out_.put("]}\n");
    fputs(out_.ptr(), stdout);
    return 0;
}

// This session's key and name go to the session that branched, and that
// one's key comes here: it is who this one was, at the node, from now on.
private int give(const(char)[] self, const(char)[] to) {
    import core.stdc.stdio : stdout, stderr, fputs, rename;
    bool branch = false;
    eachBranch(self, (const(char)[] id) { if (id == to) branch = true; });
    if (!branch) {
        fputs("ground forks give: that is no session that branched from this one\n", stderr);
        return 1;
    }
    __gshared ZBuf mine, theirs, held;
    fileInto(mine, self, "key");
    fileInto(theirs, to, "key");
    fileInto(held, self, "key.giving");
    if (!exists(mine.ptr())) {
        fputs("ground forks give: this session holds no key to give\n", stderr);
        return 1;
    }
    if (rename(mine.ptr(), held.ptr()) != 0) {
        fputs("ground forks give: this session's key could not be moved\n", stderr);
        return 1;
    }
    if (exists(theirs.ptr()) && rename(theirs.ptr(), mine.ptr()) != 0) {
        rename(held.ptr(), mine.ptr());
        fputs("ground forks give: that session's key could not be moved\n", stderr);
        return 1;
    }
    if (rename(held.ptr(), theirs.ptr()) != 0) {
        fputs("ground forks give: the key could not be put in that session's place; it is at key.giving\n", stderr);
        return 1;
    }
    // The name goes with the key, and so does going on.
    fileInto(mine, self, "name");
    fileInto(theirs, to, "name");
    fileInto(held, self, "name.giving");
    bool had = exists(theirs.ptr());
    if (had) rename(theirs.ptr(), held.ptr());
    if (exists(mine.ptr())) rename(mine.ptr(), theirs.ptr());
    if (had) rename(held.ptr(), mine.ptr());
    fileInto(mine, self, "continues");
    fileInto(theirs, to, "continues");
    if (exists(mine.ptr())) rename(mine.ptr(), theirs.ptr());
    char[256] nameBuf;
    auto name = lineFrom(to, "name", nameBuf[]);
    __gshared ZBuf line;
    line.reset();
    line.put(to);
    line.put(" holds ");
    line.put(name.length > 0 ? name : "this session's key");
    line.put(" now\n");
    fputs(line.ptr(), stdout);
    return 0;
}
