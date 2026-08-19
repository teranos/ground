module git;

// The branch, read out of .git/HEAD. No process is spawned for it: a frame is
// a fresh process already, and the file is one line.

// What `git status --porcelain` says about the tree. The one thing on the row
// that cannot be read off a file: git owns the comparison, not us.
const(char)[] readPorcelain(const(char)[] cwd) {
    import core.stdc.stdio : FILE, fread;
    import core.sys.posix.stdio : popen, pclose;

    __gshared char[8192] cmd = void;
    enum head = "cd '";
    enum tail = "' 2>/dev/null && git status --porcelain 2>/dev/null";
    if (cwd.length + head.length + tail.length + 1 > cmd.length) return null;

    // A path holding a quote would end the quoting and run what follows.
    foreach (c; cwd) if (c == '\'') return null;

    size_t p = 0;
    foreach (c; head) cmd[p++] = c;
    foreach (c; cwd) cmd[p++] = c;
    foreach (c; tail) cmd[p++] = c;
    cmd[p] = 0;

    auto f = popen(&cmd[0], "r");
    if (f is null) return null;

    __gshared char[65536] buf = void;
    size_t total = 0;
    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, f);
        if (n == 0) break;
        total += n;
    }
    pclose(f);

    return buf[0 .. total];
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
