module briefing_test;

// What an agent is told at the start of a turn. Until this exists an agent
// works inside a performance without knowing there is one, and only meets the
// ritual when something interrupts it.

import proto : parsePbt;
import ritual : briefing, flatten, start, step, jump, RitualState;
import rite : Verdict;

enum src = `
rites walk {
  START { eval: "test -f T.md" }
  PICK  { eval: "grep -q x T.md"  catch: 1  msg: "Take one and commit." }
  CHECK { eval: "test -s T.md"  catch: 1  goto: START }
}

project {
  path: "/src/proj"
  ritual probe { walk }
}
`;
enum parsed = parsePbt(src);
enum flat = flatten(parsed, 0);
enum fresh = start("probe", flat.count);

// Which ritual, where in it, and what would satisfy the rite it is on.
enum first = briefing(fresh, flat);
static assert(first.text() ==
    "Performing ritual probe, rite 1 of 3: START. "
    ~ "It is met when this exits 0: test -f T.md");

// A rite's msg is the author talking to whoever is doing the work, so it
// belongs in front of them rather than only in a failure.
enum second = briefing(step(fresh, Verdict.Advance), flat);
static assert(second.text() ==
    "Performing ritual probe, rite 2 of 3: PICK. "
    ~ "It is met when this exits 0: grep -q x T.md. Take one and commit.");

// A held rite reads the same as a fresh one. Holding is not a failure, and an
// agent told it failed would go looking for something to fix.
enum held = step(step(fresh, Verdict.Advance), Verdict.Hold);
static assert(briefing(held, flat).text() == second.text());

// Holding is not being thrown back. The watcher runs the same rite every 15
// seconds (`handleWatch`) and the agent never learns of it, so the count is
// stamped where the Stop actually goes back, not where the rite is evaluated.
import ritual : threw;

enum thrown1 = threw(held);
static assert(briefing(thrown1, flat).text() ==
    "Performing ritual probe, rite 2 of 3: PICKx1. "
    ~ "It is met when this exits 0: grep -q x T.md. Take one and commit.");

// "if there is back and forward, it would mean the counter increments no?"
// A frozen count is the stall; a climbing one is the ping-pong. It reads the
// same here as it does on the status line.
enum thrown3 = threw(threw(thrown1));
static assert(briefing(thrown3, flat).text() ==
    "Performing ritual probe, rite 2 of 3: PICKx3. "
    ~ "It is met when this exits 0: grep -q x T.md. Take one and commit.");

// The count is the rite's, not the performance's. Carried over a move it
// would tell the next rite it had already been refused.
static assert(step(thrown3, Verdict.Advance).throws == 0);
static assert(jump(thrown3, 0).throws == 0);

// An ended performance has no rite, and saying rite 4 of 3 would be a lie.
enum done = step(step(step(fresh, Verdict.Advance), Verdict.Advance), Verdict.Advance);
static assert(done.state == RitualState.Done);
static assert(briefing(done, flat).text() == "Ritual probe is done.");

enum halted = step(fresh, Verdict.Halt);
static assert(briefing(halted, flat).text() ==
    "Ritual probe halted on rite 1 of 3: START.");

// A briefing that does not fit is a different instruction, and the tail is
// what goes: the eval, the msg, the mic. The agent acts on the half it got
// and nothing anywhere says it was cut.
private template rep(string s, int n) {
    static if (n <= 0) enum rep = "";
    else enum rep = s ~ rep!(s, n - 1);
}
private enum k100 = rep!("wordwordw ", 10);

enum longSrc = `
rites big { ONE { eval: "true"  msg: "` ~ rep!(k100, 13) ~ `" } }

project {
  path: "/src/proj"
  ritual huge { big }
}
`;
enum longParsed = parsePbt(longSrc);
enum longFlat = flatten(longParsed, 0);
enum longFresh = start("huge", longFlat.count);
static assert(briefing(longFresh, longFlat).over);

// The ones above still fit, so nothing that used to be said stopped being said.
static assert(!first.over);
static assert(!briefing(halted, flat).over);
