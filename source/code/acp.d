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
import proto : ParsedQntx;
import code.store : storeOpen, storeClose, storeResume, storeList, storeDelete, storeSetMode, storeSetEffort, storeTouch;
import sessionmode : SessionMode, parseSessionMode, nameOf, letterOf;
import core.stdc.stdio : stdin, stdout, stderr, fputs, fwrite, fflush, ferror, FILE;
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.prompt;
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
    bool settingsEffort; // a new session starts at the effort Claude Code's settings name
    ParsedQntx node; // the node a prompt goes through: its gateway, its token file, its model
    long clock;      // the time, when one is given; otherwise the system's
}

// A unix time as ISO 8601 in UTC, to the second: 2026-10-23T18:55:33Z. Days
// to a civil date by arithmetic alone, so it runs where gmtime cannot.
void putIso(ref Reply r, long t) {
    long days = t / 86400, secs = t % 86400;
    if (secs < 0) { secs += 86400; days--; }
    long z = days + 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    long d = doy - (153 * mp + 2) / 5 + 1;
    long m = mp < 10 ? mp + 3 : mp - 9;
    long y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    void two(long v) { char[2] b = [cast(char)('0' + v / 10 % 10), cast(char)('0' + v % 10)]; r.add(b[]); }
    two(y / 100); two(y % 100); r.add("-"); two(m); r.add("-"); two(d);
    r.add("T"); two(secs / 3600); r.add(":"); two(secs / 60 % 60); r.add(":"); two(secs % 60); r.add("Z");
}

string isoUtc()(long t) {
    Reply r;
    putIso(r, t);
    return r.slice().idup;
}

// The effort levels effort.d names, lowest first: the one config option a
// session offers, as a thought_level select.
private immutable string[5] efforts = ["low", "medium", "high", "xhigh", "max"];
private immutable string[5] effortNames = ["Low", "Medium", "High", "Extra high", "Max"];
private enum MEDIUM = 1;

// Where a level stands among the five, or efforts.length for one ground does
// not know.
private size_t effortAt(const(char)[] level) {
    foreach (i, e; efforts) if (e == level) return i;
    return efforts.length;
}

// The effort a new session starts at: the effortLevel Claude Code's settings
// name, when it is one of the five; medium with none, or one ground does not
// know.
string effortDefault()(const(char)[] settings) {
    import effort : effortIn;
    auto at = effortAt(effortIn(settings));
    return efforts[at < efforts.length ? at : MEDIUM];
}

// The configOptions a session answers with: effort, at the level it is at.
private void putConfig(ref Reply r, size_t effort) {
    r.add(`[{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"`);
    r.add(efforts[effort]); r.add(`","options":[`);
    foreach (i, e; efforts) {
        if (i > 0) r.add(",");
        r.add(`{"value":"`); r.add(e); r.add(`","name":"`); r.add(effortNames[i]); r.add(`"}`);
    }
    r.add("]}]");
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
    size_t effort; // where it stands among efforts
    long updatedAt; // its last activity, unix seconds
    char[2048] dirs; // the JSON array a client is answered with
    size_t dirsLen;
    Reply* history; // the turns so far, as the model's messages; none until the first prompt
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

private void forget(ref Open o) {
    if (o.history !is null) { o.history.dispose(); free(o.history); o.history = null; }
}

// A session/update to the client, written as it happens: a turn's steps are
// not held until the turn ends.
private bool notify(const(char)[] sid, const(char)[] update) {
    Reply n;
    scope(exit) n.dispose();
    n.add(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"`); putEscaped(n, sid);
    n.add(`","update":`); n.add(update); n.add(`}}` ~ "\n");
    if (n.full) return false;
    auto s = n.slice();
    return fwrite(s.ptr, 1, s.length, stdout) == s.length && fflush(stdout) == 0;
}

// The gateway's answer, kept whole: a completion that did not fit is not the
// answer, and the far end's words on a refusal are the error's data.
enum GATEWAY_BODY = 4 << 20;

// "like, longer turns"
// "assume you always run it with a strong model"
// A turn ends when the model answers in words; ground code counts no rounds.
enum GATEWAY_SECONDS = 600;

private void putSessionId(ref Reply r, ref const Sessions s, uint n) {
    r.add("code-"); putNumber(r, s.started); r.add("-"); putNumber(r, s.pid); r.add("-"); putNumber(r, n);
}

private void keep(ref Open o, const(char)[] id, const(char)[] cwd, SessionMode mode, const(char)[] dirs, size_t effort) {
    foreach (i, c; id) o.id[i] = c; // a slice copy calls druntime
    o.idLen = id.length;
    foreach (i, c; cwd) o.cwd[i] = c;
    o.cwdLen = cwd.length;
    o.mode = mode;
    o.effort = effort;
    foreach (i, c; dirs) o.dirs[i] = c;
    o.dirsLen = dirs.length;
}

private long now(ref const Sessions s) {
    import core.stdc.time : time;
    if (s.clock != 0 || __ctfe) return s.clock;
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
        size_t effort = MEDIUM;
        if (sessions.settingsEffort && !__ctfe) {
            import effort : settingsInto;
            __gshared char[65536] settings;
            effort = effortAt(effortDefault(settings[0 .. settingsInto(settings[])]));
        }
        if (sessions.db !is null && !storeOpen(sessions.db, sid.slice(), cwd, dirs.slice(), efforts[effort], now(sessions))) {
            Reply detail;
            scope(exit) detail.dispose();
            if (!__ctfe) closeMcp(o.mcp, detail);
            put(`,"error":{"code":-32603,"message":"the store refused the session ground code opened"}}`);
            return true;
        }
        keep(*o, sid.slice(), cwd, SessionMode.manual, dirs.slice(), effort);
        o.updatedAt = now(sessions);
        sessions.openLen++;
        put(`,"result":{"sessionId":"`); put(sid.slice());
        put(`","modes":`); putModes(r, SessionMode.manual);
        put(`,"configOptions":`); putConfig(r, effort); put(`}}`);
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
        if (sessions.db !is null && !storeClose(sessions.db, sid, now(sessions))) {
            put(`,"error":{"code":-32603,"message":"the store refused to close `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        bool closed = true;
        Reply detail;
        if (!__ctfe) closed = closeMcp(sessions.open[cast(size_t) at].mcp, detail);
        scope(exit) detail.dispose();
        forget(sessions.open[cast(size_t) at]);
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
        // updatedAt is "ISO 8601 timestamp of last activity".
        void entry(const(char)[] sid, const(char)[] at, const(char)[] dirs, long updatedAt) {
            if (!first) put(",");
            first = false;
            put(`{"sessionId":"`); putEscaped(r, sid);
            put(`","cwd":"`); putEscaped(r, at); put(`"`);
            if (dirs != "[]") { put(`,"additionalDirectories":`); put(dirs); }
            put(`,"updatedAt":"`); putIso(r, updatedAt); put(`"}`);
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
                if (cwd is null || at == cwd) entry(o.id[0 .. o.idLen], at, o.dirs[0 .. o.dirsLen], o.updatedAt);
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
        size_t effort = at < 0 ? MEDIUM : sessions.open[cast(size_t) at].effort;
        char[16] level;
        size_t levelLen = 0;
        char[1024] was;
        size_t wasLen = 0;
        int stored;
        if (sessions.db !is null) {
            stored = storeResume(sessions.db, sid, cwd, dirs.slice(), mode, was[], wasLen, level[], levelLen, now(sessions));
            effort = effortAt(level[0 .. levelLen]);
            if (stored == 1 && effort == efforts.length) stored = -1;
        }
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
        keep(sessions.open[cast(size_t) at], sid, cwd, mode, dirs.slice(), effort);
        sessions.open[cast(size_t) at].updatedAt = now(sessions);
        put(`,"result":{"modes":`); putModes(r, mode);
        put(`,"configOptions":`); putConfig(r, effort); put(`}}`);
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
            auto kept = storeSetMode(sessions.db, sid, mode, now(sessions));
            if (kept != 1) {
                put(`,"error":{"code":-32603,"message":"the store refused the mode of `);
                putEscaped(r, sid); put(`"}}`);
                return true;
            }
        }
        sessions.open[cast(size_t) at].mode = mode;
        sessions.open[cast(size_t) at].updatedAt = now(sessions);
        put(`,"result":{}}`);
        return true;
    }

    // Effort is the one option a session offers, a select over the five
    // levels. Set, it is kept with the session, and the answer is "The full
    // set of configuration options and their current values".
    if (method == "session/set_config_option") {
        char[256] sb;
        char[64] cb;
        char[64] vb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        auto config = extractJsonString(line, `"configId"`, &cb[0], cb.length);
        auto value = extractJsonString(line, `"value"`, &vb[0], vb.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/set_config_option needs sessionId"}}`); return true; }
        if (config is null) { put(`,"error":{"code":-32602,"message":"session/set_config_option needs configId"}}`); return true; }
        if (value is null) {
            put(`,"error":{"code":-32602,"message":"session/set_config_option needs a value: effort is a select, not a boolean"}}`);
            return true;
        }
        auto at = openAt(sessions, sid);
        if (at < 0) {
            put(`,"error":{"code":-32002,"message":"no open session `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        if (config != "effort") {
            put(`,"error":{"code":-32602,"message":"no config option `); putEscaped(r, config);
            put(`; a session offers effort"}}`);
            return true;
        }
        auto effort = effortAt(value);
        if (effort == efforts.length) {
            put(`,"error":{"code":-32602,"message":"no effort `); putEscaped(r, value);
            put(`; effort is low, medium, high, xhigh or max"}}`);
            return true;
        }
        if (sessions.db !is null && storeSetEffort(sessions.db, sid, efforts[effort], now(sessions)) != 1) {
            put(`,"error":{"code":-32603,"message":"the store refused the effort of `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        sessions.open[cast(size_t) at].effort = effort;
        sessions.open[cast(size_t) at].updatedAt = now(sessions);
        put(`,"result":{"configOptions":`); putConfig(r, effort); put(`}}`);
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
            forget(sessions.open[cast(size_t) at]);
            sessions.openLen--;
            sessions.open[cast(size_t) at] = sessions.open[sessions.openLen];
            sessions.open[sessions.openLen] = Open.init;
        }
        if (ended) put(`,"result":{}}`);
        else { put(`,"error":{"code":-32603,"message":"session MCP shutdown failed","data":`); put(detail.slice()); put(`}}`); }
        return true;
    }

    // "we use the qntx openrouter plugin"
    // "as the endpoint"
    if (method == "session/prompt") {
        auto qntxNode = &sessions.node;
        char[256] sb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"session/prompt needs sessionId"}}`); return true; }
        auto at = openAt(sessions, sid);
        if (at < 0) {
            put(`,"error":{"code":-32002,"message":"no open session `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        // The model is the qntx block's, the token the one every attestation carries.
        if (qntxNode.model.length == 0) {
            put(`,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);
            return true;
        }
        if (qntxNode.url.length == 0) {
            put(`,"error":{"code":-32603,"message":"the qntx block names no url, so ground code has no gateway to prompt"}}`);
            return true;
        }
        if (__ctfe) assert(0, "the gateway is spoken to at runtime");
        else {
            import attest : qntxToken;
            import http : httpPostInto;
            import core.stdc.stdlib : malloc;
            auto o = &sessions.open[cast(size_t) at];
            // A prompt is the session's activity, as it starts.
            if (sessions.db !is null && storeTouch(sessions.db, sid, now(sessions)) != 1) {
                put(`,"error":{"code":-32603,"message":"the store refused the activity of `);
                putEscaped(r, sid); put(`"}}`);
                return true;
            }
            o.updatedAt = now(sessions);
            if (o.history is null) {
                o.history = cast(Reply*) malloc(Reply.sizeof);
                if (o.history is null) { put(`,"error":{"code":-32603,"message":"could not allocate the session's history"}}`); return true; }
                *o.history = Reply.init;
            }
            Reply text, tools, detail, url;
            scope(exit) { text.dispose(); tools.dispose(); detail.dispose(); url.dispose(); }
            promptText(line, text);
            userMessage(*o.history, text.slice());
            if (!toolsOf(o.mcp, tools, detail)) {
                put(`,"error":{"code":-32603,"message":"a session tool would not read","data":`); put(detail.slice()); put(`}}`);
                return true;
            }
            url.add(qntxNode.gateway.length > 0 ? qntxNode.gateway : qntxNode.url); url.add(GATEWAY_PATH);
            auto token = qntxToken(qntxNode.token);
            auto dest = cast(char*) malloc(GATEWAY_BODY);
            if (dest is null) { put(`,"error":{"code":-32603,"message":"could not allocate the gateway's answer"}}`); return true; }
            scope(exit) free(dest);
            // The history and the tools go to the gateway; a tool_calls answer is
            // run through the session's own MCP server and handed back, until the
            // model answers in words.
            while (true) {
                Reply body_;
                scope(exit) body_.dispose();
                requestBody(body_, qntxNode.model, o.history.slice(), tools.slice());
                if (o.history.full || body_.full) { put(`,"error":{"code":-32603,"message":"the session's history outgrew memory"}}`); return true; }
                auto http = httpPostInto(url.slice(), body_.slice(), token, dest[0 .. GATEWAY_BODY], GATEWAY_SECONDS);
                if (http.code != 0 || http.overran || http.status != 200) {
                    put(`,"error":{"code":-32603,"message":"the gateway did not answer the prompt","data":{"url":"`);
                    putEscaped(r, url.slice());
                    put(`","status":`); putNumber(r, cast(uint) http.status);
                    put(`,"curl":`); putNumber(r, cast(uint) http.code);
                    put(`,"why":"`); putEscaped(r, http.why());
                    put(`","body":"`); putEscaped(r, dest[0 .. http.len]); put(`"}}}`);
                    return true;
                }
                Completion c;
                scope(exit) c.dispose();
                if (!completionOf(dest[0 .. http.len], c)) {
                    put(`,"error":{"code":-32603,"message":"the gateway's answer is not a completion","data":"`);
                    putEscaped(r, dest[0 .. http.len]); put(`"}}`);
                    return true;
                }
                assistantMessage(*o.history, c.message);
                if (c.content.length > 0) {
                    Reply u;
                    scope(exit) u.dispose();
                    u.add(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"`);
                    putEscaped(u, c.content); u.add(`"}}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                if (c.callCount == 0) { put(`,"result":{"stopReason":"end_turn"}}`); return true; }
                foreach (i; 0 .. c.callCount) {
                    auto call = c.calls[i];
                    Reply u, server, tool, args, result;
                    scope(exit) { u.dispose(); server.dispose(); tool.dispose(); args.dispose(); result.dispose(); }
                    u.add(`{"sessionUpdate":"tool_call","toolCallId":"`); putEscaped(u, call.id);
                    u.add(`","title":"`); putEscaped(u, call.name);
                    u.add(`","status":"in_progress","rawInput":`); u.add(call.arguments); u.add(`}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                    server.add(serverOf(call.name)); server.add("\0");
                    tool.add(toolOf(call.name)); tool.add("\0");
                    args.add(call.arguments); args.add("\0");
                    import libmcp : mcp_response, mcp_error, mcp_status, mcp_response_free, mcp_status_string;
                    import core.stdc.string : strlen;
                    mcp_response response;
                    mcp_error error;
                    scope(exit) mcp_response_free(&response);
                    auto status = callMcpTool(o.mcp, server.slice().ptr, tool.slice().ptr, args.slice().ptr, response, error);
                    bool ok = status == mcp_status.MCP_OK;
                    if (ok) result.add(response.json[0 .. response.length]);
                    else {
                        result.add(`{"status":"`); result.add(mcp_status_string(status)[0 .. strlen(mcp_status_string(status))]);
                        result.add(`","message":"`); if (error.message !is null) putEscaped(result, error.message[0 .. strlen(error.message)]);
                        result.add(`","response":"`); if (response.json !is null) putEscaped(result, response.json[0 .. response.length]);
                        result.add(`"}`);
                    }
                    toolMessage(*o.history, call.id, result.slice());
                    u.len = 0;
                    u.add(`{"sessionUpdate":"tool_call_update","toolCallId":"`); putEscaped(u, call.id);
                    u.add(ok ? `","status":"completed","rawOutput":` : `","status":"failed","rawOutput":`); u.add(result.slice()); u.add(`}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
            }
        }
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
    import controls : qntxNode;
    auto sessions = Sessions(cast(ulong) time(null), cast(uint) getpid());
    sessions.settingsEffort = true;
    sessions.node = qntxNode;
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
        forget(sessions.open[i]);
    }
    sessions.openLen = 0;
    return result;
}
