module main;

// ug — the status line, ground's own.
// https://code.claude.com/docs/en/statusline

// The row is repainted about once a second and never on a schedule we set.
// Measured 2026-08-19: 53 consecutive repaints, every gap within 840–1339ms,
// with refreshInterval removed entirely. One frame a second is the budget.

import core.stdc.stdio : stdin, stdout, fread, fwrite, fputs;
import core.stdc.time : time, time_t, localtime, tm;

import row : rowOneInto;
import json : jsonString;

// The session JSON, whole. A writer whose reader never read gets a broken
// pipe, so it is read to the end whether or not every field is wanted.
__gshared char[65536] inputBuf = void;

const(char)[] readStdin() {
    size_t total = 0;
    while (total < inputBuf.length) {
        auto n = fread(&inputBuf[total], 1, inputBuf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }
    return inputBuf[0 .. total];
}

extern (C) int main(int argc, char** argv) {
    auto input = readStdin();

    time_t now = time(null);
    auto lt = localtime(&now);

    __gshared char[512] row = void;
    auto n = rowOneInto(lt.tm_hour, lt.tm_min, jsonString(input, "cwd"), row[]);

    fwrite(&row[0], 1, n, stdout);
    fputs("\n", stdout);
    return 0;
}
