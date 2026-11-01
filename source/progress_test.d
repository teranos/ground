module progress_test;

// "As tools execute, Agents send updates to report progress and results." An MCP tool call asks its
// server for progress, its _meta.progressToken the call's id; each progress the server reports with
// a message is a tool_call_update whose content is that message, while the call runs. Progress
// without a message says nothing to show, so nothing is sent for it.

import code;
import code.reply : Reply;
import matcher : indexOf;

version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2, getcwd, alarm;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    enum ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    enum calls = ok ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"test__count","arguments":"{}"}}]}}]}`;
    enum done = ok ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 2) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        alarm(30);
        char[65536] got;
        auto c = accept(fd, null, null); read(c, got.ptr, got.length); write(c, calls.ptr, calls.length); close(c);
        c = accept(fd, null, null); read(c, got.ptr, got.length); write(c, done.ptr, done.length); close(c);
        _exit(0);
    }
    close(fd);
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
    Reply req, r;
    scope(exit) { req.dispose(); r.dispose(); }
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"/usr/bin/env","args":["python3","`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/progress_server.py"],"env":[]}]}}`);
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    answer(req.slice(), r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"bypassPermissions"}}`, r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"count"}]}}`, r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    Reply closed;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
    Reply said;
    scope(exit) said.dispose();
    char[4096] buf;
    while (true) {
        auto got = read(o[0], buf.ptr, buf.length);
        if (got <= 0) break;
        said.add(buf[0 .. cast(size_t) got]);
    }
    close(o[0]);
    auto out_ = said.slice();
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    // The server was asked for progress on the call's own id.
    enum completed = `{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"`;
    assert(indexOf(out_, `"text":"token \"c1\""`) >= 0);
    // Each progress with a message, as the call runs: after it is in progress, before it completes.
    // Only what changed is sent: the content, "Replace the content collection".
    enum first = `{"sessionUpdate":"tool_call_update","toolCallId":"c1","content":[{"type":"content","content":{"type":"text","text":"counted 1 of 3"}}]}`;
    enum third = `{"sessionUpdate":"tool_call_update","toolCallId":"c1","content":[{"type":"content","content":{"type":"text","text":"counted 3 of 3"}}]}`;
    auto running = indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c1"`);
    assert(running >= 0);
    assert(indexOf(out_, first) > running);
    assert(indexOf(out_, third) > indexOf(out_, first));
    assert(indexOf(out_, completed) > indexOf(out_, third));
    // The progress without a message sent nothing: two progress updates, no more.
    size_t updates = 0;
    for (ptrdiff_t at = 0, from = 0; (at = indexOf(out_[cast(size_t) from .. $], `"toolCallId":"c1","content"`)) >= 0; from += at + 1) updates++;
    assert(updates == 2);
    s.open[0].history.dispose();
}
