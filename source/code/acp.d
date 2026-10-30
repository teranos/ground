module code.acp;

// Ground code: the agent ground runs itself, behind an ACP client. One
// JSON-RPC message a line on stdin, one answer a line on stdout. The protocol
// is the schema flake.nix pins, and `ground_parity` counts what each method's
// block here reads and writes against it.

enum BOOK_COMMAND = q"EOS
# an ACP client runs it and speaks JSON-RPC on its stdin and stdout:
ground_code
# sign in to the qntx block's node: approve the link it prints with your passkey:
ground_code login
EOS";

import parse : extractJsonString, extractBool;
import matcher : indexOf;
import provenance : jsonEscapeInto;
import db : versionString, sqlite3;
import proto : ParsedQntx;
import code.store : storeAddCost, storeOpen, storeClose, storeResume, storeList, storeDelete, storeSetMode, storeSetEffort, storeTouch, storeTitle,
    storeHistory, storeHistoryOf;
import sessionmode : SessionMode, parseSessionMode, nameOf, letterOf;
import acpmethods : AGENT_METHODS, PROTOCOL_METHODS;
import core.stdc.stdio : stdout, stderr, fputs, fwrite, fflush;
import code.mcp : McpGroup, openMcp, closeMcp, callMcpTool;
import code.prompt;
import libacp : acp_stop_reason;
public import code.reply : Reply, putEscaped, putNumber;
public import code.input : Input, nextLine, take, more, within;

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
    bool clientWritesFiles; // initialize said the client answers fs/write_text_file
    bool clientRunsCommands; // initialize said the client answers terminal/*
    Reply unreleased; // terminal/create asked by a turn called off before the answer, its id and session a line
    bool clientTakesNotices; // initialize said the client presents notice session updates
    bool elicitsForms, elicitsUrls; // initialize said the client answers elicitation/create in these modes
    bool clientRunsAuth; // initialize said the client runs a terminal auth method itself
    ulong contextSize; // the model's context window in tokens, from the gateway's models list; 0 until asked
    Input* input;    // what the client has sent and ground code has not read; a turn looks at it
    Reply after;     // what is told the client once the answer it follows is written
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
// request that asked for it, as libacp reads the line.
private bool cancels(const(char)[] line, const(char)[] sid, const(char)[] id) {
    import libacp : acp_cancel, acp_cancel_read, acp_cancel_free, acp_cancel_kind, acp_status;
    import core.stdc.string : strlen;
    acp_cancel c;
    scope(exit) acp_cancel_free(&c);
    if (acp_cancel_read(line.ptr, line.length, &c) != acp_status.ACP_OK) return false;
    if (c.kind == acp_cancel_kind.ACP_CANCEL_REQUEST) return c.request_id !is null && c.request_id[0 .. strlen(c.request_id)] == id;
    if (c.kind == acp_cancel_kind.ACP_CANCEL_SESSION) return c.session_id !is null && c.session_id[0 .. strlen(c.session_id)] == sid;
    return false;
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
// client; acceptEdits runs an edit unasked, unless the user always rejects it,
// and asks the rest as Manual does; auto has no classifier, so it asks as well.
private enum Verdict { run, ask, refuse }
private Verdict verdictOf(ref Open o, const(char)[] tool, bool readOnly, bool edit, ref const(char)[] why) {
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
            if (o.mode == SessionMode.acceptEdits && edit) return Verdict.run;
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

// The client's answer to fs/read_text_file: 1 and the file's text in content,
// every byte of it, or -1 for an answer of any other kind, an error among
// them. libacp reads it.
private int readTextContent(const(char)[] line, ref Reply content) {
    import libacp : acp_text_file, acp_read_text_file_result_read, acp_text_file_free, acp_status;
    acp_text_file file;
    scope(exit) acp_text_file_free(&file);
    if (acp_read_text_file_result_read(line.ptr, line.length, &file) != acp_status.ACP_OK || file.content is null) return -1;
    content.add(file.content[0 .. file.length]);
    return content.full ? -1 : 1;
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
    // libacp writes the request from these, each its own bytes and a NUL.
    import libacp : acp_read_text_file_request_write, acp_buffer, acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), pathAt = at(path);
    if (text.full) { why.add(`"could not allocate fs/read_text_file"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_read_text_file_request_write(t + idAt, t + sidAt, t + pathAt, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write fs/read_text_file"`);
        return -1;
    }
    if (fwrite(request.data, 1, request.length, stdout) != request.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
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

// fs/write_text_file, asked of the client for what a write_text_file call gives: 1 answered, its answer in
// answered; 0 not asked, the arguments being no absolute path and text, said in answered; 2 the turn was
// called off; -1 the client could not be asked, why the reason.
private int writeThroughClient(ref Sessions sessions, ref Turn turn, const(char)[] sid,
        const(char)[] arguments, ref Reply answered, ref Reply why) {
    import libjsonc : parseJson, jsonField, json_object_put, json_object_get_type, json_type,
        json_object_get_string, json_object_get_string_len;
    import core.stdc.string : strlen;
    auto args = parseJson(arguments);
    scope(exit) json_object_put(args);
    auto path = jsonField(args, "path"), content = jsonField(args, "content");
    // A path is a C string to libacp, so one holding a NUL would name another file.
    if (json_object_get_type(path) != json_type.string_ || json_object_get_type(content) != json_type.string_
            || json_object_get_string(path)[0] != '/' || strlen(json_object_get_string(path)) != cast(size_t) json_object_get_string_len(path)) {
        answered.add(`{"status":"not run","why":"write_text_file takes path, an absolute path, and content, text"}`);
        return 0;
    }
    if (turn.input is null) { why.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    sessions.asked++;
    Reply pid;
    scope(exit) pid.dispose();
    pid.add(`"write-`); putNumber(pid, sessions.asked); pid.add(`"`);
    // libacp writes the request from these, each its own bytes and a NUL; content goes by its length.
    import libacp : acp_write_text_file_request_write, acp_buffer, acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid);
    if (text.full) { why.add(`"could not allocate fs/write_text_file"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_write_text_file_request_write(t + idAt, t + sidAt, json_object_get_string(path), json_object_get_string(content),
            cast(size_t) json_object_get_string_len(content), &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write fs/write_text_file"`);
        return -1;
    }
    if (fwrite(request.data, 1, request.length, stdout) != request.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
        why.add(`"could not write fs/write_text_file"`);
        return -1;
    }
    auto waited = awaitAnswer(turn, pid.slice(), answered);
    if (waited < 0) { why.add(`"the client's input ended while ground code waited on the write"`); return -1; }
    return waited;
}

// Whether the client's answer to fs/write_text_file is a result, the file written. libacp reads it.
private bool clientWrote(const(char)[] line) {
    import libacp : acp_write_text_file_result_read, acp_status;
    int written;
    return acp_write_text_file_result_read(line.ptr, line.length, &written) == acp_status.ACP_OK && written == 1;
}

// How much of a command's output the client keeps for ground code, cut from its start.
enum OUTPUT_BYTE_LIMIT = 65536;

// The id of the next request ground code asks of the client about a terminal.
private void termId(ref Sessions sessions, ref Reply pid) {
    sessions.asked++;
    pid.add(`"term-`); putNumber(pid, sessions.asked); pid.add(`"`);
}

// A terminal/* request libacp wrote, sent as pid and its answer waited on: 1 answered, into
// answered; 2 the turn was called off; -1 not, why the reason.
private int askTerminal(ref Turn turn, const(char)[] pid, const(char)[] request, const(char)[] method,
        ref Reply answered, ref Reply why) {
    if (fwrite(request.ptr, 1, request.length, stdout) != request.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
        why.add(`"could not write `); why.add(method); why.add(`"`);
        return -1;
    }
    auto waited = awaitAnswer(turn, pid, answered);
    if (waited < 0) { why.add(`"the client's input ended while ground code waited on `); why.add(method); why.add(`"`); }
    return waited;
}

// terminal/create for command and its args, in cwd, asked as pid: 1 created, its id in terminalId; 0 the
// client answered with none, its answer in answered; 2 the turn was called off; -1 not asked, why the reason.
private int terminalCreate(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] cwd,
        const(char)* command, const(const(char)*)[] args, ref Reply pid, ref Reply terminalId, ref Reply answered, ref Reply why) {
    import libacp : acp_terminal_create_request_write, acp_terminal_create_result_read, acp_terminal_id_free,
        acp_buffer, acp_buffer_free, acp_status;
    import core.stdc.string : strlen;
    Reply text;
    scope(exit) text.dispose();
    termId(sessions, pid);
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), cwdAt = at(cwd);
    if (text.full) { why.add(`"could not allocate terminal/create"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_terminal_create_request_write(t + idAt, t + sidAt, command, args.ptr, args.length, t + cwdAt,
            OUTPUT_BYTE_LIMIT, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write terminal/create"`);
        return -1;
    }
    auto waited = askTerminal(turn, pid.slice(), request.data[0 .. request.length], "terminal/create", answered, why);
    if (waited != 1) return waited;
    char* id;
    scope(exit) acp_terminal_id_free(id);
    if (acp_terminal_create_result_read(answered.slice().ptr, answered.len, &id) != acp_status.ACP_OK || id is null) return 0;
    terminalId.add(id[0 .. strlen(id)]);
    return 1;
}

// terminal/wait_for_exit: 1 exited, how into code, hasCode and signal; 0 the client answered
// otherwise, into answered; 2 the turn was called off; -1 not asked, why the reason.
private int terminalWait(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] terminalId,
        ref bool hasCode, ref ulong code, ref Reply signal, ref Reply answered, ref Reply why) {
    import libacp : acp_terminal_wait_for_exit_request_write, acp_terminal_exit_read, acp_terminal_exit_free,
        acp_terminal_exit, acp_buffer, acp_buffer_free, acp_status;
    import core.stdc.string : strlen;
    Reply pid, text;
    scope(exit) { pid.dispose(); text.dispose(); }
    termId(sessions, pid);
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), termAt = at(terminalId);
    if (text.full) { why.add(`"could not allocate terminal/wait_for_exit"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_terminal_wait_for_exit_request_write(t + idAt, t + sidAt, t + termAt, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write terminal/wait_for_exit"`);
        return -1;
    }
    auto waited = askTerminal(turn, pid.slice(), request.data[0 .. request.length], "terminal/wait_for_exit", answered, why);
    if (waited != 1) return waited;
    acp_terminal_exit e;
    scope(exit) acp_terminal_exit_free(&e);
    if (acp_terminal_exit_read(answered.slice().ptr, answered.len, &e) != acp_status.ACP_OK || !e.exited) return 0;
    hasCode = e.has_exit_code != 0;
    code = e.exit_code;
    if (e.signal !is null) signal.add(e.signal[0 .. strlen(e.signal)]);
    return 1;
}

// terminal/output: 1 read, every byte into output and whether the client cut it into truncated; 0
// the client answered otherwise, into answered; 2 the turn was called off; -1 not asked, why the reason.
private int terminalOutput(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] terminalId,
        ref Reply output, ref bool truncated, ref Reply answered, ref Reply why) {
    import libacp : acp_terminal_output_request_write, acp_terminal_output_result_read, acp_terminal_output_free,
        acp_terminal_output, acp_buffer, acp_buffer_free, acp_status;
    Reply pid, text;
    scope(exit) { pid.dispose(); text.dispose(); }
    termId(sessions, pid);
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), termAt = at(terminalId);
    if (text.full) { why.add(`"could not allocate terminal/output"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_terminal_output_request_write(t + idAt, t + sidAt, t + termAt, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write terminal/output"`);
        return -1;
    }
    auto waited = askTerminal(turn, pid.slice(), request.data[0 .. request.length], "terminal/output", answered, why);
    if (waited != 1) return waited;
    acp_terminal_output o;
    scope(exit) acp_terminal_output_free(&o);
    if (acp_terminal_output_result_read(answered.slice().ptr, answered.len, &o) != acp_status.ACP_OK || o.output is null) return 0;
    output.add(o.output[0 .. o.length]);
    truncated = o.truncated != 0;
    return output.full ? -1 : 1;
}

// terminal/kill: 1 the client killed it; 0 it answered otherwise, into answered; 2 the turn was called
// off; -1 not asked, why the reason.
private int terminalKill(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] terminalId,
        ref Reply answered, ref Reply why) {
    import libacp : acp_terminal_kill_request_write, acp_terminal_answered_read, acp_buffer, acp_buffer_free, acp_status;
    Reply pid, text;
    scope(exit) { pid.dispose(); text.dispose(); }
    termId(sessions, pid);
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), termAt = at(terminalId);
    if (text.full) { why.add(`"could not allocate terminal/kill"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_terminal_kill_request_write(t + idAt, t + sidAt, t + termAt, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write terminal/kill"`);
        return -1;
    }
    auto waited = askTerminal(turn, pid.slice(), request.data[0 .. request.length], "terminal/kill", answered, why);
    if (waited != 1) return waited;
    int done;
    return acp_terminal_answered_read(answered.slice().ptr, answered.len, &done) == acp_status.ACP_OK && done ? 1 : 0;
}

// terminal/release: 1 the client released it; 0 it answered otherwise, into answered; 2 the turn was
// called off; -1 not asked, why the reason.
private int terminalRelease(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] terminalId,
        ref Reply answered, ref Reply why) {
    import libacp : acp_terminal_release_request_write, acp_terminal_answered_read, acp_buffer, acp_buffer_free, acp_status;
    Reply pid, text;
    scope(exit) { pid.dispose(); text.dispose(); }
    termId(sessions, pid);
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), termAt = at(terminalId);
    if (text.full) { why.add(`"could not allocate terminal/release"`); return -1; }
    auto t = text.slice().ptr;
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_terminal_release_request_write(t + idAt, t + sidAt, t + termAt, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write terminal/release"`);
        return -1;
    }
    auto waited = askTerminal(turn, pid.slice(), request.data[0 .. request.length], "terminal/release", answered, why);
    if (waited != 1) return waited;
    int done;
    return acp_terminal_answered_read(answered.slice().ptr, answered.len, &done) == acp_status.ACP_OK && done ? 1 : 0;
}

// The answer to a terminal/create a turn was called off before: the terminal it names is released, its
// own answer left to arrive as one no turn waits on. false when line answers no such request.
private bool releaseUnreleased(ref Sessions sessions, const(char)[] id, const(char)[] line) {
    import libacp : acp_terminal_create_result_read, acp_terminal_id_free, acp_terminal_release_request_write,
        acp_buffer, acp_buffer_free, acp_status;
    import core.stdc.string : strlen;
    auto all = sessions.unreleased.slice();
    for (size_t from = 0; from < all.length; ) {
        auto end = from;
        while (end < all.length && all[end] != '\n') end++;
        auto entry = all[from .. end];
        auto tab = indexOf(entry, "\t");
        if (tab >= 0 && entry[0 .. cast(size_t) tab] == id) {
            Reply sid, pid, text;
            scope(exit) { sid.dispose(); pid.dispose(); text.dispose(); }
            sid.add(entry[cast(size_t) tab + 1 .. $]);
            // Out of the list first: an answer is released once, whatever comes of it.
            Reply rest;
            scope(exit) rest.dispose();
            rest.add(all[0 .. from]); if (end < all.length) rest.add(all[end + 1 .. $]);
            sessions.unreleased.len = 0; sessions.unreleased.add(rest.slice());
            char* terminal;
            scope(exit) acp_terminal_id_free(terminal);
            if (acp_terminal_create_result_read(line.ptr, line.length, &terminal) != acp_status.ACP_OK || terminal is null) {
                fputs("ground code: a called-off turn's terminal/create made no terminal to release: ", stderr);
                fwrite(line.ptr, 1, line.length, stderr); fputs("\n", stderr);
                return true;
            }
            termId(sessions, pid);
            size_t at(const(char)[] s) { auto f = text.len; text.add(s); text.add("\0"); return f; }
            auto idAt = at(pid.slice()), sidAt = at(sid.slice());
            acp_buffer request;
            scope(exit) acp_buffer_free(&request);
            if (text.full || acp_terminal_release_request_write(text.slice().ptr + idAt, text.slice().ptr + sidAt, terminal, &request) != acp_status.ACP_OK
                    || fwrite(request.data, 1, request.length, stdout) != request.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
                fputs("ground code: could not release the terminal a called-off turn's terminal/create made: ", stderr);
                fwrite(line.ptr, 1, line.length, stderr); fputs("\n", stderr);
            }
            return true;
        }
        from = end + 1;
    }
    return false;
}

// A run_command call, run in the client's terminal in the session's cwd: shown in the call, waited on, read
// and released, killed first when the turn is called off. 1 it ran, into result, ok when it exited 0; 0 not
// asked, said in result; 2 the turn was called off, said in result; -1 not asked, why the reason.
private int runThroughClient(ref Sessions sessions, ref Turn turn, const(char)[] sid, const(char)[] cwd,
        const(char)[] callId, const(char)[] arguments, ref Reply result, ref bool ok, ref Reply terminalId, ref Reply why) {
    import libjsonc : parseJson, jsonField, json_object_put, json_object_get_type, json_type, json_object_get_string,
        json_object_get_string_len, json_object_array_length, json_object_array_get_idx;
    import core.stdc.string : strlen;
    import core.stdc.stdlib : malloc, free;
    ok = false;
    auto root = parseJson(arguments);
    scope(exit) json_object_put(root);
    // Each a C string to libacp, so one holding a NUL would run something else.
    bool whole(typeof(root) v) {
        return json_object_get_type(v) == json_type.string_
            && strlen(json_object_get_string(v)) == cast(size_t) json_object_get_string_len(v);
    }
    auto command = jsonField(root, "command"), list = jsonField(root, "args");
    bool usable = whole(command) && json_object_get_string_len(command) > 0
        && (list is null || json_object_get_type(list) == json_type.array);
    size_t count = usable && list !is null ? json_object_array_length(list) : 0;
    foreach (i; 0 .. count) if (!whole(json_object_array_get_idx(list, i))) usable = false;
    if (!usable) {
        result.add(`{"status":"not run","why":"run_command takes command, text, and args, a list of text"}`);
        return 0;
    }
    if (turn.input is null) { why.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    auto args = cast(const(char)**) malloc((count > 0 ? count : 1) * (const(char)*).sizeof);
    if (args is null) { why.add(`"could not allocate run_command's args"`); return -1; }
    scope(exit) free(args);
    foreach (i; 0 .. count) args[i] = json_object_get_string(json_object_array_get_idx(list, i));

    Reply answered, asked;
    scope(exit) { answered.dispose(); asked.dispose(); }
    auto made = terminalCreate(sessions, turn, sid, cwd, json_object_get_string(command), args[0 .. count], asked, terminalId, answered, why);
    if (made < 0) return -1;
    // Called off before the client answered: the terminal it makes is released when its answer comes.
    if (made == 2) {
        sessions.unreleased.add(asked.slice()); sessions.unreleased.add("\t"); sessions.unreleased.add(sid); sessions.unreleased.add("\n");
        result.add(`{"status":"cancelled","why":"the client cancelled the turn while it was asked to run the command"}`);
        return 2;
    }
    if (made == 0) { result.add(answered.slice()); return 1; }
    // The terminal is shown in the call before it is released:
    // "The terminal must be added before calling `terminal/release`."
    {
        Reply u;
        scope(exit) u.dispose();
        if (!putToolCall(u, true, callId, null, null, null, "in_progress", null, null, terminalId.slice()) || !notify(sid, u.slice())) {
            why.add(`"could not write session/update"`);
            return -1;
        }
    }
    bool hasCode, truncated;
    ulong code;
    Reply signal, output, released;
    scope(exit) { signal.dispose(); output.dispose(); released.dispose(); }
    answered.len = 0;
    auto exited = terminalWait(sessions, turn, sid, terminalId.slice(), hasCode, code, signal, answered, why);
    if (exited < 0) return -1;
    // Called off: killed, and what it printed so far read, before it is released.
    if (exited == 2) {
        Reply killed;
        scope(exit) killed.dispose();
        if (terminalKill(sessions, turn, sid, terminalId.slice(), killed, why) < 0) return -1;
    }
    Reply readAnswer;
    scope(exit) readAnswer.dispose();
    auto read = terminalOutput(sessions, turn, sid, terminalId.slice(), output, truncated, readAnswer, why);
    if (read < 0) return -1;
    auto freed = terminalRelease(sessions, turn, sid, terminalId.slice(), released, why);
    if (freed < 0) return -1;
    void tail() {
        result.add(`"truncated":`); result.add(truncated ? "true" : "false");
        result.add(`,"output":"`); putEscaped(result, output.slice()); result.add(`"`);
        if (freed == 0) { result.add(`,"release":`); result.add(released.len > 0 ? released.slice() : "null"); }
        result.add(`}`);
    }
    if (exited == 2) {
        result.add(`{"status":"cancelled","why":"the client cancelled the turn while the command ran",`);
        tail();
        return 2;
    }
    // An answer that is no exit, or no output, is what came of the call, as the client gave it.
    if (exited == 0) { result.add(answered.slice()); return 1; }
    if (read == 0) { result.add(readAnswer.slice()); return 1; }
    result.add(`{"exitCode":`);
    if (hasCode) putNumber(result, cast(uint) code); else result.add("null");
    result.add(`,"signal":`);
    if (signal.len > 0) { result.add(`"`); putEscaped(result, signal.slice()); result.add(`"`); } else result.add("null");
    result.add(`,`);
    tail();
    ok = hasCode && code == 0;
    return result.full ? -1 : 1;
}

// The client's answer to session/request_permission: 1 an option was selected,
// its optionId in optionId; 0 "The prompt turn was cancelled before the user
// responded"; -1 an answer of neither kind, or an error. libacp reads it.
private int permissionOutcome(const(char)[] line, ref Reply optionId) {
    import libacp : acp_permission_outcome, acp_permission_outcome_read, acp_permission_outcome_free,
        acp_permission_kind, acp_status;
    import core.stdc.string : strlen;
    acp_permission_outcome o;
    scope(exit) acp_permission_outcome_free(&o);
    if (acp_permission_outcome_read(line.ptr, line.length, &o) != acp_status.ACP_OK) return -1;
    if (o.kind == acp_permission_kind.ACP_PERMISSION_CANCELLED) return 0;
    if (o.kind != acp_permission_kind.ACP_PERMISSION_SELECTED) return -1;
    optionId.add(o.option_id[0 .. strlen(o.option_id)]);
    return 1;
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
    // libacp writes the request from these, each its own bytes and a NUL.
    import libacp : acp_permission_option, acp_permission_request, acp_permission_request_write, acp_buffer,
        acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    size_t at(const(char)[] s) { auto from = text.len; text.add(s); text.add("\0"); return from; }
    auto idAt = at(pid.slice()), sidAt = at(sid), callAt = at(callId), toolAt = at(tool), inputAt = at(arguments);
    auto allowAt = text.len; text.add("Always allow "); text.add(tool); text.add("\0");
    auto rejectAt = text.len; text.add("Always reject "); text.add(tool); text.add("\0");
    if (text.full) { why.add(`"could not allocate the permission request"`); return -1; }
    auto t = text.slice().ptr;
    acp_permission_option[4] options = [
        acp_permission_option("allow_once", "Allow once", "allow_once"),
        acp_permission_option("allow_always", t + allowAt, "allow_always"),
        acp_permission_option("reject_once", "Reject once", "reject_once"),
        acp_permission_option("reject_always", t + rejectAt, "reject_always"),
    ];
    auto asked = acp_permission_request(t + idAt, t + sidAt, t + callAt, t + toolAt, t + toolAt,
        readOnlyTool(o.mcp, tool) ? "read".ptr : null, "pending", t + inputAt, options.ptr, options.length);
    acp_buffer request;
    scope(exit) acp_buffer_free(&request);
    if (acp_permission_request_write(&asked, &request) != acp_status.ACP_OK) {
        why.add(`"libacp could not write session/request_permission"`);
        return -1;
    }
    if (fwrite(request.data, 1, request.length, stdout) != request.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
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

// "After creating a session, the Agent MAY send a list of available
// commands via the available_commands_update session notification": the
// session's MCP prompts, told once the answer that made the session the
// client's is written, so the session they name is one it knows.
private void announceCommands(ref Sessions sessions, const(char)[] sid, ref McpGroup group) {
    if (__ctfe || group.count == 0) return;
    Reply commands;
    scope(exit) commands.dispose();
    commandsOf(group, commands);
    if (commands.slice() == "[]") return;
    import libacp : acp_available_commands_update_write, acp_buffer, acp_buffer_free, acp_status;
    commands.add("\0");
    acp_buffer update;
    scope(exit) acp_buffer_free(&update);
    if (commands.full || acp_available_commands_update_write(commands.slice().ptr, &update) != acp_status.ACP_OK
        || !sessionUpdate(sessions.after, sid, update.data[0 .. update.length])) {
        fputs("ground code: libacp could not write available_commands_update\n", stderr);
        return;
    }
    sessions.after.add("\n");
}

// ground code's auth methods: qntx it runs itself through authenticate,
// qntx-terminal the client runs as `ground_code login`.
enum AGENT_METHOD = "qntx";
enum TERMINAL_METHOD = "qntx-terminal";
private enum AGENT_AUTH = `{"id":"qntx","name":"Sign in to QNTX","description":"Open the link ground code gives, and approve it at your QNTX node with your passkey"}`;
private enum TERMINAL_AUTH = `{"type":"terminal","id":"qntx-terminal","name":"Sign in to QNTX in a terminal","description":"Runs ground_code login, which prints the link to approve at your QNTX node with your passkey","args":["login"]}`;

// "Authentication methods supported by the agent": qntx to a client that can
// send the person to a link, and qntx-terminal only to one that said it runs
// terminal methods: "Agents MUST advertise this method only when the client
// enabled its terminal authentication capability."
private const(char)* authMethods(ref const Sessions sessions) {
    if (sessions.elicitsUrls && sessions.clientRunsAuth) return "[" ~ AGENT_AUTH ~ "," ~ TERMINAL_AUTH ~ "]";
    if (sessions.elicitsUrls) return "[" ~ AGENT_AUTH ~ "]";
    if (sessions.clientRunsAuth) return "[" ~ TERMINAL_AUTH ~ "]";
    return "[]";
}

// authenticate qntx, its answer added to r after its id: the node starts a
// sign-in, the person is sent to its link by an elicitation "tied to a
// specific JSON-RPC request outside of a session (e.g., during
// auth/configuration phases before any session is started)", the node is
// asked until they said yes, and the token it gives is kept where every
// ground reads its token. The client can call it off while it waits.
private void signIn(ref Sessions sessions, const(char)[] id, ref Reply r) {
    import code.login : SignIn, startSignIn, pollSignIn, keepToken, LABEL;
    import attest : qntxTokenFile;
    import libacp : acp_elicitation_url_write, acp_elicitation_complete_write, acp_buffer, acp_buffer_free, acp_status;
    import core.stdc.string : strlen;
    import core.sys.posix.sys.time : gettimeofday, timeval;
    void error(int code, const(char)[] message, const(char)[] data = null) {
        r.add(`,"error":{"code":`); r.add(code == -32000 ? "-32000" : code == -32800 ? "-32800" : "-32603");
        r.add(`,"message":"`); putEscaped(r, message); r.add(`"`);
        if (data !is null) { r.add(`,"data":`); r.add(data); }
        r.add(`}}`);
    }
    if (sessions.input is null) return error(-32603, "ground code reads no input here, so it cannot ask the client");
    // Auth is q's, the block's gateway, and its token is kept in ~/.qntx/token: the block's url and
    // token file are k's, the hooks' node for attestations, and are left alone.
    auto q = sessions.node.gateway.length > 0 ? sessions.node.gateway : sessions.node.url;
    if (q.length == 0) return error(-32603, "the qntx block names no node, so there is none to sign in to");
    auto named = qntxTokenFile("");
    if (named is null) return error(-32603, "the token is kept in a home, and HOME names none");
    Reply file, why, token, pid, text, answered;
    SignIn s;
    scope(exit) { file.dispose(); why.dispose(); token.dispose(); pid.dispose(); text.dispose(); answered.dispose(); s.dispose(); }
    file.add(named[0 .. strlen(named)]); file.add("\0");
    if (startSignIn(q, s, why) != 1) return error(-32603, "the node did not start a sign-in", why.slice());

    sessions.asked++;
    pid.add(`"login-`); putNumber(pid, sessions.asked); pid.add(`"`);
    size_t at(const(char)[] part) { auto from = text.len; text.add(part); text.add("\0"); return from; }
    auto pidAt = at(pid.slice()), idAt = at(id);
    auto eidAt = text.len; text.add("qntx-"); text.add(s.userCode.slice()); text.add("\0");
    auto linkAt = at(s.link.slice());
    auto messageAt = text.len; text.add("Sign in to QNTX as "); text.add(LABEL); text.add(". The code there is ");
    text.add(s.userCode.slice()); text.add(".\0");
    if (text.full || file.full) return error(-32603, "could not allocate the sign-in");
    auto t = text.slice().ptr;
    acp_buffer asked;
    scope(exit) acp_buffer_free(&asked);
    if (acp_elicitation_url_write(t + pidAt, t + idAt, t + eidAt, t + linkAt, t + messageAt, &asked) != acp_status.ACP_OK)
        return error(-32603, "libacp could not write elicitation/create");
    if (fwrite(asked.data, 1, asked.length, stdout) != asked.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0)
        return error(-32603, "could not write elicitation/create");

    Turn turn = Turn(sessions.input, "", id);
    auto waited = awaitAnswer(turn, pid.slice(), answered);
    if (waited < 0) return error(-32603, "the client's input ended while ground code waited on the sign-in");
    if (waited == 2) return error(-32800, "the client cancelled the sign-in");
    auto refused = objectValue(answered.slice(), `"error"`);
    if (refused !is null) return error(-32000, "the client did not send the person to sign in", refused);
    auto result = objectValue(answered.slice(), `"result"`);
    char[32] actionBuf;
    auto action = result is null ? null : extractJsonString(result, `"action"`, &actionBuf[0], actionBuf.length);
    if (action != "accept") {
        Reply data;
        scope(exit) data.dispose();
        if (action is null) { data.add(`"`); putEscaped(data, answered.slice()); data.add(`"`); }
        else { data.add(`{"action":"`); putEscaped(data, action); data.add(`"}`); }
        return error(-32000, "the person did not sign in to QNTX", data.slice());
    }

    // gettimeofday, as the rest of ground reads the time: druntime declares
    // it on Darwin and Linux alike, where clock_gettime it does not.
    long nowMs() {
        timeval tv;
        gettimeofday(&tv, null);
        return cast(long) tv.tv_sec * 1000 + tv.tv_usec / 1000;
    }
    while (true) {
        if (cancelAsked(turn)) return error(-32800, "the client cancelled the sign-in");
        why.len = 0;
        auto got = pollSignIn(q, s, token, why);
        if (got == 1) break;
        if (got < 0) return error(-32000, "the node did not sign ground code in", why.slice());
        // "the minimum amount of time in seconds that the client SHOULD wait between polling requests"
        auto until = nowMs() + cast(long) s.interval * 1000;
        while (true) {
            if (cancelAsked(turn)) return error(-32800, "the client cancelled the sign-in");
            auto left = until - nowMs();
            if (left <= 0) break;
            if (!within(*turn.input, left > 1000 ? 1000 : cast(int) left))
                return error(-32603, "the client's input ended while ground code waited on the sign-in");
        }
    }
    why.len = 0;
    if (!keepToken(file.slice().ptr, token.slice(), why)) return error(-32603, "signed in, but the token could not be kept", why.slice());
    // "Notification sent by the agent when a URL-based elicitation is complete."
    acp_buffer done;
    scope(exit) acp_buffer_free(&done);
    if (acp_elicitation_complete_write(t + eidAt, &done) != acp_status.ACP_OK
        || fwrite(done.data, 1, done.length, stdout) != done.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0)
        fputs("ground code: signed in, but could not write elicitation/complete\n", stderr);
    r.add(`,"result":{}}`);
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
        // Its one field is read from the server's and written, not the server's passed on unread.
        char[256] idBuf;
        auto elicitationId = extractJsonString(params, `"elicitationId"`, &idBuf[0], idBuf.length);
        if (elicitationId is null) {
            fputs("ground code: a server's elicitation/complete names no elicitationId: ", stderr);
            fwrite(params.ptr, 1, params.length, stderr);
            fputs("\n", stderr);
            return -1;
        }
        import libacp : acp_elicitation_complete_write, acp_buffer, acp_buffer_free, acp_status;
        Reply id;
        scope(exit) id.dispose();
        id.add(elicitationId); id.add("\0");
        acp_buffer n;
        scope(exit) acp_buffer_free(&n);
        if (!id.full && acp_elicitation_complete_write(id.slice().ptr, &n) == acp_status.ACP_OK
            && fwrite(n.data, 1, n.length, stdout) == n.length && fputs("\n", stdout) >= 0 && fflush(stdout) == 0) return 1;
        fputs("ground code: could not write elicitation/complete\n", stderr);
        return -1;
    }
    if (method != "elicitation/create") {
        answer.add(`{"code":-32601,"message":"ground code answers a server's elicitation/create, and nothing else it asks"}`);
        return 0;
    }
    // libacp writes the client's elicitation/create from what the server asked: the session and
    // the call lead, then its mode, form when it names none, then everything else it asked.
    import libacp : acp_elicitation_create_write, acp_elicit_mode, acp_buffer, acp_buffer_free, acp_status;
    Reply pid, text;
    scope(exit) { pid.dispose(); text.dispose(); }
    pid.add(`"elicit-`); putNumber(pid, sessions.asked + 1); pid.add(`"`);
    auto idAt = text.len; text.add(pid.slice()); text.add("\0");
    auto sidAt = text.len; text.add(sid); text.add("\0");
    auto callAt = text.len; text.add(callId); text.add("\0");
    if (text.full) { answer.add(`"could not allocate elicitation/create"`); return -1; }
    auto t = text.slice().ptr;
    int mode;
    acp_buffer n;
    scope(exit) acp_buffer_free(&n);
    if (acp_elicitation_create_write(t + idAt, t + sidAt, t + callAt, params.ptr, params.length, &mode, &n) != acp_status.ACP_OK) {
        answer.add(`"the server's elicitation/create names no object to ask"`);
        return -1;
    }
    if ((mode == acp_elicit_mode.ACP_ELICIT_FORM && !sessions.elicitsForms) || (mode == acp_elicit_mode.ACP_ELICIT_URL && !sessions.elicitsUrls)
        || mode == acp_elicit_mode.ACP_ELICIT_OTHER) {
        answer.add(`{"code":-32602,"message":"the client offers no elicitation in the mode the server asked"}`);
        return 0;
    }
    if (turn.input is null) { answer.add(`"ground code reads no input here, so it cannot ask the client"`); return -1; }
    sessions.asked++;
    if (fwrite(n.data, 1, n.length, stdout) != n.length || fputs("\n", stdout) < 0 || fflush(stdout) != 0) {
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
    Reply u, text;
    scope(exit) { u.dispose(); text.dispose(); }
    if (sessions.clientTakesNotices) {
        import libacp : acp_notice_write, acp_buffer, acp_buffer_free, acp_status;
        auto severityAt = text.len; text.add(severity); text.add("\0");
        auto titleAt = text.len; text.add(title); text.add("\0");
        auto descriptionAt = text.len; text.add(description); text.add("\0");
        if (text.full) return false;
        auto t = text.slice().ptr;
        acp_buffer notice;
        scope(exit) acp_buffer_free(&notice);
        if (acp_notice_write(t + severityAt, t + titleAt, t + descriptionAt, &notice) != acp_status.ACP_OK) return false;
        u.add(notice.data[0 .. notice.length]);
    } else {
        text.add(title); text.add(": "); text.add(description); text.add("\n");
        if (text.full || !putChunk(u, 0, text.slice())) return false;
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
// libacp writes them; false when it could not.
private bool putConfig(ref Reply r, SessionMode mode, size_t effort) {
    import libacp : acp_config_value, acp_config_select, acp_config_options_write, acp_buffer, acp_buffer_free,
        acp_status;
    OptionTexts t;
    scope(exit) t.dispose();
    if (!t.fill()) return false;
    auto current = modeAt(mode);
    if (current == offered.length) return false;
    acp_config_value[offered.length] modes;
    foreach (i; 0 .. offered.length) modes[i] = acp_config_value(t.at(t.idAt[i]), t.at(t.nameAt[i]), t.at(t.describedAt[i]));
    acp_config_value[efforts.length] levels;
    foreach (i; 0 .. efforts.length) levels[i] = acp_config_value(t.at(t.effortAt[i]), t.at(t.effortNameAt[i]), null);
    acp_config_select[2] selects = [
        acp_config_select("mode", "Mode", "mode", t.at(t.idAt[current]), modes.ptr, modes.length),
        acp_config_select("effort", "Effort", "thought_level", t.at(t.effortAt[effort]), levels.ptr, levels.length),
    ];
    acp_buffer options;
    scope(exit) acp_buffer_free(&options);
    if (acp_config_options_write(selects.ptr, selects.length, &options) != acp_status.ACP_OK) return false;
    r.add(options.data[0 .. options.length]);
    return true;
}

// The rest of set_config_option's answer, from its configOptions on: "The full
// set of configuration options and their current values". head is where it began.
private bool putOptions(ref Reply r, size_t head, const(char)[] sid, SessionMode mode, size_t effort) {
    if (!putConfig(r, mode, effort)) {
        r.len = head;
        r.add(`,"error":{"code":-32603,"message":"libacp could not write the configOptions of `); putEscaped(r, sid); r.add(`"}}`);
        return true;
    }
    r.add(`}}`);
    return true;
}

// The rest of session/prompt's answer, from its result on: why the turn stopped, as libacp writes it.
private void putStop(ref Reply r, acp_stop_reason reason) {
    import libacp : acp_prompt_result_write, acp_buffer, acp_buffer_free, acp_status;
    acp_buffer result;
    scope(exit) acp_buffer_free(&result);
    if (acp_prompt_result_write(reason, &result) != acp_status.ACP_OK) {
        r.add(`,"error":{"code":-32603,"message":"libacp could not write the turn's stop reason"}}`);
        return;
    }
    r.add(`,"result":`); r.add(result.data[0 .. result.length]); r.add(`}`);
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

// The additionalDirectories a request names, read by libacp into dirs as the JSON array
// a client is answered with; true when it was refused, the refusal said in r.
private bool readDirs(const(char)[] line, ref Reply dirs, ref Reply r) {
    import libacp : acp_directories_read, acp_buffer, acp_buffer_free, acp_status;
    auto params = objectValue(line, `"params"`);
    if (params is null) params = "{}";
    acp_buffer list, said;
    scope(exit) { acp_buffer_free(&list); acp_buffer_free(&said); }
    if (acp_directories_read(params.ptr, params.length, &list, &said) != acp_status.ACP_OK) {
        r.add(`,"error":`);
        if (said.data !is null) r.add(said.data[0 .. said.length]);
        else r.add(`{"code":-32603,"message":"libacp could not read additionalDirectories"}`);
        r.add(`}`);
        return true;
    }
    dirs.add(list.data[0 .. list.length]);
    if (dirs.len > Open.init.dirs.length) {
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
    // write_text_file is the one edit ground code has, and auto no classifier to run on.
    if (m == SessionMode.acceptEdits) r.add(`; ground code writes files without asking, and asks the rest as Manual does`);
    if (m == SessionMode.auto_) r.add(`; ground code asks, as Manual does`);
}

// Where a mode stands among those offered, or offered.length for one it does not.
private size_t modeAt(SessionMode m) {
    foreach (i, o; offered) if (o == m) return i;
    return offered.length;
}

// The modes and efforts as C reads them: each string its own bytes, then a NUL.
// at() is taken once fill() is done, as text may move while it grows.
private struct OptionTexts {
    Reply text;
    size_t[offered.length] idAt, nameAt, describedAt;
    size_t[efforts.length] effortAt, effortNameAt;

    bool fill() {
        foreach (i, m; offered) {
            idAt[i] = text.len; text.add(nameOf(m)); text.add("\0");
            nameAt[i] = text.len; text.add(shownAs(m)); text.add("\0");
            describedAt[i] = text.len; putModeDescription(text, m); text.add("\0");
        }
        foreach (i; 0 .. efforts.length) {
            effortAt[i] = text.len; text.add(efforts[i]); text.add("\0");
            effortNameAt[i] = text.len; text.add(effortNames[i]); text.add("\0");
        }
        return !text.full;
    }

    const(char)* at(size_t from) { return text.slice().ptr + from; }
    void dispose() { text.dispose(); }
}

// libacp writes the SessionModeState; false when it could not.
private bool putModes(ref Reply r, SessionMode current) {
    import libacp : acp_mode, acp_modes_write, acp_buffer, acp_buffer_free, acp_status;
    OptionTexts t;
    scope(exit) t.dispose();
    if (!t.fill()) return false;
    auto at = modeAt(current);
    if (at == offered.length) return false;
    acp_mode[offered.length] modes;
    foreach (i; 0 .. offered.length) modes[i] = acp_mode(t.at(t.idAt[i]), t.at(t.nameAt[i]), t.at(t.describedAt[i]));
    acp_buffer state;
    scope(exit) acp_buffer_free(&state);
    if (acp_modes_write(t.at(t.idAt[at]), modes.ptr, modes.length, &state) != acp_status.ACP_OK) return false;
    r.add(state.data[0 .. state.length]);
    return true;
}

private void forget(ref Open o) {
    if (o.history !is null) { o.history.dispose(); free(o.history); o.history = null; }
    o.always.dispose(); o.never.dispose();
}

// A session/update to the client, written as it happens: a turn's steps are
// not held until the turn ends. libacp writes the notification around update.
private bool notify(const(char)[] sid, const(char)[] update) {
    Reply n;
    scope(exit) n.dispose();
    if (!sessionUpdate(n, sid, update)) return false;
    n.add("\n");
    if (n.full) return false;
    auto s = n.slice();
    return fwrite(s.ptr, 1, s.length, stdout) == s.length && fflush(stdout) == 0;
}

// session_info_update, as libacp writes it, into u: the title when one is given, and updatedAt.
private bool sessionInfo(ref Reply u, const(char)[] title, long updatedAt) {
    import libacp : acp_session_info_update_write, acp_buffer, acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    auto titleAt = text.len; if (title !is null) { text.add(title); text.add("\0"); }
    auto isoAt = text.len; putIso(text, updatedAt); text.add("\0");
    if (text.full) return false;
    auto t = text.slice().ptr;
    acp_buffer written;
    scope(exit) acp_buffer_free(&written);
    if (acp_session_info_update_write(title is null ? null : t + titleAt, t + isoAt, &written) != acp_status.ACP_OK) return false;
    u.add(written.data[0 .. written.length]);
    return !u.full;
}

// usage_update, as libacp writes it, into u: the cost when amount, a decimal, is given, in dollars.
private bool usageUpdate(ref Reply u, ulong used, ulong size, const(char)[] amount) {
    import libacp : acp_usage_update_write, acp_buffer, acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    if (amount !is null) { text.add(amount); text.add("\0"); }
    if (text.full) return false;
    acp_buffer written;
    scope(exit) acp_buffer_free(&written);
    if (acp_usage_update_write(used, size, amount is null ? null : text.slice().ptr, amount is null ? null : "USD".ptr, &written)
        != acp_status.ACP_OK) return false;
    u.add(written.data[0 .. written.length]);
    return !u.full;
}

// The session/update notification around update, as libacp writes it, into n.
private bool sessionUpdate(ref Reply n, const(char)[] sid, const(char)[] update) {
    import libacp : acp_session_update_write, acp_buffer, acp_buffer_free, acp_status;
    Reply text;
    scope(exit) text.dispose();
    auto sidAt = text.len; text.add(sid); text.add("\0");
    auto updateAt = text.len; text.add(update); text.add("\0");
    if (text.full) return false;
    acp_buffer written;
    scope(exit) acp_buffer_free(&written);
    auto t = text.slice().ptr;
    if (acp_session_update_write(t + sidAt, t + updateAt, &written) != acp_status.ACP_OK) return false;
    n.add(written.data[0 .. written.length]);
    return !n.full;
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
        if (!__ctfe && releaseUnreleased(sessions, id, line)) return true;
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

    // libacp reads the client's offer in the shape of the version it asked for,
    // selects the version the connection speaks, and writes the result in its
    // shape. ground code speaks v1 alone, until its v2 surface stands.
    if (method == AGENT_METHODS.initialize) {
        import libacp : acp_initialize, acp_buffer, acp_status, acp_initialize_read,
                        acp_initialize_result, acp_buffer_free;
        static immutable uint[1] speaks = [1];
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        acp_initialize got;
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        auto read = acp_initialize_read(params.ptr, params.length, speaks.ptr, speaks.length, &got, &said);
        if (read != acp_status.ACP_OK) {
            put(`{"jsonrpc":"2.0","id":`); put(id); put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else { put(`{"code":-32603,"message":"libacp could not read initialize"}`); }
            put(`}`);
            return true;
        }
        sessions.clientReadsFiles = got.capabilities.fs_read_text_file != 0;
        sessions.clientWritesFiles = got.capabilities.fs_write_text_file != 0;
        sessions.clientRunsCommands = got.capabilities.terminal != 0;
        sessions.clientTakesNotices = got.capabilities.session_notices != 0;
        sessions.elicitsForms = got.capabilities.elicitation_form != 0;
        sessions.elicitsUrls = got.capabilities.elicitation_url != 0;
        sessions.clientRunsAuth = got.capabilities.auth_terminal != 0;
        Reply version_;
        scope(exit) version_.dispose();
        version_.add(versionString()); version_.add("\0");
        acp_buffer result;
        scope(exit) acp_buffer_free(&result);
        auto wrote = acp_initialize_result(got.selected_version, "ground", version_.slice().ptr,
            `{"loadSession":true,"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}},"mcpCapabilities":{"http":true},"promptCapabilities":{"embeddedContext":true},"auth":{"logout":{}}}`,
            authMethods(sessions), &result);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (wrote != acp_status.ACP_OK) { put(`,"error":{"code":-32603,"message":"libacp could not write initialize's result"}}`); return true; }
        put(`,"result":`); put(result.data[0 .. result.length]); put(`}`);
        return true;
    }

    // "Clients MAY cancel an ongoing prompt turn at any time by sending a
    // session/cancel notification". A turn takes its own cancel while it runs;
    // one read here found no turn running, and has nothing to stop. A
    // notification is answered with nothing, so it is said on stderr.
    // "Notification to cancel an ongoing request." Every request but a turn is
    // answered before the next line is read, so only a turn's can be ongoing.
    // libacp reads either cancel's id.
    if (method == AGENT_METHODS.session_cancel || method == PROTOCOL_METHODS.cancel_request) {
        import libacp : acp_cancel, acp_cancel_read, acp_cancel_free, acp_status;
        import core.stdc.string : strlen;
        acp_cancel c;
        scope(exit) acp_cancel_free(&c);
        bool read = acp_cancel_read(line.ptr, line.length, &c) == acp_status.ACP_OK;
        bool session = method == AGENT_METHODS.session_cancel;
        auto named = session ? c.session_id : c.request_id;
        fputs(session ? "ground code: session/cancel for " : "ground code: $/cancel_request for ", stderr);
        if (!read) fputs("a message libacp could not read", stderr);
        else if (named is null) fputs(session ? "no sessionId" : "no requestId", stderr);
        else fwrite(named, 1, strlen(named), stderr);
        fputs(session ? ", with no turn running\n" : ", which no turn is answering\n", stderr);
        return true;
    }

    // "Must be one of the methods advertised in the initialize response."
    // qntx signs in to the node; qntx-terminal is the client's to run.
    if (method == AGENT_METHODS.authenticate) {
        // libacp reads the methodId, and refuses a request with none in its words.
        import libacp : acp_authenticate_read, acp_authenticate_free, acp_buffer, acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        char* named;
        scope(exit) acp_authenticate_free(&named);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_authenticate_read(params.ptr, params.length, &named, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read authenticate"}`);
            put(`}`);
            return true;
        }
        auto mid = named[0 .. strlen(named)];
        if (mid == TERMINAL_METHOD) {
            put(`,"error":{"code":-32602,"message":"qntx-terminal is a terminal method: the client runs ground_code login itself, and does not pass it to authenticate"}}`);
            return true;
        }
        if (mid != AGENT_METHOD) {
            put(`,"error":{"code":-32602,"message":"ground code's auth method is qntx, and authenticate named `);
            putEscaped(r, mid); put(`"}}`);
            return true;
        }
        if (!sessions.elicitsUrls) {
            put(`,"error":{"code":-32602,"message":"qntx sends the person to their node's link, and the client offers no url elicitation"}}`);
            return true;
        }
        if (__ctfe) assert(0, "the node is signed in to at runtime");
        else signIn(sessions, id, r);
        return true;
    }

    // "Terminates the current authenticated session": the token ground code
    // was given is dropped. The node keeps it until the person revokes it there.
    if (method == AGENT_METHODS.logout) {
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (__ctfe) assert(0, "a token file is dropped at runtime");
        else {
            import attest : qntxTokenFile;
            import code.login : dropToken;
            import errors : getenv;
            // q's token, the one ground code signed in with, in ~/.qntx/token; k's is the hooks'.
            if (getenv("QNTX_TOKEN\0".ptr) !is null) {
                put(`,"error":{"code":-32603,"message":"QNTX_TOKEN in ground code's environment is read before the token file, and logout cannot drop it"}}`);
                return true;
            }
            auto file = qntxTokenFile("");
            if (file is null) { put(`,"error":{"code":-32603,"message":"the token is kept in a home, and HOME names none"}}`); return true; }
            Reply why;
            scope(exit) why.dispose();
            if (dropToken(file, why) < 0) {
                put(`,"error":{"code":-32603,"message":"logout could not drop the token","data":`); put(why.slice()); put(`}}`);
                return true;
            }
        }
        put(`,"result":{}}`);
        return true;
    }

    // Ground owns each session's MCP clients, including discovery and close.
    if (method == AGENT_METHODS.session_new) {
        import libacp : acp_session_new, acp_session_new_read, acp_session_new_free,
            acp_session_new_result, acp_buffer, acp_buffer_free, acp_status;
        import libjsonc : parseJson, jsonField, json_object_put, json_object_to_json_string_ext;
        import core.stdc.string : strlen;
        // Only the envelope's own params: a nested _meta.params is not the request.
        auto root = parseJson(line);
        scope(exit) json_object_put(root);
        auto params = json_object_to_json_string_ext(jsonField(root, "params"), 0);
        if (params is null) params = "null";
        acp_session_new asked;
        scope(exit) acp_session_new_free(&asked);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_session_new_read(params, strlen(params), &asked, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read session/new"}`);
            put(`}`);
            return true;
        }
        auto cwd = asked.cwd[0 .. strlen(asked.cwd)];
        auto dirs = asked.additional_directories.data[0 .. asked.additional_directories.length];
        if (cwd.length > sessions.open[0].cwd.length) {
            put(`,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);
            return true;
        }
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
        }
        sessions.count++;
        Reply sid;
        scope(exit) sid.dispose();
        putSessionId(sid, sessions, sessions.count);
        size_t effort = MEDIUM;
        if (sessions.settingsEffort && !__ctfe) {
            import effort : settingsInto;
            __gshared char[65536] settings;
            effort = effortAt(effortDefault(settings[0 .. settingsInto(settings[])]));
        }
        if (sessions.db !is null && !storeOpen(sessions.db, sid.slice(), cwd, dirs, efforts[effort], now(sessions))) {
            Reply detail;
            scope(exit) detail.dispose();
            if (!__ctfe) closeMcp(o.mcp, detail);
            put(`,"error":{"code":-32603,"message":"the store refused the session ground code opened"}}`);
            return true;
        }
        keep(*o, sid.slice(), cwd, SessionMode.manual, dirs, effort);
        o.updatedAt = now(sessions);
        sessions.openLen++;
        announceCommands(sessions, sid.slice(), o.mcp);
        Reply modes, config;
        scope(exit) { modes.dispose(); config.dispose(); }
        acp_buffer result;
        scope(exit) acp_buffer_free(&result);
        bool written = putModes(modes, SessionMode.manual) && putConfig(config, SessionMode.manual, effort);
        modes.add("\0"); config.add("\0"); sid.add("\0");
        if (!written || modes.full || config.full || sid.full ||
            acp_session_new_result(sid.slice().ptr, modes.slice().ptr, config.slice().ptr, &result) != acp_status.ACP_OK) {
            put(`,"error":{"code":-32603,"message":"libacp could not write session/new"}}`);
            return true;
        }
        put(`,"result":`); put(result.data[0 .. result.length]); put(`}`);
        return true;
    }

    // Close owns every MCP child. The session is removed even if a child needs
    // forced termination, and that failure is returned to the ACP client.
    if (method == AGENT_METHODS.session_close) {
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
    if (method == AGENT_METHODS.session_list) {
        // libacp reads the cwd and the cursor, refuses either as not a string, and a cwd not absolute.
        import libacp : acp_session_list, acp_session_list_read, acp_session_list_free, acp_session_info,
            acp_session_info_write, acp_buffer, acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        acp_session_list asked;
        scope(exit) acp_session_list_free(&asked);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_session_list_read(params.ptr, params.length, &asked, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read session/list"}`);
            put(`}`);
            return true;
        }
        const(char)[] cwd = asked.cwd is null ? null : asked.cwd[0 .. strlen(asked.cwd)];
        if (asked.cursor !is null) {
            put(`,"error":{"code":-32602,"message":"ground code gives no nextCursor, so it has no cursor to page from"}}`);
            return true;
        }
        auto head = r.len;
        put(`,"result":{"sessions":[`);
        bool first = true;
        bool unwritten = false;
        Reply named; // the session libacp could not write
        scope(exit) named.dispose();
        // libacp writes each SessionInfo. updatedAt is "ISO 8601 timestamp of
        // last activity". title: "Human-readable title for the session. May be
        // auto-generated from the first prompt." One not named yet lists none.
        void entry(const(char)[] sid, const(char)[] at, const(char)[] dirs, const(char)[] title, long updatedAt) {
            if (unwritten) return;
            Reply text;
            scope(exit) text.dispose();
            size_t sidAt = text.len; text.add(sid); text.add("\0");
            size_t cwdAt = text.len; text.add(at); text.add("\0");
            size_t dirsAt = text.len; text.add(dirs.length ? dirs : "[]"); text.add("\0");
            size_t titleAt = text.len; text.add(title); text.add("\0");
            size_t isoAt = text.len; putIso(text, updatedAt); text.add("\0");
            acp_buffer info;
            scope(exit) acp_buffer_free(&info);
            auto p = text.slice().ptr;
            auto fields = acp_session_info(p + sidAt, p + cwdAt, p + dirsAt, p + titleAt, p + isoAt);
            if (text.full || acp_session_info_write(&fields, &info) != acp_status.ACP_OK) { unwritten = true; named.add(sid); return; }
            if (!first) put(",");
            first = false;
            put(info.data[0 .. info.length]);
        }
        if (sessions.db !is null) {
            if (!storeList(sessions.db, cwd, &entry)) {
                r.len = head;
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
        if (unwritten) {
            r.len = head;
            put(`,"error":{"code":-32603,"message":"libacp could not write the session `); putEscaped(r, named.slice()); put(`"}}`);
            return true;
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
    if (method == AGENT_METHODS.session_resume || method == AGENT_METHODS.session_load) {
        bool load = method == AGENT_METHODS.session_load;
        auto verb = load ? "load" : "resume";
        // libacp reads the request, load's servers required too, and refuses it in its words.
        import libacp : acp_session_resume, acp_session_resume_read, acp_session_load_read, acp_session_resume_free,
            acp_buffer, acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        acp_session_resume resumed;
        scope(exit) acp_session_resume_free(&resumed);
        {
            auto params = objectValue(line, `"params"`);
            if (params is null) params = "{}";
            acp_buffer said;
            scope(exit) acp_buffer_free(&said);
            auto read = load ? acp_session_load_read(params.ptr, params.length, &resumed, &said)
                : acp_session_resume_read(params.ptr, params.length, &resumed, &said);
            if (read != acp_status.ACP_OK) {
                put(`{"jsonrpc":"2.0","id":`); put(id); put(`,"error":`);
                if (said.data !is null) put(said.data[0 .. said.length]);
                else { put(`{"code":-32603,"message":"libacp could not read `); put(method); put(`"}`); }
                put(`}`);
                return true;
            }
        }
        auto sid = resumed.session_id[0 .. strlen(resumed.session_id)];
        auto cwd = resumed.cwd[0 .. strlen(resumed.cwd)];
        auto mcp = emptyArray(line, `"mcpServers"`);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (cwd.length > sessions.open[0].cwd.length) {
            put(`,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);
            return true;
        }
        Reply dirs;
        scope(exit) dirs.dispose();
        if (readDirs(line, dirs, r)) return true;
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
        if (!__ctfe) {
            auto opened = openAt(sessions, sid);
            if (opened >= 0) announceCommands(sessions, sid, sessions.open[cast(size_t) opened].mcp);
        }
        auto head = r.len;
        put(`,"result":{"modes":`);
        if (!putModes(r, mode)) {
            r.len = head;
            put(`,"error":{"code":-32603,"message":"libacp could not write the modes of `); putEscaped(r, sid); put(`"}}`);
            return true;
        }
        put(`,"configOptions":`);
        if (!putConfig(r, mode, effort)) {
            r.len = head;
            put(`,"error":{"code":-32603,"message":"libacp could not write the configOptions of `); putEscaped(r, sid); put(`"}}`);
            return true;
        }
        put(`}}`);
        return true;
    }

    // A mode is one a session offers, set on a session live here. It is kept
    // with the session, so a resume comes back in it. The client chose it, so
    // there is no current_mode_update to tell it what it already knows.
    if (method == AGENT_METHODS.session_set_mode) {
        // libacp reads the session and the mode, and refuses either missing in its words.
        import libacp : acp_set_mode, acp_set_mode_read, acp_set_mode_free, acp_buffer, acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        acp_set_mode asked;
        scope(exit) acp_set_mode_free(&asked);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_set_mode_read(params.ptr, params.length, &asked, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read session/set_mode"}`);
            put(`}`);
            return true;
        }
        auto sid = asked.session_id[0 .. strlen(asked.session_id)];
        auto want = asked.mode_id[0 .. strlen(asked.mode_id)];
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
    if (method == AGENT_METHODS.session_set_config_option) {
        // libacp reads the session, the option and its value, and refuses any missing in its words.
        import libacp : acp_set_config_option, acp_set_config_option_read, acp_set_config_option_free, acp_buffer,
            acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        acp_set_config_option asked;
        scope(exit) acp_set_config_option_free(&asked);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_set_config_option_read(params.ptr, params.length, &asked, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read session/set_config_option"}`);
            put(`}`);
            return true;
        }
        if (asked.is_boolean) {
            put(`,"error":{"code":-32602,"message":"session/set_config_option needs a value: mode and effort are selects, not booleans"}}`);
            return true;
        }
        auto sid = asked.session_id[0 .. strlen(asked.session_id)];
        auto config = asked.config_id[0 .. strlen(asked.config_id)];
        auto value = asked.value[0 .. strlen(asked.value)];
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
            auto head = r.len;
            put(`,"result":{"configOptions":`);
            return putOptions(r, head, sid, o.mode, o.effort);
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
        auto head = r.len;
        put(`,"result":{"configOptions":`);
        return putOptions(r, head, sid, o.mode, effort);
    }

    // "deleting an existing session from `session/list`": what list would show
    // is what delete takes. Gone from the store, it is gone for every process,
    // and one live here is no longer live.
    if (method == AGENT_METHODS.session_delete) {
        // libacp reads the session session/delete names, and refuses it in its words.
        import libacp : acp_session_target_read, acp_session_target_free, acp_buffer, acp_buffer_free, acp_status;
        import core.stdc.string : strlen;
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        char* named;
        scope(exit) acp_session_target_free(&named);
        acp_buffer said;
        scope(exit) acp_buffer_free(&said);
        put(`{"jsonrpc":"2.0","id":`); put(id);
        if (acp_session_target_read("session/delete", params.ptr, params.length, &named, &said) != acp_status.ACP_OK) {
            put(`,"error":`);
            if (said.data !is null) put(said.data[0 .. said.length]);
            else put(`{"code":-32603,"message":"libacp could not read session/delete"}`);
            put(`}`);
            return true;
        }
        auto sid = named[0 .. strlen(named)];
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
    if (method == AGENT_METHODS.session_prompt) {
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
        auto params = objectValue(line, `"params"`);
        if (params is null) params = "{}";
        Reply text, other, links, embedded, said;
        scope(exit) { text.dispose(); other.dispose(); links.dispose(); embedded.dispose(); said.dispose(); }
        auto blocks = promptText(params, text, other, links, embedded, said);
        if (blocks == Blocks.refused) { put(`,"error":`); put(said.slice()); put(`}`); return true; }
        if (blocks == Blocks.other) {
            put(`,"error":{"code":-32602,"message":"ground code reads text blocks, resource links and resources holding text, and the prompt holds a block `);
            if (other.len == 0) put(`that names no type"}}`);
            else { put(`of type `); putEscaped(r, other.slice()); put(`"}}`); }
            return true;
        }
        // A file:// resource_link is read through the client, "Only available
        // if the client supports the fs.readTextFile capability", and only one
        // on this machine has the "Absolute path" that asks for. Any other is
        // read through the session's MCP servers as the turn starts.
        for (size_t at_ = 0, field = 0, from = 0; at_ < links.len; at_++) {
            if (links.slice()[at_] != '\0') continue;
            if (field++ % 2 == 1) {
                auto uri = links.slice()[from .. at_];
                Reply path;
                scope(exit) path.dispose();
                if (fileUriPath(uri, path) && !sessions.clientReadsFiles) {
                    put(`,"error":{"code":-32602,"message":"ground code reads a file:// resource_link through the client's fs/read_text_file, and the client offers none: `);
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
            void stopCancelled() { putStop(r, acp_stop_reason.ACP_STOP_CANCELLED); }
            // "Agents typically send this notification after the first meaningful
            // exchange to auto-generate a title": the first prompt that types
            // something names the session, in the store and to the client.
            // updatedAt, "ISO 8601 timestamp of last activity", is told with
            // every turn, so a client's list keeps "in sync without polling".
            Reply newTitle, info;
            scope(exit) { newTitle.dispose(); info.dispose(); }
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
                        newTitle.add(title.slice());
                    }
                }
            }
            if (!sessionInfo(info, newTitle.len > 0 ? newTitle.slice() : null, o.updatedAt) || !notify(sid, info.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
            // What was typed, before any linked file joins it: what a command is read from.
            auto typedLen = text.len;
            // Each linked file is read before the model is asked, and its text
            // is the user's, after what they typed, under the link's name.
            for (size_t at_ = 0, from = 0, field = 0, nameFrom = 0, nameTo = 0; at_ < links.len; at_++) {
                if (links.slice()[at_] != '\0') continue;
                if (field++ % 2 == 0) { nameFrom = from; nameTo = at_; from = at_ + 1; continue; }
                auto uri = links.slice()[from .. at_];
                from = at_ + 1;
                Reply path, content, why;
                scope(exit) { path.dispose(); content.dispose(); why.dispose(); }
                if (!fileUriPath(uri, path)) {
                    // "Resource not found" from every server that has none by this uri.
                    import code.mcp : readMcpResource;
                    auto had = readMcpResource(o.mcp, uri, content, why);
                    if (had == 0) {
                        put(`,"error":{"code":-32603,"message":"no MCP server of the session reads `); putEscaped(r, uri);
                        put(`","data":`); put(why.slice()); put(`}}`);
                        return true;
                    }
                    if (had < 0) {
                        put(`,"error":{"code":-32603,"message":"`); putEscaped(r, uri); put(` holds no text to give the model"}}`);
                        return true;
                    }
                    text.add("\n\n"); text.add(links.slice()[nameFrom .. nameTo]);
                    text.add(" ("); text.add(uri); text.add("):\n"); text.add(content.slice());
                    continue;
                }
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
            // Each embedded resource's text after the linked ones', under its uri.
            for (size_t at_ = 0, from = 0, field = 0, uriFrom = 0, uriTo = 0; at_ < embedded.len; at_++) {
                if (embedded.slice()[at_] != '\0') continue;
                if (field++ % 2 == 0) { uriFrom = from; uriTo = at_; from = at_ + 1; continue; }
                text.add("\n\n"); text.add(embedded.slice()[uriFrom .. uriTo]); text.add(":\n");
                text.add(embedded.slice()[from .. at_]);
                from = at_ + 1;
            }
            // "Commands are included as regular user messages in prompt
            // requests": one the turn starts with asks the model what its
            // prompt gives, in place of what was typed; linked files follow.
            Command command;
            scope(exit) command.dispose();
            const(char)[] input;
            if (commandOf(o.mcp, text.slice()[0 .. typedLen], command, input)) {
                import code.mcp : getMcpPrompt;
                import libmcp : mcp_response, mcp_error, mcp_status, mcp_response_free, mcp_status_string;
                import core.stdc.string : strlen;
                if (command.required && input.length == 0) {
                    put(`,"error":{"code":-32602,"message":"`); putEscaped(r, command.full.slice());
                    put(` needs input: `); putEscaped(r, command.hint.slice()); put(`"}}`);
                    return true;
                }
                Reply args;
                scope(exit) args.dispose();
                args.add("{");
                if (command.argument.len > 0 && input.length > 0) {
                    args.add(`"`); putEscaped(args, command.argument.slice()); args.add(`":"`); putEscaped(args, input); args.add(`"`);
                }
                args.add("}\0");
                command.server.add("\0"); command.prompt.add("\0");
                mcp_response got;
                mcp_error failed;
                scope(exit) mcp_response_free(&got);
                auto status = getMcpPrompt(o.mcp, command.server.slice().ptr, command.prompt.slice().ptr, args.slice().ptr, got, failed);
                if (status != mcp_status.MCP_OK) {
                    put(`,"error":{"code":-32603,"message":"`); putEscaped(r, command.full.slice());
                    put(` could not be had from its server","data":{"status":"`);
                    auto st = mcp_status_string(status); putEscaped(r, st[0 .. strlen(st)]);
                    put(`","message":"`); if (failed.message !is null) putEscaped(r, failed.message[0 .. strlen(failed.message)]);
                    put(`","response":"`); if (got.json !is null) putEscaped(r, got.json[0 .. got.length]); put(`"}}}`);
                    return true;
                }
                Reply why, given;
                scope(exit) { why.dispose(); given.dispose(); }
                auto read = promptMessages(got.json[0 .. got.length], given, why);
                if (read == -1) {
                    put(`,"error":{"code":-32603,"message":"`); putEscaped(r, command.full.slice());
                    put(` gives a message ground code cannot ask the model: `); putEscaped(r, why.slice()); put(`"}}`);
                    return true;
                }
                if (read < 0) {
                    put(`,"error":{"code":-32603,"message":"`); putEscaped(r, command.full.slice());
                    put(` gave no messages","data":"`); putEscaped(r, got.json[0 .. got.length]); put(`"}}`);
                    return true;
                }
                if (o.history.len > 0 && given.len > 0) o.history.add(",");
                o.history.add(given.slice());
                if (text.len > typedLen) userMessage(*o.history, text.slice()[typedLen .. $]);
            } else userMessage(*o.history, text.slice());
            if (!toolsOf(o.mcp, tools, detail)) {
                put(`,"error":{"code":-32603,"message":"a session tool would not read","data":`); put(detail.slice()); put(`}}`);
                return true;
            }
            if (sessions.clientWritesFiles) putWriteTool(tools);
            if (sessions.clientRunsCommands) putRunTool(tools);
            url.add(qntxNode.gateway.length > 0 ? qntxNode.gateway : qntxNode.url); url.add(GATEWAY_PATH);
            // One token: what ground code signed in to q with, ~/.qntx/token. The block's file is k's.
            auto token = qntxToken("");
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
                    // "Authentication required": the node did not take the token, and a sign-in gives it one it does.
                    put(listed.status == 401 ? `,"error":{"code":-32000,"message":"the node did not accept ground code's sign-in","data":{"url":"`
                        : `,"error":{"code":-32603,"message":"the gateway's models list did not answer","data":{"url":"`);
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
                    put(http.status == 401 ? `,"error":{"code":-32000,"message":"the node did not accept ground code's sign-in","data":{"url":"`
                        : `,"error":{"code":-32603,"message":"the gateway did not answer the prompt","data":{"url":"`);
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
                    if (!putChunk(u, 1, c.reasoning) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                if (c.content.length > 0) {
                    Reply u;
                    scope(exit) u.dispose();
                    if (!putChunk(u, 0, c.content) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                // "Context window and cost update for a session": what the
                // conversation holds now, of the model's window.
                if (c.hasUsage) {
                    Reply u, amount;
                    scope(exit) { u.dispose(); amount.dispose(); }
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
                        putAmount(amount, total);
                    }
                    if (!usageUpdate(u, c.used, sessions.contextSize, c.hasCost ? amount.slice() : null) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                }
                // "max_tokens": the answer was cut off at the model's token
                // limit. The calls it asked for are not run, and the history
                // says so, so the next turn is one the gateway still takes.
                if (c.finish == "length") {
                    foreach (i; 0 .. c.callCount)
                        toolMessage(*o.history, c.calls[i].id, `{"status":"not run","why":"the answer asking for it was cut off at the model's token limit"}`);
                    putStop(r, acp_stop_reason.ACP_STOP_MAX_TOKENS);
                    return true;
                }
                if (c.callCount == 0) { putStop(r, acp_stop_reason.ACP_STOP_END_TURN); return true; }
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
                    bool own = call.name == WRITE_TOOL && sessions.clientWritesFiles;
                    bool runs = call.name == RUN_TOOL && sessions.clientRunsCommands;
                    auto verdict = verdictOf(*o, call.name, readOnlyTool(o.mcp, call.name), own, why);
                    // "Agents SHOULD include it in the first report when available
                    // and SHOULD NOT change it later": the name the model called,
                    // here and in no update after.
                    // "Helps clients choose appropriate icons and UI
                    // treatment": read, when the tool's annotations say it only reads.
                    // edit, for ground code's own write:
                    // "Modifying files or content."
                    // execute, for ground code's own command:
                    // "Running commands or code."
                    auto kind = own ? "edit" : runs ? "execute" : readOnlyTool(o.mcp, call.name) ? "read" : null;
                    auto callStatus = verdict == Verdict.run ? "in_progress" : "pending";
                    if (!putToolCall(u, false, call.id, call.name, call.name, kind, callStatus, call.arguments, null) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
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
                            if (!putToolCall(u, true, call.id, null, null, null, "in_progress", null, null) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                        }
                    }
                    // Not run: the model is told why, and so is the client.
                    if (verdict == Verdict.refuse) {
                        Reply refused;
                        scope(exit) refused.dispose();
                        refused.add(`{"status":"not run","why":"`); putEscaped(refused, why); refused.add(`"}`);
                        toolMessage(*o.history, call.id, refused.slice());
                        u.len = 0;
                        if (!putToolCall(u, true, call.id, null, null, null, "failed", null, refused.slice()) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
                        continue;
                    }
                    bool ok;
                    Reply shown; // the terminal the call shows, when it ran a command
                    scope(exit) shown.dispose();
                    if (own) {
                        // What the client answered is what the call answered.
                        Reply asking;
                        scope(exit) asking.dispose();
                        auto wrote = writeThroughClient(sessions, turn, sid, call.arguments, result, asking);
                        if (wrote < 0) {
                            foreach (j; i .. c.callCount)
                                toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"ground code could not ask the client"}`);
                            put(`,"error":{"code":-32603,"message":"ground code could not ask the client to write the file","data":`);
                            put(asking.slice()); put(`}}`);
                            return true;
                        }
                        if (wrote == 2) result.add(`{"status":"cancelled","why":"the client cancelled the turn while it was asked to write the file"}`);
                        ok = wrote == 1 && clientWrote(result.slice());
                    } else if (runs) {
                        // What the command printed, and how it exited, is what the call answered.
                        Reply asking;
                        scope(exit) asking.dispose();
                        auto ran = runThroughClient(sessions, turn, sid, o.cwd[0 .. o.cwdLen], call.id, call.arguments, result, ok, shown, asking);
                        if (ran < 0) {
                            foreach (j; i .. c.callCount)
                                toolMessage(*o.history, c.calls[j].id, `{"status":"not run","why":"ground code could not ask the client"}`);
                            put(`,"error":{"code":-32603,"message":"ground code could not ask the client to run the command","data":`);
                            put(asking.slice()); put(`}}`);
                            return true;
                        }
                    } else {
                        server.add(serverOf(call.name)); server.add("\0");
                        tool.add(toolOf(call.name)); tool.add("\0");
                        args.add(call.arguments); args.add("\0");
                        import libmcp : mcp_response, mcp_error, mcp_status, mcp_response_free, mcp_status_string;
                        import core.stdc.string : strlen;
                        mcp_response response, validation;
                        mcp_error error;
                        scope(exit) { mcp_response_free(&response); mcp_response_free(&validation); }
                        // A cancel that arrives while the call runs cancels it at the server:
                        // "Abort all tool call invocations in progress"
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
                        ok = status == mcp_status.MCP_OK;
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
                    }
                    toolMessage(*o.history, call.id, result.slice());
                    u.len = 0;
                    // What the tool call produced, as MCP gave it, is its content.
                    if (!putToolCall(u, true, call.id, null, null, null, ok ? "completed" : "failed", null, result.slice(),
                            shown.len > 0 ? shown.slice() : null) || !notify(sid, u.slice())) { put(`,"error":{"code":-32603,"message":"could not write session/update"}}`); return true; }
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
    // "so give it a config per ground per node"
    // An engine built from the floor names no node: nodes.pbt beside the store does.
    if (sessions.node.url.length == 0) {
        import nodeconfig : NodeConfig, loadNodes;
        __gshared NodeConfig nodes;
        loadNodes(nodes);
        if (nodes.why().length > 0) {
            fwrite(nodes.why().ptr, 1, nodes.why().length, stderr);
            fputs("\n", stderr);
            return 1;
        }
        if (nodes.count > 1) {
            fputs("ground code: nodes.pbt names more than one node, and which one ground code prompts through is not decided\n", stderr);
            return 1;
        }
        if (nodes.count == 1) {
            sessions.node.present = true;
            sessions.node.url = cast(string) nodes.nodes[0].url;
            sessions.node.token = cast(string) nodes.nodes[0].token;
            sessions.node.model = cast(string) nodes.nodes[0].model;
            sessions.node.gateway = cast(string) nodes.nodes[0].gateway;
        }
    }
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
        // What follows the answer, now that it is the client's.
        if (sessions.after.len > 0) {
            auto after = sessions.after.slice();
            bool written = !sessions.after.full && fwrite(after.ptr, 1, after.length, stdout) == after.length && fflush(stdout) == 0;
            sessions.after.len = 0;
            if (!written) { fputs("ground code: failed writing what follows an ACP response\n", stderr); result = 1; break; }
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
