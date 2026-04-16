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
    req.reset();
    req.put("POST ");
    req.put(path);
    req.put(" HTTP/1.0\r\nHost: ");
    req.put(host);
    req.put("\r\nContent-Type: application/json\r\nContent-Length: ");
    putInt(req, body_.length);
    req.put("\r\nConnection: close\r\n\r\n");
    req.put(body_);

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

private void putInt(ref ZBuf buf, size_t v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
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
