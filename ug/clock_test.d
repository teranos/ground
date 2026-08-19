module clock_test;

// CTFE tests — failure shows as a compile error.

import clock : clockInto;

char[32] drawn(int h, int m)() {
    char[32] buf = '.';
    clockInto(h, m, buf[]);
    return buf;
}

// The exact bytes the capture opens with.
enum capture = "\033[32m[05:45]\033[0m";
static assert(clockInto(5, 45, new char[32]) == capture.length);
static assert(drawn!(5, 45)()[0 .. capture.length] == capture);

// Both fields are two digits at every hour of the day, so nothing to the
// right of the clock ever shifts.
static assert(drawn!(0, 0)()[0 .. capture.length] == "\033[32m[00:00]\033[0m");
static assert(drawn!(23, 59)()[0 .. capture.length] == "\033[32m[23:59]\033[0m");
static assert(drawn!(9, 5)()[0 .. capture.length] == "\033[32m[09:05]\033[0m");

// 24 hours, never 12 with a letter after it.
static assert(drawn!(13, 0)()[0 .. capture.length] == "\033[32m[13:00]\033[0m");
