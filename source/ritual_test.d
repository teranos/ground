module ritual_test;

// Where we are, and what each rite has already been.
// Brandon: "see where we are INSIDE of the ritual"

import rite : Verdict;
import ritual : Position, RiteState, RitualState, start, step, jump,
                encodeStates, restore;

// A ritual that has not run has no history. Every rite is the darker gray.
enum fresh = start("probe", 3);
static assert(fresh.ritual == "probe");
static assert(fresh.current == 0);
static assert(fresh.state == RitualState.Live);
static assert(fresh.states[0] == RiteState.Never);
static assert(fresh.states[2] == RiteState.Never);

// "green is passed"
enum passedOne = step(fresh, Verdict.Advance);
static assert(passedOne.states[0] == RiteState.Passed);
static assert(passedOne.current == 1);
static assert(passedOne.state == RitualState.Live);

// "so catch means hold, until true" / "lighter gray is pending ran before"
// A held rite keeps the position and stops being one that never ran, which
// is the whole difference between the two grays.
enum held = step(passedOne, Verdict.Hold);
static assert(held.current == 1);
static assert(held.states[1] == RiteState.Ran);
static assert(held.state == RitualState.Live);

// Holding again changes nothing. The ritual is not stuck, it is waiting.
static assert(step(held, Verdict.Hold).current == 1);
static assert(step(held, Verdict.Hold).states[1] == RiteState.Ran);

// "it ends when it ends, not because i ran ritual stop"
// The last rite passing is one of the two endings, and it needs no command.
enum atLast = step(step(held, Verdict.Advance), Verdict.Advance);
static assert(atLast.current == 3);
static assert(atLast.state == RitualState.Done);
static assert(atLast.states[2] == RiteState.Passed);

// "blinking red is halted" — the other ending.
enum halted = step(passedOne, Verdict.Halt);
static assert(halted.states[1] == RiteState.Halted);
static assert(halted.state == RitualState.Halted);

// An ended ritual does not move. Whatever ran after the halt was not a rite
// of this ritual, and must not be recorded as one.
static assert(step(halted, Verdict.Advance).current == 1);
static assert(step(halted, Verdict.Advance).state == RitualState.Halted);
static assert(step(atLast, Verdict.Advance).state == RitualState.Done);

// "i think i want goto, not else, goto seems more honest for what it is"
// A jump backwards keeps the history, so the line shows what happened rather
// than pretending it did not.
enum jumped = jump(atLast, 0);
static assert(jumped.current == 0);
static assert(jumped.state == RitualState.Live);
static assert(jumped.states[0] == RiteState.Passed);
static assert(jumped.states[2] == RiteState.Passed);

// A jump out of range is refused rather than clamped: CTFE item 10 already
// proved the name resolves, so this would be a runtime bug, not a pbt one.
static assert(jump(atLast, 9).current == atLast.current);

// --- What the row holds ---
// One character per rite, so collet reads the line without a join and a
// person reads the row without a decoder.

static assert(encodeStates(fresh)     == "...");
static assert(encodeStates(passedOne) == "+..");
static assert(encodeStates(held)      == "+-.");
static assert(encodeStates(atLast)    == "+++");
static assert(encodeStates(halted)    == "+!.");

// A character the writer never emits is not silently a Never — a row this
// process cannot read is a row it must not render.
enum bad = restore("r", 0, "+?.", RitualState.Live);
static assert(!bad.valid);

// Round trip. The states survive; so does everything the row carries.
enum heldRow = encodeStates(held);
enum back = restore("probe", held.current, heldRow.text(), RitualState.Live);
static assert(back.valid);
static assert(back.p.ritual == "probe");
static assert(back.p.current == 1);
static assert(back.p.riteCount == 3);
static assert(back.p.states[0] == RiteState.Passed);
static assert(back.p.states[1] == RiteState.Ran);
static assert(back.p.states[2] == RiteState.Never);
static assert(back.p.state == RitualState.Live);

// A current past the end of the states is the row disagreeing with itself.
static assert(!restore("r", 5, "+-.", RitualState.Live).valid);

// Except at exactly the end, which is where a Done ritual sits.
static assert(restore("r", 3, "+++", RitualState.Done).valid);

// --- Abort ---
// "it ends when it ends, not because i ran ritual stop" — so this is the
// exception, and it is the only ending a person causes.

import ritual : abort;

enum stopped = abort(step(fresh, Verdict.Advance));
static assert(stopped.state == RitualState.Aborted);

// The position is left where it was. Aborting says stop, not rewind, and the
// line still shows how far it got.
static assert(stopped.current == 1);
static assert(stopped.states[0] == RiteState.Passed);

// An ending is not overwritten by another ending. A done performance that
// could be aborted would lose the verdict it earned.
static assert(abort(atLast).state == RitualState.Done);
static assert(abort(halted).state == RitualState.Halted);

// --- Identity ---
// "each ritual perfomance occurs in separate named branches" /
// "the name of the branch is not something to key on"

import ritual : performanceId;

// The id names the performance and the moment. Two performances of the same
// ritual are two rows, not one overwriting the other.
enum idA = performanceId("probe", 1754400000);
enum idB = performanceId("probe", 1754400001);
static assert(idA.text() == "probe-1754400000");
static assert(idA.text() != idB.text());

// --- The row on disk ---

import ritual : writePosition, readPosition, readPositionAt;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db), "test runs against the product schema, not a copy of it");
    return db;
}

private Position perf(Position p, string id, string repo, string tree) {
    p.id = id;
    p.repo = repo;
    p.worktree = tree;
    p.branch = "detached";
    return p;
}

unittest {
    auto db = memDb();
    // No performance here. Absence is a verdict too, not an empty Position.
    assert(!readPosition(db, "/src/proj").valid);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    auto p = perf(held, "probe-1", "/src/proj", "/tmp/wt-a");
    assert(writePosition(db, p));

    auto got = readPosition(db, "/src/proj");
    assert(got.valid);
    assert(got.p.id == "probe-1");
    assert(got.p.ritual == "probe");
    assert(got.p.worktree == "/tmp/wt-a");
    assert(got.p.current == 1);
    assert(got.p.states[0] == RiteState.Passed);
    assert(got.p.states[1] == RiteState.Ran);
    assert(got.p.state == RitualState.Live);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    auto p = perf(held, "probe-1", "/src/proj", "/tmp/wt-a");
    assert(writePosition(db, p));

    // The tree is gone. The record is not — that is the whole point of the
    // id being the key and the path being an index.
    assert(!readPositionAt(db, "/tmp/wt-a-removed").valid);
    assert(readPosition(db, "/src/proj").valid);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, perf(held, "probe-1", "/src/proj", "/tmp/wt-a")));
    // Standing in the tree finds the performance being done there.
    auto got = readPositionAt(db, "/tmp/wt-a");
    assert(got.valid);
    assert(got.p.id == "probe-1");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, perf(held, "probe-1", "/src/proj", "/tmp/wt-a")));
    assert(writePosition(db, perf(atLast, "probe-1", "/src/proj", "/tmp/wt-a")));
    // Same id is the same performance moving, not a second one.
    auto got = readPosition(db, "/src/proj");
    assert(got.valid);
    assert(got.p.state == RitualState.Done);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, perf(held, "probe-1", "/src/proj", "/tmp/wt-a")));
    // Repos do not see each other's performances.
    assert(!readPosition(db, "/src/other").valid);
    sqlite3_close(db);
}

// A walk that held twice and then passed reads as ten clean passes: `throws`
// is the rite's own counter and the advance clears it, `states` keeps one
// glyph per rite. Nothing survives to say the world was ever not ready.
enum heldOnce = step(fresh, Verdict.Hold);
enum heldTwice = step(heldOnce, Verdict.Hold);
static assert(heldTwice.throws == 0, "throws counts throw-backs, not holds");
static assert(heldTwice.holds == 2);

// Cleared on nothing. The count is the performance's, the way gotos is.
static assert(step(heldTwice, Verdict.Advance).holds == 2);
static assert(jump(heldTwice, 0).holds == 2);
static assert(fresh.holds == 0);

unittest {
    auto db = memDb();
    auto p = perf(heldTwice, "probe-h", "/src/proj", "/tmp/wt-h");
    assert(writePosition(db, p));
    // It has to outlive the process, or it answers nothing tomorrow.
    auto got = readPositionAt(db, "/tmp/wt-h");
    assert(got.valid);
    assert(got.p.holds == 2);
    sqlite3_close(db);
}
