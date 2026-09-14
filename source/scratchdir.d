module scratchdir;

// BOOK_GLOSSARY **Scratch**: A directory Claude Code owns for a session's throwaway files: $CLAUDE_CODE_TMPDIR/claude-{uid} for a foreground session, $CLAUDE_JOB_DIR/tmp for a background one.

// Both roots are told to the session rather than guessed from a path, so they
// are passed in. A root ground was not told is a root nothing sits under.

private bool startsAt(const(char)[] s, const(char)[] prefix) {
    if (s.length < prefix.length) return false;
    return s[0 .. prefix.length] == prefix;
}

// Strictly under: a path equal to the root is the directory, not a file being
// written in it. The separator is what keeps a sibling out.
private bool under(const(char)[] path, const(char)[] root) {
    if (root.length == 0 || path.length <= root.length) return false;
    if (path[0 .. root.length] != root) return false;
    return path[root.length] == '/';
}

// The per-uid directory Claude Code makes under $CLAUDE_CODE_TMPDIR. Zero when
// there is no override or the path does not fit: a cut path names a directory
// the session was never given.
size_t tmpRootInto(const(char)[] tmpdir, uint uid, char[] dest) {
    if (tmpdir.length == 0) return 0;

    char[10] digits = 0;
    size_t nd = 0;
    do {
        digits[nd++] = cast(char)('0' + uid % 10);
        uid /= 10;
    } while (uid > 0);

    enum mark = "/claude-";
    auto total = tmpdir.length + mark.length + nd;
    if (total > dest.length) return 0;

    size_t o = 0;
    foreach (c; tmpdir) dest[o++] = c;
    foreach (c; mark) dest[o++] = c;
    foreach_reverse (i; 0 .. nd) dest[o++] = digits[i];
    return o;
}

// A job directory also holds state that outlives a turn, so only its tmp/ is
// scratch. Everything under the session's own temp root is.
bool isScratch(const(char)[] path, const(char)[] tmpRoot, const(char)[] jobDir) {
    if (path.length == 0) return false;
    if (under(path, tmpRoot)) return true;
    if (!under(path, jobDir)) return false;
    return startsAt(path[jobDir.length + 1 .. $], "tmp/");
}

private const(char)[] envSlice(const(char)* p) {
    if (p is null) return null;
    size_t n = 0;
    while (p[n] != 0) n++;
    return p[0 .. n];
}

// The roots as this process was told them. Read at the moment ground asks,
// because a hook is started by the session and inherits exactly its env.
bool scratchHere(const(char)[] path) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.unistd : getuid;

    __gshared char[4096] rootBuf = 0;
    auto n = tmpRootInto(envSlice(getenv("CLAUDE_CODE_TMPDIR\0".ptr)), getuid(), rootBuf[]);
    return isScratch(path, rootBuf[0 .. n], envSlice(getenv("CLAUDE_JOB_DIR\0".ptr)));
}
