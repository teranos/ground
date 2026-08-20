module status;

// The working tree, counted off `git status --porcelain`.
// Rule read from collet's own git_status, not inferred from the capture.

enum YELLOW = "\033[33m";
enum RED    = "\033[31m";
enum RESET  = "\033[0m";

struct Counts {
    int staged;
    int modified;
    int untracked;
}

// Column one is the index, column two the working tree. A line is counted
// once per column, so one file can be both staged and modified.
Counts countPorcelain(const(char)[] porcelain) {
    Counts c;

    size_t i = 0;
    while (i < porcelain.length) {
        size_t end = i;
        while (end < porcelain.length && porcelain[end] != '\n') end++;

        if (end > i + 1) {
            auto x = porcelain[i];
            auto y = porcelain[i + 1];
            if (x != ' ' && x != '?') c.staged++;
            if (y == 'M' || y == 'D') c.modified++;
            if (x == '?') c.untracked++;
        }

        i = end + 1;
    }

    return c;
}

// The bracketed segment, with the space that precedes it. Empty when there is
// nothing to say: a clean tree adds no width to the row.
size_t statusInto(Counts c, char[] dest) {
    if (c.staged == 0 && c.modified == 0 && c.untracked == 0) return 0;

    size_t o = 0;

    void put(const(char)[] s) {
        foreach (ch; s) if (o < dest.length) dest[o++] = ch;
    }

    void putInt(int v) {
        if (v >= 100 && o < dest.length) dest[o++] = cast(char)('0' + (v / 100) % 10);
        if (v >= 10 && o < dest.length) dest[o++] = cast(char)('0' + (v / 10) % 10);
        if (o < dest.length) dest[o++] = cast(char)('0' + v % 10);
    }

    bool first = true;

    void part(const(char)[] colour, char mark, int v) {
        if (v == 0) return;
        if (!first) put(" ");
        first = false;
        put(colour);
        if (o < dest.length) dest[o++] = mark;
        putInt(v);
        put(RESET);
    }

    put(" [");
    part(YELLOW, '+', c.staged);
    part(YELLOW, '~', c.modified);
    part(RED, '?', c.untracked);
    put("]");

    return o;
}
