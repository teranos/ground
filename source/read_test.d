module read_test;

// File System, "Reading files": "The `fs/read_text_file` method allows Agents to read text file
// contents from the Client's filesystem, including unsaved changes in the editor." ground code offers
// the model read_text_file, the request in the schema's words, when the client offers fs.readTextFile;
// a call to it reads through the client, what it read the call's content, the client's answer the
// model's.

import code;
import code.prompt : putReadTool, READ_TOOL;
import code.reply : Reply;
import matcher : indexOf;

// The tool, as the model is offered it: ReadTextFileRequest's path, line and limit.
unittest {
    Reply tools;
    scope(exit) tools.dispose();
    putReadTool(tools);
    assert(tools.slice() == `{"type":"function","function":{"name":"read_text_file","description":"Request to read content from a text file.",`
        ~ `"parameters":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to read."},`
        ~ `"line":{"type":"integer","minimum":0,"maximum":4294967295,"description":"Line number to start reading from (1-based)."},`
        ~ `"limit":{"type":"integer","minimum":0,"maximum":4294967295,"description":"Maximum number of lines to read."}},"required":["path"]}}}`);
    assert(READ_TOOL == "read_text_file");
}

version (Posix) private struct Ran {
    Reply said, asked, answered, history;
    void dispose() { said.dispose(); asked.dispose(); answered.dispose(); history.dispose(); }
}

// A turn in mode, the client offering caps, whose model calls read_text_file with args and then
// answers "done"; the client sends queued once the model has called.
version (Posix) private void readTurn(const(char)[] caps, const(char)[] mode, const(char)[] args, const(char)[] queued, ref Ran ran) {
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
    calls.add(`{"id":"r1","type":"function","function":{"name":"read_text_file","arguments":"`); calls.add(args); calls.add(`"}}]}}]}`);
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 2) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    int[2] first, p;
    assert(pipe(first) == 0 && pipe(p) == 0);
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
        write(p[1], queued.ptr, queued.length);
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
    Reply r, init, set;
    scope(exit) { r.dispose(); init.dispose(); set.dispose(); }
    init.add(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":`); init.add(caps); init.add(`}`);
    answer(init.slice(), r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
    set.add(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"`); set.add(mode); set.add(`"}}`);
    answer(set.slice(), r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"read it"}]}}`, r, s);
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

enum READS = `{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true}}}`;
enum ENDED = `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`;
enum TEXT = `{"jsonrpc":"2.0","id":"read-1","result":{"content":"two\n"}}`;

// Offered and read: the request carries line and limit as given; the call is a read, in plan mode
// too, as reading changes nothing; what was read is its content, and the client's answer the model's.
version (Posix) unittest {
    foreach (mode; ["bypassPermissions", "plan"]) {
        Ran ran;
        scope(exit) ran.dispose();
        readTurn(READS, mode, `{\"path\":\"/tmp/a b\",\"line\":2,\"limit\":1}`, TEXT ~ "\n", ran);
        assert(ran.answered.slice() == ENDED);
        assert(indexOf(ran.asked.slice(), `{"type":"function","function":{"name":"read_text_file","description":"Request to read content from a text file."`) >= 0);
        assert(indexOf(ran.said.slice(), `{"jsonrpc":"2.0","id":"read-1","method":"fs/read_text_file","params":{"sessionId":"code-100-7-1","path":"/tmp/a b","line":2,"limit":1}}`) >= 0);
        assert(indexOf(ran.said.slice(), `{"sessionUpdate":"tool_call","toolCallId":"r1","title":"read_text_file","name":"read_text_file","kind":"read","status":"in_progress"`) >= 0);
        assert(indexOf(ran.said.slice(), `{"sessionUpdate":"tool_call_update","toolCallId":"r1","status":"completed","rawOutput":` ~ TEXT
            ~ `,"content":[{"type":"content","content":{"type":"text","text":"two\n"}}]}`) >= 0);
        assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"r1","content":"{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"result\":{\"content\":\"two\\n\"}}"}`) >= 0);
    }
}

// The whole file when the model names no line or limit.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    readTurn(READS, "bypassPermissions", `{\"path\":\"/tmp/a\"}`, TEXT ~ "\n", ran);
    assert(indexOf(ran.said.slice(), `"method":"fs/read_text_file","params":{"sessionId":"code-100-7-1","path":"/tmp/a"}}`) >= 0);
}

// The client could not read it: the call failed with the client's answer, which the model is told.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    enum missing = `{"jsonrpc":"2.0","id":"read-1","error":{"code":-32002,"message":"no such file"}}`;
    readTurn(READS, "bypassPermissions", `{\"path\":\"/tmp/nope\"}`, missing ~ "\n", ran);
    assert(ran.answered.slice() == ENDED);
    assert(indexOf(ran.said.slice(), `{"sessionUpdate":"tool_call_update","toolCallId":"r1","status":"failed","rawOutput":` ~ missing) >= 0);
    assert(indexOf(ran.history.slice(), `"content":"{\"jsonrpc\":\"2.0\",\"id\":\"read-1\",\"error\":{\"code\":-32002,\"message\":\"no such file\"}}"}`) >= 0);
}

// A path that is not absolute, or a line or limit that is no uint32, is not asked of the client.
version (Posix) unittest {
    foreach (args; [`{\"path\":\"a b\"}`, `{\"path\":\"/tmp/a\",\"line\":-1}`, `{\"path\":\"/tmp/a\",\"limit\":4294967296}`, `{\"path\":\"/tmp/a\",\"line\":\"2\"}`]) {
        Ran ran;
        scope(exit) ran.dispose();
        readTurn(READS, "bypassPermissions", args, "", ran);
        assert(ran.answered.slice() == ENDED);
        assert(indexOf(ran.said.slice(), `fs/read_text_file`) < 0);
        assert(indexOf(ran.history.slice(), `{"role":"tool","tool_call_id":"r1","content":"{\"status\":\"not run\",\"why\":\"read_text_file takes path, an absolute path, `
            ~ `and line and limit, each a whole number from 0 to 4294967295\"}"}`) >= 0);
    }
}

// "If readTextFile ... is false or not present, the Agent MUST NOT attempt to call the corresponding
// filesystem method": not offered, and a call by its name is no read.
version (Posix) unittest {
    Ran ran;
    scope(exit) ran.dispose();
    readTurn(`{"protocolVersion":1,"clientCapabilities":{"fs":{"writeTextFile":true}}}`, "bypassPermissions", `{\"path\":\"/tmp/a\"}`, "", ran);
    assert(ran.answered.slice() == ENDED);
    assert(indexOf(ran.asked.slice(), `"name":"read_text_file"`) < 0);
    assert(indexOf(ran.said.slice(), `fs/read_text_file`) < 0);
}
