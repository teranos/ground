module contend_test;

// Two drivers, one position. `advance` is called from stop.d, watch.d and
// drive.d, and nothing coordinated them.
// Brandon: "fix 79"

import proto : parsePbt;
import ritual : advance, flatten, start, writePosition, readPosition,
                Position, RitualState, threw;
import rite : Verdict;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

enum src = `
rites walk {
  ONE { eval: "true" }
  TWO { eval: "false"  catch: 1 }
}

project {
  path: "/src/proj"
  ritual probe { walk }
}
`;
enum parsed = parsePbt(src);
enum flat = flatten(parsed, 0);

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private Position seeded() {
    auto p = start("probe", flat.count);
    p.id = "probe-1";
    p.repo = "/src/proj";
    p.rites = "ONE,TWO";
    return p;
}

// The willow walk recorded START twice and JACKFRUIT twice, one pass each from
// two drivers running the same rite. A second advance from a stale read must
// not land: the position it describes is already gone.
unittest {
    auto db = memDb();
    auto p = seeded();
    assert(writePosition(db, p));

    auto fresh = readPosition(db, "/src/proj");
    assert(fresh.valid);

    // Both drivers read the same row before either has run anything.
    auto driverA = fresh.p;
    auto driverB = fresh.p;

    auto first = advance(db, "sess", driverA, flat, 1000);
    assert(first.ran);
    assert(first.applied, "the first writer owns the position");
    assert(first.after.current == 1);

    // "there can only be 1 mic per ritual performance"
    auto second = advance(db, "sess", driverB, flat, 1001);
    assert(!second.ran, "the loser never reaches the rite");
    assert(!second.applied, "a write from a stale read must not land");

    auto now = readPosition(db, "/src/proj");
    assert(now.valid);
    assert(now.p.current == 1, "the losing driver must not move the position");
    sqlite3_close(db);
}

// The lost increment: both drivers read throws=N, so a guard on `current`
// alone matches for both and the second write puts the counter back.
unittest {
    auto db = memDb();
    auto p = seeded();
    p.current = 1;                 // sitting on TWO, which holds
    assert(writePosition(db, p));

    auto fresh = readPosition(db, "/src/proj");
    auto driverA = fresh.p;
    auto driverB = fresh.p;

    auto held = advance(db, "sess", driverA, flat, 2000);
    assert(held.verdict == Verdict.Hold);
    assert(held.applied);

    // What stop.d does after a Hold: count the throw-back onto the row it won.
    auto back = threw(held.after);
    assert(writePosition(db, back));

    auto stale = advance(db, "sess", driverB, flat, 2001);
    assert(!stale.applied, "the stale driver must not write the count back");

    auto now = readPosition(db, "/src/proj");
    assert(now.p.throws == 1, "the throw-back survives the other driver");
    sqlite3_close(db);
}

unittest {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_stmt, sqlite3_column_int64, SQLITE_ROW;

    auto db = memDb();
    auto p = seeded();
    assert(writePosition(db, p));

    auto fresh = readPosition(db, "/src/proj");
    advance(db, "sess", fresh.p, flat, 3000);
    advance(db, "sess", fresh.p, flat, 3001);

    enum q = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(attributes,'$.rite') = 'ONE'\0";
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, q.ptr, -1, &s, null) == SQLITE_OK);
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    sqlite3_close(db);

    assert(n == 1, "the willow recorded START twice and JACKFRUIT twice");
}
