module costgate;

// "costgated: w<70;f<30; {"

// Clauses, each a window's letter, `<` and a whole percent, ended by `;`.
// w is the Claude Code week, f is Fable's.

/** The usage window a clause's letter reads. Null for a letter that names none. */
string windowOf(char letter) {
    if (letter == 'w') return "seven_day";
    if (letter == 'f') return "fable_week";
    return null;
}

/** Why a gate cannot be read, or null when it can: asked at compile time, of what a pbt wrote. */
string refusal(const(char)[] gate) {
    if (gate.length == 0) return "a costgated block names no clause";
    size_t at = 0;
    while (at < gate.length) {
        if (windowOf(gate[at]) is null) return "a costgated clause starts with w or f";
        at++;
        if (at >= gate.length || gate[at] != '<') return "a costgated clause is a letter, < and a percent";
        at++;
        auto start = at;
        while (at < gate.length && gate[at] >= '0' && gate[at] <= '9') at++;
        if (at == start) return "a costgated clause's percent is a whole number";
        if (at >= gate.length || gate[at] != ';') return "a costgated clause ends with ;";
        at++;
    }
    return null;
}

/** What one window read, in tenths of a percent. found is false when no current week is recorded. */
struct Spent {
    bool found;
    long tenths;
}

/** Under every limit; a clause at or over its limit; or a window nothing current is recorded for. */
enum Gate { Holds, Spent, Unknown }

/** What a gate answered, and the clause that decided it when it did not hold. */
struct Gated {
    Gate gate;
    char letter;
    long tenths;
    long limit;
    string missing;
}

/** Each clause against what read gives for its window; the first that does not hold decides. */
Gated holds(R)(const(char)[] gate, scope R read) {
    Gated g;
    size_t at = 0;
    while (at < gate.length) {
        auto letter = gate[at];
        at += 2;
        long limit = 0;
        while (at < gate.length && gate[at] != ';') limit = limit * 10 + (gate[at++] - '0');
        at++;
        auto window = windowOf(letter);
        auto spent = read(window);
        if (!spent.found) {
            g.gate = Gate.Unknown;
            g.missing = window;
            return g;
        }
        if (spent.tenths < limit * 10) continue;
        g.gate = Gate.Spent;
        g.letter = letter;
        g.tenths = spent.tenths;
        g.limit = limit;
        return g;
    }
    return g;
}

/** The window's current week from ground.db: one that has reset says nothing of the week running now. */
Spent spentOf(DB)(DB db, string window) {
    import core.stdc.time : time;
    import usagecmd : currentReading;
    auto c = currentReading(db, window);
    if (!c.found || c.resetsAt <= cast(long) time(null)) return Spent(false, 0);
    return Spent(true, c.tenths);
}
