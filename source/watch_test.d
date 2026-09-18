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

// Recorded 2026-09-18 10:56: Stop killed watcher 98896 and spawned its
// replacement in the same instant. The replacement found 98896 in the tree
// file, kill(pid, 0) still answered 0, and it refused itself. The session was
// then unwatched. A pid the record says was killed does not hold the tree.
import watch : treeHeld;
static assert(treeHeld(true, false), "alive and not ended: held");
static assert(!treeHeld(false, false), "gone: free");
static assert(!treeHeld(true, true), "still answers kill(0) but the record says it ended: free");
static assert(!treeHeld(false, true));

// "it ebing truncated copy is also not preffered"
// A message the batch cannot hold whole waits for the next pass. Cut to fit,
// the reason at its end was the part that went.
import watch : batchFits;
static assert(batchFits(0, 64, 55));
static assert(!batchFits(0, 64, 56));
static assert(batchFits(20, 64, 35));
static assert(!batchFits(20, 64, 36));

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
