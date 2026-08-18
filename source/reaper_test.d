module reaper_test;

// An ending ends the agent too. Measured 2026-08-07: eleven `claude -w`
// processes against three live performances — eight against ended ones, the
// oldest an hour past its abort, still editing a worktree and committing.

import ritual : Position, RitualState, owesKill;

private Position perf(RitualState st, int pid) {
    Position p;
    p.id = "willow-1";
    p.ritual = "willow";
    p.state = st;
    p.agentPid = pid;
    return p;
}

// The three endings all owe it. A performance that stopped is not one whose
// agent should keep working.
static assert(owesKill(perf(RitualState.Aborted, 4242)));
static assert(owesKill(perf(RitualState.Halted, 4242)));
static assert(owesKill(perf(RitualState.Done, 4242)));

// A live one owes nothing — that is the agent doing its job.
static assert(!owesKill(perf(RitualState.Live, 4242)));

// No pid is nothing to kill. 0 is never signalled: kill(0, …) hits the whole
// process group, which is every claude on the machine.
static assert(!owesKill(perf(RitualState.Aborted, 0)));
static assert(!owesKill(perf(RitualState.Aborted, -1)));

// --- The pid survives the store, or nothing can find the process ---

import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, hasColumn, SQLITE_OK;
import ritual : writePosition, readPosition;

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(hasColumn(db, "ritual_position", "agent_pid"));

    auto p = perf(RitualState.Live, 91337);
    p.repo = "/sbvh-nl/grove";
    p.rites = "START,APPLE";
    p.riteCount = 2;
    assert(writePosition(db, p));

    auto got = readPosition(db, "/sbvh-nl/grove");
    assert(got.valid);
    assert(got.p.agentPid == 91337);
    sqlite3_close(db);
}
