module finish_test;

// Why the model stopped, as the gateway says it in finish_reason: "tool_calls",
// "stop", "length", "content_filter", "error" (OpenRouter's
// ChatFinishReasonEnum), each made the stop reason ACP has for it.

import code;
import code.reply : Reply;
import matcher : indexOf;

version (Posix):

import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.signal : kill, SIGKILL;

private string digits()(size_t n) {
    string s;
    do { s = cast(char)('0' + n % 10) ~ s; n /= 10; } while (n);
    return s;
}

private enum completion(string finish, string content) = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    ~ digits(sayingOf!(finish, content).length) ~ "\r\nConnection: close\r\n\r\n" ~ sayingOf!(finish, content);
private enum sayingOf(string finish, string content) =
    `{"choices":[{"finish_reason":"` ~ finish ~ `","message":{"role":"assistant","content":"` ~ content ~ `"}}]}`;

// A gateway that answers each request in turn with the next of answers.
private struct Gateway {
    int pid;
    char[32] urlBuf;
    size_t urlLen;
    const(char)[] url() return { return urlBuf[0 .. urlLen]; }
}

private Gateway gateway(string[] answers...) {
    Gateway g;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 8) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        import core.sys.posix.unistd : alarm;
        alarm(30);
        foreach (said; answers) {
            auto c = accept(fd, null, null);
            char[65536] got;
            size_t have = 0;
            while (have < got.length) {
                auto k = read(c, got.ptr + have, got.length - have);
                if (k <= 0) break;
                have += cast(size_t) k;
                if (indexOf(got[0 .. have], `"messages"`) >= 0 && got[have - 1] == '}') break;
            }
            write(c, said.ptr, said.length);
            close(c);
        }
        _exit(0);
    }
    close(fd);
    g.pid = child;
    ushort port = htons(a.sin_port);
    foreach (ch; "http://127.0.0.1:") g.urlBuf[g.urlLen++] = ch;
    char[8] d; size_t k = 0;
    do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
    while (k) g.urlBuf[g.urlLen++] = d[--k];
    return g;
}

// One prompt, its updates to stdout thrown away; the answer into r.
private void prompt(ref Sessions s, string text, ref Reply r) {
    import core.stdc.stdio : fflush, stdout;
    import core.sys.posix.fcntl : open, O_WRONLY;
    int[2] p;
    assert(pipe(p) == 0);
    Input input = Input(p[0]);
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); s.input = null; }
    fflush(stdout);
    auto saved = dup(1);
    auto sink = open("/dev/null", O_WRONLY);
    dup2(sink, 1);
    r.len = 0;
    Reply line;
    scope(exit) line.dispose();
    line.add(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"`);
    line.add(text); line.add(`"}]}}`);
    code.answer(line.slice(), r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(sink);
}

private void opened(ref Sessions s, string url) {
    import db : sqlite3, sqlite3_open, applySchema, SQLITE_OK;
    s.clock = 1_700_000_000;
    s.node.url = url; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    Reply r;
    scope(exit) r.dispose();
    code.answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s);
    assert(indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0);
}

// "refusal": "The turn ended because the agent refused to continue. The user
// prompt and everything that comes after it won't be included in the next
// prompt": the stop reason is refusal, and the conversation, kept and stored,
// is what it was before the prompt.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import code.store : storeHistoryOf;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope(exit) sqlite3_close(db);
    auto g = gateway(completion!("stop", "hello"), completion!("content_filter", ""));
    scope(exit) { kill(g.pid, SIGKILL); waitpid(g.pid, null, 0); }
    Sessions s = Sessions(100, 7);
    s.db = db;
    opened(s, cast(string) g.url);
    Reply r;
    scope(exit) r.dispose();
    prompt(s, "hi", r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    enum before = `{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}`;
    assert(s.open[0].history.slice() == before);
    prompt(s, "something refused", r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"refusal"}}`);
    assert(s.open[0].history.slice() == before);
    Reply kept;
    scope(exit) kept.dispose();
    assert(storeHistoryOf(db, "code-100-7-1", kept) == 1);
    assert(kept.slice() == before);
    s.open[0].history.dispose();
}

// "error": the gateway says the model's answer failed. That is no end of a
// turn: it is an error carrying the gateway's answer, and the failed answer is
// not kept, so the next turn is not built on it.
unittest {
    auto g = gateway(completion!("error", "half an"));
    scope(exit) { kill(g.pid, SIGKILL); waitpid(g.pid, null, 0); }
    Sessions s = Sessions(100, 7);
    opened(s, cast(string) g.url);
    Reply r;
    scope(exit) r.dispose();
    prompt(s, "hi", r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the gateway says the model's answer ended in error","data":`
        ~ sayingOf!("error", "half an") ~ `}}`);
    assert(s.open[0].history.slice() == `{"role":"user","content":"hi"}`);
    s.open[0].history.dispose();
}

// What a refused answer cost is the session's all the same: the gateway
// charged for it, whatever the conversation keeps of it.
unittest {
    enum refused = `{"choices":[{"finish_reason":"content_filter","message":{"role":"assistant","content":""}}],`
        ~ `"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11,"cost":0.0002}}`;
    enum reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " ~ digits(refused.length)
        ~ "\r\nConnection: close\r\n\r\n" ~ refused;
    auto g = gateway(reply);
    scope(exit) { kill(g.pid, SIGKILL); waitpid(g.pid, null, 0); }
    Sessions s = Sessions(100, 7);
    opened(s, cast(string) g.url);
    Reply r;
    scope(exit) r.dispose();
    prompt(s, "hi", r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"refusal"}}`);
    assert(s.open[0].costNano == 200_000);
    assert(s.open[0].history.len == 0);
    if (s.open[0].history !is null) s.open[0].history.dispose();
}
