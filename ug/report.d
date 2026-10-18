module report;

// What sits under the head: one line per performance ground is walking for
// this session.

import core.stdc.stdio : stdout, fwrite, fputs;
import core.stdc.time : time_t;

import json : jsonString;
import sql : readPerformances, Row, Read, MAX_PERFORMANCES;
import perf : chainInto, Perf, Budget;

// The QNTX line was here. It draws on the tmux bar now, where it is visible
// whether or not a session is open and where it does not spend a 1000ms frame
// on a network call. `ug tmux` is what renders it.

void ritualLines(const(char)[] input, time_t now) {
    import core.stdc.stdlib : getenv;

    auto sessionId = jsonString(input, "session_id");
    if (sessionId is null) return;

    auto home = getenv("HOME");
    if (home is null) return;

    size_t homeLen = 0;
    while (home[homeLen] != '\0') homeLen++;

    __gshared Row[MAX_PERFORMANCES] rows;
    auto reading = readPerformances(home[0 .. homeLen], sessionId, rows[]);

    // A store that cannot be read says so. Silence there is a broken table
    // wearing the face of a quiet one.
    if (reading.how != Read.ok && reading.how != Read.noStore) {
        fputs("\033[31mritual: sqlite rc=", stdout);
        printInt(reading.rc);
        fputs("\033[0m\n", stdout);
        return;
    }

    // Blink is the second's parity, not ANSI 5: most terminals drop that, and
    // the row is repainted once a second anyway.
    bool blinkOn = (now % 2) == 0;

    __gshared char[2048] line = void;
    foreach (i; 0 .. reading.count) {
        auto r = &rows[i];
        auto p = Perf(r.rites(), r.states(), r.state(), r.current, r.throws, blinkOn,
                      cast(long) now, r.thrownAt, r.actedAt, r.updatedAt);
        groupsInto(p, r.gates(), home[0 .. homeLen], cast(long) now);
        auto len = chainInto(p, line[]);
        if (len == 0) continue;

        fwrite(line.ptr, 1, len, stdout);
        fputs("\n", stdout);
    }
}

// Each run of rites under the same clauses is one group, and its budget is read now.
private void groupsInto(ref Perf p, const(char)[] gates, const(char)[] home, long now) {
    import perf : Gated, Budget;
    long i = 0;
    long from = -1;
    const(char)[] open;
    size_t at = 0;
    while (at <= gates.length) {
        size_t end = at;
        while (end < gates.length && gates[end] != ',') end++;
        auto gate = gates[at .. end];
        if (from >= 0 && gate != open) {
            if (p.gatedCount < p.gated.length) p.gated[p.gatedCount++] = Gated(from, i, budgetOf(open, home, now));
            from = -1;
        }
        if (from < 0 && gate.length > 0) { from = i; open = gate; }
        i++;
        if (end >= gates.length) break;
        at = end + 1;
    }
    if (from >= 0 && p.gatedCount < p.gated.length) p.gated[p.gatedCount++] = Gated(from, i, budgetOf(open, home, now));
}

// Every clause under its limit is under budget; some spent is over it; all spent is exhausted.
private Budget budgetOf(const(char)[] gate, const(char)[] home, long now) {
    import perf : Budget;
    import costgate : windowOf;
    import sql : readWindow;
    size_t clauses = 0;
    size_t spent = 0;
    size_t at = 0;
    while (at < gate.length) {
        auto letter = gate[at];
        at += 2;
        long limit = 0;
        while (at < gate.length && gate[at] != ';') limit = limit * 10 + (gate[at++] - '0');
        at++;
        clauses++;
        auto week = readWindow(home, windowOf(letter));
        if (week.found && week.resetsAt > now && week.percent >= limit) spent++;
    }
    if (spent == 0) return Budget.under;
    return spent == clauses ? Budget.exhausted : Budget.over;
}

private void printInt(long v) {
    __gshared char[24] buf = void;
    size_t n = 0;
    if (v < 0) { fputs("-", stdout); v = -v; }
    do { buf[n++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
    foreach_reverse (i; 0 .. n) fwrite(&buf[i], 1, 1, stdout);
}
