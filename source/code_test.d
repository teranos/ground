module code_test;

import code;
import db : versionString;

// The six modes ground already names, by their wire values, in the order
// sessionmode.d gives them; current is the one the session is in.
enum modesOf(string current) = modes(current); // folded at compile time: betterC has no GC

// The one config option a session offers: effort, a thought_level select over
// the levels effort.d already names, current the level the session is at.
enum effortOf(string current) = `[{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"`
    ~ current ~ `","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},`
    ~ `{"value":"high","name":"High"},{"value":"xhigh","name":"Extra high"},{"value":"max","name":"Max"}]}]`;

private string modes()(string current) {
    return `{"currentModeId":"` ~ current ~ `","availableModes":[`
        ~ `{"id":"default","name":"Manual","description":"m in a permission block"},`
        ~ `{"id":"plan","name":"Plan","description":"p in a permission block"},`
        ~ `{"id":"acceptEdits","name":"Accept edits","description":"a in a permission block"},`
        ~ `{"id":"auto","name":"Auto","description":"a in a permission block"},`
        ~ `{"id":"dontAsk","name":"Don't ask","description":"d in a permission block"},`
        ~ `{"id":"bypassPermissions","name":"Bypass permissions","description":"b in a permission block"}]}`;
}

private string answerOf()(string line) {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
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
    == `{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}}},"authMethods":[],"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// "The protocol version the client specified if supported by the agent, or the
// latest protocol version supported by the agent."
static assert(answerOf(`{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":7}}`)
    == `{"jsonrpc":"2.0","id":"a","result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}}},"authMethods":[],"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// authenticate: "Must be one of the methods advertised in the initialize
// response." ground code advertises none, so no methodId is one of them.
static assert(answerOf(`{"jsonrpc":"2.0","id":5,"method":"authenticate","params":{"methodId":"agent"}}`)
    == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"ground code advertises no auth methods, and authenticate named agent"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":6,"method":"authenticate","params":{}}`)
    == `{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"authenticate needs methodId"}}`);

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
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    enum req = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    return answerWith(req, s) ~ "\n" ~ answerWith(req, s);
}
static assert(twoSessions()
    == `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`);

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
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
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
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/srv","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/close","params":{"sessionId":"code-100-7-3"}}`, s);
    return answerWith(list, s);
}
static assert(listAfter(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{}}`)
    == `{"jsonrpc":"2.0","id":9,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/tmp","updatedAt":"2023-11-14T22:13:20Z"},{"sessionId":"code-100-7-2","cwd":"/srv","updatedAt":"2023-11-14T22:13:20Z"}]}}`);
// "Filter sessions by working directory. Must be an absolute path."
static assert(listAfter(`{"jsonrpc":"2.0","id":9,"method":"session/list","params":{"cwd":"/srv"}}`)
    == `{"jsonrpc":"2.0","id":9,"result":{"sessions":[{"sessionId":"code-100-7-2","cwd":"/srv","updatedAt":"2023-11-14T22:13:20Z"}]}}`);
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
    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));

    // The next one lists it, and resumes it. A session's cwd is its own for
    // its life: a resume names the same one, or is refused.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work2"}}`,
        `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"code-100-7-1 is in /work, not /work2"}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":4,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":4,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"}]}}`));

    // Resumed, it is this process's to close; closed, it is gone for every one.
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/close","params":{"sessionId":"code-100-7-1"}}`,
        `{"jsonrpc":"2.0","id":5,"result":{}}`));
    Sessions c = Sessions(300, 9); c.clock = 1_700_000_000;
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

    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    enum open = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`;
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-3","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));

    // Another process deletes one; no process lists it or resumes it after.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":2,"method":"session/delete","params":{"sessionId":"code-100-7-1"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"sessions":[{"sessionId":"code-100-7-2","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"},{"sessionId":"code-100-7-3","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"}]}}`));
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

// session/set_mode: a mode is one of the six a session offers, set on a session
// live here, and kept with the session, so a resume comes back in it.
private string setThen()(string set) {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(set, s) ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/tmp"}}`, s);
}
static assert(setThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"plan"}}`)
    == `{"jsonrpc":"2.0","id":2,"result":{}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"plan" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`);
static assert(setThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"yolo"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no mode yolo; a session offers default, plan, acceptEdits, auto, dontAsk and bypassPermissions"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-1-1-1","modeId":"plan"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"no open session code-1-1-1"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"modeId":"plan"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_mode needs sessionId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-1-1-1"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_mode needs modeId"}}`);

// A mode set in one process is the mode the next one resumes in.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"acceptEdits"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"acceptEdits" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
}

// additionalDirectories: "Additional workspace roots for this session. Each
// path must be absolute." They are kept in order with the session, listed with
// it, and a resume's non-empty list is "the complete resulting additional-root
// list"; an empty or missing one activates none.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","additionalDirectories":["/lib/b","/lib/a"],"mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","additionalDirectories":["/lib/b","/lib/a"],"updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/work","additionalDirectories":["/lib","rel"],"mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"additionalDirectories must be absolute paths: rel"}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":4,"method":"session/new","params":{"cwd":"/work","additionalDirectories":"/lib","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"additionalDirectories must be a list of paths"}}`));

    // Another process resumes it with a list of its own, then with none.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work","additionalDirectories":["/srv"]}}`,
        `{"jsonrpc":"2.0","id":5,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":6,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":6,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","additionalDirectories":["/srv"],"updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":7,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":7,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":8,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":8,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"}]}}`));
}

// session/set_config_option: effort is the option a session offers, one of the
// five levels; set, it is kept with the session and answered with the whole
// set, as "The full set of configuration options and their current values".
private string effortThen()(string set) {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(set, s) ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/tmp"}}`, s);
}
static assert(effortThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"result":{"configOptions":` ~ effortOf!"high" ~ `}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"high" ~ `}}`);
static assert(effortThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"ultra"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no effort ultra; effort is low, medium, high, xhigh or max"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`);
static assert(effortThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"model","value":"x"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no config option model; a session offers effort"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","configId":"effort","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"no open session code-1-1-1"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"configId":"effort","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs sessionId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs configId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","configId":"effort","value":true}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs a value: effort is a select, not a boolean"}}`);

// A new session starts at the effort Claude Code's settings name, when it is
// one of the five; with none, or one ground does not know, at medium.
static assert(effortDefault(`{"effortLevel":"high","model":"x"}`) == "high");
static assert(effortDefault(`{"effortLevel":null}`) == "medium");
static assert(effortDefault(`{"model":"x"}`) == "medium");
static assert(effortDefault(`{"effortLevel":"ultra"}`) == "medium");
static assert(effortDefault(``) == "medium");

// An effort set in one process is the effort the next one resumes at.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"xhigh"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"configOptions":` ~ effortOf!"xhigh" ~ `}}`));
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"xhigh" ~ `}}`));
}
// "we use the qntx openrouter plugin"
// session/prompt is a turn through the node's gateway. It needs a live session
// and a model, and the model is the qntx block's: none, and ground code says so before it asks.
static assert(answerOf(`{"jsonrpc":"2.0","id":11,"method":"session/prompt","params":{"sessionId":"code-100-7-9","prompt":[{"type":"text","text":"hi"}]}}`)
    == `{"jsonrpc":"2.0","id":11,"error":{"code":-32002,"message":"no open session code-100-7-9"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":12,"method":"session/prompt","params":{"prompt":[]}}`)
    == `{"jsonrpc":"2.0","id":12,"error":{"code":-32602,"message":"session/prompt needs sessionId"}}`);
private string promptWithoutModel()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, s);
}
static assert(promptWithoutModel()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);

// updatedAt: "ISO 8601 timestamp of last activity". A session's activity is
// its opening, a resume, and a change to its mode or effort; each one is the
// time the list then reports.
static assert(isoUtc(0) == "1970-01-01T00:00:00Z");
static assert(isoUtc(1_700_000_000) == "2023-11-14T22:13:20Z");
static assert(isoUtc(951_782_400) == "2000-02-29T00:00:00Z");
static assert(isoUtc(1_792_782_328) == "2026-10-23T19:05:28Z");

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    Sessions a = Sessions(100, 7);
    a.db = db;
    a.clock = 1_700_000_000;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ effortOf!"medium" ~ `}}`));
    a.clock = 1_700_000_060;
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"plan"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:14:20Z"}]}}`));
    a.clock = 1_700_000_120;
    assert(says(a, `{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"low"}}`,
        `{"jsonrpc":"2.0","id":4,"result":{"configOptions":` ~ effortOf!"low" ~ `}}`));
    Sessions b = Sessions(200, 8);
    b.db = db;
    b.clock = 1_700_000_180;
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":5,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:15:20Z"}]}}`));
    b.clock = 1_700_000_240;
    assert(says(b, `{"jsonrpc":"2.0","id":6,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":6,"result":{"modes":` ~ modesOf!"plan" ~ `,"configOptions":` ~ effortOf!"low" ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":7,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":7,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:17:20Z"}]}}`));
}
