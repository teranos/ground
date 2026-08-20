module probe;

// Reaching QNTX. The pure half is in qntx.d; this is the part that spends the
// frame, and the only part that can fail in ways a test cannot reach.

import qntx : State, classify, indexOf;

enum HOST = "https://api.q.sbvh.nl";

// Pinned by absolute path: PATH belongs to whichever shell started the row,
// and a credential must not be handed to whatever curl that PATH resolves.
enum CURL = "/usr/bin/curl";

// Where the token is, under the home the row is running as.
enum TOKEN_FILE = "/.qntx/collet-token";

// Longer than the frame, deliberately: a probe that gave up inside a second
// would report a timeout the box never had.
enum MAX_TIME = 3;

// What came back, and what it means.
struct Answer {
    State state;
    int status;
    const(char)[] body_;
}

// The token, or which of the two ways there wasn't one. Absent and unreadable
// are different facts with different fixes: one says mint a token, the other
// says the one on disk is fine and the permissions are not.
struct Token {
    const(char)[] value;
    State fault;
    bool ok;
}

Token readToken(const(char)[] home) {
    import core.stdc.stdio : fopen, fread, fclose;
    import core.stdc.stdlib : getenv;

    auto env = getenv("QNTX_TOKEN\0".ptr);
    if (env !is null) {
        size_t n = 0;
        while (env[n] != 0) n++;
        auto t = trimToken(env[0 .. n]);
        if (t.length > 0) return Token(t, State.ok, true);
    }

    if (home.length == 0) return Token(null, State.noToken, false);

    __gshared char[1024] path = void;
    if (home.length + TOKEN_FILE.length + 1 > path.length)
        return Token(null, State.noToken, false);

    size_t p = 0;
    foreach (c; home) path[p++] = c;
    foreach (c; TOKEN_FILE) path[p++] = c;
    path[p] = 0;

    auto f = fopen(&path[0], "rb");
    if (f is null) return Token(null, State.noToken, false);

    __gshared char[4096] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);

    // A file that opened and gave nothing is not the same as no file: the
    // token is there and something about reading it went wrong.
    if (n == 0) return Token(null, State.tokenUnreadable, false);

    auto t = trimToken(buf[0 .. n]);
    if (t.length == 0) return Token(null, State.noToken, false);
    return Token(t, State.ok, true);
}

// One request. The token goes in a config file rather than on the argv: a
// command line is readable by every process on the machine, and a credential
// that leaks by being used is worse than one that is merely stored.
Answer fetch(const(char)[] home, const(char)[] path) {
    import core.stdc.stdio : FILE, fopen, fwrite, fclose, fread, remove;
    import core.sys.posix.stdio : popen, pclose;
    import core.sys.posix.unistd : getpid;

    auto tok = readToken(home);
    if (!tok.ok) return Answer(tok.fault, 0, "");

    __gshared char[256] conf = void;
    size_t c = 0;
    foreach (ch; "/tmp/ug-qntx-") conf[c++] = ch;
    {
        auto pid = getpid();
        char[12] d = void;
        size_t dl = 0;
        int v = pid < 0 ? 0 : pid;
        if (v == 0) { d[dl++] = '0'; }
        else { while (v > 0 && dl < 11) { d[dl++] = cast(char)('0' + v % 10); v /= 10; } }
        foreach_reverse (i; 0 .. dl) conf[c++] = d[i];
    }
    foreach (ch; ".conf") conf[c++] = ch;
    conf[c] = 0;

    {
        auto f = fopen(&conf[0], "wb");
        if (f is null) return Answer(State.probeError, 0, "");

        void line(const(char)[] s) { fwrite(s.ptr, 1, s.length, f); }
        line("silent\nshow-error\nmax-time = ");
        line(MAX_TIME == 3 ? "3" : "3");
        line("\nheader = \"Authorization: Bearer ");
        line(tok.value);
        line("\"\n");
        fclose(f);
    }

    __gshared char[512] cmd = void;
    size_t m = 0;
    void putCmd(const(char)[] s) { foreach (ch; s) cmd[m++] = ch; }
    putCmd(CURL);
    putCmd(" --config ");
    putCmd(conf[0 .. c]);
    putCmd(" --write-out '\\nHTTP %{http_code}' ");
    putCmd(HOST);
    putCmd(path);
    putCmd(" 2>/dev/null");
    cmd[m] = 0;

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) { remove(&conf[0]); return Answer(State.probeError, 0, ""); }

    __gshared char[262144] out_ = void;
    size_t total = 0;
    while (total < out_.length) {
        auto n = fread(&out_[total], 1, out_.length - total, cast(FILE*) pipe);
        if (n == 0) break;
        total += n;
    }

    // pclose hands back a wait status, and the exit code is its high byte.
    auto status = pclose(pipe);
    remove(&conf[0]);
    auto curlExit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status;

    return split(out_[0 .. total], curlExit);
}

// Surrounding whitespace is not part of a credential; a file written by echo
// carries the newline it ended with.
const(char)[] trimToken(const(char)[] s) {
    size_t b = 0;
    size_t e = s.length;
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (b < e && ws(s[b])) b++;
    while (e > b && ws(s[e - 1])) e--;
    return s[b .. e];
}

// The marker is the last line curl writes, so it is found from the end. A
// body cannot end it early that way, whatever the body contains.
ptrdiff_t lastIndexOf(const(char)[] text, const(char)[] needle) {
    if (needle.length == 0 || needle.length > text.length) return -1;
    for (ptrdiff_t i = cast(ptrdiff_t)(text.length - needle.length); i >= 0; i--)
        if (text[i .. i + needle.length] == needle) return i;
    return -1;
}

// The status curl was told to append, and the body without it.
Answer split(const(char)[] out_, int curlExit) {
    auto at = lastIndexOf(out_, "\nHTTP ");
    if (at < 0) return Answer(classify(curlExit, 0), 0, out_);

    size_t i = cast(size_t) at + 6;
    int status = 0;
    while (i < out_.length && out_[i] >= '0' && out_[i] <= '9') {
        status = status * 10 + (out_[i] - '0');
        i++;
    }
    return Answer(classify(curlExit, status), status, out_[0 .. cast(size_t) at]);
}
