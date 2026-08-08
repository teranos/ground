module delivery_test;

// Brandon: "WHY DONT WE HAVE MORE ABSOLUTE CONTROL OVER WHAT GOES WHERE"

import ritual.position : Position, start;
import ritual.delivery : Receiver, sessionOf, deliverable, wants, both, PARENT;

private Position perf() {
    auto p = start("willow", 10);
    p.id = "willow-1";
    p.parent = "parent-session";
    p.agentSession = "agent-session";
    return p;
}

enum p = perf();

// Two sides, two readers each. Human and HostLlm read the same session and
// differ by channel; that is the distinction the old two-value enum lost.
static assert(sessionOf(p, Receiver.Human) == "parent-session");
static assert(sessionOf(p, Receiver.HostLlm) == "parent-session");
static assert(sessionOf(p, Receiver.AgentLlm) == "agent-session");

// The ritual is the receiver, not a rite — a rite is a piece of it, and the
// ritual is what drives the chat through them. It has no session of its own,
// so naming it as an address is a mistake with an answer.
static assert(sessionOf(p, Receiver.Ritual) is null);

// "NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM"
static assert(wants(PARENT, Receiver.Human));
static assert(wants(PARENT, Receiver.HostLlm));
static assert(!wants(PARENT, Receiver.AgentLlm));

static assert(both(Receiver.Human, Receiver.HostLlm) == PARENT);

// Nobody to tell is not a delivery. A performance started from a terminal has
// no parent, and the rite lines it produces have nowhere to go.
enum orphan = { auto q = perf(); q.parent = ""; return q; }();
static assert(!deliverable(orphan, Receiver.HostLlm, false));
static assert(deliverable(orphan, Receiver.AgentLlm, false));

// The bug this exists to make unwriteable: an agent handed its own last
// message, framed as somebody quoting it and asking for work.
enum solo = { auto q = perf(); q.parent = "same"; q.agentSession = "same"; return q; }();
static assert(!deliverable(solo, Receiver.HostLlm, true));

// Ground's own words to that same session are fine — a briefing is not a
// quotation, and the agent has to be told which rite is open.
static assert(deliverable(solo, Receiver.HostLlm, false));
static assert(deliverable(solo, Receiver.AgentLlm, false));

// --- "to both the agent and parent" ---

import ritual.delivery : deliver;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
            sqlite3_column_int64, SQLITE_ROW;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private long count(sqlite3* db, const(char)* q) {
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

unittest {
    // "the outcome is what is spoken back into the mic to both the agent and
    // parent" — one call, two sessions.
    auto db = memDb();
    auto q = perf();
    assert(deliver(db, q, both(PARENT, Receiver.AgentLlm), "ci:willow-1:JUDGE", "all checks passed"));

    enum toParent = "SELECT count(*) FROM attestations WHERE id = 'immediate:note:parent-session:ci:willow-1:JUDGE'\0";
    enum toAgent  = "SELECT count(*) FROM attestations WHERE id = 'immediate:note:agent-session:ci:willow-1:JUDGE'\0";
    assert(count(db, toParent.ptr) == 1, "the parent hears it");
    assert(count(db, toAgent.ptr) == 1, "the agent hears it too");
    sqlite3_close(db);
}

unittest {
    // A rite naming only the parent still reaches only the parent.
    auto db = memDb();
    auto q = perf();
    assert(deliver(db, q, PARENT, "rite:willow-1:APPLE", "APPLE passed"));

    enum toParent = "SELECT count(*) FROM attestations WHERE id = 'immediate:note:parent-session:rite:willow-1:APPLE'\0";
    enum toAgent  = "SELECT count(*) FROM attestations WHERE id = 'immediate:note:agent-session:rite:willow-1:APPLE'\0";
    assert(count(db, toParent.ptr) == 1);
    assert(count(db, toAgent.ptr) == 0, "silence to anyone the rite did not name");
    sqlite3_close(db);
}
