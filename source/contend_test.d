module contend_test;

// Two drivers, one position. `advance` is called from stop.d, watch.d and
// drive.d, and nothing coordinated them.
// "fix 79"

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

// "An abort that leaves the agent running has aborted nothing."
// 「[Opus 5.5] A verdict that lost its revision to a write while the rite ran is retaken on the row as it」
// 「[Opus 5.5] stands only while that row is still the walk it was about: an abort leaves `current` where it」
// 「[Opus 5.5] was, and the retake wrote the walk on over it. deploy-1793841311 was aborted at 01:24:44 and」
// 「[Opus 5.5] walked on to done at 01:28:41.」
unittest {
    import ritual : retakes, abort;
    auto p = seeded();
    p.current = 1;
    auto same = p;
    same.rev = p.rev + 1;
    assert(retakes(p, same), "a revision moved by bookkeeping is retaken");
    auto walked = same;
    walked.current = 2;
    assert(!retakes(p, walked), "a walk somebody moved on is theirs");
    auto aborted = abort(same);
    assert(aborted.current == p.current);
    assert(!retakes(p, aborted), "an aborted walk stays aborted");
}

// "ritual is hands-off, walk away"
// A start that failed made no agent and no tree, so no rite of the walk can run: the performance
// is halted where the failure is known, at bind, and not left live for the ten minutes the
// driver waits on a tree nobody makes. A performance that is not live is not touched.
unittest {
    import ritual : haltFailedStart, byPerformanceId;
    auto db = memDb();
    auto p = seeded();
    assert(writePosition(db, p));
    assert(haltFailedStart(db, "probe-1"));
    auto now = byPerformanceId(db, "probe-1");
    assert(now.valid && now.p.state == RitualState.Halted, "a failed start halts its walk");

    auto ended = seeded();
    ended.id = "probe-2";
    ended.state = RitualState.Aborted;
    assert(writePosition(db, ended));
    assert(!haltFailedStart(db, "probe-2"), "an ended walk is not halted again");
    assert(byPerformanceId(db, "probe-2").p.state == RitualState.Aborted);
    assert(!haltFailedStart(db, "no-such"), "no row, nothing to halt");
    sqlite3_close(db);
}

// A failed start halts only a walk nobody has touched: once the driver has claimed a rite, or a push
// waits to land on it, the halt would discard that rite's outcome or be revived by the landing. That
// walk is left to the driver, which halts it when no tree comes.
unittest {
    import ritual : haltFailedStart, byPerformanceId, RiteState;
    import ritual.store : setLanding;
    auto db = memDb();

    auto claimed = seeded();
    claimed.id = "probe-3";
    claimed.states[0] = RiteState.Running;
    assert(writePosition(db, claimed));
    assert(!haltFailedStart(db, "probe-3"), "a rite the driver claimed is its to finish");
    assert(byPerformanceId(db, "probe-3").p.state == RitualState.Live);

    auto pushed = seeded();
    pushed.id = "probe-4";
    assert(writePosition(db, pushed));
    assert(setLanding(db, "probe-4", "0123456789abcdef0123456789abcdef01234567"));
    assert(!haltFailedStart(db, "probe-4"), "a push waiting to land is the driver's to walk");
    assert(byPerformanceId(db, "probe-4").p.state == RitualState.Live);
    sqlite3_close(db);
}
