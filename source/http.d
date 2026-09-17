module http;

import db : ZBuf;

// Everything over HTTP goes through curl. A remote node needs DNS and TLS,
// and ground already reaches aws, gh and every control script by spawning a
// process, so reaching a node the same way is the house idiom.

// Strip surrounding whitespace from a credential. A token read from a file
// carries the newline the file ends with, and a newline inside a header value
// is a malformed request, not a bad token.
const(char)[] trimToken(const(char)[] s) {
    size_t b = 0;
    size_t e = s.length;
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (b < e && ws(s[b])) b++;
    while (e > b && ws(s[e - 1])) e--;
    return s[b .. e];
}

// Pinned by absolute path: PATH belongs to whichever shell invoked the hook,
// and a credential must not be handed to whatever `curl` that PATH resolves.
// Written against /usr/bin/curl 8.7.1 (LibreSSL 3.3.6), the system curl.
enum CURL_BIN = "/usr/bin/curl";

// The token goes in the `curl -K` config rather than on the argv: a command
// line is readable by every process on the machine. The body goes in a file
// for the same reason, and because JSON on a command line is a quoting bug.
void buildCurlConfig(ref ZBuf cfg, const(char)[] bodyPath, const(char)[] token,
                     int timeoutSec, const(char)[] contentType = "application/json") {
    cfg.reset();
    cfg.put("silent\nshow-error\nrequest = \"POST\"\n");
    cfg.put("header = \"Content-Type: ");
    cfg.put(contentType);
    cfg.put("\"\n");
    putBearer(cfg, token);
    cfg.put("data-binary = \"@");
    cfg.put(bodyPath);
    cfg.put("\"\noutput = \"/dev/null\"\nwrite-out = \"%{http_code}\"\n");
    cfg.put("max-time = ");
    cfg.putUint(timeoutSec);
    cfg.put("\n");
}

// A GET carries the token the same way and nothing else. The answer is the
// body, so it is read from the pipe rather than sent to /dev/null.
void buildCurlGetConfig(ref ZBuf cfg, const(char)[] token, int timeoutSec) {
    cfg.reset();
    cfg.put("silent\nshow-error\n");
    putBearer(cfg, token);
    cfg.put("max-time = ");
    cfg.putUint(timeoutSec);
    cfg.put("\n");
}

// An absent token omits the header entirely. Sending `Authorization: Bearer `
// with nothing after it earns a 401, which reads as "your token was rejected"
// when the truth is there was never a token to send.
private void putBearer(ref ZBuf cfg, const(char)[] token) {
    auto tok = trimToken(token);
    if (tok.length == 0) return;
    cfg.put("header = \"Authorization: Bearer ");
    cfg.put(tok);
    cfg.put("\"\n");
}

// /tmp/ground-<stem>-<pid>.<ext>, one per process so two hooks never share.
private void tempPath(ref ZBuf p, const(char)[] stem, uint pid, const(char)[] ext) {
    p.reset();
    p.put("/tmp/ground-");
    p.put(stem);
    p.put("-");
    p.putUint(pid);
    p.put(".");
    p.put(ext);
}

// 0600 at creation, not chmod after — the config holds the token, and a
// window in which it is world-readable is the whole exposure.
private bool writeSecret(const(char)* path, const(char)[] data) {
    import errors : open, write, close, O_WRONLY, O_CREAT, O_TRUNC;
    auto fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, cast(uint) 0x180);
    if (fd < 0) return false;
    auto n = write(fd, data.ptr, data.length);
    close(fd);
    return n == cast(ptrdiff_t) data.length;
}

// POST JSON to a URL via curl. Returns the HTTP status code, or 0 when curl
// could not be run or produced no status: "no answer", never "answer was bad",
// so a dead endpoint is not reported as a rejected credential.
int curlPost(const(char)[] url, const(char)[] body_, const(char)[] token,
             int timeoutSec = 10, const(char)[] contentType = "application/json") {
    import core.stdc.stdio : FILE, fgetc, EOF;
    import core.sys.posix.unistd : getpid;
    import errors : unlink, popen, pclose;

    auto pid = cast(uint) getpid();

    __gshared ZBuf bodyPath, cfgPath;
    tempPath(bodyPath, "attest", pid, "json");
    tempPath(cfgPath, "attest", pid, "conf");

    __gshared ZBuf cfg;
    buildCurlConfig(cfg, bodyPath.slice(), token, timeoutSec, contentType);

    scope (exit) {
        unlink(bodyPath.ptr());
        unlink(cfgPath.ptr());
    }

    if (!writeSecret(bodyPath.ptr(), body_)) return 0;
    if (!writeSecret(cfgPath.ptr(), cfg.slice())) return 0;

    __gshared ZBuf cmd;
    cmd.reset();
    cmd.put(CURL_BIN);
    cmd.put(" --config ");
    cmd.put(cfgPath.slice());
    cmd.put(" ");
    cmd.put(url);
    cmd.put(" 2>/dev/null");

    auto pipe = popen(cmd.ptr(), "r");
    if (pipe is null) return 0;

    int code = 0;
    int digits = 0;
    for (;;) {
        auto c = fgetc(cast(FILE*) pipe);
        if (c == EOF) break;
        if (c < '0' || c > '9') continue;
        if (digits >= 3) continue;
        code = code * 10 + (c - '0');
        digits++;
    }
    pclose(pipe);

    return digits == 3 ? code : 0;
}

// GET a URL via curl, the body into dest. Returns the length written, or 0
// when curl could not be run, answered nothing, or the body did not fit:
// a body cut short is not the answer either.
size_t curlGet(const(char)[] url, const(char)[] token, char[] dest, int timeoutSec = 10) {
    import core.stdc.stdio : FILE, fread;
    import core.sys.posix.unistd : getpid;
    import errors : unlink, popen, pclose;

    auto pid = cast(uint) getpid();

    __gshared ZBuf cfgPath;
    tempPath(cfgPath, "get", pid, "conf");

    __gshared ZBuf cfg;
    buildCurlGetConfig(cfg, token, timeoutSec);

    scope (exit) unlink(cfgPath.ptr());

    if (!writeSecret(cfgPath.ptr(), cfg.slice())) return 0;

    __gshared ZBuf cmd;
    cmd.reset();
    cmd.put(CURL_BIN);
    cmd.put(" --config ");
    cmd.put(cfgPath.slice());
    cmd.put(" ");
    cmd.put(url);
    cmd.put(" 2>/dev/null");

    auto pipe = popen(cmd.ptr(), "r");
    if (pipe is null) return 0;
    auto n = fread(dest.ptr, 1, dest.length, cast(FILE*) pipe);
    pclose(pipe);

    return n < dest.length ? n : 0;
}

// --- Tests ---

unittest {
    // buildCurlConfig: the token becomes a header inside the config file and
    // never reaches the command line, where any process could read it.
    import matcher : contains;
    ZBuf cfg;
    buildCurlConfig(cfg, "/tmp/b.json", "sekrit", 10);
    auto s = cfg.slice();
    assert(contains(s, "header = \"Authorization: Bearer sekrit\"\n"));
    assert(contains(s, "header = \"Content-Type: application/json\"\n"));
    assert(contains(s, "data-binary = \"@/tmp/b.json\"\n"));
    assert(contains(s, "request = \"POST\"\n"));
    assert(contains(s, "write-out = \"%{http_code}\"\n"));
    assert(contains(s, "max-time = 10\n"));
}

unittest {
    // An envelope is not JSON: it is lines of it, and sentry is told so. The
    // type is the caller's to name, and naming none is still JSON.
    import matcher : contains;
    ZBuf cfg;
    buildCurlConfig(cfg, "/tmp/b.envelope", null, 10, "application/x-sentry-envelope");
    assert(contains(cfg.slice(), "header = \"Content-Type: application/x-sentry-envelope\"\n"));
    assert(!contains(cfg.slice(), "application/json"));
}

unittest {
    // buildCurlConfig: no token, no header. An empty Bearer would come back
    // 401 and name the wrong problem.
    import matcher : contains;
    ZBuf cfg;
    buildCurlConfig(cfg, "/tmp/b.json", null, 10);
    assert(!contains(cfg.slice(), "Authorization"));

    ZBuf cfg2;
    buildCurlConfig(cfg2, "/tmp/b.json", "  \n", 10);
    assert(!contains(cfg2.slice(), "Authorization"),
           "whitespace is not a credential");
}

unittest {
    // A GET carries the token the same way and nothing else: no method, no
    // body, and the answer is the body, so it is not sent to /dev/null.
    import matcher : contains;
    ZBuf cfg;
    buildCurlGetConfig(cfg, "sekrit", 10);
    auto s = cfg.slice();
    assert(contains(s, "header = \"Authorization: Bearer sekrit\"\n"));
    assert(contains(s, "max-time = 10\n"));
    assert(contains(s, "silent\n"));
    assert(!contains(s, "request ="));
    assert(!contains(s, "data-binary"));
    assert(!contains(s, "output ="));

    ZBuf cfg2;
    buildCurlGetConfig(cfg2, "", 10);
    assert(!contains(cfg2.slice(), "Authorization"));
}

unittest {
    // trimToken: surrounding whitespace and a trailing newline are not
    // part of the credential. A file written by `echo` has one.
    assert(trimToken("abc") == "abc");
    assert(trimToken("abc\n") == "abc");
    assert(trimToken("  abc\r\n") == "abc");
    assert(trimToken("\n\n") == "");
    assert(trimToken("") == "");
    assert(trimToken("   ") == "");
}
