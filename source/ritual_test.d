module ritual_test;

// Where we are, and what each rite has already been.
// Brandon: "see where we are INSIDE of the ritual"

import rite : Verdict;
import ritual : Position, RiteState, RitualState, start, step, jump,
                encodeStates, restore;

// A ritual that has not run has no history. Every rite is the darker gray.
enum fresh = start("boxsurvival", 3);
static assert(fresh.ritual == "boxsurvival");
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
enum back = restore("boxsurvival", held.current, heldRow.text(), RitualState.Live);
static assert(back.valid);
static assert(back.p.ritual == "boxsurvival");
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

// --- The row on disk ---

import ritual : writePosition, readPosition;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db), "test runs against the product schema, not a copy of it");
    return db;
}

unittest {
    auto db = memDb();
    // No ritual here. Absence is a verdict too, not an empty Position.
    assert(!readPosition(db, "/q.sbvh.nl").valid);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, "/q.sbvh.nl", held));
    auto got = readPosition(db, "/q.sbvh.nl");
    assert(got.valid);
    assert(got.p.ritual == "boxsurvival");
    assert(got.p.current == 1);
    assert(got.p.states[0] == RiteState.Passed);
    assert(got.p.states[1] == RiteState.Ran);
    assert(got.p.state == RitualState.Live);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, "/q.sbvh.nl", held));
    assert(writePosition(db, "/q.sbvh.nl", atLast));
    // One ritual per project. A second start replaces, never accumulates —
    // two live rituals both want the one Stop message per turn.
    auto got = readPosition(db, "/q.sbvh.nl");
    assert(got.valid);
    assert(got.p.state == RitualState.Done);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    assert(writePosition(db, "/q.sbvh.nl", held));
    // Projects do not see each other's rituals.
    assert(!readPosition(db, "/QNTX").valid);
    sqlite3_close(db);
}
