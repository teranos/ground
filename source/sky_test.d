module sky_test;

// "the first part of the hear me out is renaming ground watch to ground sky"
// The command, the module, the process kind, the files and the error origins
// all say sky. The record it keeps names the kind, so the kind is asserted.
import sky : KIND, TREE_FILE, CLAIM_FILE, BOOK_COMMAND;
static assert(KIND == "sky");
static assert(TREE_FILE == "sky-tree-");
static assert(CLAIM_FILE == "sky-claim-");
static assert(contains(BOOK_COMMAND, "ground sky $PWD"));

// The pid file is read to decide what to SIGTERM. Everything it can contain
// that is not a live pid has to reach that decision as "signal nothing".

import sky : parsePid, orphaned;

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
private enum skySource = import("source/sky.d");
static assert(!contains(skySource, "bool urgent"));
static assert(!contains(skySource, "urgent = true"));
static assert(!contains(skySource, "sleep(5)"));
// No watch. left in the origins: an error row names the process that raised it.
static assert(!contains(skySource, `"watch.`));

// Recorded 2026-09-18 10:56: Stop killed watcher 98896 and spawned its
// replacement in the same instant. The replacement found 98896 in the tree
// file, kill(pid, 0) still answered 0, and it refused itself. The session was
// then unwatched. A pid the record says was killed does not hold the tree.
import sky : treeHeld;
static assert(treeHeld(true, false), "alive and not ended: held");
static assert(!treeHeld(false, false), "gone: free");
static assert(!treeHeld(true, true), "still answers kill(0) but the record says it ended: free");
static assert(!treeHeld(false, true));

// Recorded 2026-09-18 11:50:32: a Stop killed watcher 35708 and its replacement
// refused itself in the same second, before the kill was in the record; at
// 11:45:50 the Stop read the replacement's fresh pid file and killed that one.
// Two hooks Claude Code runs together have no order, so the replacement does
// the replacing: a Stop-spawned watcher takes the tree from its own session's
// watcher, and from nobody else's.
import sky : takesOver;
static assert(takesOver(true, true), "a Stop's watcher replaces its session's own");
static assert(!takesOver(true, false), "another session's watcher is left alone");
static assert(!takesOver(false, true), "a PostToolUse watcher refuses as before");
static assert(!takesOver(false, false));

// Recorded 2026-09-18 12:05: four watchers with ended_at 0 and no process,
// each silent after some 250 polls. A holder that no longer answers and whose
// row never ended is finished by the watcher that finds it so, in its words.
import sky : diedUnsaid;
static assert(diedUnsaid(false, false), "gone, and the record does not know");
static assert(!diedUnsaid(false, true), "gone, and the record already says how");
static assert(!diedUnsaid(true, false), "still there");
static assert(!diedUnsaid(true, true));

// "it ebing truncated copy is also not preffered"
// A message the batch cannot hold whole waits for the next pass. Cut to fit,
// the reason at its end was the part that went.
import sky : batchFits;
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
