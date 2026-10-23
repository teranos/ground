module code.acp;

// Ground code: the agent ground runs itself, behind an ACP client. One
// JSON-RPC message a line on stdin, one answer a line on stdout. The protocol
// is the schema flake.nix pins, and `ground parity` counts what each method's
// block here reads and writes against it.

enum BOOK_COMMAND = q"EOS
# an ACP client runs it and speaks JSON-RPC on its stdin and stdout:
ground code
EOS";

import parse : extractJsonString;
import matcher : indexOf;
import provenance : jsonEscapeInto;
import db : versionString;
import core.stdc.stdio : stdin, stdout, stderr, fputs, fwrite, fflush, FILE;

extern (C) ptrdiff_t getline(char** lineptr, size_t* n, FILE* stream);
extern (C) void free(void* p);
extern (C) int getpid();

struct Reply {
    char[4096] data = 0;
    size_t len;
    bool full; // an answer that did not fit; said, never sent cut short

    void add(const(char)[] s) {
        if (len + s.length > data.length) { full = true; return; }
        foreach (c; s) data[len++] = c;
    }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// The value at a key as it stands in the line: a number, a quoted string with
// its quotes, or null. An id is echoed, never interpreted.
const(char)[] rawValue(const(char)[] json, const(char)[] key) {
    auto at = indexOf(json, key);
    if (at < 0) return null;
    size_t p = cast(size_t) at + key.length;
    while (p < json.length && json[p] == ' ') p++;
    if (p >= json.length || json[p] != ':') return null;
    p++;
    while (p < json.length && json[p] == ' ') p++;
    size_t from = p;
    if (p < json.length && json[p] == '"') {
        p++;
        while (p < json.length && json[p] != '"') p += json[p] == '\\' ? 2 : 1;
        if (p >= json.length) return null;
        return json[from .. p + 1];
    }
    while (p < json.length && json[p] != ',' && json[p] != '}' && json[p] != ' ') p++;
    return p > from ? json[from .. p] : null;
}

// Whether the array at a key is empty: 1 empty, 0 not, -1 no array there.
int emptyArray(const(char)[] json, const(char)[] key) {
    auto at = indexOf(json, key);
    if (at < 0) return -1;
    size_t p = cast(size_t) at + key.length;
    while (p < json.length && json[p] == ' ') p++;
    if (p >= json.length || json[p] != ':') return -1;
    p++;
    while (p < json.length && json[p] == ' ') p++;
    if (p >= json.length || json[p] != '[') return -1;
    p++;
    while (p < json.length && json[p] == ' ') p++;
    return p < json.length && json[p] == ']' ? 1 : 0;
}

// The sessions one ground code has opened. An id is its start, its pid and a
// count, so two sessions of one process differ and so do two processes.
struct Sessions {
    ulong started;
    uint pid;
    uint count;
    uint[1024] open; // the counts of the sessions not yet closed
    size_t openLen;
}

private void putNumber(ref Reply r, ulong u) {
    char[24] d;
    size_t k = d.length;
    do { d[--k] = cast(char)('0' + u % 10); u /= 10; } while (u > 0);
    r.add(d[k .. $]);
}

// Where an id stands among the open sessions, or -1: one this process never
// opened, one it closed, and one of another process's are all not open here.
private ptrdiff_t openAt(ref const Sessions s, const(char)[] id) {
    Reply p;
    p.add("code-"); putNumber(p, s.started); p.add("-"); putNumber(p, s.pid); p.add("-");
    auto prefix = p.slice();
    if (id.length <= prefix.length || id[0 .. prefix.length] != prefix) return -1;
    auto digits = id[prefix.length .. $];
    if (digits.length > 1 && digits[0] == '0') return -1;
    ulong n = 0;
    foreach (c; digits) {
        if (c < '0' || c > '9') return -1;
        n = n * 10 + (c - '0');
        if (n > uint.max) return -1;
    }
    foreach (i; 0 .. s.openLen) if (s.open[i] == n) return cast(ptrdiff_t) i;
    return -1;
}

// The line that answers this one, or false for a notification, which JSON-RPC
// gives no answer. A method's block is the whole branch that tests for it.
bool answer(const(char)[] line, ref Reply r, ref Sessions sessions) {
    void put(const(char)[] s) { r.add(s); }
    char[256] mb;
    auto method = extractJsonString(line, `"method"`, &mb[0], mb.length);
    auto id = rawValue(line, `"id"`);
    if (id is null) id = "null";

    if (method is null) {
        put(`{"jsonrpc":"2.0","id":`); put(id);
        put(`,"error":{"code":-32600,"message":"no method"}}`);
        return true;
    }

    // ACP's version is 1 for all of v1, and there is no other to offer: the
    // client's is answered with it whatever it asked for.
    if (method == "initialize") {
        put(`{"jsonrpc":"2.0","id":`); put(id);
        put(`,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{}}},"agentInfo":{"name":"ground","version":"`);
        put(versionString()); put(`"}}}`);
        return true;
    }

    // Stdio MCP is a transport every agent "MUST support". Ground code cannot
    // yet, and says so rather than taking the servers and never connecting them.
    if (method == "session/new") {
        char[4096] cb;
        auto cwd = extractJsonString(line, `"cwd"`, &cb[0], cb.length);
        auto mcp = emptyArray(line, `"mcpServers"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (cwd is null) { put(`,"error":{"code":-32602,"message":"session/new needs cwd"}}`); return true; }
        if (cwd[0] != '/') {
            char[8192] eb;
            auto n = jsonEscapeInto(cwd, eb[]);
            put(`,"error":{"code":-32602,"message":"cwd must be an absolute path: `);
            put(n < 0 ? "one too long to name" : eb[0 .. cast(size_t) n]);
            put(`"}}`);
            return true;
        }
        if (mcp < 0) { put(`,"error":{"code":-32602,"message":"session/new needs mcpServers"}}`); return true; }
        if (mcp == 0) {
            put(`,"error":{"code":-32602,"message":"ground code connects no MCP servers yet, and session/new named some"}}`);
            return true;
        }
        if (sessions.openLen == sessions.open.length) {
            put(`,"error":{"code":-32603,"message":"ground code holds 1024 open sessions; close one first"}}`);
            return true;
        }
        sessions.count++;
        sessions.open[sessions.openLen] = sessions.count;
        sessions.openLen++;
        put(`,"result":{"sessionId":"code-`);
        putNumber(r, sessions.started); put("-");
        putNumber(r, sessions.pid); put("-");
        putNumber(r, sessions.count); put(`"}}`);
        return true;
    }

    // The agent "must cancel any ongoing work related to the session". Nothing
    // runs in a session yet, so closing one frees its id and cancels nothing.
    if (method == "session/close") {
        char[256] sb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/close needs sessionId"}}`); return true; }
        auto at = openAt(sessions, sid);
        if (at < 0) {
            char[512] eb;
            auto n = jsonEscapeInto(sid, eb[]);
            put(`,"error":{"code":-32002,"message":"no open session `);
            put(n < 0 ? "one too long to name" : eb[0 .. cast(size_t) n]);
            put(`"}}`);
            return true;
        }
        sessions.openLen--;
        sessions.open[cast(size_t) at] = sessions.open[sessions.openLen];
        put(`,"result":{}}`);
        return true;
    }

    if (rawValue(line, `"id"`) is null) return false;
    char[512] eb;
    auto n = jsonEscapeInto(method, eb[]);
    put(`{"jsonrpc":"2.0","id":`); put(id);
    put(`,"error":{"code":-32601,"message":"ground code does not handle `);
    put(n < 0 ? "a method too long to name" : eb[0 .. cast(size_t) n]);
    put(`"}}`);
    return true;
}

int handleCode() {
    import core.stdc.time : time;
    char* buf = null;
    size_t cap = 0;
    auto sessions = Sessions(cast(ulong) time(null), cast(uint) getpid());
    while (true) {
        auto n = getline(&buf, &cap, stdin);
        if (n < 0) break;
        auto line = buf[0 .. cast(size_t) n];
        while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r')) line = line[0 .. $ - 1];
        if (line.length == 0) continue;
        Reply r;
        if (!answer(line, r, sessions)) {
            fputs("ground code: a notification it does not handle: ", stderr);
            fwrite(line.ptr, 1, line.length, stderr);
            fputs("\n", stderr);
            continue;
        }
        if (r.full) {
            fputs("ground code: the answer to this outgrew its buffer and was not sent: ", stderr);
            fwrite(line.ptr, 1, line.length, stderr);
            fputs("\n", stderr);
            continue;
        }
        fwrite(r.data.ptr, 1, r.len, stdout);
        fputs("\n", stdout);
        fflush(stdout);
    }
    free(buf);
    return 0;
}
