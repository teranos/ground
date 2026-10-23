module code_test;

import code;
import db : versionString;

private string answerOf()(string line) {
    Sessions s = Sessions(100, 7);
    return answerWith(line, s);
}

private string answerWith()(string line, ref Sessions s) {
    Reply r;
    if (!answer(line, r, s)) return null;
    return r.slice().idup;
}

// initialize: the only required field either way is protocolVersion. ACP's is
// 1, bumped only for breaking changes; ground's own version is agentInfo's.
static assert(answerOf(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}`)
    == `{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{}}},"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// "The protocol version the client specified if supported by the agent, or the
// latest protocol version supported by the agent."
static assert(answerOf(`{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":7}}`)
    == `{"jsonrpc":"2.0","id":"a","result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{}}},"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// A method ground code does not handle is said to the client, by name.
static assert(answerOf(`{"jsonrpc":"2.0","id":3,"method":"session/load","params":{}}`)
    == `{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"ground code does not handle session/load"}}`);

// A notification has no answer to give; the caller says it on stderr instead.
static assert(answerOf(`{"jsonrpc":"2.0","method":"session/cancel","params":{}}`) is null);

// A line naming no method is not a request.
static assert(answerOf(`{"jsonrpc":"2.0","id":4}`)
    == `{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"no method"}}`);
static assert(answerOf(`not json`)
    == `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"no method"}}`);

// session/new: cwd and mcpServers are required, and sessionId is all the
// answer needs. An id is ground code's start, its pid and a count, so two
// sessions of one process are told apart and so are two processes.
private string twoSessions()() {
    Sessions s = Sessions(100, 7);
    enum req = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    return answerWith(req, s) ~ "\n" ~ answerWith(req, s);
}
static assert(twoSessions()
    == `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2"}}`);

// "The working directory for this session. Must be an absolute path."
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"tmp","mcpServers":[]}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"cwd must be an absolute path: tmp"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"mcpServers":[]}}`)
    == `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"session/new needs cwd"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":4,"method":"session/new","params":{"cwd":"/tmp"}}`)
    == `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"session/new needs mcpServers"}}`);

// Nonempty mcpServers launch real processes. libmcp/tests/test_ground.py
// verifies the runtime path, rollback, per-session ownership and EOF cleanup.

// session/close: "Supplying `{}` means the agent supports closing sessions",
// so initialize says so. A session closed is gone, and closing it again, or
// one ground code never opened, is "Resource not found".
private string openThenClose()(string close) {
    Sessions s = Sessions(100, 7);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(close, s) ~ "\n" ~ answerWith(close, s);
}
static assert(openThenClose(`{"jsonrpc":"2.0","id":2,"method":"session/close","params":{"sessionId":"code-100-7-1"}}`)
    == `{"jsonrpc":"2.0","id":2,"result":{}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"no open session code-100-7-1"}}`);
static assert(openThenClose(`{"jsonrpc":"2.0","id":3,"method":"session/close","params":{"sessionId":"code-100-7-9"}}`)
    == `{"jsonrpc":"2.0","id":3,"error":{"code":-32002,"message":"no open session code-100-7-9"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"error":{"code":-32002,"message":"no open session code-100-7-9"}}`);
// Another process's session is not this one's to close.
static assert(answerOf(`{"jsonrpc":"2.0","id":4,"method":"session/close","params":{"sessionId":"code-1-1-1"}}`)
    == `{"jsonrpc":"2.0","id":4,"error":{"code":-32002,"message":"no open session code-1-1-1"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":5,"method":"session/close","params":{}}`)
    == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"session/close needs sessionId"}}`);

// session/list: the sessions this process has open, each with the cwd it was
// opened in. Nothing is kept past the process yet, so that is all there is.
private string listAfter()(string list) {
    Sessions s = Sessions(100, 7);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/srv","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/close","params":{"sessionId":"code-100-7-3"}}`, s);
    return answerWith(list, s);
}
static assert(listAfter(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{}}`)
    == `{"jsonrpc":"2.0","id":9,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/tmp"},{"sessionId":"code-100-7-2","cwd":"/srv"}]}}`);
// "Filter sessions by working directory. Must be an absolute path."
static assert(listAfter(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{"cwd":"/srv"}}`)
    == `{"jsonrpc":"2.0","id":9,"result":{"sessions":[{"sessionId":"code-100-7-2","cwd":"/srv"}]}}`);
static assert(listAfter(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{"cwd":"srv"}}`)
    == `{"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"cwd must be an absolute path: srv"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{}}`)
    == `{"jsonrpc":"2.0","id":9,"result":{"sessions":[]}}`);
// Ground code never gives a nextCursor, so a cursor is not one it gave.
static assert(answerOf(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{"cursor":"x"}}`)
    == `{"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"ground code gives no nextCursor, so it has no cursor to page from"}}`);
// A cwd is kept whole or not at all.
static assert(answerOf(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/` ~ replicate("a", 1024) ~ `","mcpServers":[]}}`)
    == `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"cwd is longer than the 1024 bytes ground code keeps"}}`);

private string replicate()(string s, size_t n) {
    string r;
    foreach (_; 0 .. n) r ~= s;
    return r;
}

// session/resume: "Resumes an existing session without returning previous
// messages (unlike `session/load`)." A session is kept in the store, so one a
// process opened and never closed is there for the next process to resume.
private bool says()(ref Sessions s, string line, string want) {
    Reply r;
    answer(line, r, s);
    return r.slice() == want;
}

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    // One process opens a session and ends without closing it.
    Sessions a = Sessions(100, 7);
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1"}}`));

    // The next one lists it, and resumes it in the cwd it names now.
    Sessions b = Sessions(200, 8);
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work2"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":4,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":4,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work2"}]}}`));

    // Resumed, it is this process's to close; closed, it is gone for every one.
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/close","params":{"sessionId":"code-100-7-1"}}`,
        `{"jsonrpc":"2.0","id":5,"result":{}}`));
    Sessions c = Sessions(300, 9);
    c.db = db;
    assert(says(c, `{"jsonrpc":"2.0","id":6,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":6,"error":{"code":-32002,"message":"no session to resume: code-100-7-1"}}`));
    assert(says(c, `{"jsonrpc":"2.0","id":7,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":7,"result":{"sessions":[]}}`));

    assert(says(c, `{"jsonrpc":"2.0","id":8,"method":"session/resume","params":{"sessionId":"code-1-1-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":8,"error":{"code":-32002,"message":"no session to resume: code-1-1-1"}}`));
    assert(says(c, `{"jsonrpc":"2.0","id":9,"method":"session/resume","params":{"cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"session/resume needs sessionId"}}`));
    assert(says(c, `{"jsonrpc":"2.0","id":10,"method":"session/resume","params":{"sessionId":"code-1-1-1"}}`,
        `{"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"session/resume needs cwd"}}`));
    assert(says(c, `{"jsonrpc":"2.0","id":11,"method":"session/resume","params":{"sessionId":"code-1-1-1","cwd":"work"}}`,
        `{"jsonrpc":"2.0","id":11,"error":{"code":-32602,"message":"cwd must be an absolute path: work"}}`));
    assert(says(c, `{"jsonrpc":"2.0","id":12,"method":"session/resume","params":{"sessionId":"code-1-1-1","cwd":"/work","mcpServers":[{"name":"x","command":"/bin/x","args":[],"env":[]}]}}`,
        `{"jsonrpc":"2.0","id":12,"error":{"code":-32602,"message":"ground code connects no MCP servers yet, and session/resume named some"}}`));
}

// session/delete: "deleting an existing session from `session/list`". What
// list would show is what delete takes; deleted, it is gone for every process,
// and one live here is no longer live.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    Sessions a = Sessions(100, 7);
    a.db = db;
    enum open = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`;
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1"}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2"}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-3"}}`));

    // Another process deletes one; no process lists it or resumes it after.
    Sessions b = Sessions(200, 8);
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":2,"method":"session/delete","params":{"sessionId":"code-100-7-1"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"sessions":[{"sessionId":"code-100-7-2","cwd":"/work"},{"sessionId":"code-100-7-3","cwd":"/work"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":4,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":4,"error":{"code":-32002,"message":"no session to resume: code-100-7-1"}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/delete","params":{"sessionId":"code-100-7-1"}}`,
        `{"jsonrpc":"2.0","id":5,"error":{"code":-32002,"message":"no session to delete: code-100-7-1"}}`));

    // A closed session is not on the list, so it is not there to delete.
    assert(says(a, `{"jsonrpc":"2.0","id":6,"method":"session/close","params":{"sessionId":"code-100-7-2"}}`,
        `{"jsonrpc":"2.0","id":6,"result":{}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":7,"method":"session/delete","params":{"sessionId":"code-100-7-2"}}`,
        `{"jsonrpc":"2.0","id":7,"error":{"code":-32002,"message":"no session to delete: code-100-7-2"}}`));

    // Deleted where it is live, it is not live there any more.
    assert(says(a, `{"jsonrpc":"2.0","id":8,"method":"session/delete","params":{"sessionId":"code-100-7-3"}}`,
        `{"jsonrpc":"2.0","id":8,"result":{}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":9,"method":"session/close","params":{"sessionId":"code-100-7-3"}}`,
        `{"jsonrpc":"2.0","id":9,"error":{"code":-32002,"message":"no open session code-100-7-3"}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":10,"method":"session/delete","params":{}}`,
        `{"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"session/delete needs sessionId"}}`));
}
