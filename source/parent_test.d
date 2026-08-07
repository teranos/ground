module parent_test;

// The row knows the agent's session and never knew yours. `ground ritual` is
// a CLI call with no session in it — but you run it as a Bash tool call, and
// ground sees that at PostToolUse with your session id and the command text.

import ritual : ritualStarted;

// The name of the ritual a command just started, or nothing.
static assert(ritualStarted("ground ritual willow") == "willow");
static assert(ritualStarted("cd /x/grove && ground ritual willow") == "willow");
static assert(ritualStarted("ground ritual boxsurvival ") == "boxsurvival");

// Other ground verbs start nothing. abort ends one and drive rides one.
static assert(ritualStarted("ground abort willow") == "");
static assert(ritualStarted("ground drive /x/grove-willow-1") == "");
static assert(ritualStarted("ground ritual") == "");

// Commands that merely mention it are not it. A grep for the word would bind
// the parent to whoever read the docs.
static assert(ritualStarted("grep -n 'ground ritual willow' RITUAL.md") == "");
static assert(ritualStarted("echo ground ritual willow") == "");
static assert(ritualStarted("") == "");

// --- The column round-trips ---

import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, hasColumn, SQLITE_OK;
import ritual : Position, RitualState, writePosition, readPosition;

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(hasColumn(db, "ritual_position", "parent"));

    Position p;
    p.id = "willow-1";
    p.repo = "/sbvh-nl/grove";
    p.ritual = "willow";
    p.rites = "START,APPLE";
    p.riteCount = 2;
    p.session = "agent-sess";
    p.parent = "operator-sess";
    p.state = RitualState.Live;
    assert(writePosition(db, p));

    auto got = readPosition(db, "/sbvh-nl/grove");
    assert(got.valid);
    assert(got.p.parent == "operator-sess");
    assert(got.p.session == "agent-sess");
    sqlite3_close(db);
}
