module row;

// Line one of the row, segment by segment, against captures/grove/out.bytes.

import clock : clockInto;
import json : baseName;

// Unconditional in both captures, at the same offset, with no space before it
// and one after.
enum FLAME = "🔥 ";

enum BLUE = "\033[34m";
enum RESET = "\033[0m";

size_t rowOneInto(int hour, int minute, const(char)[] cwd, char[] dest) {
    size_t o = clockInto(hour, minute, dest);

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    put(FLAME);

    // The repository is the last element of the working directory: `grove` in
    // one capture, `ground` in the other, both blue.
    auto repo = baseName(cwd);
    if (repo !is null) {
        put(BLUE);
        put(repo);
        put(RESET);
        put(" ");
    }

    return o;
}
