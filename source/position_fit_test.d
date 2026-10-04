module position_fit_test;

// A 220-character performance id read back as its first 80. The driver's halt
// wrote a second row under the cut id, its own row stayed live, and the driver
// asked again without sleeping, four million times an hour.

import ritual : writePosition, byPerformanceId, start, RitualState;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    static immutable char[220] longId = 'x';
    auto p = start("stepcounter", 4);
    p.id = longId[];
    p.repo = "/alice/smartwatchapp";
    p.rites = "STEP1,STEP2,STEP3,END";
    p.state = RitualState.Live;
    assert(writePosition(db, p));
    auto got = byPerformanceId(db, longId[]);
    assert(!got.valid || got.p.id.length == longId.length, "a row is never read as whole with a column cut");
    sqlite3_close(db);
}
