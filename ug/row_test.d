module row_test;

// CTFE tests against the reference capture itself, so parity is asserted
// against collet's own bytes and not against bytes retyped from a dump.

import row : rowOneInto, Head, FLAME;
import json : jsonString;
import status : Counts;

enum reference = import("captures/grove/out.bytes");
enum payload = import("captures/grove/in.json");
enum CWD = jsonString(payload, "cwd");

// The capture was taken at 05:45, which is what the clock has to be given for
// its bytes to line up with collet's.
enum HOUR = 5;
enum MINUTE = 45;

// What collet was looking at when the capture was taken. Everything here is
// read off the reference bytes, so the test says what the row must produce
// rather than what the code happens to produce.
// HOME is whatever the payload's cwd sits under; the capture was taken at the
// project root, so the path rule never reaches the tilde branch here.
enum HOME = jsonString(payload, "project_dir");

enum head = Head(CWD, CWD, HOME, "ref-test", "Opus 5",
                 "default", Counts(0, 0, 1), 12);

char[128] drawn() {
    char[128] buf = '.';
    rowOneInto(HOUR, MINUTE, head, buf[]);
    return buf;
}

enum built = drawn();
enum len = rowOneInto(HOUR, MINUTE, head, new char[128]);

// The whole of collet's first line, up to but not including its newline.
enum firstLine = lineOne(reference);
static assert(len == firstLine.length);
static assert(built[0 .. len] == firstLine);

const(char)[] lineOne(const(char)[] all) {
    foreach (i, c; all) if (c == '\n') return all[0 .. i];
    return all;
}

// The repository is read from the payload, so the two captures draw two
// different names from the same code.
enum other = import("captures/quiet/out.bytes");
enum otherCwd = jsonString(import("captures/quiet/in.json"), "cwd");
enum otherHead = Head(otherCwd, otherCwd, otherCwd, null, null,
                      "default", Counts(0, 0, 0), -1);

char[128] drawnOther() {
    char[128] buf = '.';
    rowOneInto(5, 32, otherHead, buf[]);
    return buf;
}

enum builtOther = drawnOther();
enum lenOther = rowOneInto(5, 32, otherHead, new char[128]);
static assert(builtOther[0 .. lenOther] == other[0 .. lenOther]);

// A field the session does not carry draws nothing at all, rather than an
// empty pair of brackets or a bare percent sign. The repository is the last
// thing drawn, and the space after it belongs to the segment that follows.
static assert(lenOther == 36);

// The flame carries no colour of its own: nothing between the clock's reset
// and the emoji.
static assert(FLAME.length == 5);
static assert(reference[16 .. 21] == FLAME);
