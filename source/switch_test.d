module switch_test;

// Session Modes, "Exiting plan modes": "A common case where an Agent might switch modes is from
// within a special "exit mode" tool that can be provided to the language model during plan/architect
// modes. The language model can call this tool when it determines it's ready to start implementing a
// solution. This "switch mode" tool will usually request permission before running". "When an option
// is chosen, the tool runs, setting the mode and sending the current_mode_update notification".

import code;
import code.prompt : putSwitchTool, replayHistory, SWITCH_TOOL;
import code.reply : Reply;
import matcher : indexOf;
import sessionmode : SessionMode;

// The tool, as the model is offered it in plan mode, in the spec's words.
unittest {
    Reply tools;
    scope(exit) tools.dispose();
    putSwitchTool(tools);
    assert(tools.slice() == `{"type":"function","function":{"name":"switch_mode","description":"Call this when you determine you are ready `
        ~ `to start implementing a solution: it asks the user to leave plan mode.","parameters":{"type":"object","properties":{`
        ~ `"plan":{"type":"string","description":"The plan to implement, shown to the user as they are asked."}},"required":["plan"]}}}`);
    assert(SWITCH_TOOL == "switch_mode");
}

// A turn in mode whose model calls switch_mode with args, then answers "done"; the client answers
// what queued holds. What ground code said, what the gateway was first asked, the turn's answer,
// the model's history, and the session's mode after.
version (Posix) private struct Ran {
    Reply said, asked, answered, history;
    SessionMode mode;
    void dispose() { said.dispose(); asked.dispose(); answered.dispose(); history.dispose(); }
}

version (Posix) private void switchTurn(const(char)[] mode, const(char)[] args, const(char)[] queued, ref Ran ran) {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2, alarm;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;

    enum http = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    enum done = http ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    Reply calls;
    scope(exit) calls.dispose();
    calls.add(http);
    calls.add(`{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`);
    calls.add(`{"id":"s1","type":"function","function":{"name":"switch_mode","arguments":"`); calls.add(args); calls.add(`"}}]}}]}`);
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 2) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    int[2] first;
    assert(pipe(first) == 0);
    auto child = fork();
    if (child == 0) {
        alarm(30);
        close(first[0]);
        char[65536] got;
        size_t have = 0;
        auto c = accept(fd, null, null);
        while (have < got.length) {
            auto k = read(c, got.ptr + have, got.length - have);
            if (k <= 0) break;
            have += cast(size_t) k;
            if (indexOf(got[0 .. have], `"messages"`) >= 0 && got[have - 1] == '}') break;
        }
        write(first[1], got.ptr, have);
        close(first[1]);
        write(c, calls.slice().ptr, calls.len);
        close(c);
        c = accept(fd, null, null);
        read(c, got.ptr, got.length);
        write(c, done.ptr, done.length);
        close(c);
        _exit(0);
    }
    close(fd);
    close(first[1]);
    __gshared char[32] urlBuf;
    ushort port = htons(a.sin_port);
    size_t len = 0;
    foreach (ch; "http://127.0.0.1:") urlBuf[len++] = ch;
    char[8] d; size_t k = 0;
    do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
    while (k) urlBuf[len++] = d[--k];

    int[2] p;
    assert(pipe(p) == 0);
    Input input = Input(p[0]);
    Sessions s = Sessions(100, 7); s.initialized = true; s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
    assert(write(p[1], queued.ptr, queued.length) == queued.length);
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    Reply r, set;
    scope(exit) { r.dispose(); set.dispose(); }
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
    set.add(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"`); set.add(mode); set.add(`"}}`);
    answer(set.slice(), r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"plan it"}]}}`, r, s);
    ran.answered.add(r.slice());
    ran.history.add(s.open[0].history.slice());
    ran.mode = s.open[0].mode;
    s.open[0].history.dispose();
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    char[4096] buf;
    while (true) {
        auto got = read(o[0], buf.ptr, buf.length);
        if (got <= 0) break;
        ran.said.add(buf[0 .. cast(size_t) got]);
    }
    close(o[0]);
    while (true) {
        auto got = read(first[0], buf.ptr, buf.length);
        if (got <= 0) break;
        ran.asked.add(buf[0 .. cast(size_t) got]);
    }
    close(first[0]);
}

enum PLAN = `{\"plan\":\"## Implementation Plan\"}`;
enum CHOSE_DEFAULT = `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"selected","optionId":"default"}}}` ~ "\n";

// In plan mode the model is offered switch_mode. Its call is shown as a switch_mode tool call whose
// content is the plan, and asked as the spec's example asks: each option a mode, or staying in plan.
// The user chose Manual: the mode is set, kept, and told as current_mode_update and, as the session
// offers the mode as a config option too, "Agents SHOULD keep both in sync", as config_option_update.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    switchTurn("plan", PLAN, CHOSE_DEFAULT, ran);
    assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(ran.asked.slice(), `{"type":"function","function":{"name":"switch_mode",`) >= 0);
    auto said = ran.said.slice();
    assert(indexOf(said, `{"sessionUpdate":"tool_call","toolCallId":"s1","title":"Ready for implementation","name":"switch_mode",`
        ~ `"kind":"switch_mode","status":"pending","rawInput":{"plan":"## Implementation Plan"},`
        ~ `"content":[{"type":"content","content":{"type":"text","text":"## Implementation Plan"}}]}`) >= 0);
    assert(indexOf(said, `"method":"session/request_permission","params":{"sessionId":"code-100-7-1","toolCall":{"toolCallId":"s1",`
        ~ `"title":"Ready for implementation","name":"switch_mode","kind":"switch_mode","status":"pending",`
        ~ `"rawInput":{"plan":"## Implementation Plan"},"content":[{"type":"content","content":{"type":"text","text":"## Implementation Plan"}}]},`
        ~ `"options":[{"optionId":"bypassPermissions","name":"Yes, and auto-accept all actions","kind":"allow_always"},`
        ~ `{"optionId":"default","name":"Yes, and manually accept actions","kind":"allow_once"},`
        ~ `{"optionId":"reject","name":"No, stay in plan mode","kind":"reject_once"}]}}`) >= 0);
    assert(indexOf(said, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`
        ~ `{"sessionUpdate":"current_mode_update","currentModeId":"default"}}}`) >= 0);
    assert(indexOf(said, `{"sessionUpdate":"config_option_update","configOptions":[{"id":"mode",`) >= 0);
    assert(indexOf(said, `"type":"select","currentValue":"default"`) >= 0);
    assert(indexOf(said, `{"sessionUpdate":"tool_call_update","toolCallId":"s1","status":"completed"`) >= 0);
    assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"s1","content":"{\"currentModeId\":\"default\"}"}`) >= 0);
    assert(ran.mode == SessionMode.manual);
}

// "No, stay in plan mode": the mode stays, nothing is told of it, and the model is told it was not run.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    switchTurn("plan", PLAN, `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"selected","optionId":"reject"}}}` ~ "\n", ran);
    assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    auto said = ran.said.slice();
    assert(indexOf(said, `current_mode_update`) < 0 && indexOf(said, `config_option_update`) < 0);
    assert(indexOf(said, `{"sessionUpdate":"tool_call_update","toolCallId":"s1","status":"failed"`) >= 0);
    assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"s1","content":"{\"status\":\"not run\",\"why\":\"the user stays in plan mode\"}"}`) >= 0);
    assert(ran.mode == SessionMode.plan);
}

// Cancelled while asked: the turn is cancelled, and the mode stays.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    switchTurn("plan", PLAN, `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"cancelled"}}}` ~ "\n", ran);
    assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}`);
    assert(indexOf(ran.said.slice(), `current_mode_update`) < 0);
    assert(ran.mode == SessionMode.plan);
}

// Outside plan mode the tool is not offered, and a call to it anyway is not run, shown nor asked.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    switchTurn("default", PLAN, "", ran);
    assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(ran.asked.slice(), `"name":"switch_mode"`) < 0);
    assert(indexOf(ran.said.slice(), `"toolCallId":"s1"`) < 0 && indexOf(ran.said.slice(), `session/request_permission`) < 0);
    assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"s1","content":"{\"status\":\"not run\",\"why\":\"switch_mode leaves plan mode, and the session is not in it\"}"}`) >= 0);
    assert(ran.mode == SessionMode.manual);
}

// A call that names no plan, as text, is not asked: the model is told what the tool takes.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    switchTurn("plan", `{\"plan\":7}`, "", ran);
    assert(indexOf(ran.said.slice(), `session/request_permission`) < 0);
    assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"s1","content":"{\"status\":\"not run\",\"why\":\"switch_mode takes plan, text\"}"}`) >= 0);
    assert(ran.mode == SessionMode.plan);
}

// Told back on session/load as it came out live: a switch the user chose completed, one they
// rejected failed.
unittest {
    Reply told;
    scope(exit) told.dispose();
    bool send(const(char)[] u) { told.add(u); told.add("\n"); return true; }
    enum call = `{"role":"assistant","content":null,"tool_calls":[{"id":"s1","type":"function","function":{"name":"switch_mode",`
        ~ `"arguments":"{\"plan\":\"Fix it\"}"}}]},`;
    assert(replayHistory(call ~ `{"role":"tool","tool_call_id":"s1","content":"{\"currentModeId\":\"default\"}"}`, &send));
    assert(indexOf(told.slice(), `{"sessionUpdate":"tool_call_update","toolCallId":"s1","status":"completed"`) >= 0);
    told.len = 0;
    assert(replayHistory(call ~ `{"role":"tool","tool_call_id":"s1","content":"{\"status\":\"not run\",\"why\":\"the user stays in plan mode\"}"}`, &send));
    assert(indexOf(told.slice(), `{"sessionUpdate":"tool_call_update","toolCallId":"s1","status":"failed"`) >= 0);
}
