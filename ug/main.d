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
    import tmux : tmuxMain, expandMain;

    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    auto home = hl > 0 ? h[0 .. hl] : "";

    // A status bar has no session to tell us about, so this mode reads no
    // stdin and draws one line.
    if (argc >= 2 && argv[1] !is null) {
        size_t al = 0;
        while (argv[1][al] != 0) al++;
        auto verb = argv[1][0 .. al];

        if (verb == "tmux")
            return tmuxMain(home, cast(long) time(null));

        // What a click asked about. tmux hands the range name as the argument.
        if (verb == "expand") {
            const(char)[] which;
            if (argc >= 3 && argv[2] !is null) {
                size_t nl = 0;
                while (argv[2][nl] != 0) nl++;
                which = argv[2][0 .. nl];
            }
            return expandMain(home, which);
        }
    }

    auto session = readStdin();
    time_t now = time(null);

    // The QNTX row lives on the tmux bar, where it is visible whether or not a
    // session is open, and where it does not spend this frame on a network
    // call. `ug tmux` draws it.
    statushead(session, now);
    ritualLines(session, now);
    return 0;
}
