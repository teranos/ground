module rite_attest_test;

// A rite that ran leaves a record. Nothing outside the ritual can otherwise
// tell that anything happened — not the grove's own `ran` rite, not a script
// counting how many times a rite passed.

import ritual : riteAttributes, RiteState;
import rite : Verdict;

// The fields something else has to read: which performance, which rite, what
// the verdict was, and what the command actually said.
enum a = riteAttributes("probe-1", "probe", "APPLE", Verdict.Advance, 0, "picked\n");
static assert(a.text() ==
    `{"performance":"probe-1","ritual":"probe","rite":"APPLE",`
    ~ `"verdict":"advance","code":0,"output":"picked\n"}`);

// Hold and halt are the other two, spelled out rather than inferred from the
// code — a reader should not have to know the rite's pass and catch values.
enum h = riteAttributes("probe-1", "probe", "CI", Verdict.Hold, 1, "");
static assert(h.text() ==
    `{"performance":"probe-1","ritual":"probe","rite":"CI",`
    ~ `"verdict":"hold","code":1,"output":""}`);

enum x = riteAttributes("probe-1", "probe", "CI", Verdict.Halt, 127, "not found");
static assert(x.text() ==
    `{"performance":"probe-1","ritual":"probe","rite":"CI",`
    ~ `"verdict":"halt","code":127,"output":"not found"}`);

// Output is whatever the command printed, so it can carry anything that would
// break the row it is being written into.
enum q = riteAttributes("p", "r", "n", Verdict.Advance, 0, `say "hi"\ok`);
static assert(q.text() ==
    `{"performance":"p","ritual":"r","rite":"n",`
    ~ `"verdict":"advance","code":0,"output":"say \"hi\"\\ok"}`);

// A tab and a carriage return are as fatal to the JSON as a quote is.
enum c = riteAttributes("p", "r", "n", Verdict.Advance, 0, "a\tb\rc");
static assert(c.text() ==
    `{"performance":"p","ritual":"r","rite":"n",`
    ~ `"verdict":"advance","code":0,"output":"a\tb\rc"}`);

// --- The row ---

import ritual : attestRite, Position;
import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, applySchema,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
            sqlite3_column_int64, SQLITE_OK, SQLITE_ROW;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private long countRites(sqlite3* db) {
    enum q = "SELECT count(*) FROM attestations WHERE json_extract(attributes,'$.rite') IS NOT NULL\0";
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

private Position pos() {
    Position p;
    p.id = "probe-1";
    p.ritual = "probe";
    p.riteCount = 3;
    return p;
}

unittest {
    auto db = memDb();
    // The query the grove ritual's own `ran` rite runs.
    assert(countRites(db) == 0);

    assert(attestRite(db, "sess", pos(), "APPLE", Verdict.Advance, 0, "picked\n", 100));
    assert(countRites(db) == 1);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // A held rite re-run leaves a row per attempt, so counting rows counts
    // attempts. Sharing an id would make twenty holds look like one.
    assert(attestRite(db, "sess", pos(), "CI", Verdict.Hold, 1, "", 100));
    assert(attestRite(db, "sess", pos(), "CI", Verdict.Hold, 1, "", 101));
    assert(countRites(db) == 2);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // The same attempt written twice is one row, not two.
    assert(attestRite(db, "sess", pos(), "CI", Verdict.Hold, 1, "", 100));
    assert(attestRite(db, "sess", pos(), "CI", Verdict.Hold, 1, "", 100));
    assert(countRites(db) == 1);
    sqlite3_close(db);
}
