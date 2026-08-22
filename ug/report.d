module report;

// What sits under the head: one line per performance ground is walking for
// this session.

import core.stdc.stdio : stdout, fwrite, fputs;
import core.stdc.time : time_t;

import json : jsonString;
import sql : readPerformances, Row, Read, MAX_PERFORMANCES;
import perf : chainInto, Perf;

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
        auto len = chainInto(p, line[]);
        if (len == 0) continue;

        fwrite(line.ptr, 1, len, stdout);
        fputs("\n", stdout);
    }
}

private void printInt(long v) {
    __gshared char[24] buf = void;
    size_t n = 0;
    if (v < 0) { fputs("-", stdout); v = -v; }
    do { buf[n++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
    foreach_reverse (i; 0 .. n) fwrite(&buf[i], 1, 1, stdout);
}
