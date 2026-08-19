module row_test;

// CTFE tests against the reference capture itself, so parity is asserted
// against collet's own bytes and not against bytes retyped from a dump.

import row : rowOneInto, FLAME;
import json : jsonString;

enum reference = import("captures/grove/out.bytes");
enum payload = import("captures/grove/in.json");
enum CWD = jsonString(payload, "cwd");

// The capture was taken at 05:45, which is what the clock has to be given for
// its bytes to line up with collet's.
enum HOUR = 5;
enum MINUTE = 45;

char[64] drawn() {
    char[64] buf = '.';
    rowOneInto(HOUR, MINUTE, CWD, buf[]);
    return buf;
}

enum built = drawn();
enum len = rowOneInto(HOUR, MINUTE, CWD, new char[64]);

// Sixteen of clock, five of flame, fifteen of repository.
static assert(len == 36);
static assert(built[0 .. len] == reference[0 .. len]);

// The repository is read from the payload, so the two captures draw two
// different names from the same code.
enum other = import("captures/quiet/out.bytes");
enum otherCwd = jsonString(import("captures/quiet/in.json"), "cwd");

char[64] drawnOther() {
    char[64] buf = '.';
    rowOneInto(5, 32, otherCwd, buf[]);
    return buf;
}

enum builtOther = drawnOther();
enum lenOther = rowOneInto(5, 32, otherCwd, new char[64]);
static assert(builtOther[0 .. lenOther] == other[0 .. lenOther]);

// The flame carries no colour of its own: nothing between the clock's reset
// and the emoji.
static assert(FLAME.length == 5);
static assert(reference[16 .. 21] == FLAME);
