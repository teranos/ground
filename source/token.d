module token;

// A third party's token as a file holds it (Jev's, ~/.qntx/jev-token): in a
// module of its own so what needs only that compiles nothing else. A QNTX node
// is never spoken to with one: ground signs with ~/.qntx/key (signed.d).
//
// "A signature proves the key, and nothing reusable leaves the node."

import zbuf : ZBuf;

// A token as a file holds it: surrounding whitespace and a trailing newline
// are not part of it.
const(char)[] trimToken(const(char)[] s) {
    size_t b = 0;
    size_t e = s.length;
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (b < e && ws(s[b])) b++;
    while (e > b && ws(s[e - 1])) e--;
    return s[b .. e];
}

// The token in the file at path, `~/` being the home, or null when there is
// no such file or no home. Good until the next call.
const(char)[] tokenIn(const(char)[] path) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.fcntl : open, O_RDONLY;
    import core.sys.posix.unistd : read, close;
    __gshared ZBuf pathBuf;
    pathBuf.reset();
    if (path.length >= 2 && path[0 .. 2] == "~/") {
        auto home = getenv("HOME\0".ptr);
        if (home is null) return null;
        size_t hLen = 0;
        while (home[hLen] != 0) hLen++;
        pathBuf.put(home[0 .. hLen]);
        pathBuf.put(path[1 .. $]);
    } else {
        pathBuf.put(path);
    }
    auto fd = open(pathBuf.ptr(), O_RDONLY);
    if (fd < 0) return null;
    __gshared char[TOKEN_MAX + 2] tokBuf = 0;
    auto n = read(fd, &tokBuf[0], tokBuf.length);
    close(fd);
    if (n <= 0) return null;
    auto t = trimToken(tokBuf[0 .. cast(size_t) n]);
    // Longer than ground reads is no token, never the start of one, and is said.
    if (t.length > TOKEN_MAX) {
        import core.stdc.stdio : stderr, fprintf;
        fprintf(stderr, "ground: the token in %s is longer than the %d bytes ground reads, so it is not used\n",
                pathBuf.ptr(), cast(int) TOKEN_MAX);
        return null;
    }
    return t;
}

// The longest token ground reads back.
enum TOKEN_MAX = 4096;
