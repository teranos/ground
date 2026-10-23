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
import db : versionString, sqlite3;
import code.store : storeOpen, storeClose, storeResume, storeList, storeDelete, storeSetMode;
import sessionmode : SessionMode, parseSessionMode, nameOf, letterOf;
import core.stdc.stdio : stdin, stdout, stderr, fputs, fwrite, fflush, ferror, FILE;
import code.mcp : McpGroup, openMcp, closeMcp;
public import code.reply : Reply, putEscaped, putNumber;

extern (C) ptrdiff_t getline(char** lineptr, size_t* n, FILE* stream);
extern (C) void free(void* p);
extern (C) int getpid();

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

// The sessions one ground code has live. An id is the start, pid and count of
// the process that opened it, so two sessions of one process differ and so do
// two processes. With a store, a session outlives that process: the next one
// resumes it by its id.
struct Sessions {
    ulong started;
    uint pid;
    uint count;
    Open[64] open; // the sessions live in this process
    size_t openLen;
    sqlite3* db;   // where sessions are kept; none, and they live in this process only
}

// A live session: its id, the cwd it is in and its additional roots, each kept
// whole, and the mode it is in.
struct Open {
    char[64] id;
    size_t idLen;
    char[1024] cwd;
    size_t cwdLen;
    McpGroup mcp;
    SessionMode mode;
    char[2048] dirs; // the JSON array a client is answered with
    size_t dirsLen;
}

// The additionalDirectories a request names, into list as the JSON array a
// client is answered with: in order, each path re-escaped, [] when it names
// none or null. 1 read; -1 not a list of strings; -2 a path not absolute,
// written into bad; -3 a path longer than ground code reads.
private int dirsOf(const(char)[] json, const(char)[] key, ref Reply list, ref Reply bad) {
    auto at = indexOf(json, key);
    if (at < 0) { list.add("[]"); return 1; }
    size_t p = cast(size_t) at + key.length;
    void ws() { while (p < json.length && (json[p] == ' ' || json[p] == '\t' || json[p] == '\n' || json[p] == '\r')) p++; }
    ws();
    if (p >= json.length || json[p] != ':') return -1;
    p++;
    ws();
    if (p + 4 <= json.length && json[p .. p + 4] == "null") { list.add("[]"); return 1; }
    if (p >= json.length || json[p] != '[') return -1;
    p++;
    ws();
    list.add("[");
    if (p < json.length && json[p] == ']') { list.add("]"); return 1; }
    for (bool first = true;; first = false) {
        if (p >= json.length || json[p] != '"') return -1;
        p++;
        char[4096] buf;
        size_t n = 0;
        bool put1(char c) { if (n >= buf.length) return false; buf[n++] = c; return true; }
        while (true) {
            if (p >= json.length) return -1;
            char c = json[p++];
            if (c == '"') break;
            if (c != '\\') { if (!put1(c)) return -3; continue; }
            if (p >= json.length) return -1;
            char e = json[p++];
            char o;
            switch (e) {
                case '"': o = '"'; break;
                case '\\': o = '\\'; break;
                case '/': o = '/'; break;
                case 'n': o = '\n'; break;
                case 't': o = '\t'; break;
                case 'r': o = '\r'; break;
                case 'b': o = '\b'; break;
                case 'f': o = '\f'; break;
                case 'u': {
                    uint cp;
                    if (!hex4(json, p, cp)) return -1;
                    if (cp >= 0xD800 && cp < 0xDC00) {
                        uint lo;
                        if (p + 2 > json.length || json[p] != '\\' || json[p + 1] != 'u') return -1;
                        p += 2;
                        if (!hex4(json, p, lo) || lo < 0xDC00 || lo >= 0xE000) return -1;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 && cp < 0xE000) return -1;
                    if (cp < 0x80) { if (!put1(cast(char) cp)) return -3; }
                    else if (cp < 0x800) {
                        if (!put1(cast(char)(0xC0 | (cp >> 6))) || !put1(cast(char)(0x80 | (cp & 0x3F)))) return -3;
                    } else if (cp < 0x10000) {
                        if (!put1(cast(char)(0xE0 | (cp >> 12))) || !put1(cast(char)(0x80 | ((cp >> 6) & 0x3F)))
                            || !put1(cast(char)(0x80 | (cp & 0x3F)))) return -3;
                    } else {
                        if (!put1(cast(char)(0xF0 | (cp >> 18))) || !put1(cast(char)(0x80 | ((cp >> 12) & 0x3F)))
                            || !put1(cast(char)(0x80 | ((cp >> 6) & 0x3F))) || !put1(cast(char)(0x80 | (cp & 0x3F)))) return -3;
                    }
                    continue;
                }
                default: return -1;
            }
            if (!put1(o)) return -3;
        }
        auto path = buf[0 .. n];
        if (n == 0 || path[0] != '/') { bad.add(path); return -2; }
        if (!first) list.add(",");
        list.add(`"`); putEscaped(list, path); list.add(`"`);
        ws();
        if (p < json.length && json[p] == ',') { p++; ws(); continue; }
        if (p < json.length && json[p] == ']') { list.add("]"); return 1; }
        return -1;
    }
}

private bool hex4(const(char)[] json, ref size_t p, ref uint cp) {
    if (p + 4 > json.length) return false;
    cp = 0;
    foreach (c; json[p .. p + 4]) {
        cp <<= 4;
        if (c >= '0' && c <= '9') cp |= c - '0';
        else if (c >= 'a' && c <= 'f') cp |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') cp |= c - 'A' + 10;
        else return false;
    }
    p += 4;
    return true;
}

// The error a dirsOf refusal is said to the client as, or false when it read.
private bool refuseDirs(int got, ref Reply bad, ref Reply r, const(char)[] kept) {
    if (got == -1) { r.add(`,"error":{"code":-32602,"message":"additionalDirectories must be a list of paths"}}`); return true; }
    if (got == -2) {
        r.add(`,"error":{"code":-32602,"message":"additionalDirectories must be absolute paths: `);
        putEscaped(r, bad.slice()); r.add(`"}}`);
        return true;
    }
    if (got == -3) { r.add(`,"error":{"code":-32602,"message":"a path in additionalDirectories is longer than the 4096 bytes ground code reads"}}`); return true; }
    if (kept.length > Open.init.dirs.length) {
        r.add(`,"error":{"code":-32602,"message":"additionalDirectories are longer than the 2048 bytes ground code keeps"}}`);
        return true;
    }
    return false;
}

// The modes a session offers: the six ground already names, by their wire
// values, in sessionmode.d's order. A permission block's letter is how a rule
// says which of them it applies in.
private immutable SessionMode[6] offered = [SessionMode.manual, SessionMode.plan,
    SessionMode.acceptEdits, SessionMode.auto_, SessionMode.dontAsk, SessionMode.bypassPermissions];

private string shownAs(SessionMode m) {
    final switch (m) {
        case SessionMode.manual: return "Manual";
        case SessionMode.plan: return "Plan";
        case SessionMode.acceptEdits: return "Accept edits";
        case SessionMode.auto_: return "Auto";
        case SessionMode.dontAsk: return "Don't ask";
        case SessionMode.bypassPermissions: return "Bypass permissions";
        case SessionMode.unknown: return "";
    }
}

// A SessionModeState: the mode the session is in, and the six it offers.
private void putModes(ref Reply r, SessionMode current) {
    r.add(`{"currentModeId":"`); r.add(nameOf(current)); r.add(`","availableModes":[`);
    foreach (i, m; offered) {
        if (i > 0) r.add(",");
        char[1] letter = [letterOf(m)];
        r.add(`{"id":"`); r.add(nameOf(m)); r.add(`","name":"`); r.add(shownAs(m));
        r.add(`","description":"`); r.add(letter[]); r.add(` in a permission block"}`);
    }
    r.add("]}");
}

private void putSessionId(ref Reply r, ref const Sessions s, uint n) {
    r.add("code-"); putNumber(r, s.started); r.add("-"); putNumber(r, s.pid); r.add("-"); putNumber(r, n);
}

private void keep(ref Open o, const(char)[] id, const(char)[] cwd, SessionMode mode, const(char)[] dirs) {
    foreach (i, c; id) o.id[i] = c; // a slice copy calls druntime
    o.idLen = id.length;
    foreach (i, c; cwd) o.cwd[i] = c;
    o.cwdLen = cwd.length;
    o.mode = mode;
    foreach (i, c; dirs) o.dirs[i] = c;
    o.dirsLen = dirs.length;
}

private long now() {
    import core.stdc.time : time;
    if (__ctfe) return 0;
    return cast(long) time(null);
}

// Where an id stands among the sessions live here, or -1: one this process
// never opened or resumed, and one it closed, are not live here.
private ptrdiff_t openAt(ref const Sessions s, const(char)[] id) {
    foreach (i; 0 .. s.openLen)
        if (s.open[i].id[0 .. s.open[i].idLen] == id) return cast(ptrdiff_t) i;
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
        put(`,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}}},"agentInfo":{"name":"ground","version":"`);
        put(versionString()); put(`"}}}`);
        return true;
    }

    // Ground owns each session's MCP clients, including discovery and close.
    if (method == "session/new") {
        char[4096] cb;
        auto cwd = extractJsonString(line, `"cwd"`, &cb[0], cb.length);
        auto mcp = emptyArray(line, `"mcpServers"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (cwd is null) { put(`,"error":{"code":-32602,"message":"session/new needs cwd"}}`); return true; }
        if (cwd.length == 0 || cwd[0] != '/') {
            char[8192] eb;
            auto n = jsonEscapeInto(cwd, eb[]);
            put(`,"error":{"code":-32602,"message":"cwd must be an absolute path: `);
            put(n < 0 ? "one too long to name" : eb[0 .. cast(size_t) n]);
            put(`"}}`);
            return true;
        }
        if (mcp < 0) { put(`,"error":{"code":-32602,"message":"session/new needs mcpServers"}}`); return true; }
        if (cwd.length > sessions.open[0].cwd.length) {
            put(`,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);
            return true;
        }
        Reply dirs, bad;
        scope(exit) { dirs.dispose(); bad.dispose(); }
        if (refuseDirs(dirsOf(line, `"additionalDirectories"`, dirs, bad), bad, r, dirs.slice())) return true;
        if (sessions.openLen == sessions.open.length) {
            put(`,"error":{"code":-32603,"message":"ground code holds 64 open sessions; close one first"}}`);
            return true;
        }
        // The servers come up before the row is written: a session the store
        // keeps is one whose tools are there.
        auto o = &sessions.open[sessions.openLen];
        if (!__ctfe) {
            Reply detail;
            scope(exit) detail.dispose();
            if (!openMcp(line, cwd, o.mcp, detail)) {
                put(`,"error":{"code":-32603,"message":"session MCP setup failed","data":`);
                put(detail.slice()); put(`}}`);
                return true;
            }
        } else if (mcp == 0) assert(0, "MCP processes are tested at runtime");
        sessions.count++;
        Reply sid;
        putSessionId(sid, sessions, sessions.count);
        if (sessions.db !is null && !storeOpen(sessions.db, sid.slice(), cwd, dirs.slice(), now())) {
            Reply detail;
            scope(exit) detail.dispose();
            if (!__ctfe) closeMcp(o.mcp, detail);
            put(`,"error":{"code":-32603,"message":"the store refused the session ground code opened"}}`);
            return true;
        }
        keep(*o, sid.slice(), cwd, SessionMode.manual, dirs.slice());
        sessions.openLen++;
        put(`,"result":{"sessionId":"`); put(sid.slice());
        put(`","modes":`); putModes(r, SessionMode.manual); put(`}}`);
        return true;
    }

    // Close owns every MCP child. The session is removed even if a child needs
    // forced termination, and that failure is returned to the ACP client.
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
        if (sessions.db !is null && !storeClose(sessions.db, sid, now())) {
            put(`,"error":{"code":-32603,"message":"the store refused to close `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        bool closed = true;
        Reply detail;
        if (!__ctfe) closed = closeMcp(sessions.open[cast(size_t) at].mcp, detail);
        scope(exit) detail.dispose();
        sessions.openLen--;
        sessions.open[cast(size_t) at] = sessions.open[sessions.openLen];
        sessions.open[sessions.openLen] = Open.init;
        if (closed) put(`,"result":{}}`);
        else { put(`,"error":{"code":-32603,"message":"session MCP shutdown failed","data":`); put(detail.slice()); put(`}}`); }
        return true;
    }

    // Only the sessions of this process: nothing is kept past it yet. Ground
    // code never gives a nextCursor, so there is no cursor of its to page from.
    if (method == "session/list") {
        char[4096] fb;
        auto cwd = extractJsonString(line, `"cwd"`, &fb[0], fb.length);
        auto cursor = rawValue(line, `"cursor"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (cwd !is null && (cwd.length == 0 || cwd[0] != '/')) {
            put(`,"error":{"code":-32602,"message":"cwd must be an absolute path: `);
            putEscaped(r, cwd); put(`"}}`);
            return true;
        }
        if (cursor !is null && cursor != "null") {
            put(`,"error":{"code":-32602,"message":"ground code gives no nextCursor, so it has no cursor to page from"}}`);
            return true;
        }
        put(`,"result":{"sessions":[`);
        bool first = true;
        // "Omitted and empty values are equivalent", so a session with no
        // additional roots lists none.
        void entry(const(char)[] sid, const(char)[] at, const(char)[] dirs) {
            if (!first) put(",");
            first = false;
            put(`{"sessionId":"`); putEscaped(r, sid);
            put(`","cwd":"`); putEscaped(r, at); put(`"`);
            if (dirs != "[]") { put(`,"additionalDirectories":`); put(dirs); }
            put(`}`);
        }
        if (sessions.db !is null) {
            if (!storeList(sessions.db, cwd, &entry)) {
                r.len = 0;
                put(`{"jsonrpc":"2.0","id":`); put(id);
                put(`,"error":{"code":-32603,"message":"the store refused to list sessions"}}`);
                return true;
            }
        } else {
            foreach (i; 0 .. sessions.openLen) {
                auto o = &sessions.open[i];
                auto at = o.cwd[0 .. o.cwdLen];
                if (cwd is null || at == cwd) entry(o.id[0 .. o.idLen], at, o.dirs[0 .. o.dirsLen]);
            }
        }
        put(`]}}`);
        return true;
    }

    // "Resumes an existing session without returning previous messages", so
    // there is nothing to replay: a session the store has open becomes live
    // here. Its cwd is its own for its life: the additional roots "may differ
    // from any previously used or reported list as long as the request `cwd`
    // matches the session's `cwd`". One the store does not have open was
    // closed or never opened, and is not there to resume.
    if (method == "session/resume") {
        char[256] sb;
        char[4096] cb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        auto cwd = extractJsonString(line, `"cwd"`, &cb[0], cb.length);
        auto mcp = emptyArray(line, `"mcpServers"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/resume needs sessionId"}}`); return true; }
        if (cwd is null) { put(`,"error":{"code":-32602,"message":"session/resume needs cwd"}}`); return true; }
        if (cwd[0] != '/') {
            put(`,"error":{"code":-32602,"message":"cwd must be an absolute path: `);
            putEscaped(r, cwd); put(`"}}`);
            return true;
        }
        if (mcp == 0) {
            put(`,"error":{"code":-32602,"message":"ground code connects no MCP servers yet, and session/resume named some"}}`);
            return true;
        }
        if (cwd.length > sessions.open[0].cwd.length) {
            put(`,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);
            return true;
        }
        Reply dirs, bad;
        scope(exit) { dirs.dispose(); bad.dispose(); }
        if (refuseDirs(dirsOf(line, `"additionalDirectories"`, dirs, bad), bad, r, dirs.slice())) return true;
        auto at = openAt(sessions, sid);
        auto mode = at < 0 ? SessionMode.manual : sessions.open[cast(size_t) at].mode;
        char[1024] was;
        size_t wasLen = 0;
        int stored;
        if (sessions.db !is null) stored = storeResume(sessions.db, sid, cwd, dirs.slice(), mode, was[], wasLen);
        else if (at < 0) stored = 0;
        else {
            auto o = &sessions.open[cast(size_t) at];
            stored = o.cwd[0 .. o.cwdLen] == cwd ? 1 : 2;
            foreach (c; o.cwd[0 .. o.cwdLen]) was[wasLen++] = c;
        }
        if (stored == 2) {
            put(`,"error":{"code":-32602,"message":"`); putEscaped(r, sid);
            put(` is in `); putEscaped(r, was[0 .. wasLen]);
            put(`, not `); putEscaped(r, cwd); put(`"}}`);
            return true;
        }
        if (stored < 0) {
            put(`,"error":{"code":-32603,"message":"the store refused to resume `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        if (stored == 0 || sid.length > sessions.open[0].id.length) {
            put(`,"error":{"code":-32002,"message":"no session to resume: `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        if (at < 0) {
            if (sessions.openLen == sessions.open.length) {
                put(`,"error":{"code":-32603,"message":"ground code holds 64 open sessions; close one first"}}`);
                return true;
            }
            at = cast(ptrdiff_t) sessions.openLen;
            sessions.openLen++;
        }
        keep(sessions.open[cast(size_t) at], sid, cwd, mode, dirs.slice());
        put(`,"result":{"modes":`); putModes(r, mode); put(`}}`);
        return true;
    }

    // A mode is one a session offers, set on a session live here. It is kept
    // with the session, so a resume comes back in it. The client chose it, so
    // there is no current_mode_update to tell it what it already knows.
    if (method == "session/set_mode") {
        char[256] sb;
        char[64] mb2;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        auto want = extractJsonString(line, `"modeId"`, &mb2[0], mb2.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/set_mode needs sessionId"}}`); return true; }
        if (want is null) { put(`,"error":{"code":-32602,"message":"session/set_mode needs modeId"}}`); return true; }
        auto at = openAt(sessions, sid);
        if (at < 0) {
            put(`,"error":{"code":-32002,"message":"no open session `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        auto mode = parseSessionMode(want);
        if (mode == SessionMode.unknown) {
            put(`,"error":{"code":-32602,"message":"no mode `); putEscaped(r, want);
            put(`; a session offers default, plan, acceptEdits, auto, dontAsk and bypassPermissions"}}`);
            return true;
        }
        if (sessions.db !is null) {
            auto kept = storeSetMode(sessions.db, sid, mode);
            if (kept != 1) {
                put(`,"error":{"code":-32603,"message":"the store refused the mode of `);
                putEscaped(r, sid); put(`"}}`);
                return true;
            }
        }
        sessions.open[cast(size_t) at].mode = mode;
        put(`,"result":{}}`);
        return true;
    }

    // "deleting an existing session from `session/list`": what list would show
    // is what delete takes. Gone from the store, it is gone for every process,
    // and one live here is no longer live.
    if (method == "session/delete") {
        char[256] sb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/delete needs sessionId"}}`); return true; }
        auto at = openAt(sessions, sid);
        int gone = sessions.db is null ? (at < 0 ? 0 : 1) : storeDelete(sessions.db, sid);
        if (gone < 0) {
            put(`,"error":{"code":-32603,"message":"the store refused to delete `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        if (gone == 0) {
            put(`,"error":{"code":-32002,"message":"no session to delete: `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        // A session live here owns its servers, and deleting it ends them.
        bool ended = true;
        Reply detail;
        scope(exit) detail.dispose();
        if (at >= 0) {
            if (!__ctfe) ended = closeMcp(sessions.open[cast(size_t) at].mcp, detail);
            sessions.openLen--;
            sessions.open[cast(size_t) at] = sessions.open[sessions.openLen];
            sessions.open[sessions.openLen] = Open.init;
        }
        if (ended) put(`,"result":{}}`);
        else { put(`,"error":{"code":-32603,"message":"session MCP shutdown failed","data":`); put(detail.slice()); put(`}}`); }
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
    import db : openDb, sqlite3_close;
    auto sessions = Sessions(cast(ulong) time(null), cast(uint) getpid());
    // Ground stops rather than degrades: a session no store keeps could not
    // be resumed, and a client told it could would find out too late.
    sessions.db = openDb();
    if (sessions.db is null) {
        fputs("ground code: the store would not open, so no session could outlive this process\n", stderr);
        return 1;
    }
    scope (exit) sqlite3_close(sessions.db);
    int result;
    scope(exit) free(buf);
    while (true) {
        auto n = getline(&buf, &cap, stdin);
        if (n < 0) {
            if (ferror(stdin)) { fputs("ground code: failed reading ACP input\n", stderr); result = 1; }
            break;
        }
        auto line = buf[0 .. cast(size_t) n];
        while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r')) line = line[0 .. $ - 1];
        if (line.length == 0) continue;
        Reply r;
        scope(exit) r.dispose();
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
            // Allocation failure must still answer the request. Stream a
            // small error without allocating another response buffer.
            auto id = rawValue(line, `"id"`);
            if (id is null) id = "null";
            fputs(`{"jsonrpc":"2.0","id":`, stdout);
            fwrite(id.ptr, 1, id.length, stdout);
            fputs(`,"error":{"code":-32603,"message":"could not allocate ACP response"}}` ~ "\n", stdout);
            if (fflush(stdout) != 0) { result = 1; break; }
            continue;
        }
        auto reply = r.slice();
        if (fwrite(reply.ptr, 1, reply.length, stdout) != reply.length ||
            fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
            fputs("ground code: failed writing ACP response\n", stderr);
            result = 1; break;
        }
    }
    // Cleanup runs before returning, so its failure is part of the exit status.
    foreach (i; 0 .. sessions.openLen) {
        Reply detail;
        if (!closeMcp(sessions.open[i].mcp, detail)) result = 1;
        detail.dispose();
    }
    sessions.openLen = 0;
    return result;
}
