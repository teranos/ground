module ritual;

import rite : Verdict;

// The two pendings are distinct because a rite waiting for the first time
// and one waiting again are not the same fact.
enum RiteState {
    Never,    // darker gray
    Ran,      // lighter gray — held, will run again
    Running,  // blinking blue
    Passed,   // green
    Halted,   // blinking red
}

// Done and Halted are reached by running, not by a command. Aborted is the
// exception: "it ends when it ends, not because i ran ritual stop".
enum RitualState { Live, Done, Halted, Aborted }

enum MAX_RITES = 32;

struct Position {
    const(char)[] ritual;
    size_t current;
    size_t riteCount;
    RiteState[MAX_RITES] states;
    RitualState state;
}

Position start(const(char)[] name, size_t riteCount) {
    Position p;
    p.ritual = name;
    p.riteCount = riteCount;
    p.state = RitualState.Live;
    return p;
}

// The verdict of the rite at `current`, applied.
Position step(Position p, Verdict v) {
    if (p.state != RitualState.Live) return p;
    if (p.current >= p.riteCount) return p;

    final switch (v) {
    case Verdict.Advance:
        p.states[p.current] = RiteState.Passed;
        p.current++;
        if (p.current >= p.riteCount) p.state = RitualState.Done;
        break;
    case Verdict.Hold:
        p.states[p.current] = RiteState.Ran;
        break;
    case Verdict.Halt:
        p.states[p.current] = RiteState.Halted;
        p.state = RitualState.Halted;
        break;
    }
    return p;
}

// goto. History is left alone: a rite that passed still passed, even if the
// ritual is about to walk over it again.
Position jump(Position p, size_t target) {
    if (target >= p.riteCount) return p;
    p.current = target;
    if (p.state == RitualState.Done) p.state = RitualState.Live;
    return p;
}
