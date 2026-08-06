module briefing_test;

// What an agent is told at the start of a turn. Until this exists an agent
// works inside a performance without knowing there is one, and only meets the
// ritual when something interrupts it.

import proto : parsePbt;
import ritual : briefing, flatten, start, step, jump, RitualState;
import rite : Verdict;

enum src = `
rites walk {
  START { cmd: "test -f T.md" }
  PICK  { cmd: "grep -q x T.md"  catch: 1  msg: "Take one and commit." }
  CHECK { cmd: "test -s T.md"  catch: 1  goto: START }
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

// An ended performance has no rite, and saying rite 4 of 3 would be a lie.
enum done = step(step(step(fresh, Verdict.Advance), Verdict.Advance), Verdict.Advance);
static assert(done.state == RitualState.Done);
static assert(briefing(done, flat).text() == "Ritual probe is done.");

enum halted = step(fresh, Verdict.Halt);
static assert(briefing(halted, flat).text() ==
    "Ritual probe halted on rite 1 of 3: START.");
