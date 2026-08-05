module ritual_test;

// Where we are, and what each rite has already been.
// Brandon: "see where we are INSIDE of the ritual"

import rite : Verdict;
import ritual : Position, RiteState, RitualState, start, step, jump;

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
