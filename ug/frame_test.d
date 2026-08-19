module frame_test;

// CTFE tests — failure shows as a compile error.

import frame : parseFrame, formatFrame;

// What the file holds is a count.
static assert(parseFrame("0") == 0);
static assert(parseFrame("7") == 7);
static assert(parseFrame("1234") == 1234);
static assert(parseFrame("1234\n") == 1234);

// A file that holds nothing readable starts the count over rather than
// stopping the row.
static assert(parseFrame("") == 0);
static assert(parseFrame("\n") == 0);
static assert(parseFrame("wat") == 0);
static assert(parseFrame("12x4") == 12);

char[8] written(size_t n)() {
    char[8] buf = '.';
    formatFrame(n, buf[]);
    return buf;
}

static assert(formatFrame(0, new char[8]) == 1);
static assert(written!0()[0 .. 1] == "0");
static assert(formatFrame(9, new char[8]) == 1);
static assert(written!9()[0 .. 1] == "9");
static assert(formatFrame(1234, new char[8]) == 4);
static assert(written!1234()[0 .. 4] == "1234");

// What is written can be read back, which is the whole contract between one
// repaint and the next.
static assert(parseFrame(written!407()[0 .. formatFrame(407, new char[8])]) == 407);
