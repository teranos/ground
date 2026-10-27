module code.acp;

// Ground code: the agent ground runs itself, behind an ACP client. One
// JSON-RPC message a line on stdin, one answer a line on stdout. The protocol
// is the schema flake.nix pins, and `ground_parity` counts what each method's
// block here reads and writes against it.

enum BOOK_COMMAND = q"EOS
# an ACP client runs it and speaks JSON-RPC on its stdin and stdout:
ground_code
EOS";

import parse : extractJsonString, extractBool;
import matcher : indexOf;
import provenance : jsonEscapeInto;
import db : versionString, sqlite3;
import proto : ParsedQntx;
import code.store : storeAddCost, storeOpen, storeClose, storeResume, storeList, storeDelete, storeSetMode, storeSetEffort, storeTouch, storeTitle,
    storeHistory, storeHistoryOf;
import sessionmode : SessionMode, parseSessionMode, nameOf, letterOf;
import core.stdc.stdio : stdout, stderr, fputs, fwrite, fflush;
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.prompt;
public import code.reply : Reply, putEscaped, putNumber;
public import code.input : Input, nextLine, take, more;

extern (C) void free(void* p);
extern (C) int getpid();

// The value at a key as it stands in the line: a number, a quoted string with
// its quotes, or null. An id is echoed, never interpreted.
// The object a key names, braces and all, however it is spaced; null when
// the key is absent or names no object.
const(char)[] objectValue(const(char)[] json, const(char)[] key) {
    auto at = indexOf(json, key);
    if (at < 0) return null;
    size_t p = cast(size_t) at + key.length;
    while (p < json.length && (json[p] == ' ' || json[p] == '\t' || json[p] == '\n' || json[p] == '\r')) p++;
    if (p >= json.length || json[p] != ':') return null;
    p++;
    while (p < json.length && (json[p] == ' ' || json[p] == '\t' || json[p] == '\n' || json[p] == '\r')) p++;
    if (p >= json.length || json[p] != '{') return null;
    return json[p .. skipValue(json, p)];
}

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
    uint asked;      // the questions ground code has asked the client, for the next one's id
    bool clientReadsFiles; // initialize said the client answers fs/read_text_file
    bool clientTakesNotices; // initialize said the client presents notice session updates
    bool elicitsForms, elicitsUrls; // initialize said the client answers elicitation/create in these modes
    ulong contextSize; // the model's context window in tokens, from the gateway's models list; 0 until asked
    Input* input;    // what the client has sent and ground code has not read; a turn looks at it
}

// The turn under way: whose it is, the request that asked for it, and whether
// the client has called it off.
private struct Turn {
    Input* input;
    const(char)[] sid;
    const(char)[] id;
    bool cancelled;
}

// session/cancel for this turn's session, or $/cancel_request naming the
// request that asked for it.
private bool cancels(const(char)[] line, const(char)[] sid, const(char)[] id) {
    char[64] mb;
    auto method = extractJsonString(line, `"method"`, &mb[0], mb.length);
    if (method == "$/cancel_request") return rawValue(line, `"requestId"`) == id;
    if (method != "session/cancel") return false;
    char[256] sb;
    return extractJsonString(line, `"sessionId"`, &sb[0], sb.length) == sid;
}

// Whether the client has called the turn off, taking the line that did.
private bool cancelAsked(ref Turn t) {
    if (t.cancelled || t.input is null) return t.cancelled;
    bool mine(const(char)[] line) { return cancels(line, t.sid, t.id); }
    t.cancelled = take(*t.input, &mine);
    return t.cancelled;
}

// Whether name is a line of names.
private bool listed(const(char)[] names, const(char)[] name) {
    size_t start = 0;
    foreach (i, c; names) {
        if (c != '\n') continue;
        if (names[start .. i] == name) return true;
        start = i + 1;
    }
    return false;
}

// What a session's mode makes of a call its turn asks for. Manual asks the
// client; acceptEdits and auto have no meaning of their own for ground code,
// which has no edit tools and no classifier, so they ask as Manual does.
private enum Verdict { run, ask, refuse }
private Verdict verdictOf(ref Open o, const(char)[] tool, bool readOnly, ref const(char)[] why) {
    final switch (o.mode) {
        case SessionMode.bypassPermissions: return Verdict.run;
        case SessionMode.plan:
            why = "plan mode runs only tools whose MCP annotations say readOnlyHint";
            return readOnly ? Verdict.run : Verdict.refuse;
        case SessionMode.dontAsk:
            why = "dontAsk mode runs only what is approved ahead, and nothing is";
            return Verdict.refuse;
        case SessionMode.manual:
        case SessionMode.acceptEdits:
        case SessionMode.auto_:
        case SessionMode.unknown:
            if (listed(o.always.slice(), tool)) return Verdict.run;
            why = "the user rejected it";
            if (listed(o.never.slice(), tool)) return Verdict.refuse;
            return Verdict.ask;
    }
}

// The client's answer to the request ground code sent it as pid, into
// answered, the turn waiting on it and still on a cancel: 1 answered, 2 the
// turn was called off, -1 the client's input ended first.
private int awaitAnswer(ref Turn turn, const(char)[] pid, ref Reply answered) {
    bool calledOff = false;
    bool mine(const(char)[] line) {
        if (cancels(line, turn.sid, turn.id)) { calledOff = true; return true; }
        char[64] mb;
        if (extractJsonString(line, `"method"`, &mb[0], mb.length) !is null) return false;
        if (rawValue(line, `"id"`) != pid) return false;
        answered.add(line);
        return true;
    }
    while (!take(*turn.input, &mine)) {
        if (!more(*turn.input)) return -1;
    }
    if (calledOff) { turn.cancelled = true; return 2; }
    return 1;
}

// "Request to read content from a text file", asked of the client for path.
// 1 and the file's text in content; 2 the turn was called off; -1 no text,
// why the reason, the client's own answer when it gave one.
private int readThroughClient(ref Sessions sessions, ref Turn turn, const(char)[] sid,
        const(char)[] path, ref Reply content, ref Reply why) {
    if (turn.input is null) { why.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    sessions.asked++;
    Reply pid;
    scope(exit) pid.dispose();
    pid.add(`"read-`); putNumber(pid, sessions.asked); pid.add(`"`);
    Reply n;
    scope(exit) n.dispose();
    n.add(`{"jsonrpc":"2.0","id":`); n.add(pid.slice());
    n.add(`,"method":"fs/read_text_file","params":{"sessionId":"`); putEscaped(n, sid);
    n.add(`","path":"`); putEscaped(n, path); n.add(`"}}` ~ "\n");
    if (n.full) { why.add(`"could not allocate fs/read_text_file"`); return -1; }
    auto out_ = n.slice();
    if (fwrite(out_.ptr, 1, out_.length, stdout) != out_.length || fflush(stdout) != 0) {
        why.add(`"could not write fs/read_text_file"`);
        return -1;
    }
    Reply answered;
    scope(exit) answered.dispose();
    auto waited = awaitAnswer(turn, pid.slice(), answered);
    if (waited < 0) { why.add(`"the client's input ended while ground code waited on the file"`); return -1; }
    if (waited == 2) return 2;
    if (readTextContent(answered.slice(), content) == 1) return 1;
    why.add(answered.slice());
    return -1;
}

// "Request for user permission to execute a tool call." Asked of the client,
// the turn waiting on its answer, and still on a cancel: 1 allowed, 0
// rejected, 2 the turn was called off, -1 no answer ground code can read,
// said in why. An always is the session's from then on.
private int askPermission(ref Sessions sessions, ref Open o, ref Turn turn, const(char)[] sid,
        const(char)[] callId, const(char)[] tool, const(char)[] arguments, ref Reply why) {
    if (turn.input is null) { why.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    sessions.asked++;
    Reply pid;
    scope(exit) pid.dispose();
    pid.add(`"perm-`); putNumber(pid, sessions.asked); pid.add(`"`);
    Reply n;
    scope(exit) n.dispose();
    n.add(`{"jsonrpc":"2.0","id":`); n.add(pid.slice());
    n.add(`,"method":"session/request_permission","params":{"sessionId":"`); putEscaped(n, sid);
    n.add(`","toolCall":{"toolCallId":"`); putEscaped(n, callId);
    n.add(`","title":"`); putEscaped(n, tool);
    n.add(`","name":"`); putEscaped(n, tool);
    if (readOnlyTool(o.mcp, tool)) n.add(`","kind":"read`);
    n.add(`","status":"pending","rawInput":`); n.add(arguments);
    n.add(`},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},`);
    n.add(`{"optionId":"allow_always","name":"Always allow `); putEscaped(n, tool); n.add(`","kind":"allow_always"},`);
    n.add(`{"optionId":"reject_once","name":"Reject once","kind":"reject_once"},`);
    n.add(`{"optionId":"reject_always","name":"Always reject `); putEscaped(n, tool); n.add(`","kind":"reject_always"}]}}` ~ "\n");
    if (n.full) { why.add(`"could not allocate the permission request"`); return -1; }
    auto out_ = n.slice();
    if (fwrite(out_.ptr, 1, out_.length, stdout) != out_.length || fflush(stdout) != 0) {
        why.add(`"could not write session/request_permission"`);
        return -1;
    }
    Reply answered;
    scope(exit) answered.dispose();
    auto waited = awaitAnswer(turn, pid.slice(), answered);
    if (waited < 0) { why.add(`"the client's input ended while ground code waited on its permission"`); return -1; }
    if (waited == 2) return 2;
    Reply option;
    scope(exit) option.dispose();
    auto outcome = permissionOutcome(answered.slice(), option);
    if (outcome == 0) { turn.cancelled = true; return 2; }
    auto chosen = option.slice();
    if (outcome == 1 && chosen == "allow_once") return 1;
    if (outcome == 1 && chosen == "allow_always") { o.always.add(tool); o.always.add("\n"); return 1; }
    if (outcome == 1 && chosen == "reject_once") return 0;
    if (outcome == 1 && chosen == "reject_always") { o.never.add(tool); o.never.add("\n"); return 0; }
    why.add(`{"message":"the client's answer to session/request_permission is not one ground code offered","answer":"`);
    putEscaped(why, answered.slice()); why.add(`"}`);
    return -1;
}

// What a session's MCP servers are told they may ask, as MCP's client
// capabilities: the elicitation the client offers, and nothing when it offers none.
private const(char)* serverAsks(ref const Sessions sessions) {
    if (sessions.elicitsForms && sessions.elicitsUrls) return `{"elicitation":{"form":{},"url":{}}}`;
    if (sessions.elicitsForms) return `{"elicitation":{"form":{}}}`;
    if (sessions.elicitsUrls) return `{"elicitation":{"url":{}}}`;
    return null;
}

// What a session's MCP server asks while the call callId runs, asked of the
// client: "This is useful when an agent receives an elicitation from an MCP
// server during a tool call and needs to redirect it to the user." The
// client's answer is the server's: 1 its result in answer, 0 its error in
// answer, 2 the turn was called off, -1 it could not be asked, why in answer.
// A url elicitation's completion is passed on to the client as it comes.
private int elicit(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] callId,
        const(char)[] method, const(char)[] params, ref Reply answer) {
    if (method == "notifications/elicitation/complete") {
        // "Notification sent by the agent when a URL-based elicitation is complete."
        Reply n;
        scope(exit) n.dispose();
        n.add(`{"jsonrpc":"2.0","method":"elicitation/complete","params":`); n.add(params); n.add("}\n");
        auto out_ = n.slice();
        if (!n.full && fwrite(out_.ptr, 1, out_.length, stdout) == out_.length && fflush(stdout) == 0) return 1;
        fputs("ground code: could not write elicitation/complete\n", stderr);
        return -1;
    }
    if (method != "elicitation/create") {
        answer.add(`{"code":-32601,"message":"ground code answers a server's elicitation/create, and nothing else it asks"}`);
        return 0;
    }
    Reply asked;
    scope(exit) asked.dispose();
    auto mode = elicitationParams(params, sid, callId, asked);
    if (mode < 0) { answer.add(`"the server's elicitation/create names no object to ask"`); return -1; }
    if ((mode == 1 && !sessions.elicitsForms) || (mode == 2 && !sessions.elicitsUrls) || mode == 0) {
        answer.add(`{"code":-32602,"message":"the client offers no elicitation in the mode the server asked"}`);
        return 0;
    }
    if (turn.input is null) { answer.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    sessions.asked++;
    Reply pid;
    scope(exit) pid.dispose();
    pid.add(`"elicit-`); putNumber(pid, sessions.asked); pid.add(`"`);
    Reply n;
    scope(exit) n.dispose();
    n.add(`{"jsonrpc":"2.0","id":`); n.add(pid.slice());
    n.add(`,"method":"elicitation/create","params":`); n.add(asked.slice()); n.add("}\n");
    if (n.full || asked.full) { answer.add(`"could not allocate elicitation/create"`); return -1; }
    auto out_ = n.slice();
    if (fwrite(out_.ptr, 1, out_.length, stdout) != out_.length || fflush(stdout) != 0) {
        answer.add(`"could not write elicitation/create"`);
        return -1;
    }
    Reply answered;
    scope(exit) answered.dispose();
    auto waited = awaitAnswer(turn, pid.slice(), answered);
    if (waited < 0) { answer.add(`"the client's input ended while ground code waited on its elicitation"`); return -1; }
    if (waited == 2) return 2;
    auto result = objectValue(answered.slice(), `"result"`);
    if (result !is null) { answer.add(result); return 1; }
    auto error = objectValue(answered.slice(), `"error"`);
    if (error !is null) { answer.add(error); return 0; }
    answer.add(`"the client's answer to elicitation/create is neither a result nor an error: `);
    putEscaped(answer, answered.slice()); answer.add(`"`);
    return -1;
}

// What the user should know of a session, as it happens: "Fire-and-forget
// information for the user", a notice, when the client "advertised
// ClientSessionCapabilities::notices. Otherwise, Agents may use an agent
// message when the information should still be surfaced to the user." stderr
// has it too. false when it could not be written.
private bool tellUser(ref Sessions sessions, const(char)[] sid, const(char)[] severity,
        const(char)[] title, const(char)[] description) {
    if (!__ctfe) {
        fputs("ground code: ", stderr); fwrite(title.ptr, 1, title.length, stderr);
        fputs(": ", stderr); fwrite(description.ptr, 1, description.length, stderr); fputs("\n", stderr);
    }
    Reply u;
    scope(exit) u.dispose();
    if (sessions.clientTakesNotices) {
        u.add(`{"sessionUpdate":"notice","severity":"`); u.add(severity);
        u.add(`","title":"`); putEscaped(u, title);
        u.add(`","description":"`); putEscaped(u, description); u.add(`"}`);
    } else {
        u.add(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"`);
        putEscaped(u, title); u.add(": "); putEscaped(u, description); u.add(`\n"}}`);
    }
    return notify(sid, u.slice());
}

// A notification ground code does not handle: said on stderr, and to the
// session it names when that one is open here.
void unhandled(const(char)[] line, ref Sessions sessions) {
    char[256] mb, sb;
    auto method = extractJsonString(line, `"method"`, &mb[0], mb.length);
    auto params = objectValue(line, `"params"`);
    auto sid = params is null ? null : extractJsonString(params, `"sessionId"`, &sb[0], sb.length);
    if (sid !is null && method !is null && openAt(sessions, sid) >= 0) {
        Reply title;
        scope(exit) title.dispose();
        title.add("ground code does not handle "); title.add(method);
        tellUser(sessions, sid, "warning", title.slice(), line);
        return;
    }
    fputs("ground code: a notification it does not handle: ", stderr);
    fwrite(line.ptr, 1, line.length, stderr);
    fputs("\n", stderr);
}

// libcurl asks this while the gateway is answering: a cancel cuts the request off.
private extern (C) int stopIfCancelled(void* turn, long, long, long, long) {
    return cancelAsked(*cast(Turn*) turn) ? 1 : 0;
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

// The configOptions a session answers with: its mode, then its effort.
// "Agents that provide mode-like configuration SHOULD send both": configOptions
// with a category mode option, and modes, kept in sync by being one value.
// "Agents SHOULD place higher-priority options first in the list."
private void putConfig(ref Reply r, SessionMode mode, size_t effort) {
    r.add(`[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"`);
    r.add(nameOf(mode)); r.add(`","options":[`);
    foreach (i, m; offered) {
        if (i > 0) r.add(",");
        r.add(`{"value":"`); r.add(nameOf(m)); r.add(`","name":"`); r.add(shownAs(m));
        r.add(`","description":"`); putModeDescription(r, m); r.add(`"}`);
    }
    r.add(`]},{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"`);
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
    char[TITLE_BYTES + 4] title; // what the first prompt named it, ellipsis and all
    long costNano;  // what it has cost, when no store keeps it
    size_t titleLen;
    bool titled;    // named, here or by the store, so no later prompt renames it
    Reply always;   // the tools the user said to always allow here, a name a line
    Reply never;    // and to always reject
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
// What a mode is, said the same in modes and in the mode config option.
private void putModeDescription(ref Reply r, SessionMode m) {
    char[1] letter = [letterOf(m)];
    r.add(letter[]); r.add(` in a permission block`);
    // Neither has a meaning of its own for ground code's tool calls yet.
    if (m == SessionMode.acceptEdits || m == SessionMode.auto_) r.add(`; ground code asks, as Manual does`);
}

private void putModes(ref Reply r, SessionMode current) {
    r.add(`{"currentModeId":"`); r.add(nameOf(current)); r.add(`","availableModes":[`);
    foreach (i, m; offered) {
        if (i > 0) r.add(",");
        r.add(`{"id":"`); r.add(nameOf(m)); r.add(`","name":"`); r.add(shownAs(m));
        r.add(`","description":"`); putModeDescription(r, m); r.add(`"}`);
    }
    r.add("]}");
}

private void forget(ref Open o) {
    if (o.history !is null) { o.history.dispose(); free(o.history); o.history = null; }
    o.always.dispose(); o.never.dispose();
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
// How long the gateway's models list may take: a list, not a model's answer.
enum MODELS_SECONDS = 30;

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

    // An answer to a question ground code asked and stopped waiting on, as a
    // turn called off while asking leaves: no request, so no answer to give.
    if (method is null && (rawValue(line, `"result"`) !is null || rawValue(line, `"error"`) !is null)) {
        if (!__ctfe) {
            fputs("ground code: an answer to a request no turn is waiting on: ", stderr);
            fwrite(line.ptr, 1, line.length, stderr);
            fputs("\n", stderr);
        }
        return true;
    }
    if (method is null) {
        put(`{"jsonrpc":"2.0","id":`); put(id);
        put(`,"error":{"code":-32600,"message":"no method"}}`);
        return true;
    }

    // ACP's version is 1 for all of v1, and there is no other to offer: the
    // client's is answered with it whatever it asked for.
    if (method == "initialize") {
        // "Whether the Client supports fs/read_text_file requests."
        auto caps = objectValue(line, `"clientCapabilities"`);
        auto fs = caps is null ? null : objectValue(caps, `"fs"`);
        sessions.clientReadsFiles = fs !is null && extractBool(fs, `"readTextFile"`);
        // "Supplying {} means the client can present notices to the user."
        auto session = caps is null ? null : objectValue(caps, `"session"`);
        sessions.clientTakesNotices = session !is null && objectValue(session, `"notices"`) !is null;
        // "Supplying {} explicitly advertises form support", and url's the same.
        auto elicits = caps is null ? null : objectValue(caps, `"elicitation"`);
        sessions.elicitsForms = elicits !is null && objectValue(elicits, `"form"`) !is null;
        sessions.elicitsUrls = elicits !is null && objectValue(elicits, `"url"`) !is null;
        put(`{"jsonrpc":"2.0","id":`); put(id);
        put(`,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}},"mcpCapabilities":{"http":true}},"authMethods":[],"agentInfo":{"name":"ground","version":"`);
        put(versionString()); put(`"}}}`);
        return true;
    }

    // "Clients MAY cancel an ongoing prompt turn at any time by sending a
    // session/cancel notification". A turn takes its own cancel while it runs;
    // one read here found no turn running, and has nothing to stop. A
    // notification is answered with nothing, so it is said on stderr.
    if (method == "session/cancel") {
        char[256] sb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        if (!__ctfe) {
            fputs("ground code: session/cancel for ", stderr);
            if (sid is null) fputs("no sessionId", stderr); else fwrite(sid.ptr, 1, sid.length, stderr);
            fputs(", with no turn running\n", stderr);
        }
        return true;
    }
    // "Notification to cancel an ongoing request." Every request but a turn is
    // answered before the next line is read, so only a turn's can be ongoing.
    if (method == "$/cancel_request") {
        auto rid = rawValue(line, `"requestId"`);
        if (!__ctfe) {
            fputs("ground code: $/cancel_request for ", stderr);
            if (rid is null) fputs("no requestId", stderr); else fwrite(rid.ptr, 1, rid.length, stderr);
            fputs(", which no turn is answering\n", stderr);
        }
        return true;
    }

    // "Must be one of the methods advertised in the initialize response."
    // initialize advertises none: the model is reached through the QNTX node,
    // whose credentials ground code never holds.
    if (method == "authenticate") {
        char[256] ab;
        auto mid = extractJsonString(line, `"methodId"`, &ab[0], ab.length);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (mid is null) { put(`,"error":{"code":-32602,"message":"authenticate needs methodId"}}`); return true; }
        put(`,"error":{"code":-32602,"message":"ground code advertises no auth methods, and authenticate named `);
        putEscaped(r, mid); put(`"}}`);
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
            if (!openMcp(line, cwd, o.mcp, detail, serverAsks(sessions))) {
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
        put(`,"configOptions":`); putConfig(r, SessionMode.manual, effort); put(`}}`);
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
        // title: "Human-readable title for the session. May be auto-generated
        // from the first prompt." One not named yet lists none.
        void entry(const(char)[] sid, const(char)[] at, const(char)[] dirs, const(char)[] title, long updatedAt) {
            if (!first) put(",");
            first = false;
            put(`{"sessionId":"`); putEscaped(r, sid);
            put(`","cwd":"`); putEscaped(r, at); put(`"`);
            if (dirs != "[]") { put(`,"additionalDirectories":`); put(dirs); }
            if (title.length > 0) { put(`,"title":"`); putEscaped(r, title); put(`"`); }
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
                if (cwd is null || at == cwd) entry(o.id[0 .. o.idLen], at, o.dirs[0 .. o.dirsLen], o.title[0 .. o.titleLen], o.updatedAt);
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
    // session/load is session/resume that also tells the conversation back:
    // "Unlike session/load, the Agent MUST NOT replay the conversation history
    // via session/update notifications before responding."
    if (method == "session/resume" || method == "session/load") {
        bool load = method == "session/load";
        auto verb = load ? "load" : "resume";
        char[256] sb;
        char[4096] cb;
        auto sid = extractJsonString(line, `"sessionId"`, &sb[0], sb.length);
        auto cwd = extractJsonString(line, `"cwd"`, &cb[0], cb.length);
        auto mcp = emptyArray(line, `"mcpServers"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (sid is null) { put(`,"error":{"code":-32602,"message":"`); put(method); put(` needs sessionId"}}`); return true; }
        if (cwd is null) { put(`,"error":{"code":-32602,"message":"`); put(method); put(` needs cwd"}}`); return true; }
        if (cwd[0] != '/') {
            put(`,"error":{"code":-32602,"message":"cwd must be an absolute path: `);
            putEscaped(r, cwd); put(`"}}`);
            return true;
        }
        if (load && mcp < 0) { put(`,"error":{"code":-32602,"message":"session/load needs mcpServers"}}`); return true; }
        if (cwd.length > sessions.open[0].cwd.length) {
            put(`,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);
            return true;
        }
        Reply dirs, bad;
        scope(exit) { dirs.dispose(); bad.dispose(); }
        if (refuseDirs(dirsOf(line, `"additionalDirectories"`, dirs, bad), bad, r, dirs.slice())) return true;
        auto at = openAt(sessions, sid);
        bool live = at >= 0;
        if (at < 0 && sessions.openLen == sessions.open.length) {
            put(`,"error":{"code":-32603,"message":"ground code holds 64 open sessions; close one first"}}`);
            return true;
        }
        // "List of MCP servers to connect to for this session." They are the
        // session's from now on, and they come up once it is found, before its
        // row says it was resumed. None named is none.
        McpGroup fresh;
        Reply setup;
        scope(exit) setup.dispose();
        bool up() {
            if (__ctfe) { if (mcp == 0) assert(0, "MCP processes are tested at runtime"); return true; }
            return mcp != 0 || openMcp(line, cwd, fresh, setup, serverAsks(sessions));
        }
        auto mode = at < 0 ? SessionMode.manual : sessions.open[cast(size_t) at].mode;
        size_t effort = at < 0 ? MEDIUM : sessions.open[cast(size_t) at].effort;
        char[16] level;
        size_t levelLen = 0;
        char[1024] was;
        size_t wasLen = 0;
        int stored;
        if (sessions.db !is null) {
            stored = storeResume(sessions.db, sid, cwd, dirs.slice(), mode, was[], wasLen, level[], levelLen, now(sessions), &up);
            effort = effortAt(level[0 .. levelLen]);
            if (stored == 1 && effort == efforts.length) stored = -1;
        }
        else if (at < 0) stored = 0;
        else {
            auto o = &sessions.open[cast(size_t) at];
            stored = o.cwd[0 .. o.cwdLen] == cwd ? (up() ? 1 : 3) : 2;
            foreach (c; o.cwd[0 .. o.cwdLen]) was[wasLen++] = c;
        }
        if (stored == 3) {
            put(`,"error":{"code":-32603,"message":"session MCP setup failed","data":`);
            put(setup.slice()); put(`}}`);
            return true;
        }
        // Up, but not resumed: the servers it brought up are not the session's.
        if (stored != 1 && !__ctfe && fresh.count > 0) { Reply d; closeMcp(fresh, d); d.dispose(); }
        if (stored == 2) {
            put(`,"error":{"code":-32602,"message":"`); putEscaped(r, sid);
            put(` is in `); putEscaped(r, was[0 .. wasLen]);
            put(`, not `); putEscaped(r, cwd); put(`"}}`);
            return true;
        }
        if (stored < 0) {
            put(`,"error":{"code":-32603,"message":"the store refused to `); put(verb); put(` `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        if (stored == 0 || sid.length > sessions.open[0].id.length) {
            put(`,"error":{"code":-32002,"message":"no session to `); put(verb); put(`: `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        // "it restores the session context": a session not live here gets its
        // conversation back from the store, so its next turn goes on from it.
        Reply* restored = null;
        if (!live && sessions.db !is null && !__ctfe) {
            import core.stdc.stdlib : malloc;
            restored = cast(Reply*) malloc(Reply.sizeof);
            if (restored is null) { put(`,"error":{"code":-32603,"message":"could not allocate the session's history"}}`); return true; }
            *restored = Reply.init;
            if (storeHistoryOf(sessions.db, sid, *restored) != 1) {
                restored.dispose(); free(restored);
                put(`,"error":{"code":-32603,"message":"the store refused the conversation of `);
                putEscaped(r, sid); put(`"}}`);
                return true;
            }
            if (restored.len == 0) { restored.dispose(); free(restored); restored = null; }
        }
        if (at < 0) {
            at = cast(ptrdiff_t) sessions.openLen;
            sessions.openLen++;
        }
        auto o = &sessions.open[cast(size_t) at];
        // The servers it had end; ending them failing is said, with the
        // session already resumed on its new ones.
        bool ended = true;
        Reply shutdown;
        scope(exit) shutdown.dispose();
        if (!__ctfe && o.mcp.count > 0) ended = closeMcp(o.mcp, shutdown);
        o.mcp = fresh;
        if (!live) o.history = restored;
        keep(*o, sid, cwd, mode, dirs.slice(), effort);
        o.updatedAt = now(sessions);
        if (!ended) {
            put(`,"error":{"code":-32603,"message":"session resumed on its new MCP servers, but its old ones failed to shut down","data":`);
            put(shutdown.slice()); put(`}}`);
            return true;
        }
        // "When all the conversation entries have been streamed to the Client,
        // the Agent MUST respond to the original session/load request."
        if (load && !__ctfe && o.history !is null) {
            bool tell(const(char)[] update) { return notify(sid, update); }
            bool readOnly(const(char)[] tool) { return readOnlyTool(o.mcp, tool); }
            if (!replayHistory(o.history.slice(), &tell, &readOnly)) {
                put(`,"error":{"code":-32603,"message":"could not tell the conversation of `);
                putEscaped(r, sid); put(` back"}}`);
                return true;
            }
        }
        put(`,"result":{"modes":`); putModes(r, mode);
        put(`,"configOptions":`); putConfig(r, mode, effort); put(`}}`);
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
            put(`,"error":{"code":-32602,"message":"session/set_config_option needs a value: mode and effort are selects, not booleans"}}`);
            return true;
        }
        auto at = openAt(sessions, sid);
        if (at < 0) {
            put(`,"error":{"code":-32002,"message":"no open session `);
            putEscaped(r, sid); put(`"}}`);
            return true;
        }
        auto o = &sessions.open[cast(size_t) at];
        // The mode by its config option is the mode set_mode sets: one value,
        // stored once, so modes and configOptions cannot disagree.
        if (config == "mode") {
            auto mode = parseSessionMode(value);
            if (mode == SessionMode.unknown) {
                put(`,"error":{"code":-32602,"message":"no mode `); putEscaped(r, value);
                put(`; a session offers default, plan, acceptEdits, auto, dontAsk and bypassPermissions"}}`);
                return true;
            }
            if (sessions.db !is null && storeSetMode(sessions.db, sid, mode, now(sessions)) != 1) {
                put(`,"error":{"code":-32603,"message":"the store refused the mode of `);
                putEscaped(r, sid); put(`"}}`);
                return true;
            }
            o.mode = mode;
            o.updatedAt = now(sessions);
            put(`,"result":{"configOptions":`); putConfig(r, o.mode, o.effort); put(`}}`);
            return true;
        }
        if (config != "effort") {
            put(`,"error":{"code":-32602,"message":"no config option `); putEscaped(r, config);
            put(`; a session offers mode and effort"}}`);
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
        o.effort = effort;
        o.updatedAt = now(sessions);
        put(`,"result":{"configOptions":`); putConfig(r, o.mode, effort); put(`}}`);
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
        // "the Agent MUST support ContentBlock::Text and ContentBlock::ResourceLink"
        // ground code reads text only: a block it cannot read is refused by its
        // type, not dropped from what the model is told.
        Reply text, other, links;
        scope(exit) { text.dispose(); other.dispose(); links.dispose(); }
        if (!promptText(line, text, other, links)) {
            put(`,"error":{"code":-32602,"message":"ground code reads only text blocks and resource links, and the prompt holds a block `);
            if (other.len == 0) put(`that names no type"}}`);
            else { put(`of type `); putEscaped(r, other.slice()); put(`"}}`); }
            return true;
        }
        // A resource_link is read through the client, "Only available if the
        // client supports the fs.readTextFile capability", and only one on this
        // machine has the "Absolute path" that asks for.
        if (links.len > 0 && !sessions.clientReadsFiles) {
            put(`,"error":{"code":-32602,"message":"ground code reads a resource_link through the client's fs/read_text_file, and the client offers none"}}`);
            return true;
        }
        for (size_t at_ = 0, field = 0, from = 0; at_ < links.len; at_++) {
            if (links.slice()[at_] != '\0') continue;
            if (field++ % 2 == 1) {
                auto uri = links.slice()[from .. at_];
                Reply path;
                scope(exit) path.dispose();
                if (!fileUriPath(uri, path)) {
                    put(`,"error":{"code":-32602,"message":"ground code reads only file:// resource links on this machine, and the prompt links `);
                    putEscaped(r, uri); put(`"}}`);
                    return true;
                }
            }
            from = at_ + 1;
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
            // The conversation is the store's as the turn ends, however it
            // ends; a store that refuses it makes the turn's answer an error
            // carrying the answer it would have been.
            scope(exit) if (sessions.db !is null && storeHistory(sessions.db, sid, o.history.slice()) != 1) {
                Reply would;
                would.add(r.slice());
                r.len = 0;
                put(`{"jsonrpc":"2.0","id":`); put(id);
                put(`,"error":{"code":-32603,"message":"the store refused the conversation of `); putEscaped(r, sid);
                put(`","data":`); put(would.slice()); put(`}}`);
                would.dispose();
            }
            Reply tools, detail, url;
            scope(exit) { tools.dispose(); detail.dispose(); url.dispose(); }
            Turn turn = Turn(sessions.input, sid, id);
            // "the Agent MUST respond to the original session/prompt request
            // with the cancelled stop reason"; the history keeps what happened.
            void stopCancelled() { put(`,"result":{"stopReason":"cancelled"}}`); }
            // "Agents typically send this notification after the first meaningful
            // exchange to auto-generate a title": the first prompt that types
            // something names the session, in the store and to the client.
            if (!o.titled) {
                Reply title;
                scope(exit) title.dispose();
                titleOf(text.slice(), title);
                if (title.len > 0) {
                    auto named = sessions.db is null ? 1 : storeTitle(sessions.db, sid, title.slice());
                    if (named < 0) {
                        put(`,"error":{"code":-32603,"message":"the store refused the title of `);
                        putEscaped(r, sid); put(`"}}`);
                        return true;
                    }
                    o.titled = true;
                    if (named == 1) {
                        o.titleLen = 0;
                        foreach (c; title.slice()) if (o.titleLen < o.title.length) o.title[o.titleLen++] = c;
                        Reply u;
                        scope(exit) u.dispose();
                        u.add(`{"sessionUpdate":"session_info_update","title":"`); putEscaped(u, title.slice()); u.add(`"}`);
                        if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                    }
                }
            }
            // Each linked file is read before the model is asked, and its text
            // is the user's, after what they typed, under the link's name.
            for (size_t at_ = 0, from = 0, field = 0, nameFrom = 0, nameTo = 0; at_ < links.len; at_++) {
                if (links.slice()[at_] != '\0') continue;
                if (field++ % 2 == 0) { nameFrom = from; nameTo = at_; from = at_ + 1; continue; }
                auto uri = links.slice()[from .. at_];
                from = at_ + 1;
                Reply path, content, why;
                scope(exit) { path.dispose(); content.dispose(); why.dispose(); }
                fileUriPath(uri, path);
                auto got = readThroughClient(sessions, turn, sid, path.slice(), content, why);
                if (got == 2) { stopCancelled(); return true; }
                if (got < 0) {
                    put(`,"error":{"code":-32603,"message":"ground code could not read `); putEscaped(r, uri);
                    put(` through the client","data":`); put(why.slice()); put(`}}`);
                    return true;
                }
                text.add("\n\n"); text.add(links.slice()[nameFrom .. nameTo]);
                text.add(" ("); text.add(uri); text.add("):\n"); text.add(content.slice());
            }
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
            // usage_update's size, "Total context window size in tokens", is
            // the model's context_length in the gateway's models list, asked
            // once a process. A model it does not size is said before the
            // model is asked.
            if (sessions.contextSize == 0) {
                import http : httpGet;
                Reply models;
                scope(exit) models.dispose();
                models.add(qntxNode.gateway.length > 0 ? qntxNode.gateway : qntxNode.url); models.add(MODELS_PATH);
                auto listed = httpGet(models.slice(), token, dest[0 .. GATEWAY_BODY], MODELS_SECONDS);
                if (listed.code != 0 || listed.overran || listed.status != 200) {
                    put(`,"error":{"code":-32603,"message":"the gateway's models list did not answer","data":{"url":"`);
                    putEscaped(r, models.slice());
                    put(`","status":`); putNumber(r, cast(uint) listed.status);
                    put(`,"curl":`); putNumber(r, cast(uint) listed.code);
                    put(`,"why":"`); putEscaped(r, listed.why());
                    put(`","body":"`); putEscaped(r, dest[0 .. listed.len]); put(`"}}}`);
                    return true;
                }
                if (!contextLengthOf(dest[0 .. listed.len], qntxNode.model, sessions.contextSize)) {
                    put(`,"error":{"code":-32603,"message":"the gateway's models list gives no context_length for `);
                    putEscaped(r, qntxNode.model); put(`","data":{"url":"`); putEscaped(r, models.slice()); put(`"}}}`);
                    return true;
                }
            }
            // The history and the tools go to the gateway; a tool_calls answer is
            // run through the session's own MCP server and handed back, until the
            // model answers in words, or the client calls the turn off.
            while (true) {
                if (cancelAsked(turn)) { stopCancelled(); return true; }
                Reply body_;
                scope(exit) body_.dispose();
                requestBody(body_, qntxNode.model, o.history.slice(), tools.slice(), efforts[o.effort]);
                if (o.history.full || body_.full) { put(`,"error":{"code":-32603,"message":"the session's history outgrew memory"}}`); return true; }
                import http : Abort;
                auto http = httpPostInto(url.slice(), body_.slice(), token, dest[0 .. GATEWAY_BODY], GATEWAY_SECONDS,
                    "application/json", Abort(&stopIfCancelled, &turn));
                if (turn.cancelled) { stopCancelled(); return true; }
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
                // "A chunk of the agent's internal reasoning being streamed": what
                // the model reasoned, which the effort asked for, before its words.
                if (c.reasoning.length > 0) {
                    Reply u;
                    scope(exit) u.dispose();
                    u.add(`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"`);
                    putEscaped(u, c.reasoning); u.add(`"}}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                if (c.content.length > 0) {
                    Reply u;
                    scope(exit) u.dispose();
                    u.add(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"`);
                    putEscaped(u, c.content); u.add(`"}}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                // "Context window and cost update for a session": what the
                // conversation holds now, of the model's window.
                if (c.hasUsage) {
                    Reply u;
                    scope(exit) u.dispose();
                    u.add(`{"sessionUpdate":"usage_update","used":`); putNumber(u, c.used);
                    u.add(`,"size":`); putNumber(u, sessions.contextSize);
                    // cost: "Cumulative session cost (optional)", every answer's
                    // added to the session's; OpenRouter's credits are dollars.
                    if (c.hasCost) {
                        long total = o.costNano + c.costNano;
                        if (sessions.db !is null && storeAddCost(sessions.db, sid, c.costNano, total) != 1) {
                            put(`,"error":{"code":-32603,"message":"the store refused the cost of `);
                            putEscaped(r, sid); put(`"}}`);
                            return true;
                        }
                        o.costNano = total;
                        u.add(`,"cost":{"amount":`); putAmount(u, total); u.add(`,"currency":"USD"}`);
                    }
                    u.add(`}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                // "max_tokens": the answer was cut off at the model's token
                // limit. The calls it asked for are not run, and the history
                // says so, so the next turn is one the gateway still takes.
                if (c.finish == "length") {
                    foreach (i; 0 .. c.callCount)
                        toolMessage(*o.history, c.calls[i].id, `{"status":"not run","why":"the answer asking for it was cut off at the model's token limit"}`);
                    put(`,"result":{"stopReason":"max_tokens"}}`);
                    return true;
                }
                if (c.callCount == 0) { put(`,"result":{"stopReason":"end_turn"}}`); return true; }
                foreach (i; 0 .. c.callCount) {
                    auto call = c.calls[i];
                    // A call the turn was called off before is not run; the
                    // history answers it, as the gateway needs every call answered.
                    if (cancelAsked(turn)) {
                        foreach (j; i .. c.callCount)
                            toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"the client cancelled the turn"}`);
                        stopCancelled();
                        return true;
                    }
                    Reply u, server, tool, args, result;
                    scope(exit) { u.dispose(); server.dispose(); tool.dispose(); args.dispose(); result.dispose(); }
                    // The session's mode decides whether the call runs, and
                    // Manual asks the client. "pending": "awaiting approval".
                    const(char)[] why;
                    auto verdict = verdictOf(*o, call.name, readOnlyTool(o.mcp, call.name), why);
                    u.add(`{"sessionUpdate":"tool_call","toolCallId":"`); putEscaped(u, call.id);
                    u.add(`","title":"`); putEscaped(u, call.name);
                    // "Agents SHOULD include it in the first report when available
                    // and SHOULD NOT change it later": the name the model called,
                    // here and in no update after.
                    u.add(`","name":"`); putEscaped(u, call.name);
                    // "Helps clients choose appropriate icons and UI
                    // treatment": read, when the tool's annotations say it only reads.
                    if (readOnlyTool(o.mcp, call.name)) u.add(`","kind":"read`);
                    u.add(verdict == Verdict.run ? `","status":"in_progress","rawInput":` : `","status":"pending","rawInput":`);
                    u.add(call.arguments); u.add(`}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                    if (verdict == Verdict.ask) {
                        Reply asking;
                        scope(exit) asking.dispose();
                        auto got = askPermission(sessions, *o, turn, sid, call.id, call.name, call.arguments, asking);
                        if (got == 2) {
                            foreach (j; i .. c.callCount)
                                toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"the client cancelled the turn"}`);
                            stopCancelled();
                            return true;
                        }
                        if (got < 0) {
                            foreach (j; i .. c.callCount)
                                toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"ground code could not ask the client"}`);
                            put(`,"error":{"code":-32603,"message":"ground code could not ask the client's permission","data":`);
                            put(asking.slice()); put(`}}`);
                            return true;
                        }
                        why = "the user rejected it";
                        verdict = got == 1 ? Verdict.run : Verdict.refuse;
                        if (verdict == Verdict.run) {
                            u.len = 0;
                            u.add(`{"sessionUpdate":"tool_call_update","toolCallId":"`); putEscaped(u, call.id);
                            u.add(`","status":"in_progress"}`);
                            if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                        }
                    }
                    // Not run: the model is told why, and so is the client.
                    if (verdict == Verdict.refuse) {
                        Reply refused;
                        scope(exit) refused.dispose();
                        refused.add(`{"status":"not run","why":"`); putEscaped(refused, why); refused.add(`"}`);
                        toolMessage(*o.history, call.id, refused.slice());
                        u.len = 0;
                        u.add(`{"sessionUpdate":"tool_call_update","toolCallId":"`); putEscaped(u, call.id);
                        u.add(`","status":"failed","rawOutput":`); u.add(refused.slice());
                        putToolContent(u, refused.slice()); u.add(`}`);
                        if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                        continue;
                    }
                    server.add(serverOf(call.name)); server.add("\0");
                    tool.add(toolOf(call.name)); tool.add("\0");
                    args.add(call.arguments); args.add("\0");
                    import libmcp : mcp_response, mcp_error, mcp_status, mcp_response_free, mcp_status_string;
                    import core.stdc.string : strlen;
                    mcp_response response, validation;
                    mcp_error error;
                    scope(exit) { mcp_response_free(&response); mcp_response_free(&validation); }
                    // "Abort all tool call invocations in progress": a cancel
                    // that arrives while the call runs cancels it at the server.
                    bool stopCall() { return cancelAsked(turn); }
                    // What the server asks while it runs is asked of the client, tied to this call.
                    int askClient(const(char)[] method, const(char)[] params, ref Reply answer) {
                        return elicit(sessions, turn, sid, call.id, method, params, answer);
                    }
                    // What the server logs at warning or above while it runs, the user is told.
                    void hearServer(const(char)[] name, const(char)[] level, const(char)[] data) {
                        Reply title;
                        scope(exit) title.dispose();
                        title.add("MCP server "); title.add(name); title.add(" logged ");
                        title.add(level == "warning" ? "a warning" : level == "error" ? "an error"
                            : level == "critical" ? "a critical error" : level == "alert" ? "an alert" : "an emergency");
                        tellUser(sessions, sid, level == "warning" ? "warning" : "error", title.slice(), data);
                    }
                    auto status = callMcpTool(o.mcp, server.slice().ptr, tool.slice().ptr, args.slice().ptr, response, validation, error, &stopCall, &askClient, &hearServer);
                    bool ok = status == mcp_status.MCP_OK;
                    if (ok) result.add(response.json[0 .. response.length]);
                    else {
                        result.add(`{"status":"`); result.add(mcp_status_string(status)[0 .. strlen(mcp_status_string(status))]);
                        result.add(`","message":"`); if (error.message !is null) putEscaped(result, error.message[0 .. strlen(error.message)]);
                        result.add(`","response":"`); if (response.json !is null) putEscaped(result, response.json[0 .. response.length]);
                        result.add(`","validation":`);
                        if (validation.json !is null) result.add(validation.json[0 .. validation.length]);
                        else result.add("null");
                        result.add(`}`);
                    }
                    toolMessage(*o.history, call.id, result.slice());
                    u.len = 0;
                    u.add(`{"sessionUpdate":"tool_call_update","toolCallId":"`); putEscaped(u, call.id);
                    u.add(ok ? `","status":"completed","rawOutput":` : `","status":"failed","rawOutput":`); u.add(result.slice());
                    // "Content produced by the tool call", as MCP gave it.
                    putToolContent(u, result.slice()); u.add(`}`);
                    if (!notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                    // Cancelled in the call: the calls after it are not run,
                    // and the turn answers cancelled now.
                    if (turn.cancelled) {
                        foreach (j; i + 1 .. c.callCount)
                            toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"the client cancelled the turn"}`);
                        stopCancelled();
                        return true;
                    }
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
    // ground code reads its input itself, so a turn can see what arrives while it runs.
    Input input = Input(0);
    scope(exit) input.dispose();
    sessions.input = &input;
    while (true) {
        const(char)[] line;
        if (!nextLine(input, line)) {
            if (input.failed) { fputs("ground code: failed reading ACP input\n", stderr); result = 1; }
            break;
        }
        while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r')) line = line[0 .. $ - 1];
        if (line.length == 0) continue;
        Reply r;
        scope(exit) r.dispose();
        if (!answer(line, r, sessions)) {
            unhandled(line, sessions);
            continue;
        }
        // A notification it handled has no answer to write.
        if (r.len == 0 && !r.full) continue;
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
