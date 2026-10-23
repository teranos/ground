module code;

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

// The line that answers this one, or false for a notification, which JSON-RPC
// gives no answer. A method's block runs from its test to its first return.
bool answer(const(char)[] line, ref Reply r) {
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
        put(`,"result":{"protocolVersion":1,"agentInfo":{"name":"ground","version":"`);
        put(versionString()); put(`"}}}`);
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
    char* buf = null;
    size_t cap = 0;
    while (true) {
        auto n = getline(&buf, &cap, stdin);
        if (n < 0) break;
        auto line = buf[0 .. cast(size_t) n];
        while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r')) line = line[0 .. $ - 1];
        if (line.length == 0) continue;
        Reply r;
        if (!answer(line, r)) {
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
