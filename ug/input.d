module input;

import core.stdc.stdio : stdin, fread;

// The session JSON, whole. A writer whose reader never read gets a broken
// pipe, so it is read to the end whether or not every field is wanted.
__gshared char[65536] buf = void;

const(char)[] readStdin() {
    size_t total = 0;
    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }
    return buf[0 .. total];
}
