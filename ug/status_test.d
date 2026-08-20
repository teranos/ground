module status_test;

// CTFE tests — failure shows as a compile error.

import status : countPorcelain, statusInto, Counts;

// One untracked file, which is what the capture was taken with.
enum one = countPorcelain("?? ug/\n");
static assert(one.untracked == 1);
static assert(one.staged == 0);
static assert(one.modified == 0);

// Index column and working-tree column are counted separately, so a file
// staged and then edited again counts on both.
enum both = countPorcelain("MM a.d\n");
static assert(both.staged == 1);
static assert(both.modified == 1);

enum mixed = countPorcelain(" M a.d\nA  b.d\n?? c.d\n D d.d\n");
static assert(mixed.staged == 1);
static assert(mixed.modified == 2);
static assert(mixed.untracked == 1);

// A question mark in the index column is untracked, never staged.
enum q = countPorcelain("?? x\n?? y\n");
static assert(q.staged == 0);
static assert(q.untracked == 2);

enum none = countPorcelain("");
static assert(none.staged == 0 && none.modified == 0 && none.untracked == 0);

char[64] drawn(Counts c)() {
    char[64] buf = '.';
    statusInto(c, buf[]);
    return buf;
}

// The exact bytes the capture carries, leading space included.
enum capture = " [\033[31m?1\033[0m]";
static assert(statusInto(Counts(0, 0, 1), new char[64]) == capture.length);
static assert(drawn!(Counts(0, 0, 1))()[0 .. capture.length] == capture);

// Staged and modified are yellow, and the parts are joined by one space
// inside a single bracket.
enum all = " [\033[33m+1\033[0m \033[33m~2\033[0m \033[31m?3\033[0m]";
static assert(drawn!(Counts(1, 2, 3))()[0 .. all.length] == all);

// A clean tree draws nothing, not an empty bracket.
static assert(statusInto(Counts(0, 0, 0), new char[64]) == 0);
