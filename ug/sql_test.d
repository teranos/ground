module sql_test;

// CTFE tests — failure shows as a compile error.

import sql : dbPathInto;

char[128] built(const(char)[] home)() {
    char[128] buf = 0;
    dbPathInto(home, buf[]);
    return buf;
}

enum want = "/Users/x/.local/share/ground/ground.db";
static assert(dbPathInto("/Users/x", new char[128]) == want.length);
static assert(built!"/Users/x"()[0 .. want.length] == want);

// A HOME that already ends in a separator does not produce a doubled one.
static assert(built!"/Users/x/"()[0 .. want.length] == want);

// The path is written with a terminating zero, because sqlite3_open_v2 takes
// a C string and a slice is not one.
static assert(built!"/Users/x"()[want.length] == 0);

// Nowhere to look is nothing, rather than a path rooted at the filesystem.
static assert(dbPathInto("", new char[128]) == 0);
