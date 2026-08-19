module row;

// Line one of the row, segment by segment, against captures/grove/out.bytes.

import clock : clockInto;
import json : baseName;
import status : statusInto, Counts;

// Unconditional in both captures, at the same offset, with no space before it
// and one after.
enum FLAME = "🔥 ";

enum BLUE    = "\033[34m";
enum MAGENTA = "\033[35m";
enum RED     = "\033[31m";
enum GREEN   = "\033[32m";
enum DIM     = "\033[2m";
enum RESET   = "\033[0m";

// The branch glyph, and the single space that follows it.
enum BRANCH_MARK = "⎇ ";

// What the row knows about the session. Gathered by the caller so the line
// itself stays a function of its inputs and can be checked against a capture.
struct Head {
    const(char)[] cwd;
    const(char)[] branch;
    const(char)[] model;
    Counts counts;
    int percent = -1;
}

size_t rowOneInto(int hour, int minute, Head h, char[] dest) {
    size_t o = clockInto(hour, minute, dest);

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    put(FLAME);

    // The repository is the last element of the working directory: `grove` in
    // one capture, `ground` in the other, both blue.
    auto repo = baseName(h.cwd);
    if (repo !is null) {
        put(BLUE);
        put(repo);
        put(RESET);
    }

    // Every segment past the repository carries the space that precedes it,
    // so a segment with nothing to say leaves no gap where it would have been.
    if (h.branch !is null) {
        put(" ");
        put(MAGENTA);
        put(BRANCH_MARK);
        put(h.branch);
        put(RESET);
    }

    o += statusInto(h.counts, dest[o .. $]);

    if (h.percent >= 0) {
        put(" ");
        put(GREEN);
        putInt(h.percent, dest, o);
        put("%");
        put(RESET);
    }

    if (h.model !is null) {
        put(" ");
        put(DIM);
        put(h.model);
        put(RESET);
    }

    return o;
}

// Digits, most significant first, with no padding: the context share is one
// or two digits and a hundred is three.
private void putInt(int v, char[] dest, ref size_t o) {
    if (v >= 100) { if (o < dest.length) dest[o++] = cast(char)('0' + (v / 100) % 10); }
    if (v >= 10)  { if (o < dest.length) dest[o++] = cast(char)('0' + (v / 10) % 10); }
    if (o < dest.length) dest[o++] = cast(char)('0' + v % 10);
}
