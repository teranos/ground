module watch_test;

// The pid file is read to decide what to SIGTERM. Everything it can contain
// that is not a live pid has to reach that decision as "signal nothing".

import watch : parsePid, orphaned;

static assert(parsePid("12345\n") == 12345);
static assert(parsePid("12345") == 12345);

// An empty or truncated file is a watcher that died between fopen and write.
static assert(parsePid("") == 0);
static assert(parsePid("\n") == 0);

// kill(0, SIGTERM) signals every process in the caller's group. A file
// holding a literal zero must not become that call.
static assert(parsePid("0\n") == 0);

// Anything else is a file somebody else wrote.
static assert(parsePid("abc") == 0);
static assert(parsePid("-1") == 0);

// A watcher outlives the session that spawned it only by accident: its
// parent is claude, so ppid 1 means nobody is left to be woken.
static assert(orphaned(1));
static assert(!orphaned(3787));

// "nothing can wait, and everything is urgent, at the same level of
// predictable urgency"
private enum watchSource = import("source/watch.d");
static assert(!contains(watchSource, "bool urgent"));
static assert(!contains(watchSource, "urgent = true"));
static assert(!contains(watchSource, "sleep(5)"));

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool hit = true;
        foreach (j; 0 .. needle.length)
            if (hay[i + j] != needle[j]) { hit = false; break; }
        if (hit) return true;
    }
    return false;
}
