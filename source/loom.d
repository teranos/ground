module loom;

import sqlite : ZBuf;

// --- UDP send to loom ---

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

// 64KB packet buffer — localhost UDP supports up to 65507 bytes
__gshared char[65536] pktBuf = 0;

void sendToLoom(ref ZBuf subjects, ref ZBuf predicates, const(char)[] attributes) {
    // Build JSON: {"subjects":...,"predicates":...,"attributes":...}
    size_t pos = 0;

    void append(const(char)[] s) {
        foreach (c; s) {
            if (pos >= pktBuf.length) return;
            pktBuf[pos++] = c;
        }
    }

    append(`{"subjects":`);
    append(subjects.slice());
    append(`,"predicates":`);
    append(predicates.slice());
    append(`,"attributes":`);
    append(attributes);
    append("}");

    if (pos == 0) return;

    enum AF_INET = 2;
    enum SOCK_DGRAM = 2;
    enum LOOM_PORT = 19470;

    auto fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;

    sockaddr_in addr;
    addr.sin_len = 16;
    addr.sin_family = AF_INET;
    addr.sin_port = (LOOM_PORT >> 8) | ((LOOM_PORT & 0xFF) << 8); // htons
    addr.sin_addr = 0x0100007F; // 127.0.0.1 in network byte order

    sendto(fd, &pktBuf[0], pos, 0, &addr, addr.sizeof);
    close(fd);
}
