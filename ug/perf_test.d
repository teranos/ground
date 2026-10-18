module perf_test;

// CTFE tests — failure shows as a compile error.

import perf : riteColour, chainInto, Perf;
import perf : GREEN, RED, BLUE, YELLOW, DIM, DARK_GRAY, LIGHT_GRAY, RESET;

// Passed is green whatever the second is doing; never-ran and ran-before are
// two different grays, which is what tells a hold from a fresh wait.
static assert(riteColour('+', true) == GREEN);
static assert(riteColour('+', false) == GREEN);
static assert(riteColour('.', true) == DARK_GRAY);
static assert(riteColour('-', true) == LIGHT_GRAY);

// Running and halted blink on the second's parity, so both spend half their
// time dim and are read by the fact that they change.
static assert(riteColour('>', true) == BLUE);
static assert(riteColour('>', false) == DIM);
static assert(riteColour('!', true) == RED);
static assert(riteColour('!', false) == DIM);

// A glyph this build has no colour for is not guessed at.
static assert(riteColour('?', true) is null);
static assert(riteColour(' ', false) is null);

char[512] drawn(Perf p)() {
    char[512] buf = '.';
    chainInto(p, buf[]);
    return buf;
}

size_t len(Perf p)() {
    char[512] buf = '.';
    return chainInto(p, buf[]);
}

// Three rites, the second being performed: brackets in the rite's own colour
// with the name inside, and the rest coloured by what they have been.
enum walking = Perf("APPLE,LIME,PEAR", "+>.", "live", 1, 0, true);
enum walkingWant =
    GREEN ~ "APPLE" ~ RESET ~ " > " ~
    BLUE ~ "[" ~ RESET ~ BLUE ~ "LIME" ~ RESET ~ BLUE ~ "]" ~ RESET ~ " > " ~
    DARK_GRAY ~ "PEAR" ~ RESET;

static assert(len!walking() == walkingWant.length);
static assert(drawn!walking()[0 .. walkingWant.length] == walkingWant);

// Thrown back: the count rides inside the brackets, in yellow, because a
// frozen count is a stall and a climbing one is ping-pong.
enum thrown = Perf("APPLE,LIME", "+>", "live", 1, 3, true);
enum thrownWant =
    GREEN ~ "APPLE" ~ RESET ~ " > " ~
    BLUE ~ "[" ~ RESET ~ BLUE ~ "LIME" ~ RESET ~
    YELLOW ~ "x3" ~ RESET ~ BLUE ~ "]" ~ RESET;

static assert(drawn!thrown()[0 .. thrownWant.length] == thrownWant);

// An ended performance is not coloured by what each rite was, and is not
// anywhere, so no brackets: done is spent, aborted is killed.
enum done = Perf("APPLE,LIME", "++", "done", 1, 0, true);
enum doneWant = DIM ~ "APPLE" ~ RESET ~ " > " ~ DIM ~ "LIME" ~ RESET;
static assert(drawn!done()[0 .. doneWant.length] == doneWant);

enum aborted = Perf("APPLE,LIME", "+!", "aborted", 1, 0, true);
enum abortedWant = RED ~ "APPLE" ~ RESET ~ " > " ~ RED ~ "LIME" ~ RESET;
static assert(drawn!aborted()[0 .. abortedWant.length] == abortedWant);

// A state string shorter than the rite list leaves the rest never-run rather
// than dropping them off the line.
enum short_ = Perf("A,B,C", "+", "live", 0, 0, true);
static assert(len!short_() > 0);

// Nothing to walk is no line at all.
static assert(len!(Perf("", "", "live", 0, 0, true))() == 0);

// "and the ${ and } become orange"

// "when over budget"

// "and red when all budgets are exhausted"

// "${[RITE1] RITE2}"

// "i want the group"
import perf : ORANGE, Gated, Budget;

// The group passed over, the walk on the rite after it.
private Perf withGroup(Budget b)() {
    auto p = Perf("CHERRY,MANGO,LIME", "++>", "live", 2, 0, true);
    p.gated[0] = Gated(0, 2, b);
    p.gatedCount = 1;
    return p;
}

enum under = withGroup!(Budget.under)();
enum underWant =
    "${" ~ GREEN ~ "CHERRY" ~ RESET ~ " " ~ GREEN ~ "MANGO" ~ RESET ~ "}" ~ " " ~
    BLUE ~ "[" ~ RESET ~ BLUE ~ "LIME" ~ RESET ~ BLUE ~ "]" ~ RESET;
static assert(len!under() == underWant.length);
static assert(drawn!under()[0 .. underWant.length] == underWant);

enum over = withGroup!(Budget.over)();
enum overWant =
    ORANGE ~ "${" ~ RESET ~ GREEN ~ "CHERRY" ~ RESET ~ " " ~ GREEN ~ "MANGO" ~ RESET ~ ORANGE ~ "}" ~ RESET ~ " " ~
    BLUE ~ "[" ~ RESET ~ BLUE ~ "LIME" ~ RESET ~ BLUE ~ "]" ~ RESET;
static assert(drawn!over()[0 .. overWant.length] == overWant);

enum exhausted = withGroup!(Budget.exhausted)();
enum exhaustedWant =
    RED ~ "${" ~ RESET ~ GREEN ~ "CHERRY" ~ RESET ~ " " ~ GREEN ~ "MANGO" ~ RESET ~ RED ~ "}" ~ RESET ~ " " ~
    BLUE ~ "[" ~ RESET ~ BLUE ~ "LIME" ~ RESET ~ BLUE ~ "]" ~ RESET;
static assert(drawn!exhausted()[0 .. exhaustedWant.length] == exhaustedWant);
