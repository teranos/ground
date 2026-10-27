module code_test;

import code;
import db : versionString;

// The six modes ground already names, by their wire values, in the order
// sessionmode.d gives them; current is the one the session is in.
enum modesOf(string current) = modes(current); // folded at compile time: betterC has no GC

// The one config option a session offers: effort, a thought_level select over
// the levels effort.d already names, current the level the session is at.
// "Agents that provide mode-like configuration SHOULD send both": the mode is
// the first config option too, a select over the same six modes, and effort
// follows it, "higher-priority options first".
enum configOf(string mode, string effort) = `[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"`
    ~ mode ~ `","options":[{"value":"default","name":"Manual","description":"m in a permission block"},`
    ~ `{"value":"plan","name":"Plan","description":"p in a permission block"},`
    ~ `{"value":"acceptEdits","name":"Accept edits","description":"a in a permission block; ground code asks, as Manual does"},`
    ~ `{"value":"auto","name":"Auto","description":"a in a permission block; ground code asks, as Manual does"},`
    ~ `{"value":"dontAsk","name":"Don't ask","description":"d in a permission block"},`
    ~ `{"value":"bypassPermissions","name":"Bypass permissions","description":"b in a permission block"}]},`
    ~ `{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"`
    ~ effort ~ `","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},`
    ~ `{"value":"high","name":"High"},{"value":"xhigh","name":"Extra high"},{"value":"max","name":"Max"}]}]`;

private string modes()(string current) {
    return `{"currentModeId":"` ~ current ~ `","availableModes":[`
        ~ `{"id":"default","name":"Manual","description":"m in a permission block"},`
        ~ `{"id":"plan","name":"Plan","description":"p in a permission block"},`
        ~ `{"id":"acceptEdits","name":"Accept edits","description":"a in a permission block; ground code asks, as Manual does"},`
        ~ `{"id":"auto","name":"Auto","description":"a in a permission block; ground code asks, as Manual does"},`
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
    == `{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}},"mcpCapabilities":{"http":true},"promptCapabilities":{"embeddedContext":true}},"authMethods":[],"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// "The protocol version the client specified if supported by the agent, or the
// latest protocol version supported by the agent."
static assert(answerOf(`{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":7}}`)
    == `{"jsonrpc":"2.0","id":"a","result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"list":{},"resume":{},"delete":{},"additionalDirectories":{}},"mcpCapabilities":{"http":true},"promptCapabilities":{"embeddedContext":true}},"authMethods":[],"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// authenticate: "Must be one of the methods advertised in the initialize
// response." ground code advertises none, so no methodId is one of them.
static assert(answerOf(`{"jsonrpc":"2.0","id":5,"method":"authenticate","params":{"methodId":"agent"}}`)
    == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"ground code advertises no auth methods, and authenticate named agent"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":6,"method":"authenticate","params":{}}`)
    == `{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"authenticate needs methodId"}}`);

// A method ground code does not handle is said to the client, by name.
static assert(answerOf(`{"jsonrpc":"2.0","id":3,"method":"logout","params":{}}`)
    == `{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"ground code does not handle logout"}}`);

// session/load: "Clients MUST call the session/load method with" the session,
// "MCP servers to connect to" and "The working directory": all three required.
static assert(answerOf(`{"jsonrpc":"2.0","id":4,"method":"session/load","params":{"cwd":"/w","mcpServers":[]}}`)
    == `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"session/load needs sessionId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"code-1-1-1","cwd":"/w"}}`)
    == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"session/load needs mcpServers"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":6,"method":"session/load","params":{"sessionId":"code-1-1-1","cwd":"/w","mcpServers":[]}}`)
    == `{"jsonrpc":"2.0","id":6,"error":{"code":-32002,"message":"no session to load: code-1-1-1"}}`);

// A notification has no answer to give; the caller says it on stderr instead.
static assert(answerOf(`{"jsonrpc":"2.0","method":"session/frobnicate","params":{}}`) is null);
// A cancel with no turn running has nothing to stop: it is answered with
// nothing, and said on stderr.
static assert(answerOf(`{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-1-1-1"}}`) == "");
static assert(answerOf(`{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":4}}`) == "");

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
    == `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`);

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
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));

    // The next one lists it, and resumes it. A session's cwd is its own for
    // its life: a resume names the same one, or is refused.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work2"}}`,
        `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"code-100-7-1 is in /work, not /work2"}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
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
    // A session's servers come up once it is found: one that isn't spawns nothing.
    assert(says(c, `{"jsonrpc":"2.0","id":12,"method":"session/resume","params":{"sessionId":"code-1-1-1","cwd":"/work","mcpServers":[{"name":"x","command":"/does/not/exist","args":[],"env":[]}]}}`,
        `{"jsonrpc":"2.0","id":12,"error":{"code":-32002,"message":"no session to resume: code-1-1-1"}}`));
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
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-2","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(says(a, open, `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-3","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));

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
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"plan" ~ `,"configOptions":` ~ configOf!("plan", "medium") ~ `}}`);
static assert(setThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"yolo"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no mode yolo; a session offers default, plan, acceptEdits, auto, dontAsk and bypassPermissions"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`);
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
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"acceptEdits"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"acceptEdits" ~ `,"configOptions":` ~ configOf!("acceptEdits", "medium") ~ `}}`));
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
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
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
        `{"jsonrpc":"2.0","id":5,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":6,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":6,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","additionalDirectories":["/srv"],"updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":7,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":7,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
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
    == `{"jsonrpc":"2.0","id":2,"result":{"configOptions":` ~ configOf!("default", "high") ~ `}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "high") ~ `}}`);
static assert(effortThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"ultra"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no effort ultra; effort is low, medium, high, xhigh or max"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`);
static assert(effortThen(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"model","value":"x"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no config option model; a session offers mode and effort"}}` ~ "\n"
     ~ `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","configId":"effort","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"no open session code-1-1-1"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"configId":"effort","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs sessionId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","value":"high"}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs configId"}}`);
static assert(answerOf(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-1-1-1","configId":"effort","value":true}}`)
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"session/set_config_option needs a value: mode and effort are selects, not booleans"}}`);

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
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"xhigh"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"configOptions":` ~ configOf!("default", "xhigh") ~ `}}`));
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "xhigh") ~ `}}`));
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
// "As a baseline, the Agent MUST support ContentBlock::Text and
// ContentBlock::ResourceLink". ground code reads text only, so a block of any
// other kind is refused by its type before the turn starts, not dropped.
private string promptWithLink()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"read this"},{"type":"resource_link","uri":"file:///tmp/a","name":"a"}]}}`, s);
}
static assert(promptWithLink()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"ground code reads a file:// resource_link through the client's fs/read_text_file, and the client offers none: file:///tmp/a"}}`);
// "Only available if the client supports the fs.readTextFile capability", which
// initialize reads from clientCapabilities. Offered, a file:// link goes on to
// the turn. Any other is read through the session's MCP servers once the
// turn starts, so it goes on to the turn too.
private string promptWithLinkFor()(string link) {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":false}}}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"resource_link","uri":"` ~ link ~ `","name":"a"}]}}`, s);
}
// As a client writes it, spaced: the capability is read from the object, not
// from where its first space falls.
private string promptWithSpacedCaps()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {"terminal": false, "fs": {"writeTextFile": false, "readTextFile": true}}}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"resource_link","uri":"file:///tmp/a","name":"a"}]}}`, s);
}
static assert(promptWithSpacedCaps()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);
static assert(promptWithLinkFor("file:///tmp/a")
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);
static assert(promptWithLinkFor("https://example.com/a")
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);
private string promptLinkNotOffered()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false},"x":{"readTextFile":true}}}}`, s);
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"resource_link","uri":"file:///tmp/a","name":"a"}]}}`, s);
}
static assert(promptLinkNotOffered()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"ground code reads a file:// resource_link through the client's fs/read_text_file, and the client offers none: file:///tmp/a"}}`);
private string promptUntyped()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"text":"hi"}]}}`, s);
}
static assert(promptUntyped()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"ground code reads text blocks, resource links and resources holding text, and the prompt holds a block that names no type"}}`);
static assert(promptWithoutModel()
    == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"the qntx block names no model, so ground code has none to prompt"}}`);

// The mode is set through either door, and both say the same: set by config
// option, the modes a session reports follow; set by set_mode, the config
// option does.
private string modeBothWays()() {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    answerWith(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, s);
    return answerWith(`{"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"mode","value":"plan"}}`, s)
        ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"mode","value":"sometimes"}}`, s)
        ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":4,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"dontAsk"}}`, s)
        ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":5,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"high"}}`, s)
        ~ "\n" ~ answerWith(`{"jsonrpc":"2.0","id":6,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"model","value":"x"}}`, s);
}
static assert(modeBothWays() ==
      `{"jsonrpc":"2.0","id":2,"result":{"configOptions":` ~ configOf!("plan", "medium") ~ `}}` ~ "\n"
    ~ `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"no mode sometimes; a session offers default, plan, acceptEdits, auto, dontAsk and bypassPermissions"}}` ~ "\n"
    ~ `{"jsonrpc":"2.0","id":4,"result":{}}` ~ "\n"
    ~ `{"jsonrpc":"2.0","id":5,"result":{"configOptions":` ~ configOf!("dontAsk", "high") ~ `}}` ~ "\n"
    ~ `{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"no config option model; a session offers mode and effort"}}`);

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
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    a.clock = 1_700_000_060;
    assert(says(a, `{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"plan"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{}}`));
    assert(says(a, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:14:20Z"}]}}`));
    a.clock = 1_700_000_120;
    assert(says(a, `{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"code-100-7-1","configId":"effort","value":"low"}}`,
        `{"jsonrpc":"2.0","id":4,"result":{"configOptions":` ~ configOf!("plan", "low") ~ `}}`));
    Sessions b = Sessions(200, 8);
    b.db = db;
    b.clock = 1_700_000_180;
    assert(says(b, `{"jsonrpc":"2.0","id":5,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":5,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:15:20Z"}]}}`));
    b.clock = 1_700_000_240;
    assert(says(b, `{"jsonrpc":"2.0","id":6,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":6,"result":{"modes":` ~ modesOf!"plan" ~ `,"configOptions":` ~ configOf!("plan", "low") ~ `}}`));
    assert(says(b, `{"jsonrpc":"2.0","id":7,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":7,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/work","updatedAt":"2023-11-14T22:17:20Z"}]}}`));
}

// ACP's input is read a line at a time, by ground code itself: a turn looks at
// what has arrived while it runs and takes the cancel meant for it out of line,
// and every other line is still answered after, in order.
unittest {
    import core.sys.posix.unistd : pipe, write, close;
    int[2] p;
    assert(pipe(p) == 0);
    enum lines = "a\n\nb\n{\"method\":\"x\"}\nc";
    assert(write(p[1], lines.ptr, lines.length) == lines.length);
    close(p[1]);
    Input input = Input(p[0]);
    scope(exit) { input.dispose(); close(p[0]); }
    const(char)[] line;
    assert(nextLine(input, line) && line == "a");
    bool isX(const(char)[] l) { return l == `{"method":"x"}`; }
    assert(take(input, &isX));
    assert(!take(input, &isX));
    assert(nextLine(input, line) && line == "");
    assert(nextLine(input, line) && line == "b");
    assert(nextLine(input, line) && line == "c");
    assert(!nextLine(input, line) && !input.failed);
}

// "When the Agent receives this notification, it SHOULD stop all language model
// requests and all tool call invocations as soon as possible", and then "MUST
// respond to the original session/prompt request with the cancelled stop
// reason". A gateway that never answers is cut off by the cancel that arrives
// while ground code waits on it; one queued before the turn stops it before it
// asks. "max_tokens": the gateway's finish_reason length ends the turn there.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, sleep, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.stdc.stdio : fflush, stdout;
    import core.stdc.time : time;

    // The fake gateway: it reads a request, then writes `then` into ground
    // code's input and `answer` back, or hangs when answer is null.
    ushort gateway(int inputEnd, string then, string answer, ref int child) {
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 1) == 0);
        socklen_t n = a.sizeof;
        assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
        child = fork();
        if (child == 0) {
            auto c = accept(fd, null, null);
            char[65536] got;
            read(c, got.ptr, got.length);
            write(inputEnd, then.ptr, then.length);
            if (answer is null) sleep(30);
            else write(c, answer.ptr, answer.length);
            _exit(0);
        }
        close(fd);
        return htons(a.sin_port);
    }
    __gshared char[32] urlBuf;
    string url(ushort port) {
        size_t len = 0;
        foreach (c; "http://127.0.0.1:") urlBuf[len++] = c;
        char[8] d; size_t k = 0;
        do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
        while (k) urlBuf[len++] = d[--k];
        return cast(string) urlBuf[0 .. len];
    }
    void run(ref Sessions s, string line) { Reply r; answer(line, r, s); r.dispose(); }
    enum newSession = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    enum prompt = `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`;
    enum cancel = `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-1"}}`;
    // session/update notifications go to stdout; the test's own stays clean.
    fflush(stdout);
    auto saved = dup(1);
    auto devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, 1);
    scope(exit) { fflush(stdout); dup2(saved, 1); close(saved); close(devnull); }

    // Cut off mid-request.
    {
        int[2] p;
        assert(pipe(p) == 0);
        int child;
        auto port = gateway(p[1], cancel ~ "\n", null, child);
        Input input = Input(p[0]);
        scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
        Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = url(port); s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        run(s, newSession);
        auto began = time(null);
        assert(says(s, prompt, `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}`));
        assert(time(null) - began < 10);
    }
    // Queued before the turn: stopped before it asks, the other lines kept in order.
    {
        int[2] p;
        assert(pipe(p) == 0);
        enum queued = `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-9"}}` ~ "\n"
            ~ `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}` ~ "\n" ~ cancel ~ "\n";
        assert(write(p[1], queued.ptr, queued.length) == queued.length);
        Input input = Input(p[0]);
        scope(exit) { input.dispose(); close(p[0]); close(p[1]); }
        Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = "http://127.0.0.1:9"; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        run(s, newSession);
        assert(says(s, prompt, `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}`));
        const(char)[] line;
        assert(nextLine(input, line) && line == `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-9"}}`);
        assert(nextLine(input, line) && line == `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`);
    }
    // $/cancel_request names the prompt by its id.
    {
        int[2] p;
        assert(pipe(p) == 0);
        int child;
        auto port = gateway(p[1], `{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":2}}` ~ "\n", null, child);
        Input input = Input(p[0]);
        scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
        Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = url(port); s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        run(s, newSession);
        assert(says(s, prompt, `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}`));
    }
    // Cut off at the token limit, with a call it asked for: the call is not run,
    // and the history still answers it, so the next turn is one the gateway takes.
    {
        int[2] p;
        assert(pipe(p) == 0);
        enum body_ = `{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"par","tool_calls":[`
            ~ `{"id":"c1","type":"function","function":{"name":"x__y","arguments":"{}"}}]}}]}`;
        enum answer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" ~ body_;
        int child;
        auto port = gateway(p[1], "", answer, child);
        Input input = Input(p[0]);
        scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
        Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = url(port); s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        run(s, newSession);
        assert(says(s, prompt, `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"max_tokens"}}`));
        auto history = s.open[0].history.slice();
        assert(history.length > 0 && history[$ - 1 .. $] == "}");
        import matcher : indexOf;
        assert(indexOf(history, `{"role":"tool","tool_call_id":"c1"`) >= 0);
    }
}

// What a session's mode does to the tool calls its turns ask for:
//   default (Manual), acceptEdits, auto  the client is asked, by
//       session/request_permission; ground code has no edit tools of its own
//       and no classifier, so the last two ask as Manual does
//   plan               only a tool whose MCP annotations say readOnlyHint runs
//   dontAsk            nothing is approved ahead, so nothing runs
//   bypassPermissions  every call runs
// A call not run is answered in the history, so the model is told why.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;

    enum http = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    enum oneCall = http ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"x__y","arguments":"{}"}}]}}]}`;
    enum twoCalls = http ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"x__y","arguments":"{}"}},`
        ~ `{"id":"c2","type":"function","function":{"name":"x__y","arguments":"{}"}}]}}]}`;
    enum done = http ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    enum newSession = `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`;
    enum prompt = `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`;
    enum endTurn = `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`;
    enum chose(string option) = `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"selected","optionId":"` ~ option ~ `"}}}` ~ "\n";

    __gshared char[32] urlBuf;
    __gshared char[65536] said;  // what ground code wrote to the client
    __gshared size_t saidLen;
    __gshared char[4096] gotBuf;
    __gshared size_t gotLen;

    size_t count(const(char)[] text, const(char)[] what) {
        size_t n = 0;
        for (auto at = indexOf(text, what); at >= 0; at = indexOf(text[cast(size_t) at + 1 .. $], what) < 0 ? -1
            : at + 1 + indexOf(text[cast(size_t) at + 1 .. $], what)) n++;
        return n;
    }

    // A turn in a session at mode, against a gateway giving answers in turn,
    // with queued already sent by the client. Its answer, and what it wrote.
    bool turn(string mode, string queued, const(string)[] answers, string want, ref Sessions s, ref Input input, ref int[2] p) {
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 4) == 0);
        socklen_t n = a.sizeof;
        assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
        auto child = fork();
        if (child == 0) {
            foreach (answer; answers) {
                auto c = accept(fd, null, null);
                char[65536] got;
                read(c, got.ptr, got.length);
                write(c, answer.ptr, answer.length);
                close(c);
            }
            _exit(0);
        }
        close(fd);
        ushort port = htons(a.sin_port);
        size_t len = 0;
        foreach (ch; "http://127.0.0.1:") urlBuf[len++] = ch;
        char[8] d; size_t k = 0;
        do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
        while (k) urlBuf[len++] = d[--k];

        assert(pipe(p) == 0);
        input = Input(p[0]);
        s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        assert(write(p[1], queued.ptr, queued.length) == queued.length);

        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        Reply r;
        answer(newSession, r, s); r.len = 0;
        Reply m;
        if (mode != "default") {
            import core.stdc.string : strlen;
            m.add(`{"jsonrpc":"2.0","id":9,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"`);
            m.add(mode); m.add(`"}}`);
            answer(m.slice(), r, s); r.len = 0;
        }
        m.dispose();
        answer(prompt, r, s);
        bool ok = r.slice() == want;
        gotLen = r.len < gotBuf.length ? r.len : gotBuf.length;
        foreach (i; 0 .. gotLen) gotBuf[i] = r.slice()[i];
        r.dispose();
        fflush(stdout);
        dup2(saved, 1); close(saved); close(o[1]);
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
        import core.sys.posix.signal : kill, SIGKILL;
        kill(child, SIGKILL);
        waitpid(child, null, 0);
        if (!ok) {
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "turn at %.*s answered: %.*s\nand said: %.*s\n", cast(int) mode.length, mode.ptr,
                cast(int) gotLen, gotBuf.ptr, cast(int) saidLen, said.ptr);
        }
        return ok;
    }
    void end(ref Input input, ref int[2] p, ref Sessions s) {
        input.dispose(); close(p[0]); close(p[1]);
        foreach (i; 0 .. s.openLen) if (s.open[i].history !is null) { s.open[i].history.dispose(); }
    }
    Sessions s;
    Input input;
    int[2] p;

    // Manual: asked, with the four options the schema names, the call pending until answered.
    {
        const string[2] answers = [oneCall, done];
        assert(turn("default", chose!"allow_once", answers[], endTurn, s, input, p));
        auto out_ = said[0 .. saidLen];
        assert(count(out_, `"method":"session/request_permission"`) == 1);
        assert(indexOf(out_, `{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"code-100-7-1",`
            ~ `"toolCall":{"toolCallId":"c1","title":"x__y","name":"x__y","status":"pending","rawInput":{}},"options":[`
            ~ `{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},`
            ~ `{"optionId":"allow_always","name":"Always allow x__y","kind":"allow_always"},`
            ~ `{"optionId":"reject_once","name":"Reject once","kind":"reject_once"},`
            ~ `{"optionId":"reject_always","name":"Always reject x__y","kind":"reject_always"}]}}`) >= 0);
        assert(indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c1","title":"x__y","name":"x__y","status":"pending","rawInput":{}}`) >= 0);
        assert(indexOf(out_, `{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress"}`) >= 0);
        assert(indexOf(s.open[0].history.slice(), `not run`) < 0);
        // "Agents SHOULD include it in the first report when available and
        // SHOULD NOT change it later": no update names the tool again.
        assert(indexOf(out_, `{"sessionUpdate":"tool_call_update","toolCallId":"c1","name"`) < 0);
        assert(count(out_, `"name":"x__y","status"`) == 2);
        end(input, p, s);
    }
    // Rejected: not run, and the model is told.
    {
        const string[2] answers = [oneCall, done];
        assert(turn("default", chose!"reject_once", answers[], endTurn, s, input, p));
        auto out_ = said[0 .. saidLen];
        assert(indexOf(out_, `{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"failed","rawOutput":`) >= 0);
        assert(indexOf(s.open[0].history.slice(), `{\"status\":\"not run\",\"why\":\"the user rejected it\"}`) >= 0);
        end(input, p, s);
    }
    // Always: the session remembers, and the tool is not asked about again.
    {
        const string[2] answers = [twoCalls, done];
        assert(turn("acceptEdits", chose!"allow_always", answers[], endTurn, s, input, p));
        assert(count(said[0 .. saidLen], `"method":"session/request_permission"`) == 1);
        assert(indexOf(s.open[0].history.slice(), `not run`) < 0);
        end(input, p, s);
    }
    {
        const string[2] answers = [twoCalls, done];
        assert(turn("auto", chose!"reject_always", answers[], endTurn, s, input, p));
        assert(count(said[0 .. saidLen], `"method":"session/request_permission"`) == 1);
        assert(count(s.open[0].history.slice(), `the user rejected it`) == 2);
        end(input, p, s);
    }
    // Plan: x__y says nothing of being read-only, so it does not run and nobody is asked.
    {
        const string[2] answers = [oneCall, done];
        assert(turn("plan", "", answers[], endTurn, s, input, p));
        assert(count(said[0 .. saidLen], `request_permission`) == 0);
        assert(indexOf(s.open[0].history.slice(), `{\"status\":\"not run\",\"why\":\"plan mode runs only tools whose MCP annotations say readOnlyHint\"}`) >= 0);
        end(input, p, s);
    }
    // Don't ask: nothing is approved ahead.
    {
        const string[2] answers = [oneCall, done];
        assert(turn("dontAsk", "", answers[], endTurn, s, input, p));
        assert(count(said[0 .. saidLen], `request_permission`) == 0);
        assert(indexOf(s.open[0].history.slice(), `{\"status\":\"not run\",\"why\":\"dontAsk mode runs only what is approved ahead, and nothing is\"}`) >= 0);
        end(input, p, s);
    }
    // Bypass: run, nobody asked.
    {
        const string[2] answers = [oneCall, done];
        assert(turn("bypassPermissions", "", answers[], endTurn, s, input, p));
        assert(count(said[0 .. saidLen], `request_permission`) == 0);
        assert(indexOf(said[0 .. saidLen], `{"sessionUpdate":"tool_call","toolCallId":"c1","title":"x__y","name":"x__y","status":"in_progress","rawInput":{}}`) >= 0);
        assert(indexOf(s.open[0].history.slice(), `not run`) < 0);
        end(input, p, s);
    }
    // Cancelled while asking: "it MUST respond to all pending
    // session/request_permission requests with this Cancelled outcome", and
    // the turn stops there. The session/cancel that follows finds no turn
    // running, and an answer to a question nobody waits on is no request:
    // neither gets an answer.
    {
        enum cancelled = `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"cancelled"}}}` ~ "\n";
        const string[1] answers = [oneCall];
        assert(turn("default", cancelled, answers[], `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}`, s, input, p));
        assert(count(said[0 .. saidLen], `"method":"session/request_permission"`) == 1);
        assert(indexOf(s.open[0].history.slice(), `{\"status\":\"not run\",\"why\":\"the client cancelled the turn\"}`) >= 0);
        assert(says(s, `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-1"}}`, ""));
        assert(says(s, `{"jsonrpc":"2.0","id":"perm-7","result":{"outcome":{"outcome":"cancelled"}}}`, ""));
        end(input, p, s);
    }
    // An answer naming no option ground code offered is said, not guessed at.
    {
        const string[1] answers = [oneCall];
        assert(turn("default", chose!"maybe", answers[], `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"ground code could not ask the client's permission","data":`
            ~ `{"message":"the client's answer to session/request_permission is not one ground code offered","answer":"`
            ~ `{\"jsonrpc\":\"2.0\",\"id\":\"perm-1\",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"maybe\"}}}"}}}`, s, input, p));
        end(input, p, s);
    }
}

// A session's conversation is the store's: a turn keeps its history there, a
// resume in another process "restores the session context" without replaying
// it, and session/load does replay it: "The Agent MUST replay the entire
// conversation to the Client in the form of session/update notifications",
// and "When all the conversation entries have been streamed to the Client,
// the Agent MUST respond to the original session/load request."
version (Posix) unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import code.store : storeHistory, storeHistoryOf;
    import core.sys.posix.unistd : pipe, read, close, dup, dup2;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    enum history = `{"role":"user","content":"hi \"you\""},`
        ~ `{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"x__y","arguments":"{\"a\":1}"}},`
        ~ `{"id":"c2","type":"function","function":{"name":"x__z","arguments":"{}"}}]},`
        ~ `{"role":"tool","tool_call_id":"c1","content":"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[]}}"},`
        ~ `{"role":"tool","tool_call_id":"c2","content":"{\"status\":\"not run\",\"why\":\"the user rejected it\"}"},`
        ~ `{"role":"assistant","content":"done","reasoning":"both came back"}`;

    Sessions a = Sessions(100, 7); a.clock = 1_700_000_000;
    a.db = db;
    assert(says(a, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":1,"result":{"sessionId":"code-100-7-1","modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(storeHistory(db, "code-100-7-1", history) == 1);
    Reply kept;
    assert(storeHistoryOf(db, "code-100-7-1", kept) == 1 && kept.slice() == history);
    kept.dispose();

    __gshared char[65536] said;
    size_t saidLen;
    bool capture(ref Sessions s, string line, string want) {
        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        bool ok = says(s, line, want);
        fflush(stdout);
        dup2(saved, 1); close(saved); close(o[1]);
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
        return ok;
    }

    // Resumed elsewhere: the conversation is the session's again, and nothing is replayed.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(capture(b, `{"jsonrpc":"2.0","id":2,"method":"session/resume","params":{"sessionId":"code-100-7-1","cwd":"/work"}}`,
        `{"jsonrpc":"2.0","id":2,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(saidLen == 0);
    assert(b.open[0].history !is null && b.open[0].history.slice() == history);

    // Loaded elsewhere: replayed, in order, then answered.
    Sessions c = Sessions(300, 9); c.clock = 1_700_000_000;
    c.db = db;
    assert(capture(c, `{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"code-100-7-1","cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    enum up = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`;
    assert(said[0 .. saidLen] ==
          up ~ `{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi \"you\""}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"tool_call","toolCallId":"c1","title":"x__y","name":"x__y","rawInput":{"a":1}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"tool_call","toolCallId":"c2","title":"x__z","name":"x__z","rawInput":{}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","rawOutput":{"jsonrpc":"2.0","id":3,"result":{"content":[]}}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"tool_call_update","toolCallId":"c2","status":"failed","rawOutput":{"status":"not run","why":"the user rejected it"},`
        ~ `"content":[{"type":"content","content":{"type":"text","text":"the user rejected it"}}]}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"both came back"}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}` ~ "\n");
    assert(c.open[0].history !is null && c.open[0].history.slice() == history);
    // Loaded where it is live: its conversation is the one this process holds.
    assert(capture(c, `{"jsonrpc":"2.0","id":4,"method":"session/load","params":{"sessionId":"code-100-7-1","cwd":"/work","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":4,"result":{"modes":` ~ modesOf!"default" ~ `,"configOptions":` ~ configOf!("default", "medium") ~ `}}`));
    assert(indexOf(said[0 .. saidLen], `"text":"done"`) >= 0);
    // Its cwd is still its own for life.
    assert(says(c, `{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"code-100-7-1","cwd":"/else","mcpServers":[]}}`,
        `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"code-100-7-1 is in /work, not /else"}}`));
    foreach (i; 0 .. b.openLen) if (b.open[i].history !is null) b.open[i].history.dispose();
    foreach (i; 0 .. c.openLen) if (c.open[i].history !is null) c.open[i].history.dispose();
}

// A turn keeps its history in the store as it ends, however it ends.
version (Posix) unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import code.store : storeHistoryOf;
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.stdc.stdio : fflush, stdout;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    enum reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done","reasoning":"hi is a greeting"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 1) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        auto c = accept(fd, null, null);
        char[65536] got;
        read(c, got.ptr, got.length);
        write(c, reply.ptr, reply.length);
        close(c);
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
    s.db = db;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    Reply r;
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    __gshared char[65536] said;
    size_t saidLen = 0;
    while (true) {
        auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
        if (got <= 0) break;
        saidLen += cast(size_t) got;
    }
    close(o[0]);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    r.dispose();
    // "A chunk of the agent's internal reasoning being streamed": the
    // reasoning the gateway gave back is told before the words.
    enum up = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`;
    // "Agents can update session metadata in real-time by sending a
    // session_info_update notification": the title the first prompt gave, as
    // the turn starts.
    assert(said[0 .. saidLen] ==
          up ~ `{"sessionUpdate":"session_info_update","title":"hi","updatedAt":"2023-11-14T22:13:20Z"}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hi is a greeting"}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}` ~ "\n");
    Reply kept;
    assert(storeHistoryOf(db, "code-100-7-1", kept) == 1);
    assert(kept.slice() == `{"role":"user","content":"hi"},{"role":"assistant","content":"done","reasoning":"hi is a greeting"}`);
    assert(kept.slice() == s.open[0].history.slice());
    kept.dispose();
    // SessionInfo's title, "Human-readable title for the session", is the
    // store's, so every process lists it.
    Sessions b = Sessions(200, 8); b.clock = 1_700_000_000;
    b.db = db;
    assert(says(b, `{"jsonrpc":"2.0","id":3,"method":"session/list","params":{}}`,
        `{"jsonrpc":"2.0","id":3,"result":{"sessions":[{"sessionId":"code-100-7-1","cwd":"/tmp","title":"hi","updatedAt":"2023-11-14T22:13:20Z"}]}}`));
    s.open[0].history.dispose();
}

// A file:// link is read through the client as the turn starts: ground code
// asks fs/read_text_file for its path, waits on the answer as it waits on a
// permission, and the file's text joins what the user said. An error answer
// ends the turn carrying it; a cancel stops it before anything is asked of
// the model.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;

    enum done = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    enum prompt = `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[`
        ~ `{"type":"text","text":"read this"},{"type":"resource_link","uri":"file:///tmp/a%20b","name":"a b"}]}}`;
    __gshared char[32] urlBuf;
    __gshared char[65536] said;
    __gshared size_t saidLen;
    __gshared char[4096] gotBuf;
    __gshared size_t gotLen;

    // A turn whose client has already answered with queued, against a gateway
    // that answers done when it is asked at all.
    void turn(string queued, ref Sessions s, ref Input input, ref int[2] p) {
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 1) == 0);
        socklen_t n = a.sizeof;
        assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
        auto child = fork();
        if (child == 0) {
            auto c = accept(fd, null, null);
            char[65536] got;
            read(c, got.ptr, got.length);
            write(c, done.ptr, done.length);
            close(c);
            _exit(0);
        }
        close(fd);
        ushort port = htons(a.sin_port);
        size_t len = 0;
        foreach (ch; "http://127.0.0.1:") urlBuf[len++] = ch;
        char[8] d; size_t k = 0;
        do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
        while (k) urlBuf[len++] = d[--k];
        assert(pipe(p) == 0);
        input = Input(p[0]);
        s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        assert(write(p[1], queued.ptr, queued.length) == queued.length);
        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        Reply r;
        answer(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true}}}}`, r, s); r.len = 0;
        answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
        answer(prompt, r, s);
        gotLen = r.len < gotBuf.length ? r.len : gotBuf.length;
        foreach (i; 0 .. gotLen) gotBuf[i] = r.slice()[i];
        r.dispose();
        fflush(stdout);
        dup2(saved, 1); close(saved); close(o[1]);
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
        kill(child, SIGKILL);
        waitpid(child, null, 0);
    }
    void end(ref Input input, ref int[2] p, ref Sessions s) {
        input.dispose(); close(p[0]); close(p[1]);
        foreach (i; 0 .. s.openLen) if (s.open[i].history !is null) s.open[i].history.dispose();
    }
    Sessions s;
    Input input;
    int[2] p;

    // Read: asked by its path, and its text is the user's, after what they typed.
    turn(`{"jsonrpc":"2.0","id":"read-1","result":{"content":"line one\nline \"two\""}}` ~ "\n", s, input, p);
    assert(gotBuf[0 .. gotLen] == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(said[0 .. saidLen], `{"jsonrpc":"2.0","id":"read-1","method":"fs/read_text_file","params":{"sessionId":"code-100-7-1","path":"/tmp/a b"}}`) >= 0);
    assert(indexOf(s.open[0].history.slice(), `{"role":"user","content":"read this\n\na b (file:///tmp/a%20b):\nline one\nline \"two\""}`) >= 0);
    end(input, p, s);

    // The client could not read it: the turn ends with the client's own error, and the model is not asked.
    turn(`{"jsonrpc":"2.0","id":"read-1","error":{"code":-32002,"message":"no such file"}}` ~ "\n", s, input, p);
    assert(gotBuf[0 .. gotLen] == `{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"ground code could not read file:///tmp/a%20b through the client","data":`
        ~ `{"jsonrpc":"2.0","id":"read-1","error":{"code":-32002,"message":"no such file"}}}}`);
    assert(s.open[0].history is null || indexOf(s.open[0].history.slice(), `read this`) < 0);
    end(input, p, s);

    // Called off while waiting on the file.
    turn(`{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-1"}}` ~ "\n", s, input, p);
    assert(gotBuf[0 .. gotLen] == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"cancelled"}}`);
    end(input, p, s);
}

// "Upon receiving this notification, the Agent SHOULD: ... Abort all tool call
// invocations in progress". A cancel that arrives while a session's tool runs
// cancels it at the server, and the turn answers cancelled without waiting
// the call out; the history answers the call, and the calls after it.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, sleep, dup, dup2, getcwd;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fflush, stdout, FILE, fopen, fread, fclose;
    import core.stdc.time : time;
    import matcher : indexOf;

    enum calls = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"test__wait","arguments":"{}"}},`
        ~ `{"id":"c2","type":"function","function":{"name":"test__quick","arguments":"{}"}}]}}]}`;
    enum cancel = `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"code-100-7-1"}}` ~ "\n";

    __gshared char[4096] cwd;
    __gshared char[64] dir = "/tmp/ground-abort-XXXXXX\0";
    assert(getcwd(cwd.ptr, cwd.length) !is null && mkdtemp(dir.ptr) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    size_t dirLen = 0; while (dir[dirLen]) dirLen++;

    int[2] p;
    assert(pipe(p) == 0);
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 1) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        auto c = accept(fd, null, null);
        char[65536] got;
        read(c, got.ptr, got.length);
        write(c, calls.ptr, calls.length);
        close(c);
        sleep(1); // the turn is in its first call by now, which never answers
        write(p[1], cancel.ptr, cancel.length);
        sleep(30);
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

    Input input = Input(p[0]);
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }

    Reply req;
    scope(exit) req.dispose();
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"python3","args":["`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/abort_server.py"],"env":[{"name":"ABORT_LOG","value":"`);
    req.add(dir[0 .. dirLen]); req.add(`/wire.jsonl"}]}]}}`);
    fflush(stdout);
    auto saved = dup(1);
    auto devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, 1);
    Reply r;
    answer(req.slice(), r, s);
    bool opened = indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"bypassPermissions"}}`, r, s);
    r.len = 0;
    auto began = time(null);
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"wait"}]}}`, r, s);
    auto took = time(null) - began;
    fflush(stdout); dup2(saved, 1); close(saved); close(devnull);
    assert(opened);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}`);
    r.dispose();
    assert(took < 10);
    auto history = s.open[0].history.slice();
    assert(indexOf(history, `{"role":"tool","tool_call_id":"c1","content":"{\"status\":\"cancelled\"`) >= 0);
    assert(indexOf(history, `{"role":"tool","tool_call_id":"c2","content":"{\"status\":\"not run\",\"why\":\"the client cancelled the turn\"}"}`) >= 0);
    // The server was told, by the call's id: closed first, so it has read
    // everything sent to it before its log is.
    Reply closed;
    import code.mcp : closeMcp;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
    __gshared char[65536] wire;
    Reply path;
    scope(exit) path.dispose();
    path.add(dir[0 .. dirLen]); path.add("/wire.jsonl\0");
    auto f = fopen(path.slice().ptr, "r");
    assert(f !is null);
    auto got = fread(wire.ptr, 1, wire.length, f);
    fclose(f);
    assert(indexOf(wire[0 .. got], `"method": "notifications/cancelled"`) >= 0);
    assert(indexOf(wire[0 .. got], `"reason": "the client cancelled the turn"`) >= 0);
    s.open[0].history.dispose();
}

// usage_update: "Context window and cost update for a session." used,
// "Tokens currently in context", is what the gateway's answer says the
// conversation now holds; size, "Total context window size in tokens", is
// the model's context_length in the gateway's models list, asked once a
// process, as the first turn starts. A model the list does not carry is no
// size to report, and the turn says so before the model is asked.
version (Posix) unittest {
    import core.sys.posix.unistd : write, close, fork, _exit, read, dup, dup2, pipe;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    enum ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    enum models = ok ~ `{"data":[{"id":"other","context_length":8192},{"id":"m","context_length":200000,"top_provider":{"context_length":100000}}]}`;
    enum answer_ = ok ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}],`
        ~ `"usage":{"prompt_tokens":194,"completion_tokens":2,"total_tokens":196,"cost":0.95}}`;
    __gshared char[4096] asked;

    // A gateway that answers each connection in turn, and writes down the
    // first line of each request into asked, one a line.
    int gateway(string[] replies, ref ushort port) {
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 4) == 0);
        socklen_t n = a.sizeof;
        assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
        port = htons(a.sin_port);
        int[2] lines;
        assert(pipe(lines) == 0);
        auto child = fork();
        if (child == 0) {
            close(lines[0]);
            foreach (reply; replies) {
                auto c = accept(fd, null, null);
                char[65536] got;
                auto len = read(c, got.ptr, got.length);
                size_t end = 0;
                while (end < cast(size_t) len && got[end] != '\r') end++;
                write(lines[1], got.ptr, end); write(lines[1], "\n".ptr, 1);
                write(c, reply.ptr, reply.length);
                close(c);
            }
            _exit(0);
        }
        close(fd); close(lines[1]);
        return lines[0] | (child << 16);
    }
    string urlOf(ushort port) {
        __gshared char[32] urlBuf;
        size_t len = 0;
        foreach (ch; "http://127.0.0.1:") urlBuf[len++] = ch;
        char[8] d; size_t k = 0;
        do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
        while (k) urlBuf[len++] = d[--k];
        return cast(string) urlBuf[0 .. len];
    }
    __gshared char[65536] said;
    size_t saidLen;
    void prompt(ref Sessions s, ref Reply r) {
        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
        answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, r, s);
        fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
    }
    size_t askedOf(int lines) {
        size_t len = 0;
        while (true) {
            auto got = read(lines, asked.ptr + len, asked.length - len);
            if (got <= 0) break;
            len += cast(size_t) got;
        }
        close(lines);
        return len;
    }

    // The list, then the turn: the model's size, and what the answer says it used.
    ushort port;
    string[2] listAndTurn = [models, answer_];
    auto both = gateway(listAndTurn[], port);
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = urlOf(port); s.node.model = "m"; s.node.token = "/nonexistent";
    Reply r;
    prompt(s, r);
    auto lines = askedOf(both & 0xFFFF);
    waitpid(both >> 16, null, 0);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    assert(asked[0 .. lines] == "GET /api/openrouter-qntx/v1/models HTTP/1.1\nPOST /api/openrouter-qntx/v1/chat/completions HTTP/1.1\n");
    enum up = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`;
    assert(said[0 .. saidLen] ==
          up ~ `{"sessionUpdate":"session_info_update","title":"hi","updatedAt":"2023-11-14T22:13:20Z"}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}` ~ "\n"
        ~ up ~ `{"sessionUpdate":"usage_update","used":196,"size":200000,"cost":{"amount":0.95,"currency":"USD"}}}}` ~ "\n");
    assert(s.contextSize == 200_000);
    s.open[0].history.dispose();
    r.dispose();

    // A list without the model: the turn ends there, the model never asked.
    string[1] listOnly = [ok ~ `{"data":[{"id":"other","context_length":8192}]}`];
    auto none = gateway(listOnly[], port);
    Sessions t = Sessions(100, 7); t.clock = 1_700_000_000;
    t.node.url = urlOf(port); t.node.model = "m"; t.node.token = "/nonexistent";
    prompt(t, r);
    lines = askedOf(none & 0xFFFF);
    waitpid(none >> 16, null, 0);
    assert(asked[0 .. lines] == "GET /api/openrouter-qntx/v1/models HTTP/1.1\n");
    assert(indexOf(r.slice(), `"error":{"code":-32603,"message":"the gateway's models list gives no context_length for m"`) >= 0);
    if (t.open[0].history !is null) t.open[0].history.dispose();
    r.dispose();
}

// A session is titled once: the first prompt that types something names it,
// and a later one, in this process or another, leaves the name as it is.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import code.store : storeOpen, storeTitle, storeList;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);
    assert(storeOpen(db, "s1", "/work", "[]", "medium", 1));
    assert(storeTitle(db, "s1", "first") == 1);
    assert(storeTitle(db, "s1", "second") == 0);
    assert(storeTitle(db, "nope", "x") == 0);
    __gshared char[16] got;
    size_t gotLen;
    assert(storeList(db, null, (const(char)[] id, const(char)[] cwd, const(char)[] dirs, const(char)[] title, long at) {
        foreach (i, c; title) got[i] = c;
        gotLen = title.length;
    }));
    assert(got[0 .. gotLen] == "first");
}

// "This is useful when an agent receives an elicitation from an MCP server
// during a tool call and needs to redirect it to the user." A session's MCP
// servers are told the elicitation the client offers, and one that asks while
// its call runs is asked of the client as elicitation/create, tied to the call;
// the client's answer is the server's. A legacy server asks with a request of
// its own, a 2026-07-28 one with input_required; a url elicitation's
// completion is passed on as elicitation/complete. A client that offers none
// has none declared for it, and the server's ask is refused by libmcp.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2, getcwd;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fflush, stdout, fopen, fread, fclose;
    import matcher : indexOf;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    __gshared char[65536] said;
    __gshared char[65536] wire;
    size_t saidLen, wireLen;

    // One turn: the model calls tools, each runs on the elicit server, then
    // the model is done. The client's answers wait in its input already.
    const(char)[] turn(string protocol, string caps, string tools, string answers, ref Reply r) {
        __gshared char[64] dir;
        foreach (i, ch; "/tmp/ground-elicit-XXXXXX\0") dir[i] = ch;
        assert(mkdtemp(dir.ptr) !is null);
        size_t dirLen = 0; while (dir[dirLen]) dirLen++;
        Reply calls;
        scope(exit) calls.dispose();
        calls.add("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n");
        calls.add(`{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`);
        calls.add(tools); calls.add(`]}}]}`);
        enum done = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
            ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 2) == 0);
        socklen_t n = a.sizeof;
        assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
        auto child = fork();
        if (child == 0) {
            char[65536] got;
            auto c = accept(fd, null, null);
            read(c, got.ptr, got.length);
            write(c, calls.slice().ptr, calls.len);
            close(c);
            c = accept(fd, null, null);
            read(c, got.ptr, got.length);
            write(c, done.ptr, done.length);
            close(c);
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
        write(p[1], answers.ptr, answers.length);
        Input input = Input(p[0]);
        Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
        s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
        s.input = &input;
        scope(exit) { input.dispose(); close(p[0]); close(p[1]); kill(child, SIGKILL); waitpid(child, null, 0); }
        Reply init, req;
        scope(exit) { init.dispose(); req.dispose(); }
        init.add(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":`);
        init.add(caps); init.add(`}}`);
        req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"python3","args":["`);
        req.add(cwd[0 .. cwdLen]); req.add(`/mcp/elicit_server.py"],"env":[{"name":"ELICIT_PROTOCOL","value":"`);
        req.add(protocol); req.add(`"},{"name":"ELICIT_LOG","value":"`);
        req.add(dir[0 .. dirLen]); req.add(`/wire.jsonl"}]}]}}`);
        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        answer(init.slice(), r, s); r.len = 0;
        answer(req.slice(), r, s);
        bool opened = indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0;
        r.len = 0;
        answer(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"bypassPermissions"}}`, r, s);
        r.len = 0;
        answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"go"}]}}`, r, s);
        fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
        // Closed first: the server holds what it inherited of the pipe until
        // it ends, and has read everything sent to it before its log is.
        Reply closed;
        bool shut = closeMcp(s.open[0].mcp, closed);
        closed.dispose();
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
        assert(opened && shut);
        s.open[0].history.dispose();
        Reply path;
        scope(exit) path.dispose();
        path.add(dir[0 .. dirLen]); path.add("/wire.jsonl\0");
        auto f = fopen(path.slice().ptr, "r");
        assert(f !is null);
        wireLen = fread(wire.ptr, 1, wire.length, f);
        fclose(f);
        return said[0 .. saidLen];
    }

    enum both = `{"elicitation":{"form":{},"url":{}}}`;
    enum ask = `{"id":"c1","type":"function","function":{"name":"test__ask","arguments":"{}"}}`;
    enum link = `{"id":"c2","type":"function","function":{"name":"test__link","arguments":"{}"}}`;
    enum accepted = `{"jsonrpc":"2.0","id":"elicit-1","result":{"action":"accept","content":{"branch":"main"}}}` ~ "\n";
    enum opened = `{"jsonrpc":"2.0","id":"elicit-2","result":{"action":"accept"}}` ~ "\n";
    enum asked = `{"jsonrpc":"2.0","id":"elicit-1","method":"elicitation/create","params":{"sessionId":"code-100-7-1","toolCallId":"c1",`
        ~ `"mode":"form","message":"Which branch?","requestedSchema":{"type":"object","properties":{"branch":{"type":"string"}},"required":["branch"]}}}` ~ "\n";
    Reply r;
    scope(exit) r.dispose();

    // Legacy: the server's own request, answered on the wire.
    auto out_ = turn("legacy", both, ask ~ "," ~ link, accepted ~ opened, r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(out_, asked) >= 0);
    assert(indexOf(out_, `{"jsonrpc":"2.0","id":"elicit-2","method":"elicitation/create","params":{"sessionId":"code-100-7-1","toolCallId":"c2",`
        ~ `"mode":"url","message":"Sign in","elicitationId":"x1","url":"https://example.com/sign-in"}}` ~ "\n") >= 0);
    assert(indexOf(out_, `{"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"x1"}}` ~ "\n") >= 0);
    assert(indexOf(wire[0 .. wireLen], `{"capabilities": {"elicitation": {"form": {}, "url": {}}}}`) >= 0);
    assert(indexOf(wire[0 .. wireLen], `{"answer": {"jsonrpc": "2.0", "id": "e1", "result": {"action": "accept", "content": {"branch": "main"}}}}`) >= 0);
    assert(indexOf(wire[0 .. wireLen], `{"answer": {"jsonrpc": "2.0", "id": "e2", "result": {"action": "accept"}}}`) >= 0);

    // 2026-07-28: input_required, answered by the call's continuation.
    out_ = turn("modern", `{"elicitation":{"form":{}}}`, ask, accepted, r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(out_, asked) >= 0);
    assert(indexOf(wire[0 .. wireLen], `{"capabilities": {"elicitation": {"form": {}}}}`) >= 0);
    assert(indexOf(wire[0 .. wireLen], `{"answer": {"action": "accept", "content": {"branch": "main"}}, "state": "s1"}`) >= 0);

    // A client that offers no elicitation: none is declared, and nothing is asked of it.
    out_ = turn("legacy", `{}`, ask, "", r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(out_, `elicitation/create`) < 0);
    assert(indexOf(wire[0 .. wireLen], `{"capabilities": {}}`) >= 0);
    assert(indexOf(wire[0 .. wireLen], `"error": {"code": -32601`) >= 0);
}

// A server that takes longer to start than libmcp's probe of server/discover
// waits is taken for a legacy one and asked initialize, which one that speaks
// 2026-07-28 alone refuses: a session could not have it. ground code waits
// for the probe as long as MCP_PROBE_MS, so a server that starts in a second
// opens.
version (Posix) unittest {
    import core.sys.posix.unistd : getcwd;
    import core.stdc.time : time;
    import matcher : indexOf;
    import code.mcp : closeMcp;
    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    Reply req, r;
    scope(exit) { req.dispose(); r.dispose(); }
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"slow","command":"python3","args":["`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/slow_server.py"],"env":[]}]}}`);
    answer(req.slice(), r, s);
    if (indexOf(r.slice(), `"sessionId":"code-100-7-1"`) < 0) {
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "slow server: %.*s\n", cast(int) r.len, r.slice().ptr);
    }
    assert(indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0);
    Reply closed;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
}

// notice: "Fire-and-forget information for the user", sent only "when the
// Client advertised ClientSessionCapabilities::notices. Otherwise, Agents may
// use an agent message when the information should still be surfaced to the
// user." What a session's MCP server logs at warning or above while its call
// runs is surfaced, and info is not; a notification ground code does not
// handle is, to the session it names.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2, getcwd;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    __gshared char[65536] said;
    size_t saidLen;

    // What ground code writes while run does its work, the session's servers closed first.
    const(char)[] capture(ref Sessions s, scope void delegate() run) {
        int[2] o;
        assert(pipe(o) == 0);
        fflush(stdout);
        auto saved = dup(1);
        dup2(o[1], 1);
        run();
        fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
        foreach (i; 0 .. s.openLen) { Reply closed; closeMcp(s.open[i].mcp, closed); closed.dispose(); }
        saidLen = 0;
        while (true) {
            auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
            if (got <= 0) break;
            saidLen += cast(size_t) got;
        }
        close(o[0]);
        return said[0 .. saidLen];
    }

    // A turn whose model calls the noisy tool once, then is done.
    const(char)[] noisyTurn(string caps, ref Reply r) {
        enum ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
        enum calls = ok ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
            ~ `{"id":"c1","type":"function","function":{"name":"test__noisy","arguments":"{}"}}]}}]}`;
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
        Reply init, req;
        scope(exit) { init.dispose(); req.dispose(); }
        init.add(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":`);
        init.add(caps); init.add(`}}`);
        req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"python3","args":["`);
        req.add(cwd[0 .. cwdLen]); req.add(`/mcp/log_server.py"],"env":[]}]}}`);
        auto out_ = capture(s, () {
            answer(init.slice(), r, s); r.len = 0;
            answer(req.slice(), r, s); r.len = 0;
            answer(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"bypassPermissions"}}`, r, s);
            r.len = 0;
            answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"go"}]}}`, r, s);
        });
        s.open[0].history.dispose();
        return out_;
    }

    enum up = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`;
    Reply r;
    scope(exit) r.dispose();

    // Offered: a notice for each line at warning or above, its data said as it came.
    auto out_ = noisyTurn(`{"session":{"notices":{}}}`, r);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(out_, up ~ `{"sessionUpdate":"notice","severity":"warning","title":"MCP server test logged a warning","description":"disk is filling up"}}}` ~ "\n") >= 0);
    assert(indexOf(out_, up ~ `{"sessionUpdate":"notice","severity":"error","title":"MCP server test logged an error","description":"{\"errno\":28,\"path\":\"/var\"}"}}}` ~ "\n") >= 0);
    assert(indexOf(out_, `starting`) < 0);

    // Not offered: an agent message says the same.
    out_ = noisyTurn(`{}`, r);
    assert(indexOf(out_, `"sessionUpdate":"notice"`) < 0);
    assert(indexOf(out_, up ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"MCP server test logged a warning: disk is filling up\n"}}}}` ~ "\n") >= 0);

    // A notification ground code does not handle, to the open session it names; one naming none is stderr's alone.
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    out_ = capture(s, () {
        answer(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"session":{"notices":{}}}}}`, r, s); r.len = 0;
        answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
        unhandled(`{"jsonrpc":"2.0","method":"session/wiggle","params":{"sessionId":"code-100-7-1"}}`, s);
        unhandled(`{"jsonrpc":"2.0","method":"session/wiggle","params":{"sessionId":"code-9-9-9"}}`, s);
    });
    assert(out_ == up ~ `{"sessionUpdate":"notice","severity":"warning","title":"ground code does not handle session/wiggle","description":`
        ~ `"{\"jsonrpc\":\"2.0\",\"method\":\"session/wiggle\",\"params\":{\"sessionId\":\"code-100-7-1\"}}"}}}` ~ "\n");
}

// cost: "Total cumulative cost for session." Each answer's usage.cost is
// added to what the session has cost so far, in the store, so a session
// resumed in another process goes on from its total.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import code.store : storeOpen, storeAddCost;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);
    assert(storeOpen(db, "s1", "/work", "[]", "medium", 1));
    long total;
    assert(storeAddCost(db, "s1", 950_000_000, total) == 1 && total == 950_000_000);
    assert(storeAddCost(db, "s1", 123_000, total) == 1 && total == 950_123_000);
    assert(storeAddCost(db, "nope", 1, total) == 0);
}

// updatedAt: "ISO 8601 timestamp of last activity", pushed "in real-time via
// the session_info_update notification, keeping session titles and metadata
// in sync without polling". Each turn is the session's activity as it starts:
// the first tells the title with it, a later one the time alone.
version (Posix) unittest {
    import core.sys.posix.unistd : write, close, fork, _exit, read, dup, dup2, pipe;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    enum done = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 2) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        foreach (_; 0 .. 2) {
            char[65536] got;
            auto c = accept(fd, null, null); read(c, got.ptr, got.length); write(c, done.ptr, done.length); close(c);
        }
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
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    scope(exit) { kill(child, SIGKILL); waitpid(child, null, 0); }
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    Reply r;
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, r, s); r.len = 0;
    s.clock = 1_700_000_090;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"again"}]}}`, r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    __gshared char[65536] said;
    size_t saidLen = 0;
    while (true) {
        auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
        if (got <= 0) break;
        saidLen += cast(size_t) got;
    }
    close(o[0]);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    r.dispose();
    enum up = `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":`;
    enum chunk = up ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}` ~ "\n";
    assert(said[0 .. saidLen] ==
          up ~ `{"sessionUpdate":"session_info_update","title":"hi","updatedAt":"2023-11-14T22:13:20Z"}}}` ~ "\n" ~ chunk
        ~ up ~ `{"sessionUpdate":"session_info_update","updatedAt":"2023-11-14T22:14:50Z"}}}` ~ "\n" ~ chunk);
    s.open[0].history.dispose();
}

// kind: "The category of tool being invoked. Helps clients choose appropriate
// icons and UI treatment." Only a tool's MCP annotations say what it does:
// readOnlyHint is read, and a tool that says nothing has no kind. content,
// "Content produced by the tool call", is the call's MCP content as it came,
// and a tool's error its own words.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2, getcwd;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    enum ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    enum calls = ok ~ `{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"test__look","arguments":"{}"}},`
        ~ `{"id":"c2","type":"function","function":{"name":"test__touch","arguments":"{}"}},`
        ~ `{"id":"c3","type":"function","function":{"name":"test__break","arguments":"{}"}}]}}]}`;
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
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"python3","args":["`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/look_server.py"],"env":[]}]}}`);
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    answer(req.slice(), r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/set_mode","params":{"sessionId":"code-100-7-1","modeId":"bypassPermissions"}}`, r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"go"}]}}`, r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    Reply closed;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
    __gshared char[65536] said;
    size_t saidLen = 0;
    while (true) {
        auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
        if (got <= 0) break;
        saidLen += cast(size_t) got;
    }
    close(o[0]);
    auto out_ = said[0 .. saidLen];
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c1","title":"test__look","name":"test__look","kind":"read","status":"in_progress","rawInput":{}}`) >= 0);
    assert(indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c2","title":"test__touch","name":"test__touch","status":"in_progress","rawInput":{}}`) >= 0);
    assert(indexOf(out_, `"toolCallId":"c1","status":"completed","rawOutput":{"jsonrpc": "2.0", "id": 3, "result": {"resultType": "complete", "content": [{"type": "text", "text": "look done"}]}},`
        ~ `"content":[{"type":"content","content":{"type":"text","text":"look done"}}]}`) >= 0);
    assert(indexOf(out_, `"toolCallId":"c3","status":"failed"`) >= 0);
    assert(indexOf(out_, `"content":[{"type":"content","content":{"type":"text","text":"disk full"}}]}`) >= 0);
    s.open[0].history.dispose();
}

// "After creating a session, the Agent MAY send a list of available commands
// via the available_commands_update session notification." A session's MCP
// prompts are its commands, server__prompt, written after the answer that
// made the session the client's; a prompt takes "All text that was typed
// after the command name" as its one argument, so one with two is not offered.
// "Commands are included as regular user messages in prompt requests": a turn
// that starts with one asks the model what the prompt gives instead of what
// was typed.
version (Posix) unittest {
    import core.sys.posix.unistd : write, close, fork, _exit, read, dup, dup2, getcwd, pipe;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    enum done = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 4) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        foreach (_; 0 .. 2) {
            char[65536] got;
            auto c = accept(fd, null, null); read(c, got.ptr, got.length); write(c, done.ptr, done.length); close(c);
        }
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

    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    scope(exit) { kill(child, SIGKILL); waitpid(child, null, 0); }
    Reply req, r;
    scope(exit) { req.dispose(); r.dispose(); }
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"test","command":"python3","args":["`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/prompt_server.py"],"env":[]}]}}`);
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    answer(req.slice(), r, s);
    bool opened = indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0;
    __gshared char[8192] afterNew;
    size_t afterLen = s.after.len;
    foreach (i, c; s.after.slice()) afterNew[i] = c;
    s.after.len = 0;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"/test__review src/a.d"}]}}`, r, s);
    bool reviewed = r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`;
    __gshared char[8192] history;
    size_t historyLen = s.open[0].history.len;
    foreach (i, c; s.open[0].history.slice()) history[i] = c;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"/test__review"}]}}`, r, s);
    __gshared char[4096] bare;
    size_t bareLen = r.len;
    foreach (i, c; r.slice()) bare[i] = c;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"/test__picture"}]}}`, r, s);
    __gshared char[4096] pictured;
    size_t picturedLen = r.len;
    foreach (i, c; r.slice()) pictured[i] = c;
    r.len = 0;
    // Not a command: what was typed, as it was.
    answer(`{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"/nothing here"}]}}`, r, s);
    bool plain = r.slice() == `{"jsonrpc":"2.0","id":5,"result":{"stopReason":"end_turn"}}`;
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    Reply closed;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
    char[65536] drain;
    while (read(o[0], drain.ptr, drain.length) > 0) {}
    close(o[0]);

    assert(opened);
    assert(afterNew[0 .. afterLen] == `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"code-100-7-1","update":{"sessionUpdate":"available_commands_update","availableCommands":[`
        ~ `{"name":"test__review","description":"Review a file","input":{"hint":"the file to review"}},`
        ~ `{"name":"test__hello","description":"Say hello"},`
        ~ `{"name":"test__picture","description":"Look at a picture"}]}}}` ~ "\n");
    assert(reviewed);
    assert(indexOf(history[0 .. historyLen], `{"role":"user","content":"Review src/a.d for bugs."},{"role":"assistant","content":"I will read it first."},{"role":"assistant","content":"done"}`) == 0);
    assert(indexOf(bare[0 .. bareLen], `"error":{"code":-32602,"message":"test__review needs input: the file to review"`) >= 0);
    assert(indexOf(pictured[0 .. picturedLen], `"error":{"code":-32603,"message":"test__picture gives a message ground code cannot ask the model: image"`) >= 0);
    assert(plain);
    assert(indexOf(s.open[0].history.slice(), `{"role":"user","content":"/nothing here"}`) >= 0);
    s.open[0].history.dispose();
}

// A text resource embedded in the prompt joins what was typed, under its uri.
// A resource_link that is not file:// is read through the session's MCP
// servers, resources/read, the first that has it; one none has, or that holds
// no text, is the prompt's error, by its uri.
version (Posix) unittest {
    import core.sys.posix.unistd : write, close, fork, _exit, read, dup, dup2, getcwd, pipe;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.stdc.stdio : fflush, stdout;
    import matcher : indexOf;
    import code.mcp : closeMcp;

    __gshared char[4096] cwd;
    assert(getcwd(cwd.ptr, cwd.length) !is null);
    size_t cwdLen = 0; while (cwd[cwdLen]) cwdLen++;
    enum done = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 4) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    auto child = fork();
    if (child == 0) {
        foreach (_; 0 .. 2) {
            char[65536] got;
            auto c = accept(fd, null, null); read(c, got.ptr, got.length); write(c, done.ptr, done.length); close(c);
        }
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

    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    scope(exit) { kill(child, SIGKILL); waitpid(child, null, 0); }
    Reply req, r;
    scope(exit) { req.dispose(); r.dispose(); }
    req.add(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"notes","command":"python3","args":["`);
    req.add(cwd[0 .. cwdLen]); req.add(`/mcp/resource_server.py"],"env":[]}]}}`);
    __gshared char[4096] said1, said2, said3;
    size_t len1, len2, len3;
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    answer(req.slice(), r, s);
    bool opened = indexOf(r.slice(), `"sessionId":"code-100-7-1"`) >= 0;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"read these"},`
        ~ `{"type":"resource","resource":{"uri":"file:///work/a.d","mimeType":"text/x-d","text":"int x;"}},`
        ~ `{"type":"resource_link","name":"notes","uri":"mem://notes/a"}]}}`, r, s);
    len1 = r.len; foreach (i, c; r.slice()) said1[i] = c;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"resource_link","name":"x","uri":"mem://missing"}]}}`, r, s);
    len2 = r.len; foreach (i, c; r.slice()) said2[i] = c;
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"resource_link","name":"logo","uri":"mem://logo"}]}}`, r, s);
    len3 = r.len; foreach (i, c; r.slice()) said3[i] = c;
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    Reply closed;
    assert(closeMcp(s.open[0].mcp, closed));
    closed.dispose();
    char[65536] drain;
    while (read(o[0], drain.ptr, drain.length) > 0) {}
    close(o[0]);

    assert(opened);
    assert(said1[0 .. len1] == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(s.open[0].history.slice(), `{"role":"user","content":"read these\n\nnotes (mem://notes/a):\nthe notes say hi\n\nfile:///work/a.d:\nint x;"}`) == 0);
    assert(indexOf(said2[0 .. len2], `"error":{"code":-32603,"message":"no MCP server of the session reads mem://missing"`) >= 0);
    assert(indexOf(said3[0 .. len3], `"error":{"code":-32603,"message":"mem://logo holds no text to give the model"`) >= 0);
    s.open[0].history.dispose();
}
