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

  # "a different rite that runs a tool unconditionally"
  ACTED { run: "true" }
  BOTH  { run: "true"   eval: "false"  catch: 1 }
  BROKE { run: "exit 4" eval: "true" }
  LAST  { eval: "true" }
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
    // "Advance unconditionally is the obvious reading" — "yes". A rite with
    // run and no eval asked nothing, so there is no code to read.
    auto r = advance(db, "sess", at(6), flat, 100);
    assert(r.ran);
    assert(r.verdict == Verdict.Advance);
    assert(r.after.current == 7);
    assert(r.after.states[6] == RiteState.Passed);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // run happened, eval still decides. The tool firing is not the answer.
    auto r = advance(db, "sess", at(7), flat, 100);
    assert(r.verdict == Verdict.Hold);
    assert(r.after.current == 7);
    assert(r.after.states[7] == RiteState.Ran);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // "a failed run: is critical enough for us not to want to continue and
    // return the error point blanc , keep the mic" — so the eval that would
    // have passed is never asked.
    auto r = advance(db, "sess", at(8), flat, 100);
    assert(r.verdict == Verdict.Halt);
    assert(r.code == 4, "the tool's own code, not ground's");
    assert(r.after.state == RitualState.Halted);
    assert(r.after.states[8] == RiteState.Halted);
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

// "let's make it settable on a project { }" — per performance, a full run of
// a ritual, so a project says how long its agentic loops may run.
enum boundSrc = `
rites spin2 {
  THERE { eval: "true" }
  AWAY  { eval: "false"  catch: 1  goto: THERE }
}

project {
  path: "/src/bound"
  max_goto: 3
  ritual bounded { spin2 }
}
`;
enum boundFlat = flatten(parsePbt(boundSrc), 0);

static assert(loopFlat.maxGoto == MAX_GOTOS, "a project that says nothing gets the default");
static assert(boundFlat.maxGoto == 3, "a project sets how long its loops may run");

unittest {
    auto db = memDb();
    auto p = start("bounded", boundFlat.count);
    p.id = "bound-1";
    p.repo = "/src/bound";
    p.worktree = "/tmp";

    size_t turns;
    while (p.state == RitualState.Live && turns < 500) {
        auto r = advance(db, "sess", p, boundFlat, 100 + cast(long) turns);
        if (!r.ran) break;
        p = r.after;
        turns++;
    }

    assert(p.state == RitualState.Halted);
    assert(p.gotos == 3, "the project's number bounds the walk, not ground's");
    sqlite3_close(db);
}

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
    import ritual : RiteState;
    // "ground doesnt keep agent hostage ever, it doesnt happen its not part of
    // the spec" — a Running row is something to read, never a reason to refuse.
    auto p = at(6);
    p.states[6] = RiteState.Running;
    p.micAt = 100;
    auto r = advance(db, "sess", p, flat, 120);
    assert(r.ran, "ground does not decline to act on a row it wrote");
    assert(r.verdict == Verdict.Advance);
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    import ritual : RiteState, readPosition;
    // The claim is what the second driver reads. Running was declared with a
    // glyph and a colour and never once written.
    auto r = advance(db, "sess", at(1), flat, 100);
    assert(r.verdict == Verdict.Hold);
    assert(r.after.states[1] == RiteState.Ran, "step clears Running when the rite answers");
    sqlite3_close(db);
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
    auto r = advance(db, "sess", at(9), flat, 100);
    assert(r.after.state == RitualState.Done);
    assert(r.after.mic == Mic.Human);
    sqlite3_close(db);
}

// --- An error inside a rite is owed to the causer, not to the driver ---
// `advance` has four callers and was passed each one's own session, which is
// the address `emitError` routed to.

import ritual.run : owedSessions;

unittest {
    auto o = owedSessions("agent-a", "parent-b", "driver-c");
    assert(o.count == 3);
    assert(o.all()[0] == "agent-a", "the causer is first");
    assert(o.all()[1] == "parent-b");
}

unittest {
    // The common case: the driver is the agent. One error, not two.
    auto o = owedSessions("agent-a", "parent-b", "agent-a");
    assert(o.count == 2);
    assert(o.all()[0] == "agent-a");
    assert(o.all()[1] == "parent-b");
}

unittest {
    // Before SessionStart binds the agent there is no causer, and the error is
    // still owed to somebody.
    auto o = owedSessions("", "parent-b", "parent-b");
    assert(o.count == 1);
    assert(o.all()[0] == "parent-b");
}

unittest {
    auto o = owedSessions("", "", "driver-c");
    assert(o.count == 1);
    assert(o.all()[0] == "driver-c");
}

// --- What a rite printed comes back, whether or not it named a receiver ---
// Delivery was gated on `wait > 0 && to != None`, and `to:` appears in no rite
// in any pbt on disk, so `run: "gh pr view --json comments"` had nowhere to go.

enum speakSrc = `
rites talk {
  SPEAK { run: "echo pr-comment-body" }
  QUIET { eval: "echo eval-said-this" }

  AGAIN { eval: "echo the-same-comment; exit 1"  catch: 1 }
}

project {
  path: "/src/proj"
  ritual talker { talk }
}
`;
enum speakFlat = flatten(parsePbt(speakSrc), 0);

private Position talker(size_t i) {
    auto p = start("talker", speakFlat.count);
    p.id = "talk-1";
    p.repo = "/src/proj";
    p.worktree = "/tmp";
    p.parent = "parent-session";
    // The causer. Until SessionStart binds it there is nobody to reach.
    p.agentSession = "agent-session";
    p.current = i;
    return p;
}

unittest {
    auto db = memDb();
    // A run's output was read on the failure branch only, so a tool that
    // succeeded had what it printed dropped before anyone asked who wanted it.
    auto r = advance(db, "sess", talker(0), speakFlat, 100);
    assert(r.verdict == Verdict.Advance);

    enum q = "SELECT count(*) FROM attestations "
        ~ "WHERE id LIKE 'immediate:note:agent-session:rite:talk-1:SPEAK:%:run' "
        ~ "AND json_extract(attributes,'$.detail') LIKE '%pr-comment-body%'\0";
    assert(notes(db, q.ptr) == 1, "the run's own output is what the causer is owed");

    enum once = "SELECT count(*) FROM attestations "
        ~ "WHERE id LIKE 'immediate:note:agent-session:rite:talk-1:SPEAK:%'\0";
    assert(notes(db, once.ptr) == 1, "a run-only rite says it once, not twice");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // No `wait:`, no `to:`. The rite still said something and the causer still
    // hears it, under a key that does not claim to be CI.
    auto r = advance(db, "sess", talker(1), speakFlat, 100);
    assert(r.verdict == Verdict.Advance);

    enum q = "SELECT count(*) FROM attestations "
        ~ "WHERE id LIKE 'immediate:note:agent-session:rite:talk-1:QUIET:%' "
        ~ "AND json_extract(attributes,'$.detail') LIKE '%eval-said-this%'\0";
    assert(notes(db, q.ptr) == 1, "an eval's output is owed too");

    enum notCi = "SELECT count(*) FROM attestations WHERE id LIKE '%:ci:talk-1:%'\0";
    assert(notes(db, notCi.ptr) == 0, "a rite that did not wait is not CI");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // The parent is still gated by `to:`: the causer rule is about the causer.
    cast(void) advance(db, "sess", talker(1), speakFlat, 100);
    enum q = "SELECT count(*) FROM attestations "
        ~ "WHERE id LIKE 'immediate:note:parent-session:%'\0";
    assert(notes(db, q.ptr) == 0, "a rite naming no receiver does not reach the parent");
    sqlite3_close(db);
}

// --- A rite that asks nothing jumps where it names ---
// "no, it should have jumped over them" — a rite with no eval has no verdict
// to condition a jump on, so its goto is the only thing it says.

enum hopSrc = `
rites hop {
  WAIT       { run: "true" }
  TRAMPOLINE { goto: END }
  HEDGE1 { }
  HEDGE2 { }
  END { }
}

project {
  path: "/src/proj"
  ritual jumper { hop }
}
`;
enum hopFlat = flatten(parsePbt(hopSrc), 0);

unittest {
    auto db = memDb();
    auto p = start("jumper", hopFlat.count);
    p.id = "hop-1";
    p.repo = "/src/proj";
    p.worktree = "/tmp";
    p.current = 1;

    auto r = advance(db, "sess", p, hopFlat, 100);
    assert(r.after.current == 4, "the trampoline lands on END, not on HEDGE1");
    assert(r.after.gotos == 1, "a jump taken costs one");
    assert(r.after.states[2] == RiteState.Never, "the hedges are stepped over");
    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // SLOW keeps the `ci:` namespace and CI's own head line, which is what the
    // gutter reads. Renaming the general case must not move the CI case.
    cast(void) advance(db, "sess", at(4), flat, 100);
    enum q = "SELECT count(*) FROM attestations "
        ~ "WHERE id LIKE 'immediate:note:%:ci:probe-1:SLOW:%' "
        ~ "AND json_extract(attributes,'$.detail') LIKE '%ci all checks passed%'\0";
    assert(notes(db, q.ptr) >= 1, "a waiting rite is still spoken as CI");
    sqlite3_close(db);
}
