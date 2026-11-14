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

// Longer than the frame, deliberately: a probe that gave up inside a second
// would report a timeout the box never had.
enum MAX_TIME = 3;

// What came back, and what it means.
struct Answer {
    State state;
    int status;
    const(char)[] body_;
}

// "A signature proves the key, and nothing reusable leaves the node."
// Whether a key is kept under home, which http.d signs with.
bool keyKept(const(char)[] home) {
    import core.stdc.stdio : fopen, fclose;
    enum KEY_FILE = "/.qntx/key";
    __gshared char[1024] path = void;
    if (home.length == 0 || home.length + KEY_FILE.length + 1 > path.length) return false;
    size_t p = 0;
    foreach (c; home) path[p++] = c;
    foreach (c; KEY_FILE) path[p++] = c;
    path[p] = 0;
    auto f = fopen(&path[0], "rb");
    if (f is null) return false;
    fclose(f);
    return true;
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

// The most a node's answer may be. What is collected for agents carries what
// a room woke them with, whole: two GitHub wakes in the Node Room were 260 KiB
// waiting for one agent, past the 256 KiB this was, and none of it was kept.
enum BODY_BYTES = 4 << 20;

// One request, made in this process, signed with the key kept under home.
Answer fetch(const(char)[] home, const(char)[] path) {
    import http : httpGet, ToNode;

    if (!keyKept(home)) return Answer(State.noKey, 0, "");

    __gshared char[400] url = void;
    auto u = urlInto(host(), path, url[]);
    if (u == 0) return Answer(State.probeError, 0, "");

    __gshared char[BODY_BYTES] out_ = void;
    auto r = httpGet(url[0 .. u], ToNode(), out_[], MAX_TIME);

    // A body larger than the buffer is neither the far end failing nor a
    // failure to reach it, so it is read as neither.
    if (r.overran) return Answer(State.malformedBody, r.status, "");

    // libcurl's CURLcode and the curl program's exit status carry the same
    // numbers for every step classify reads, so the reading is unchanged.
    return Answer(classify(r.code, r.status), r.status, out_[0 .. r.len]);
}

// What a POST came back with. curlExit is -1 when no key was there to sign
// with, which is a request never made rather than one that failed.
struct Posted {
    int status;
    int curlExit;
}

// One POST of a JSON body, made in this process, signed with the key kept
// under home.
Posted post(const(char)[] home, const(char)[] path, const(char)[] body_) {
    import http : httpPost, ToNode;

    if (!keyKept(home)) return Posted(0, -1);

    __gshared char[400] url = void;
    auto u = urlInto(host(), path, url[]);
    if (u == 0) return Posted(0, 0);

    auto r = httpPost(url[0 .. u], body_, ToNode(), MAX_TIME);
    return Posted(r.status, r.code);
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
