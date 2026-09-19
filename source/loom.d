module loom;

import zbuf : ZBuf;

// "loom is a qntx plugin thing, and we arent using it today"
// "if set, we send to loom, if not set, we dont."
// One UDP datagram per attestation to QNTX's loom plugin on this machine, at
// the port the project's qntx { loomPortUDP } names. No port, no socket.

extern (C) {
    int socket(int domain, int type, int protocol);
    long sendto(int sockfd, const(void)* buf, size_t len, int flags,
                const(void)* dest_addr, uint addrlen);
    int close(int fd);
}

// sockaddr_in for IPv4
struct sockaddr_in {
    ubyte sin_len;
    ubyte sin_family;
    ushort sin_port;
    uint sin_addr;
    ubyte[8] sin_zero;
}

// Measured 2026-09-19 on macOS: SO_SNDBUF on a fresh UDP socket is 9216, and
// a datagram past it is refused with EMSGSIZE before it leaves the process.
// The 64 KB buffer here used to be filled to 65536 and every send over this
// failed unread.
enum LOOM_DATAGRAM_MAX = 9216;

bool loomSends(int port) { return port > 0 && port <= 65535; }
bool loomFits(size_t len) { return len <= LOOM_DATAGRAM_MAX; }

__gshared char[LOOM_DATAGRAM_MAX] pktBuf = 0;

// What became of one send: the bytes handed to the kernel, or why none were.
struct Sent {
    long bytes;
    int err;       // errno when bytes < 0
    bool skipped;  // no port, or a datagram that could not fit
}

Sent sendToLoom(int port, ref ZBuf subjects, ref ZBuf predicates, ref ZBuf contexts,
                const(char)[] attributes) {
    Sent s;
    if (!loomSends(port)) { s.skipped = true; return s; }

    // Build JSON: {"subjects":...,"predicates":...,"contexts":...,"attributes":...}
    size_t need = `{"subjects":`.length + subjects.len + `,"predicates":`.length + predicates.len
        + `,"contexts":`.length + contexts.len + `,"attributes":`.length + attributes.length + 1;
    if (!loomFits(need)) { s.skipped = true; s.bytes = cast(long) need; return s; }

    size_t pos = 0;
    void append(const(char)[] t) { foreach (c; t) pktBuf[pos++] = c; }
    append(`{"subjects":`);
    append(subjects.slice());
    append(`,"predicates":`);
    append(predicates.slice());
    append(`,"contexts":`);
    append(contexts.slice());
    append(`,"attributes":`);
    append(attributes);
    append("}");

    enum AF_INET = 2;
    enum SOCK_DGRAM = 2;

    auto fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { s.bytes = -1; s.err = errnoNow(); return s; }

    sockaddr_in addr;
    addr.sin_len = 16;
    addr.sin_family = AF_INET;
    addr.sin_port = cast(ushort)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF)); // htons
    addr.sin_addr = 0x0100007F; // 127.0.0.1 in network byte order

    s.bytes = sendto(fd, &pktBuf[0], pos, 0, &addr, addr.sizeof);
    if (s.bytes < 0) s.err = errnoNow();
    close(fd);
    return s;
}

private int errnoNow() {
    import core.stdc.errno : errno;
    return errno;
}

// A loom that was named and not reached is said, once per send: a datagram
// the kernel refused, or one too large to hand it. Nothing named is nothing
// to say.
void loomSaid(const Sent s, const(char)[] sessionId) {
    import exec : emitError;
    if (s.skipped && s.bytes == 0) return;
    __gshared char[160] said = 0;
    size_t n;
    void put(const(char)[] t) { foreach (c; t) if (n < said.length) said[n++] = c; }
    void num(long v) {
        char[20] d = void; size_t dl = 0;
        if (v <= 0) d[dl++] = '0';
        while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (n < said.length) said[n++] = d[i];
    }
    n = 0;
    if (s.skipped) {
        put("the datagram is ");
        num(s.bytes);
        put(" bytes and loom takes ");
        num(LOOM_DATAGRAM_MAX);
        put("; not sent");
    } else {
        put("sendto refused the datagram: errno ");
        num(s.err);
    }
    emitError("loom.send", cast(string) said[0 .. n], s.err, 0, cast(string) sessionId,
              "loom", "", "", "");
}
