module plan_test;

// Agent Plan: "When the language model creates an execution plan, the Agent SHOULD report it to the
// Client". ground code offers the model a plan tool, ACP's Plan in the schema's words; a call to it is
// reported as the plan, "sessionUpdate": "plan", in every mode, and told again on session/load.

import code;
import code.prompt : putPlanTool, replayHistory, PLAN_TOOL;
import code.reply : Reply;
import matcher : indexOf;

// The tool, as the model is offered it: Plan, its entries, and each PlanEntry's fields.
unittest {
    Reply tools;
    scope(exit) tools.dispose();
    putPlanTool(tools);
    assert(tools.slice() == `{"type":"function","function":{"name":"plan","description":"An execution plan for accomplishing complex tasks.\n\n`
        ~ `Plans consist of multiple entries representing individual tasks or goals.\n`
        ~ `Agents report plans to clients to provide visibility into their execution strategy.\n`
        ~ `Plans can evolve during execution as the agent discovers new requirements or completes tasks.",`
        ~ `"parameters":{"type":"object","properties":{"entries":{"type":"array","description":"The list of tasks to be accomplished.\n\n`
        ~ `When updating a plan, the agent must send a complete list of all entries\nwith their current status. The client replaces the entire plan with each update.",`
        ~ `"items":{"type":"object","properties":{`
        ~ `"content":{"type":"string","description":"Human-readable description of what this task aims to accomplish."},`
        ~ `"priority":{"type":"string","enum":["high","medium","low"],"description":"The relative importance of this task.\nUsed to indicate which tasks are most critical to the overall goal."},`
        ~ `"status":{"type":"string","enum":["pending","in_progress","completed"],"description":"Current execution status of this task."}},`
        ~ `"required":["content","priority","status"]}}},"required":["entries"]}}}`);
    assert(PLAN_TOOL == "plan");
}

// Told again on session/load as the plan it was, in its place, and neither its call nor its answer as
// a tool call.
unittest {
    Reply told;
    scope(exit) told.dispose();
    bool send(const(char)[] u) { told.add(u); told.add("\n"); return true; }
    assert(replayHistory(`{"role":"user","content":"fix it"},`
        ~ `{"role":"assistant","content":null,"tool_calls":[{"id":"p1","type":"function","function":{"name":"plan",`
        ~ `"arguments":"{\"entries\":[{\"content\":\"Read\",\"priority\":\"high\",\"status\":\"in_progress\"}]}"}}]},`
        ~ `{"role":"tool","tool_call_id":"p1","content":"{}"},`
        ~ `{"role":"assistant","content":"on it"}`, &send));
    assert(told.slice() ==
          `{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"fix it"}}` ~ "\n"
        ~ `{"sessionUpdate":"plan","entries":[{"content":"Read","priority":"high","status":"in_progress"}]}` ~ "\n"
        ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"on it"}}` ~ "\n");
}

// A plan call is told back as it came out live, by its answer: a refused plan as the warning the
// user was given, and one that never ran, cut short by a cancel, as the call it was, not as a plan.
unittest {
    Reply told;
    scope(exit) told.dispose();
    bool send(const(char)[] u) { told.add(u); told.add("\n"); return true; }
    enum call = `{"role":"assistant","content":null,"tool_calls":[{"id":"p1","type":"function","function":{"name":"plan",`
        ~ `"arguments":"{\"entries\":[{\"content\":\"Read\",\"priority\":\"urgent\",\"status\":\"pending\"}]}"}}]},`;
    // PLAN_REFUSED, as the history holds it: a JSON string.
    enum refused = call ~ `{"role":"tool","tool_call_id":"p1","content":"{\"status\":\"not run\",\"why\":\"plan takes entries, `
        ~ `each a content, a priority (high, medium or low) and a status (pending, in_progress or completed)\"}"}`;
    assert(replayHistory(refused, &send));
    assert(told.slice() == `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"the model's plan is not one ACP can report: `
        ~ `{\"entries\":[{\"content\":\"Read\",\"priority\":\"urgent\",\"status\":\"pending\"}]}\n"}}` ~ "\n");
    told.len = 0;
    enum ran = `{"role":"assistant","content":null,"tool_calls":[{"id":"p2","type":"function","function":{"name":"plan",`
        ~ `"arguments":"{\"entries\":[{\"content\":\"Read\",\"priority\":\"high\",\"status\":\"pending\"}]}"}}]},`;
    assert(replayHistory(ran ~ `{"role":"tool","tool_call_id":"p2","content":"{\"status\":\"not run\",\"why\":\"the client cancelled the turn\"}"}`, &send));
    assert(indexOf(told.slice(), `"sessionUpdate":"plan"`) < 0);
    assert(indexOf(told.slice(), `{"sessionUpdate":"tool_call","toolCallId":"p2","title":"plan","name":"plan"`) >= 0);
    assert(indexOf(told.slice(), `{"sessionUpdate":"tool_call_update","toolCallId":"p2","status":"failed"`) >= 0);
}

// A turn in mode whose model calls plan with args, then answers "done": what ground code said, what
// the gateway was first asked, and the turn's answer.
version (Posix) private struct Ran {
    Reply said, asked, answered, history;
    void dispose() { said.dispose(); asked.dispose(); answered.dispose(); history.dispose(); }
}

version (Posix) private void planTurn(const(char)[] mode, const(char)[] args, ref Ran ran) {
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
    calls.add(`{"id":"p1","type":"function","function":{"name":"plan","arguments":"`); calls.add(args); calls.add(`"}}]}}]}`);
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
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
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
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"fix it"}]}}`, r, s);
    ran.answered.add(r.slice());
    ran.history.add(s.open[0].history.slice());
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

enum ENTRIES = `{\"entries\":[{\"content\":\"Read the code\",\"priority\":\"high\",\"status\":\"completed\"},`
    ~ `{\"content\":\"Fix it\",\"priority\":\"medium\",\"status\":\"in_progress\"}]}`;
enum REPORTED = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":{"sessionUpdate":"plan","entries":[`
    ~ `{"content":"Read the code","priority":"high","status":"completed"},{"content":"Fix it","priority":"medium","status":"in_progress"}]}}}`;

// The model is offered plan; its plan is reported, and is no tool call. The plan touches nothing, so
// no permission is asked, in the mode that asks of every other call nor in plan mode, which runs only
// what reads. The model is answered {}, as the client answers nothing to a plan.
version (Posix) unittest {
    foreach (mode; ["default", "plan"]) {
        Ran ran;
        scope(exit) ran.dispose();
        planTurn(mode, ENTRIES, ran);
        assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
        assert(indexOf(ran.asked.slice(), `{"type":"function","function":{"name":"plan","description":"An execution plan`) >= 0);
        assert(indexOf(ran.said.slice(), REPORTED) >= 0);
        assert(indexOf(ran.said.slice(), `"toolCallId":"p1"`) < 0);
        assert(indexOf(ran.said.slice(), `session/request_permission`) < 0);
        assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"p1","content":"{}"}`) >= 0);
    }
}

// A plan that is not one, an entry missing its status here, is not reported: the model is told what
// a plan takes, and the user is told the model's plan was not reported, with what it gave.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    planTurn("default", `{\"entries\":[{\"content\":\"Fix it\",\"priority\":\"high\"}]}`, ran);
    assert(ran.answered.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(ran.said.slice(), `"sessionUpdate":"plan"`) < 0);
    // A client that takes no notices is told in the agent's message.
    assert(indexOf(ran.said.slice(), `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"the model's plan is not one ACP can report: `
        ~ `{\"entries\":[{\"content\":\"Fix it\",\"priority\":\"high\"}]}\n"}}`) >= 0);
    assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"p1","content":"{\"status\":\"not run\",\"why\":\"plan takes entries, `
        ~ `each a content, a priority (high, medium or low) and a status (pending, in_progress or completed)\"}"}`) >= 0);
}
