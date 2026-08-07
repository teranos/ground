module ritual.position;

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

// A performance is identified by itself. The worktree is where it is being
// performed, not what it is.
struct Position {
    const(char)[] id;
    const(char)[] repo;
    const(char)[] ritual;
    const(char)[] branch;
    const(char)[] worktree;
    const(char)[] rites;   // comma-joined names, so the row renders alone
    const(char)[] session; // the session that owns it
    const(char)[] agent;   // the agent carrying it, if one was started with it
    size_t current;
    size_t riteCount;
    RiteState[MAX_RITES] states;
    RitualState state;
}

// The performance and the moment it began. Two performances of one ritual are
// two rows; the same id twice is one performance moving.
struct PerfId {
    char[80] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

PerfId performanceId(const(char)[] ritual, long unixSeconds) {
    PerfId p;
    foreach (c; ritual) { if (p.len < p.buf.length) p.buf[p.len++] = c; }
    if (p.len < p.buf.length) p.buf[p.len++] = '-';

    char[20] digits = 0;
    size_t d;
    auto v = unixSeconds;
    if (v <= 0) digits[d++] = '0';
    while (v > 0) { digits[d++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. d) {
        if (p.len < p.buf.length) p.buf[p.len++] = digits[d - 1 - i];
    }
    return p;
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

// One character per rite. The row is legible without a decoder, and collet
// renders the line straight from it.
package immutable char[5] GLYPH = ['.', '-', '>', '+', '!'];

struct Encoded {
    char[MAX_RITES] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    bool opEquals(const(char)[] s) const { return text() == s; }
}

Encoded encodeStates(const Position p) {
    Encoded e;
    foreach (i; 0 .. p.riteCount) {
        if (i >= MAX_RITES) break;
        e.buf[e.len++] = GLYPH[cast(size_t) p.states[i]];
    }
    return e;
}

// A row this process cannot read is a row it must not render. Restoring is
// therefore a verdict, not a Position.
struct Restored { bool valid; Position p; }

Restored restore(const(char)[] name, size_t current,
                 const(char)[] states, RitualState st) {
    if (states.length == 0 || states.length > MAX_RITES) return Restored(false);
    if (current > states.length) return Restored(false);

    Position p;
    p.ritual = name;
    p.current = current;
    p.riteCount = states.length;
    p.state = st;

    foreach (i, c; states) {
        bool known = false;
        foreach (g, glyph; GLYPH) {
            if (c == glyph) { p.states[i] = cast(RiteState) g; known = true; break; }
        }
        if (!known) return Restored(false);
    }
    return Restored(true, p);
}
