module position_edge_test;

// "the ritual should end after the l part is over, unless a push makes it a longer ritual"
// The walk is written to its row after every rite and read back before the
// next. A commit's walk stops at the edge of its block, and the read-back has
// to say so, or the walk runs on into the push's block.

import ritual : writePosition, byPerformanceId, start, RitualState;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    auto p = start("deploy", 4, 0, 2);
    p.id = "deploy-1";
    p.repo = "/alice/smartwatchapp";
    p.rites = "STAND,MOVE,TARGET,ATS";
    p.state = RitualState.Live;
    assert(p.edge == 2);
    assert(writePosition(db, p));
    auto got = byPerformanceId(db, "deploy-1");
    assert(got.valid);
    assert(got.p.edge == 2, "the edge written is the edge read back");
    sqlite3_close(db);
}
