module kept;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
//
// What mycelia keeps, as ground_tmux reads it. mycelia is its own repository
// (Ground-Institute/mycelia): each pass it asks the node for its row and keeps
// it here with the moment it asked; ground_tmux draws what is kept and asks
// nothing.

import tmux : RED, PLAIN;

// How old a kept row may be before mycelia is taken to have stopped: its
// passes are five seconds apart, and one that waits out every fetch's
// MAX_TIME is still well inside it.
enum SILENT = 60;

// Where the row is kept. ug's state lives beside it.
enum KEPT = ".local/state/ug/mycelia";

size_t keptPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0 || home.length + KEPT.length + 2 > dest.length) return 0;
    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; KEPT) dest[o++] = c;
    if (o < dest.length) dest[o] = 0;
    return o;
}

struct Kept {
    long at;
    const(char)[] line;
}

// The moment it asked, a newline, and the row. A stamp that is not a number
// is no pass.
Kept keptOf(const(char)[] text) {
    long v = 0;
    size_t i = 0;
    while (i < text.length && text[i] >= '0' && text[i] <= '9') {
        v = v * 10 + (text[i] - '0');
        i++;
    }
    if (i == 0 || i >= text.length || text[i] != '\n') return Kept(0, text[0 .. 0]);
    return Kept(v, text[i + 1 .. $]);
}

// mycelia has kept nothing for this long, or has never kept anything (-1).
size_t silentInto(long since, char[] dest) {
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }

    put(RED);
    put("mycelia silent");
    if (since >= 0) {
        long n;
        const(char)[] unit;
        if (since < 3600) { n = since / 60; unit = "minute"; }
        else if (since < 86400) { n = since / 3600; unit = "hour"; }
        else { n = since / 86400; unit = "day"; }

        put(" ");
        char[24] d = 0;
        size_t dl = 0;
        long v = n;
        if (v <= 0) d[dl++] = '0';
        else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
        put(" ");
        put(unit);
        if (n != 1) put("s");
    }
    put(PLAIN);
    return o;
}

// What ground_tmux reads. Nothing kept is a Kept at 0.
Kept readKept(const(char)[] home) {
    import core.stdc.stdio : fopen, fread, fclose;
    __gshared char[512] path = void;
    if (keptPathInto(home, path[]) == 0) return Kept(0, null);
    auto f = fopen(&path[0], "rb");
    if (f is null) return Kept(0, null);
    __gshared char[8256] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);
    return keptOf(buf[0 .. n]);
}
