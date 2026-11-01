module probe;

// Reaching QNTX. The pure half is in qntx.d; this is the part that spends the
// frame, and the only part that can fail in ways a test cannot reach.

import qntx : State, classify, indexOf;

enum HOST = "https://api.q.sbvh.nl";

// QNTX_HOST replaces HOST for one process. The live test points it at an
// address that never answers, so no test request reaches the real node.
const(char)[] host() {
    import core.stdc.stdlib : getenv;
    auto e = getenv("QNTX_HOST\0".ptr);
    if (e is null) return HOST;
    size_t n = 0;
    while (e[n] != 0) n++;
    return n > 0 ? e[0 .. n] : HOST;
}

// The request is made through libcurl in this process, the way ground makes
// every request of its own. There is no program to find, so no path to pin and
// no PATH to be wrong about.

// Where the token is, under the home the row is running as. One file, so there
// is one thing to rotate and nothing that can go stale unnoticed beside it.
enum TOKEN_FILE = "/.qntx/token";

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

// The URL, host then path. Nothing quotes it and nothing escapes it: the
// request is made in this process, so there is no shell to mis-read an `&` in
// `&plugin=` and no command line for another process to read.
size_t urlInto(const(char)[] host_, const(char)[] path, char[] dest) {
    size_t o = 0;
    foreach (c; host_) { if (o >= dest.length) return 0; dest[o++] = c; }
    foreach (c; path)  { if (o >= dest.length) return 0; dest[o++] = c; }
    return o;
}

// One request, made in this process. It was the curl program behind a pipe,
// which meant a path to pin, a config file under /tmp to hold the token, and a
// command line for a shell to read.
Answer fetch(const(char)[] home, const(char)[] path) {
    import http : httpGet;

    auto tok = readToken(home);
    if (!tok.ok) return Answer(tok.fault, 0, "");

    __gshared char[400] url = void;
    auto u = urlInto(host(), path, url[]);
    if (u == 0) return Answer(State.probeError, 0, "");

    __gshared char[262144] out_ = void;
    auto r = httpGet(url[0 .. u], tok.value, out_[], MAX_TIME);

    // A body larger than the buffer is neither the far end failing nor a
    // failure to reach it, so it is read as neither.
    if (r.overran) return Answer(State.malformedBody, r.status, "");

    // libcurl's CURLcode and the curl program's exit status carry the same
    // numbers for every step classify reads, so the reading is unchanged.
    return Answer(classify(r.code, r.status), r.status, out_[0 .. r.len]);
}

// What a POST came back with. curlExit is -1 when no token was there to send,
// which is a request never made rather than one that failed.
struct Posted {
    int status;
    int curlExit;
}

// One POST of a JSON body, made in this process. The token and the body were
// written to files under /tmp to keep them off a command line; now there is no
// command line, so there is nothing to keep them off and nothing left behind.
Posted post(const(char)[] home, const(char)[] path, const(char)[] body_) {
    import http : httpPost;

    auto tok = readToken(home);
    if (!tok.ok) return Posted(0, -1);

    __gshared char[400] url = void;
    auto u = urlInto(host(), path, url[]);
    if (u == 0) return Posted(0, 0);

    auto r = httpPost(url[0 .. u], body_, tok.value, MAX_TIME);
    return Posted(r.status, r.code);
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
