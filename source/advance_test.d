module advance_test;

// The one piece with no code: something reads the position, runs the rite it
// is on, and moves. Every part of it existed and tested; none was ever called
// in sequence, so the briefing said rite 1 of 9 forever.

import proto : parsePbt;
import ritual : advance, flatten, start, Position, RiteState, RitualState;
import rite : Verdict;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
            sqlite3_column_int64, SQLITE_ROW;

enum src = `
rites walk {
  START { eval: "true" }
  HOLD  { eval: "false"  catch: 1 }
  BACK  { eval: "false"  catch: 1  goto: START }
  WEIRD { eval: "exit 3" }
  SLOW  { eval: "echo short-moon Successful in 8s"  wait: 20  to: parent }
  AFTER { eval: "true" }
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

private long rows(sqlite3* db) {
    enum q = "SELECT count(*) FROM attestations WHERE json_extract(attributes,'$.rite') IS NOT NULL\0";
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

private Position at(size_t i) {
    auto p = start("probe", flat.count);
    p.id = "probe-1";
    p.repo = "/src/proj";
    p.worktree = "/tmp";
    p.parent = "parent-session";
    p.branch = "probe-branch";
    p.current = i;
    return p;
}

unittest {
    auto db = memDb();
    auto r = advance(db, "sess", at(0), flat, 100);
    assert(r.ran);
    assert(r.verdict == Verdict.Advance);
    assert(r.after.current == 1);
    assert(r.after.states[0] == RiteState.Passed);
    assert(rows(db) == 1);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // A caught code holds the position and marks the rite as having run —
    // the difference between the two pendings the status line renders.
    auto r = advance(db, "sess", at(1), flat, 100);
    assert(r.verdict == Verdict.Hold);
    assert(r.after.current == 1);
    assert(r.after.states[1] == RiteState.Ran);
    assert(r.after.state == RitualState.Live);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // goto is what a caught code does when the rite names somewhere to go.
    auto r = advance(db, "sess", at(2), flat, 100);
    assert(r.verdict == Verdict.Hold);
    assert(r.after.current == 0);
    assert(r.after.states[2] == RiteState.Ran);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // 3 is neither the pass nor a catch, so the rite cannot read it.
    auto r = advance(db, "sess", at(3), flat, 100);
    assert(r.verdict == Verdict.Halt);
    assert(r.code == 3);
    assert(r.after.state == RitualState.Halted);
    assert(r.after.states[3] == RiteState.Halted);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // An ended performance is not stepped again, and no row is written for a
    // rite that did not run.
    auto p = at(0);
    p.state = RitualState.Done;
    auto r = advance(db, "sess", p, flat, 100);
    assert(!r.ran);
    assert(r.after.current == 0);
    assert(rows(db) == 0);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // The position it returns is the position on disk, or the next turn reads
    // a stale one and runs the same rite again.
    import ritual : readPosition;
    auto r = advance(db, "sess", at(0), flat, 100);
    assert(r.ran);
    auto back = readPosition(db, "/src/proj");
    assert(back.valid);
    assert(back.p.current == 1);
    sqlite3_close(db);
}

// --- A goto cycle is bounded ---
// Measured: a ritual walked its rites until it was aborted by hand, because
// a fruit in the tree had no rite to pick it and CHECKTREE never emptied.

import ritual : MAX_GOTOS, RitualState;

enum loopSrc = `
rites spin {
  HERE { eval: "true" }
  BACK { eval: "false"  catch: 1  goto: HERE }
}

project {
  path: "/src/proj"
  ritual spinner { spin }
}
`;
enum loopFlat = flatten(parsePbt(loopSrc), 0);

unittest {
    auto db = memDb();
    auto p = start("spinner", loopFlat.count);
    p.id = "spin-1";
    p.repo = "/src/proj";
    p.worktree = "/tmp";

    // Left alone this never ends: BACK holds and jumps to HERE forever.
    size_t turns;
    while (p.state == RitualState.Live && turns < 500) {
        auto r = advance(db, "sess", p, loopFlat, 100 + cast(long) turns);
        if (!r.ran) break;
        p = r.after;
        turns++;
    }

    assert(p.state == RitualState.Halted, "an unbounded cycle must stop itself");
    assert(p.gotos == MAX_GOTOS);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // The budget is spent by jumping, not by running. A rite that advances
    // does not cost one.
    auto p = at(0);
    auto r = advance(db, "sess", p, flat, 100);
    assert(r.after.gotos == 0);
    sqlite3_close(db);
}

// --- The mic is claimed before the rite, not after it ---
// "and ci keeps holding the mic in this case"

// `wait:` parsed into ParsedRite and was dropped at flatten, so no rite ever
// carried it as far as the thing that runs rites.
static assert(flat.rites[4].wait == 20);

unittest {
    auto db = memDb();
    // Two writes for one rite: the claim before it runs, and the handoff after.
    // Taken only after, the row says the agent is speaking for as long as the
    // rite blocks, which is the whole of what the mic exists to say.
    auto r = advance(db, "sess", at(0), flat, 100);
    assert(r.applied);
    assert(r.after.rev == 2, "the claim and the handoff are both writes");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    import mic : Mic;
    import ritual : readPosition;
    // SLOW names a wait, so ci is who the claim names while it runs.
    auto r = advance(db, "sess", at(4), flat, 100);
    assert(r.applied);
    assert(r.after.rev == 2);
    // "the mic would at that point be handed over to the agent as we wait for
    // it to reach a stop again"
    assert(r.after.mic == Mic.Agent);
    sqlite3_close(db);
}

private long notes(sqlite3* db, const(char)* q) {
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

unittest {
    auto db = memDb();
    // "the outcome is what is spoken back into the mic" — what the rite
    // printed is what CI said, under a key the CI gutter can recognise.
    auto r = advance(db, "sess", at(4), flat, 100);
    assert(r.verdict == Verdict.Advance);

    enum q = "SELECT count(*) FROM attestations WHERE id LIKE 'immediate:note:%:ci:probe-1:SLOW%'\0";
    assert(notes(db, q.ptr) >= 1, "nothing wrote a ci key");

    enum said = "SELECT count(*) FROM attestations WHERE id LIKE '%:ci:probe-1:SLOW%' "
        ~ "AND json_extract(attributes,'$.detail') LIKE '%short-moon Successful in 8s%'\0";
    assert(notes(db, said.ptr) >= 1, "the rite's own output is what ci said");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    import mic : Mic;
    // Nothing is waiting for a stop that will not come. A performance that
    // ended hands the mic to the operator, not to an agent it just ended.
    auto r = advance(db, "sess", at(5), flat, 100);
    assert(r.after.state == RitualState.Done);
    assert(r.after.mic == Mic.Human);
    sqlite3_close(db);
}
