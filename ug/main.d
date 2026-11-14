module main;

// ug — the status line, ground's own.
// https://code.claude.com/docs/en/statusline

// The row is repainted about once a second and never on a schedule we set.
// Measured 2026-08-19: 53 consecutive repaints, every gap within 840–1339ms,
// with refreshInterval removed entirely. One frame a second is the budget.

import core.stdc.time : time, time_t;

import input : readStdin;
import head : statushead;
import report : ritualLines;

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;

    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    auto home = h[0 .. hl];

    auto session = readStdin();
    time_t now = time(null);

    // The QNTX row lives on the tmux bar, where it is visible whether or not a
    // session is open, and where it does not spend this frame on a network
    // call. ground_tmux draws it, from what mycelia kept.
    statushead(session, now);
    ritualLines(session, now);

    {
        import core.stdc.stdio : fflush, stdout;
        import usage : recordUsage;
        fflush(stdout);
        recordUsage(home, session, cast(long) now);
    }
    return 0;
}
