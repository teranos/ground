module token;

// A node's token, read as every ground reads it, in a module of its own so what needs only the token
// compiles none of what attest posts with or errors delivers through.

import zbuf : ZBuf;

// A token as a file or the environment holds it: surrounding whitespace and a
// trailing newline are not part of it.
const(char)[] trimToken(const(char)[] s) {
    size_t b = 0;
    size_t e = s.length;
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (b < e && ws(s[b])) b++;
    while (e > b && ws(s[e - 1])) e--;
    return s[b .. e];
}

// The file a node's token is kept in: the one its qntx block names, `~/` being the home, or ~/.qntx/token,
// which ground code's login writes, so every ground reads the token it was given.
// Null when it is in a home there is none of. Good until the next call.
const(char)* qntxTokenFile(const(char)[] path = "") {
    import core.stdc.stdlib : getenv;
    __gshared ZBuf pathBuf;
    pathBuf.reset();
    if (path.length == 0 || (path.length >= 2 && path[0 .. 2] == "~/")) {
        auto home = getenv("HOME\0".ptr);
        if (home is null) return null;
        size_t hLen = 0;
        while (home[hLen] != 0) hLen++;
        pathBuf.put(home[0 .. hLen]);
        pathBuf.put(path.length == 0 ? "/.qntx/token" : path[1 .. $]);
    } else {
        pathBuf.put(path);
    }
    return pathBuf.ptr();
}

// The token a node is spoken to with: from the file its qntx block names, or QNTX_TOKEN, then ~/.qntx/token.
// One token per node: a second name for one credential is a second thing to rotate, and the one nobody
// rotated went stale and was refused for weeks. Ground's attestations are told apart by actors ["ground"].
const(char)[] qntxToken(const(char)[] path = "") {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.fcntl : open, O_RDONLY;
    import core.sys.posix.unistd : read, close;

    if (path.length == 0) {
        auto env = getenv("QNTX_TOKEN\0".ptr);
        if (env !is null) {
            size_t n = 0;
            while (env[n] != 0) n++;
            auto t = trimToken(env[0 .. n]);
            if (t.length > 0) return t;
        }
    }

    auto file = qntxTokenFile(path);
    if (file is null) return null;
    auto fd = open(file, O_RDONLY);
    if (fd < 0) return null;
    __gshared char[512] tokBuf = 0;
    auto n = read(fd, &tokBuf[0], tokBuf.length);
    close(fd);
    if (n <= 0) return null;
    return trimToken(tokBuf[0 .. cast(size_t) n]);
}
