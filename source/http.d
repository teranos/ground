module http;

import db : ZBuf;

// Minimal HTTP POST over POSIX sockets — localhost only, no TLS.
// Returns HTTP status code (e.g. 200, 201), or 0 on connection failure.

extern (C) {
    alias socklen_t = uint;

    struct sockaddr_in {
        ubyte sin_len;
        ubyte sin_family;
        ushort sin_port;
        uint sin_addr;
        ubyte[8] sin_zero;
    }

    enum AF_INET = 2;
    enum SOCK_STREAM = 1;

    int socket(int domain, int type, int protocol);
    int connect(int sockfd, const(void)* addr, socklen_t addrlen);
    long send(int sockfd, const(void)* buf, size_t len, int flags);
    long recv(int sockfd, void* buf, size_t len, int flags);
    int close(int fd);

    // Non-blocking + timeout
    struct timeval { long tv_sec; long tv_usec; }
    int setsockopt(int sockfd, int level, int optname, const(void)* optval, socklen_t optlen);
    enum SOL_SOCKET = 0xFFFF;
    enum SO_SNDTIMEO = 0x1005;
    enum SO_RCVTIMEO = 0x1006;
}

// Parse "http://host:port" into host and port.
// Returns false if not a valid http:// URL.
bool parseUrl(const(char)[] url, ref const(char)[] host, ref ushort port, ref const(char)[] path) {
    if (url.length < 8) return false;
    if (url[0 .. 7] != "http://") return false;

    auto rest = url[7 .. $];
    size_t hostEnd = 0;
    while (hostEnd < rest.length && rest[hostEnd] != ':' && rest[hostEnd] != '/') hostEnd++;
    if (hostEnd == 0) return false;
    host = rest[0 .. hostEnd];

    port = 80;
    size_t pathStart = hostEnd;
    if (hostEnd < rest.length && rest[hostEnd] == ':') {
        hostEnd++;
        ushort p = 0;
        while (hostEnd < rest.length && rest[hostEnd] >= '0' && rest[hostEnd] <= '9') {
            p = cast(ushort)(p * 10 + (rest[hostEnd] - '0'));
            hostEnd++;
        }
        if (p > 0) port = p;
        pathStart = hostEnd;
    }

    path = pathStart < rest.length ? rest[pathStart .. $] : "/";
    return true;
}

// Resolve hostname to IPv4 address (supports "localhost" and dotted-quad).
uint resolveHost(const(char)[] host) {
    if (host == "localhost") return 0x0100007F; // 127.0.0.1 in network byte order

    // Parse dotted quad: a.b.c.d
    uint result = 0;
    int octet = 0;
    int octetCount = 0;
    foreach (c; host) {
        if (c == '.') {
            if (octetCount >= 3) return 0;
            result |= (cast(uint) octet) << (octetCount * 8);
            octet = 0;
            octetCount++;
        } else if (c >= '0' && c <= '9') {
            octet = octet * 10 + (c - '0');
        } else {
            return 0;
        }
    }
    if (octetCount == 3) {
        result |= (cast(uint) octet) << 24;
        return result;
    }
    return 0;
}

// Convert ushort to network byte order (big-endian).
ushort htons(ushort v) {
    return cast(ushort)((v >> 8) | (v << 8));
}

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

// Build the request bytes. Separated from httpPost so the wire format is
// testable without a socket.
//
// An absent token omits the header entirely. Sending `Authorization: Bearer `
// with nothing after it earns a 401, which reads as "your token was rejected"
// when the truth is there was never a token to send.
void buildPostRequest(ref ZBuf req, const(char)[] host, const(char)[] path,
                      const(char)[] body_, const(char)[] token) {
    req.reset();
    req.put("POST ");
    req.put(path);
    req.put(" HTTP/1.0\r\nHost: ");
    req.put(host);
    auto tok = trimToken(token);
    if (tok.length > 0) {
        req.put("\r\nAuthorization: Bearer ");
        req.put(tok);
    }
    req.put("\r\nContent-Type: application/json\r\nContent-Length: ");
    req.putUint(body_.length);
    req.put("\r\nConnection: close\r\n\r\n");
    req.put(body_);
}

// --- curl transport ---
//
// The socket path above speaks plain HTTP to a numeric or literal-localhost
// host. A remote node needs DNS and TLS, and neither belongs in this module:
// ground already reaches `aws`, `gh` and every control script by spawning a
// process, so reaching a remote QNTX the same way is the house idiom, not a
// concession. Written against /usr/bin/curl 8.7.1 (LibreSSL 3.3.6), the
// system curl on macOS 26.
//
// Pinned by absolute path: PATH belongs to whichever shell invoked the hook,
// and a credential must not be handed to whatever `curl` that PATH resolves.
enum CURL_BIN = "/usr/bin/curl";

// True when a URL needs curl rather than the socket path — anything the
// in-process client cannot reach, which today means everything but http://.
bool needsCurl(const(char)[] url) {
    return !(url.length >= 7 && url[0 .. 7] == "http://");
}

// Build the `curl -K` config. Separated from curlPost so the invocation is
// testable without spawning anything — the same split buildPostRequest gets.
//
// The token goes here rather than on the argv: a command line is readable by
// every process on the machine, and a credential that leaks by being *used*
// is worse than one that is merely stored. The body goes in a file for the
// same class of reason — JSON on a command line is a quoting bug waiting for
// an attestation whose attributes contain a quote.
void buildCurlConfig(ref ZBuf cfg, const(char)[] bodyPath, const(char)[] token,
                     int timeoutSec) {
    cfg.reset();
    cfg.put("silent\nshow-error\nrequest = \"POST\"\n");
    cfg.put("header = \"Content-Type: application/json\"\n");
    auto tok = trimToken(token);
    if (tok.length > 0) {
        cfg.put("header = \"Authorization: Bearer ");
        cfg.put(tok);
        cfg.put("\"\n");
    }
    cfg.put("data-binary = \"@");
    cfg.put(bodyPath);
    cfg.put("\"\noutput = \"/dev/null\"\nwrite-out = \"%{http_code}\"\n");
    cfg.put("max-time = ");
    cfg.putUint(timeoutSec);
    cfg.put("\n");
}

// POST JSON to a URL via curl. Returns the HTTP status code, or 0 when curl
// could not be run or produced no status.
//
// 0 means "no answer", never "answer was bad" — the caller distinguishes
// unreachable from refused, and conflating them would report a dead endpoint
// as a rejected credential.
int curlPost(const(char)[] url, const(char)[] body_, const(char)[] token,
             int timeoutSec = 10) {
    import core.stdc.stdio : FILE, fgetc, EOF;
    import core.sys.posix.unistd : getpid;
    // errors.d already binds these, with the macOS O_* values — re-declaring
    // them here collides on the mangled name.
    import errors : open, write, close, unlink, popen, pclose,
                    O_WRONLY, O_CREAT, O_TRUNC;

    auto pid = cast(uint) getpid();

    __gshared ZBuf bodyPath, cfgPath;
    bodyPath.reset();
    bodyPath.put("/tmp/ground-attest-");
    bodyPath.putUint(pid);
    bodyPath.put(".json");
    cfgPath.reset();
    cfgPath.put("/tmp/ground-attest-");
    cfgPath.putUint(pid);
    cfgPath.put(".conf");

    // 0600 at creation, not chmod after — the config holds the token, and a
    // window in which it is world-readable is the whole exposure.
    static bool writeFile(const(char)* path, const(char)[] data) {
        auto fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, cast(uint) 0x180);
        if (fd < 0) return false;
        auto n = write(fd, data.ptr, data.length);
        close(fd);
        return n == cast(ptrdiff_t) data.length;
    }

    __gshared ZBuf cfg;
    buildCurlConfig(cfg, bodyPath.slice(), token, timeoutSec);

    scope (exit) {
        unlink(bodyPath.ptr());
        unlink(cfgPath.ptr());
    }

    if (!writeFile(bodyPath.ptr(), body_)) return 0;
    if (!writeFile(cfgPath.ptr(), cfg.slice())) return 0;

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

// POST JSON body to a URL. Returns HTTP status code or 0 on failure.
// Timeout in milliseconds.
int httpPost(const(char)[] url, const(char)[] body_, int timeoutMs = 400) {
    const(char)[] host;
    ushort port;
    const(char)[] path;
    if (!parseUrl(url, host, port, path)) return 0;

    auto addr = resolveHost(host);
    if (addr == 0) return 0;

    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;

    // Set send/recv timeouts
    timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tv.sizeof);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tv.sizeof);

    sockaddr_in sin;
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    sin.sin_addr = addr;

    if (connect(fd, &sin, sin.sizeof) < 0) {
        close(fd);
        return 0;
    }

    // Build HTTP request
    __gshared ZBuf req;
    buildPostRequest(req, host, path, body_, null);

    auto reqSlice = req.slice();
    auto sent = send(fd, reqSlice.ptr, reqSlice.length, 0);
    if (sent < 0) {
        close(fd);
        return 0;
    }

    // Read response — only need the status line
    __gshared char[128] resp = 0;
    auto n = recv(fd, &resp[0], resp.length, 0);
    close(fd);

    if (n < 12) return 0; // "HTTP/1.x NNN" minimum

    // Parse status code from "HTTP/1.x NNN"
    if (resp[0 .. 5] != "HTTP/") return 0;
    // Find space before status code
    size_t i = 5;
    while (i < n && resp[i] != ' ') i++;
    i++; // skip space
    if (i + 3 > n) return 0;

    int code = 0;
    foreach (j; 0 .. 3) {
        if (resp[i + j] < '0' || resp[i + j] > '9') return 0;
        code = code * 10 + (resp[i + j] - '0');
    }
    return code;
}

// --- Tests ---

unittest {
    // parseUrl: basic localhost with port
    const(char)[] host, path;
    ushort port;
    assert(parseUrl("http://localhost:8771/api/attestations", host, port, path));
    assert(host == "localhost");
    assert(port == 8771);
    assert(path == "/api/attestations");
}

unittest {
    // parseUrl: default port
    const(char)[] host, path;
    ushort port;
    assert(parseUrl("http://example.com/test", host, port, path));
    assert(host == "example.com");
    assert(port == 80);
    assert(path == "/test");
}

unittest {
    // parseUrl: no path
    const(char)[] host, path;
    ushort port;
    assert(parseUrl("http://localhost:9000", host, port, path));
    assert(host == "localhost");
    assert(port == 9000);
    assert(path == "/");
}

unittest {
    // parseUrl: rejects non-http
    const(char)[] host, path;
    ushort port;
    assert(!parseUrl("https://localhost:8771", host, port, path));
    assert(!parseUrl("ftp://x", host, port, path));
}

unittest {
    // resolveHost: localhost
    assert(resolveHost("localhost") == 0x0100007F);
}

unittest {
    // resolveHost: dotted quad
    assert(resolveHost("127.0.0.1") == 0x0100007F);
    assert(resolveHost("10.0.0.1") == 0x0100000A);
}

unittest {
    // resolveHost: invalid
    assert(resolveHost("not-a-host") == 0);
}

unittest {
    // htons
    assert(htons(8771) == 0x4322);
    assert(htons(80) == 0x5000);
}

unittest {
    // buildPostRequest: a token becomes an Authorization header
    import matcher : contains;
    ZBuf req;
    buildPostRequest(req, "api.q.sbvh.nl", "/api/attestations", `{"a":1}`, "sekrit");
    auto s = req.slice();
    assert(contains(s, "Authorization: Bearer sekrit\r\n"));
    assert(contains(s, "POST /api/attestations HTTP/1.0\r\n"));
    assert(contains(s, "Host: api.q.sbvh.nl\r\n"));
    assert(contains(s, "Content-Length: 7\r\n"));
    // Body follows the blank line and is unmodified.
    assert(contains(s, "\r\n\r\n" ~ `{"a":1}`));
}

unittest {
    // buildPostRequest: no token means no Authorization header at all.
    // An empty Bearer would come back 401 and name the wrong problem.
    import matcher : contains;
    ZBuf req;
    buildPostRequest(req, "localhost", "/api/attestations", `{"a":1}`, null);
    assert(!contains(req.slice(), "Authorization"));

    ZBuf req2;
    buildPostRequest(req2, "localhost", "/api/attestations", `{"a":1}`, "");
    assert(!contains(req2.slice(), "Authorization"));
}

unittest {
    // needsCurl: the socket path handles http:// and nothing else. https and
    // any other scheme must route to curl rather than fail at parseUrl with
    // an unexplained 0.
    assert(!needsCurl("http://localhost:8770/api/attestations"));
    assert(needsCurl("https://example.com/api/attestations"));
    assert(needsCurl("example.com"));
    assert(needsCurl(""));
}

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
    // buildCurlConfig: no token, no header — same rule as buildPostRequest.
    // An empty Bearer would come back 401 and name the wrong problem.
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
    // trimToken: surrounding whitespace and a trailing newline are not
    // part of the credential. A file written by `echo` has one.
    assert(trimToken("abc") == "abc");
    assert(trimToken("abc\n") == "abc");
    assert(trimToken("  abc\r\n") == "abc");
    assert(trimToken("\n\n") == "");
    assert(trimToken("") == "");
    assert(trimToken("   ") == "");
}
