module main;

// ug — the status line, ground's own.
// https://code.claude.com/docs/en/statusline

// The row is repainted about once a second and never on a schedule we set.
// Measured 2026-08-19: 53 consecutive repaints, every gap within 840–1339ms,
// with refreshInterval removed entirely. One frame a second is the budget.

import core.stdc.time : time, time_t;

import input : readStdin;
import head : statushead;
import report : ritualLines, qntxLine;

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;

    auto session = readStdin();
    time_t now = time(null);

    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;

    statushead(session, now);
    ritualLines(session, now);
    qntxLine(hl > 0 ? h[0 .. hl] : "");
    return 0;
}
