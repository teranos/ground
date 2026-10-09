module git;

// The branch, read out of .git/HEAD. No process is spawned for it: a frame is
// a fresh process already, and the file is one line.

// The codes `git status --porcelain` opens each line with, one a line. The one
// thing on the row that cannot be read off a file, read by libgit2 in this
// process; it writes nothing back to the index, as --no-optional-locks did not.
const(char)[] readPorcelain(const(char)[] cwd) {
    import libgit2 : Repo;
    __gshared Repo g;
    __gshared char[65536] buf = void;
    if (!g.open(cwd)) return null;
    scope (exit) g.close();
    return g.statusCodes(buf[]);
}

// The contents of a repository's HEAD, or null when there is none to read.
const(char)[] readHead(const(char)[] cwd) {
    import core.stdc.stdio : fopen, fread, fclose;

    __gshared char[4096] path = void;
    enum tail = "/.git/HEAD";
    if (cwd.length + tail.length + 1 > path.length) return null;

    size_t p = 0;
    foreach (c; cwd) path[p++] = c;
    foreach (c; tail) path[p++] = c;
    path[p] = 0;

    auto f = fopen(&path[0], "rb");
    if (f is null) return null;

    __gshared char[256] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);
    return n > 0 ? buf[0 .. n] : null;
}

// The branch a HEAD names, or null when it names none. A detached HEAD holds
// a bare hash and belongs to no branch, so it draws nothing.
enum PREFIX = "ref: refs/heads/";

const(char)[] branchOf(const(char)[] head) {
    if (head.length <= PREFIX.length) return null;
    if (head[0 .. PREFIX.length] != PREFIX) return null;

    size_t end = PREFIX.length;
    while (end < head.length && head[end] != '\n' && head[end] != '\r') end++;

    auto name = head[PREFIX.length .. end];
    return name.length > 0 ? name : null;
}
