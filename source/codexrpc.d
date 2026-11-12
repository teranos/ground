module codexrpc;

// Codex's existing daemon speaks WebSocket JSON-RPC over a Unix socket.
// No child process, new server, thread resume, or model request is involved.
import libjsonc;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.un;
import core.sys.posix.unistd : read, write, close;
import core.sys.posix.fcntl : open, fcntl, O_RDONLY, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.poll : poll, pollfd, POLLIN, POLLOUT;
import core.stdc.errno : errno, EINTR, EAGAIN, EINPROGRESS;
import core.stdc.string : strlen;
import core.sys.posix.time : timespec;
version (OSX) {
    extern(C) int clock_gettime(uint, timespec*);
    private enum CLOCK_MONOTONIC = 6;
} else import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC;

// Small fixed-buffer encoders keep ground_hook a BetterC binary. SHA-1 here
// serves only RFC 6455's upgrade check, never credentials or signatures.
private void base64(const(ubyte)[] bytes, char[] dest) {
    enum alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_;
    for (size_t i; i < bytes.length; i += 3) {
        uint bits = cast(uint) bytes[i] << 16;
        if (i + 1 < bytes.length) bits |= cast(uint) bytes[i + 1] << 8;
        if (i + 2 < bytes.length) bits |= bytes[i + 2];
        dest[out_++] = alphabet[(bits >> 18) & 63];
        dest[out_++] = alphabet[(bits >> 12) & 63];
        dest[out_++] = i + 1 < bytes.length ? alphabet[(bits >> 6) & 63] : '=';
        dest[out_++] = i + 2 < bytes.length ? alphabet[bits & 63] : '=';
    }
}

char[28] websocketAccept(const(char)[24] key) {
    ubyte[128] blocks;
    blocks[0 .. 24] = cast(const(ubyte)[]) key[];
    blocks[24 .. 60] = cast(const(ubyte)[]) "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    blocks[60] = 0x80;
    blocks[126] = 1; blocks[127] = 0xe0; // 60 * 8 bits
    uint[5] h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    uint rotate(uint x, uint n) { return (x << n) | (x >> (32 - n)); }
    foreach (block; 0 .. 2) {
        uint[80] w;
        foreach (i; 0 .. 16) foreach (j; 0 .. 4) w[i] = (w[i] << 8) | blocks[block * 64 + i * 4 + j];
        foreach (i; 16 .. 80) w[i] = rotate(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
        auto a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        foreach (i; 0 .. 80) {
            uint f, k;
            if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
            else { f = b ^ c ^ d; k = 0xca62c1d6; }
            auto temp = rotate(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rotate(b, 30); b = a; a = temp;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
    ubyte[20] digest;
    foreach (i; 0 .. 5) foreach (j; 0 .. 4) digest[i * 4 + j] = cast(ubyte) (h[i] >> ((3 - j) * 8));
    char[28] encoded;
    base64(digest[], encoded[]);
    return encoded;
}
private ptrdiff_t indexOf(const(char)[] text, const(char)[] needle) {
    if (needle.length > text.length) return -1;
    foreach (i; 0 .. text.length - needle.length + 1)
        if (text[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

const(char)[] jsonText(json_object* value) {
    if (json_object_get_type(value) != json_type.string_) return "";
    return json_object_get_string(value)[0 .. json_object_get_string_len(value)];
}

void textField(json_object* obj, const(char)* key, const(char)[] value) {
    json_object_object_add(obj, key, json_object_new_string_len(value.ptr, cast(int) value.length));
}

private long millis() {
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000 + now.tv_nsec / 1_000_000;
}

private bool randomBytes(ubyte[] bytes) {
    auto fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return false;
    scope(exit) close(fd);
    size_t n;
    while (n < bytes.length) {
        auto got = read(fd, bytes.ptr + n, bytes.length - n);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return false;
        n += got;
    }
    return true;
}

struct CodexRpc {
    int fd = -1;
    long deadline;
    long sequence;
    const(char)[] error;
    // One bounded message; reused after json-c has copied the reply.
    ubyte[2 * 1024 * 1024] message = void;

    void shutdown() { if (fd >= 0) close(fd); fd = -1; }
    bool fail(const(char)[] why) { error = why; return false; }

    private bool ready(short events) {
        while (true) {
            auto left = deadline - millis();
            if (left <= 0) return fail("Codex control timed out");
            pollfd p = pollfd(fd, events, 0);
            auto rc = poll(&p, 1, cast(int) left);
            if (rc < 0 && errno == EINTR) continue;
            if (rc <= 0) return fail("Codex control timed out");
            if (!(p.revents & events)) return fail("Codex control socket closed");
            return true;
        }
    }

    private bool transfer(ubyte[] bytes, bool sending) {
        size_t n;
        while (n < bytes.length) {
            if (!ready(sending ? POLLOUT : POLLIN)) return false;
            version (linux) enum sendFlags = MSG_NOSIGNAL;
            else enum sendFlags = 0;
            auto got = sending ? send(fd, bytes.ptr + n, bytes.length - n, sendFlags)
                               : read(fd, bytes.ptr + n, bytes.length - n);
            if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (got <= 0) return fail("Codex control socket closed");
            n += got;
        }
        return true;
    }

    bool connectTo(const(char)[] path, int timeoutMs = 10000) {
        deadline = millis() + timeoutMs;
        sockaddr_un address;
        if (path.length == 0 || path.length >= address.sun_path.length)
            return fail("Codex control socket path is absent or too long");
        foreach (c; path) if (c == 0) return fail("Invalid Codex socket path");
        address.sun_family = AF_UNIX;
        address.sun_path[0 .. path.length] = cast(typeof(address.sun_path[0])[]) path;
        version (OSX) address.sun_len = cast(ubyte) address.sizeof;
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return fail("Cannot open Codex control socket");
        // A dropped daemon must become an error, not SIGPIPE in Ground.
        version (OSX) {
            int yes = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, yes.sizeof);
        }
        if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0)
            return fail("Cannot make Codex control nonblocking");
        if (connect(fd, cast(sockaddr*) &address, cast(socklen_t) address.sizeof) != 0) {
            if (errno != EINPROGRESS || !ready(POLLOUT)) return fail("Cannot reach the existing Codex daemon");
            int code; socklen_t size = code.sizeof;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) != 0 || code != 0)
                return fail("Cannot reach the existing Codex daemon");
        }
        ubyte[16] nonce;
        char[24] key;
        if (!randomBytes(nonce[])) return fail("Cannot generate WebSocket nonce");
        base64(nonce[], key[]);
        auto expected = websocketAccept(key);
        import zbuf : ZBuf;
        ZBuf request;
        request.put("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ");
        request.put(key[]); request.put("\r\n\r\n");
        if (!transfer(cast(ubyte[]) request.slice(), true)) return false;
        char[8192] header; size_t n;
        while (n < header.length) {
            if (!transfer(cast(ubyte[]) header[n .. n + 1], false)) return false;
            n++;
            if (n >= 4 && header[n - 4 .. n] == "\r\n\r\n") break;
        }
        if (n == header.length || indexOf(header[0 .. n], "HTTP/1.1 101 ") != 0)
            return fail("Codex rejected WebSocket upgrade");
        bool accept, upgrade, connection;
        size_t at;
        while (at < n) {
            auto end = indexOf(header[at .. n], "\r\n");
            if (end < 0) break;
            auto line = header[at .. at + end];
            auto colon = indexOf(line, ":");
            if (colon >= 0) {
                auto name = line[0 .. colon];
                foreach (ref c; name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
                auto val = line[colon + 1 .. $];
                while (val.length && (val[0] == ' ' || val[0] == '\t')) val = val[1 .. $];
                while (val.length && (val[$-1] == ' ' || val[$-1] == '\t')) val = val[0 .. $-1];
                if (name == "sec-websocket-accept") accept = val == expected[];
                else {
                    foreach (ref c; val) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
                    if (name == "upgrade") upgrade = val == "websocket";
                    if (name == "connection") connection = val == "upgrade";
                }
            }
            at += end + 2;
        }
        if (!accept || !upgrade || !connection) return fail("Invalid Codex WebSocket handshake");
        auto params = parseJson(`{"clientInfo":{"name":"ground-effort","version":"0.2"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}`);
        auto reply = call("initialize", params);
        json_object_put(params);
        if (reply is null) return false;
        json_object_put(reply);
        return frame(1, cast(const(ubyte)[]) `{"method":"initialized","params":{}}`);
    }

    private bool frame(ubyte opcode, const(ubyte)[] bytes) {
        ubyte[14] head; size_t n = 2;
        head[0] = cast(ubyte) (0x80 | opcode);
        if (bytes.length < 126) head[1] = cast(ubyte) (0x80 | bytes.length);
        else if (bytes.length <= 65535) {
            head[1] = 0xfe; head[n++] = cast(ubyte) (bytes.length >> 8); head[n++] = cast(ubyte) bytes.length;
        } else {
            head[1] = 0xff;
            foreach_reverse (i; 0 .. 8) head[n++] = cast(ubyte) (bytes.length >> (i * 8));
        }
        ubyte[4] mask;
        if (!randomBytes(mask[])) return fail("Cannot generate WebSocket mask");
        head[n .. n + 4] = mask[]; n += 4;
        if (!transfer(head[0 .. n], true)) return false;
        ubyte[4096] chunk; size_t at;
        while (at < bytes.length) {
            auto count = bytes.length - at;
            if (count > chunk.length) count = chunk.length;
            foreach (i; 0 .. count) chunk[i] = bytes[at + i] ^ mask[(at + i) % 4];
            if (!transfer(chunk[0 .. count], true)) return false;
            at += count;
        }
        return true;
    }

    private json_object* receive() {
        size_t n; bool started;
        while (true) {
            ubyte[2] head;
            if (!transfer(head[], false)) return null;
            auto opcode = head[0] & 15; bool final_ = (head[0] & 128) != 0;
            if ((head[0] & 0x70) || (head[1] & 128)) { fail("Invalid Codex WebSocket flags"); return null; }
            ulong length = head[1] & 127;
            if (length >= 126) {
                ubyte[8] extended; auto count = length == 126 ? 2 : 8;
                if (!transfer(extended[0 .. count], false)) return null;
                length = 0;
                foreach (b; extended[0 .. count]) length = length * 256 + b;
            }
            if (opcode >= 8) {
                if (!final_ || length > 125) { fail("Invalid Codex control frame"); return null; }
                ubyte[125] control;
                if (!transfer(control[0 .. cast(size_t) length], false)) return null;
                if (opcode == 9) { if (!frame(10, control[0 .. cast(size_t) length])) return null; continue; }
                if (opcode == 10) continue;
                fail("Codex closed WebSocket"); return null;
            }
            if (length > message.length - n || !((opcode == 1 && !started) || (opcode == 0 && started))) {
                fail("Invalid or oversized Codex message"); return null;
            }
            started = true;
            if (!transfer(message[n .. n + cast(size_t) length], false)) return null;
            n += length;
            if (final_) {
                auto reply = parseJson(cast(char[]) message[0 .. n]);
                if (json_object_get_type(reply) != json_type.object) {
                    json_object_put(reply); fail("Invalid Codex RPC JSON"); return null;
                }
                return reply;
            }
        }
    }

    // Returned object owns its result until the caller puts it.
    json_object* call(const(char)[] method, json_object* params = null) {
        auto request = json_object_new_object();
        scope(exit) json_object_put(request);
        json_object_object_add(request, "id", json_object_new_int64(++sequence));
        textField(request, "method", method);
        // params is borrowed. Serialize its JSON into a new owned value.
        if (params !is null) {
            auto encoded = json_object_to_json_string_ext(params, 0);
            json_object_object_add(request, "params", parseJson(encoded[0 .. strlen(encoded)]));
        }
        auto encoded = json_object_to_json_string_ext(request, 0);
        if (!frame(1, cast(const(ubyte)[]) encoded[0 .. strlen(encoded)])) return null;
        while (true) {
            auto reply = receive();
            if (reply is null) return null;
            auto id = jsonField(reply, "id");
            if (jsonField(reply, "method") !is null) {
                // No method we call should require client-side action.
                if (id !is null) { json_object_put(reply); fail("Codex requested unsupported client action"); return null; }
                json_object_put(reply); continue;
            }
            if (json_object_get_type(id) != json_type.int_ || json_object_get_int64(id) != sequence) {
                json_object_put(reply); continue;
            }
            if (jsonField(reply, "error") !is null || jsonField(reply, "result") is null) {
                json_object_put(reply); fail("Codex rejected effort RPC or omitted its result"); return null;
            }
            return reply;
        }
    }
}
