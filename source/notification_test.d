module notification_test;

// Notification is the only event whose exit 2 shows stderr to the person and
// nothing else — it cannot block and cannot inject context. Ground was
// registered for it and had no handler, so every one was attested and dropped.

import notification : haltNotice, nthRite, noticeFor;

// The row stores rite names comma-joined so it renders without the pbt.
static assert(nthRite("START,APPLE,ORANGE", 0) == "START");
static assert(nthRite("START,APPLE,ORANGE", 1) == "APPLE");
static assert(nthRite("START,APPLE,ORANGE", 2) == "ORANGE");

// Past the end is not a name. A notice naming a rite that does not exist is
// worse than one that names none.
static assert(nthRite("START,APPLE", 5) == "");
static assert(nthRite("", 0) == "");

// The exit code lives on the rite attestation, not on the position row, so
// there are two notices and the shorter one invents nothing.
enum n = haltNotice("willow", "APPLE", 125);
static assert(n.text() == "ground: ritual willow halted on APPLE with exit 125");
static assert(haltNotice("willow", "APPLE").text() == "ground: ritual willow halted on APPLE");

// "i will be able to talk about it with more confidence"
// What the rite answered, then what the agent said about it. The verdict is
// first because it is the part that says blocking, passing or stopped.
import notification : riteLine;
import rite : Verdict;

static assert(riteLine("willow", "APPLE", Verdict.Hold, "Took the APPLE out. Six left.").text()
    == "willow APPLE held · Took the APPLE out. Six left.");
// "its technically correct, and i want to keep it, but its too positive"
static assert(riteLine("willow", "APPLE", Verdict.Advance, "Done.").text()
    == "willow APPLE passed through · Done.");
static assert(riteLine("willow", "APPLE", Verdict.Halt, "I cannot find it.").text()
    == "willow APPLE halted · I cannot find it.");

// An agent that said nothing gets a line about the rite alone. The separator
// would otherwise promise something after it.
static assert(riteLine("willow", "APPLE", Verdict.Hold, "").text() == "willow APPLE held");

// The agent speaking is not a verdict. Wiring 82c through riteLine stamped
// `held` on it, which a dispatch rite can never be.
import notification : agentLine;
static assert(agentLine("willow", "APPLE", "Took the APPLE out.").text()
    == "willow APPLE · Took the APPLE out.");

// Nothing said, nothing to carry — the separator would promise words.
static assert(agentLine("willow", "APPLE", "").text() == "");

// A dispatch is not a check, so `ci all checks passed ✓` was never true of one.
import notification : verdictWord;
static assert(verdictWord(0, true) == "dispatched");
static assert(verdictWord(0, false) == "passed through");
static assert(verdictWord(1, true) == "held");
static assert(verdictWord(2, true) == "halted");

// "shouldnt dispatch rites say what happened, which is dispatched workflow.yml"
static assert(riteLine("coinflip", "FLIP1", Verdict.Advance, "", "", "",
                       "sbvh-nl/grove long-coin.yml").text()
    == "coinflip FLIP1 dispatched sbvh-nl/grove long-coin.yml");

// gh could not send it, so nothing was dispatched and the act is not claimed.
static assert(riteLine("coinflip", "FLIP1", Verdict.Halt, "", "", "",
                       "sbvh-nl/grove long-coin.yml").text()
    == "coinflip FLIP1 halted");

// --- What the handler decides, against a real store ---

import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
import ritual : Position, RitualState, writePosition;

private sqlite3* store() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private Position perf(RitualState st) {
    Position p;
    p.id = "willow-1";
    p.repo = "/sbvh-nl/grove";
    p.ritual = "willow";
    p.worktree = "/u/grove-willow-1";
    p.rites = "START,APPLE,ORANGE";
    p.riteCount = 3;
    p.current = 1;
    p.state = st;
    return p;
}

enum HERE = "/u/SBVH/sbvh-nl/grove";

unittest {
    // A halt in this directory is what the person is owed.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Halted)));
    assert(noticeFor(db, HERE, "sess-a").text() == "ground: ritual willow halted on APPLE");
    sqlite3_close(db);
}

unittest {
    // Said once per session. Notification fires on every idle prompt, and the
    // same halt on each one is noise rather than news.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Halted)));
    assert(noticeFor(db, HERE, "sess-a").len > 0);
    assert(noticeFor(db, HERE, "sess-a").len == 0);
    sqlite3_close(db);
}

unittest {
    // Another session has not been told yet, and is owed it too.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Halted)));
    assert(noticeFor(db, HERE, "sess-a").len > 0);
    assert(noticeFor(db, HERE, "sess-b").len > 0);
    sqlite3_close(db);
}

unittest {
    // A performance still walking is not news. Only a halt needs a person.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Live)));
    assert(noticeFor(db, HERE, "sess-a").len == 0);
    sqlite3_close(db);
}

unittest {
    // Aborted is an ending somebody already knows about — they caused it.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Aborted)));
    assert(noticeFor(db, HERE, "sess-a").len == 0);
    sqlite3_close(db);
}

unittest {
    // A terminal somewhere else is not owed this repo's news.
    auto db = store();
    assert(writePosition(db, perf(RitualState.Halted)));
    assert(noticeFor(db, "/u/SBVH/teranos/ground", "sess-a").len == 0);
    sqlite3_close(db);
}

unittest {
    // An empty store says nothing rather than saying something empty.
    auto db = store();
    assert(noticeFor(db, HERE, "sess-a").len == 0);
    sqlite3_close(db);
}

