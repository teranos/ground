module perf;

// One line per performance: the rites in order, brackets on the one being
// performed, colour for what each has been.
// Rules read from collet's render_performance and rite_color.

enum GREEN      = "\033[32m";
enum RED        = "\033[31m";
enum BLUE       = "\033[34m";
enum YELLOW     = "\033[33m";
enum DIM        = "\033[2m";
enum DARK_GRAY  = "\033[90m";
enum LIGHT_GRAY = "\033[37m";
enum RESET      = "\033[0m";

enum JOIN = " > ";

struct Perf {
    const(char)[] rites;
    const(char)[] states;
    const(char)[] state;
    long current = -1;
    long throws;
    bool blinkOn;
    long now;
    long thrownAt;
    long actedAt;
    long endedAt;
}

// Seconds a finished line sits still before it goes.
enum LINGER = 10;

// One pass of the closing words, not one pass of the whole line. Scaling with
// length held a long chain on the row for minutes.
enum MAX_PASS = 20;

// An ended performance is not permanent furniture. It has its pass, sits, and
// then it is gone — otherwise every ritual ever walked is still on the row.
bool expired(Perf p) {
    if (p.state == "live") return false;
    if (p.endedAt == 0) return false;

    auto pass = ((plainLength(p) + 3) * 12) / 10;
    if (pass > MAX_PASS) pass = MAX_PASS;
    return p.now - p.endedAt > pass + LINGER;
}

// Visible characters of the chain: the names, and two more per separator than
// the comma the rite list stores.
long plainLength(Perf p) {
    if (p.rites.length == 0) return 0;
    long commas = 0;
    foreach (c; p.rites) if (c == ',') commas++;
    return cast(long) p.rites.length + commas * 2;
}

// Seconds a throw-back counts as just happened. Two was one or two repaints
// against a gap of minutes, which is not something an eye catches.
enum THROWN_FOR = 30;

// Seconds a tool call counts as the agent still acting. Longer than a tool
// takes, shorter than the silences that turned out to be stalls.
enum ACTING_FOR = 20;

// Which way the letters travel, and whether they travel at all. Both are
// stamps; neither recent is the stall, and the rite sits still.
enum Life { still, thrown, acting }

Life lifeOf(Perf p) {
    if (p.thrownAt > 0 && p.now - p.thrownAt <= THROWN_FOR) return Life.thrown;
    if (p.actedAt > 0 && p.now - p.actedAt <= ACTING_FOR) return Life.acting;
    return Life.still;
}

// Two letters travelling through the rite being worked. The bracket says where
// the walk is; this says something is happening there.
size_t scanInto(const(char)[] name, const(char)[] base, Life life, long now, char[] dest) {
    size_t o = 0;

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    // One letter has nowhere to travel, and a still rite is not travelling.
    if (name.length < 2 || life == Life.still) {
        put(base);
        put(name);
        put(RESET);
        return o;
    }

    auto lit = life == Life.thrown ? YELLOW : BLUE;
    auto step = cast(size_t)(now % cast(long) name.length);
    auto head = life == Life.thrown ? step : (name.length - 1) - step;

    foreach (i, c; name) {
        put(i == head || i == head + 1 ? lit : base);
        if (o < dest.length) dest[o++] = c;
        put(RESET);
    }
    return o;
}

// The two grays are the difference between a rite waiting for the first time
// and one waiting again, which is what a hold looks like.
const(char)[] riteColour(char glyph, bool blinkOn) {
    switch (glyph) {
        case '+': return GREEN;                    // passed
        case '!': return blinkOn ? RED : DIM;      // halted
        case '>': return blinkOn ? BLUE : DIM;     // running
        case '.': return DARK_GRAY;                // pending, never ran
        case '-': return LIGHT_GRAY;               // pending, ran before
        default:  return null;
    }
}

// The chain, joined. Zero when there is nothing to draw.
size_t chainInto(Perf p, char[] dest) {
    if (p.rites.length == 0) return 0;
    if (expired(p)) return 0;

    size_t o = 0;

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    void putChar(char c) {
        if (o < dest.length) dest[o++] = c;
    }

    void putInt(long v) {
        if (v >= 100) putChar(cast(char)('0' + (v / 100) % 10));
        if (v >= 10) putChar(cast(char)('0' + (v / 10) % 10));
        putChar(cast(char)('0' + v % 10));
    }

    bool live = p.state == "live";
    bool ended = p.state == "done" || p.state == "aborted";
    auto endedColour = p.state == "aborted" ? RED : DIM;

    long i = 0;
    size_t at = 0;
    while (at <= p.rites.length) {
        size_t end = at;
        while (end < p.rites.length && p.rites[end] != ',') end++;
        auto name = p.rites[at .. end];

        if (i > 0) put(JOIN);

        // A state string shorter than the rite list leaves the rest as rites
        // that have never run, rather than dropping them off the line.
        char glyph = i < p.states.length ? p.states[cast(size_t) i] : '.';

        if (ended) {
            put(endedColour);
            put(name);
            put(RESET);
        } else {
            auto colour = riteColour(glyph, p.blinkOn);
            if (colour is null) return 0;

            // Brackets mean the rite is being performed. An ended performance
            // is not anywhere, so it never wears them.
            if (live && i == p.current) {
                put(colour); put("["); put(RESET);
                o += scanInto(name, colour, lifeOf(p), p.now, dest[o .. $]);
                if (p.throws > 0) {
                    put(YELLOW); put("x"); putInt(p.throws); put(RESET);
                }
                put(colour); put("]"); put(RESET);
            } else {
                put(colour);
                put(name);
                put(RESET);
            }
        }

        i++;
        if (end >= p.rites.length) break;
        at = end + 1;
    }

    return o;
}
