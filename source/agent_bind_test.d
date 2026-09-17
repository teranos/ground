module agent_bind_test;

// Who carries a performance, learned from the start that started them. Two
// halves arrive in either order: the start prints the agent's short id, and the
// agent's own SessionStart carries the long one the short one opens.

import ritual.position : start, RitualState, Position;
import ritual.store : writePosition, writePositionIf, byPerformanceId,
                      bindAgentId, bindSessionByAgent, sessionOfAgent;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, attestEventAt, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private Position performing(const(char)[] id) {
    auto p = start("probe", 2);
    p.id = id;
    p.repo = "/src/probe";
    p.worktree = "/tmp";
    return p;
}

enum SHORT = "7a5399f5";
enum LONG = "7a5399f5-0d25-4a97-a62a-93fefe1324f8";

unittest {
    // The id is the bind's to write. A driver holding a copy of the row from
    // before the bind writes the whole row back, and must not write it away.
    auto db = memDb();
    auto p = performing("probe-1");
    assert(writePosition(db, p));

    auto stale = byPerformanceId(db, "probe-1");
    assert(stale.valid && stale.p.agent.length == 0);

    assert(bindAgentId(db, "probe-1", SHORT));
    assert(writePositionIf(db, stale.p, stale.p.rev), "the stale copy still lands");

    auto now = byPerformanceId(db, "probe-1");
    assert(now.p.agent == SHORT, "and the agent it never knew of is still there");
    sqlite3_close(db);
}

unittest {
    // The start landed first. The agent's SessionStart finds the performance
    // whose agent its own session id opens with.
    auto db = memDb();
    assert(writePosition(db, performing("probe-2")));
    assert(bindAgentId(db, "probe-2", SHORT));

    assert(!bindSessionByAgent(db, "deadbeef-0000-4000-8000-000000000000", 41),
           "a person's own session in the same tree carries nothing");
    assert(byPerformanceId(db, "probe-2").p.agentSession.length == 0);

    assert(bindSessionByAgent(db, LONG, 42));
    auto got = byPerformanceId(db, "probe-2");
    assert(got.p.agentSession == LONG);
    assert(got.p.agentPid == 42);
    sqlite3_close(db);
}

unittest {
    // The SessionStart landed first: a warm spare starts before `claude --bg`
    // has returned to say who it started. The bind reads the long id off the
    // start ground already recorded.
    auto db = memDb();
    assert(writePosition(db, performing("probe-3")));
    attestEventAt(db, "SessionStart", "/tmp", LONG,
        `{"session_id":"` ~ LONG ~ `","source":"startup"}`, "2026-09-17T13:37:57Z", 7001);
    attestEventAt(db, "SessionStart", "/tmp", "deadbeef-0000-4000-8000-000000000000",
        `{"session_id":"deadbeef-0000-4000-8000-000000000000","source":"startup"}`,
        "2026-09-17T13:37:58Z", 7002);

    assert(sessionOfAgent(db, SHORT) == LONG);
    assert(sessionOfAgent(db, "0badc0de") is null, "no start recorded is no session");
    assert(sessionOfAgent(db, "") is null);
    sqlite3_close(db);
}

unittest {
    // A performance over before the bind arrives still learns its agent: that
    // is the one the bind then has to stop.
    auto db = memDb();
    auto p = performing("probe-4");
    p.state = RitualState.Done;
    assert(writePosition(db, p));
    assert(bindAgentId(db, "probe-4", SHORT));
    assert(byPerformanceId(db, "probe-4").p.agent == SHORT);

    // Nobody and nothing are not binds.
    assert(!bindAgentId(db, "probe-4", ""));
    assert(!bindAgentId(db, "", SHORT));
    assert(!bindAgentId(db, "no-such-performance", SHORT));
    sqlite3_close(db);
}
