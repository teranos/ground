module stopfailure;

// https://code.claude.com/docs/en/hooks — StopFailure fires "When the turn
// ends due to an API error", and its "Output and exit code are ignored".

import errors : O_WRONLY, O_CREAT, O_APPEND;

extern (C) {
    int open(const(char)* path, int flags, uint mode);
    long write(int fd, const(void)* buf, size_t count);
    int close(int fd);
    int mkdir(const(char)* path, uint mode);
}

private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}

// main.readStdin stops at this and says nothing, so a payload that fills it
// exactly is a payload that may have been cut.
enum STDIN_CAP = 262144;

// Nothing here parses. The one question this answers is what Claude Code
// actually sends, and a recorder that reshapes its input cannot answer it.
int handleStopFailure(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import core.stdc.stdlib : getenv;
    import core.stdc.time : time;
    import exec : emitError;

    auto home = getenv("HOME\0".ptr);
    if (home is null) {
        emitError("stopfailure.home", "no HOME, so the record has nowhere to go",
                  0, 0, cast(string) sessionId, "StopFailure", "", "", "");
        return 0;
    }

    size_t hlen = 0;
    while (home[hlen] != 0) hlen++;

    char[512] dirBuf = 0;
    size_t p = 0;
    foreach (i; 0 .. hlen) { if (p < dirBuf.length - 1) dirBuf[p++] = home[i]; }
    foreach (c; "/.local/share/ground") { if (p < dirBuf.length - 1) dirBuf[p++] = c; }
    dirBuf[p] = 0;
    mkdir(&dirBuf[0], octal!755);

    char[768] pathBuf = 0;
    size_t q = 0;
    foreach (i; 0 .. p) { if (q < pathBuf.length - 1) pathBuf[q++] = dirBuf[i]; }
    foreach (c; "/stopfailure.log") { if (q < pathBuf.length - 1) pathBuf[q++] = c; }
    pathBuf[q] = 0;

    int fd = open(&pathBuf[0], O_WRONLY | O_CREAT | O_APPEND, octal!644);
    if (fd < 0) {
        emitError("stopfailure.open", "could not open the record to append to",
                  0, fd, cast(string) sessionId, "StopFailure", "", "", "");
        return 0;
    }

    // The payload can hold newlines, so the frame is what makes one record
    // one record. Read it with the eye, not with a line splitter.
    char[1024] head = 0;
    size_t h = 0;
    void put(const(char)[] s) { foreach (c; s) { if (h < head.length - 1) head[h++] = c; } }
    void putNum(long v) {
        if (v == 0) { put("0"); return; }
        char[24] d = 0;
        int n;
        while (v > 0 && n < 23) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. n) { if (h < head.length - 1) head[h++] = d[i]; }
    }

    put("=== stopfailure at ");
    putNum(cast(long) time(null));
    put(" session=");
    put(sessionId.length > 0 ? sessionId : "-");
    put(" cwd=");
    put(cwd.length > 0 ? cwd : "-");
    put(" bytes=");
    putNum(cast(long) input.length);
    if (input.length >= STDIN_CAP) put(" STDIN-BUFFER-FULL");
    put("\n");

    write(fd, &head[0], h);
    // Straight from the slice: no copy, no buffer of ours to overflow.
    if (input.length > 0) write(fd, input.ptr, input.length);
    write(fd, "\n=== end\n".ptr, 9);
    close(fd);

    return 0;
}
