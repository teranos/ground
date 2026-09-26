module loud_test;

// ERROR AXIOM: "The ERROR is never collapsed, dropped, swallowed, truncated
// or suppressed; it lands in front of the user."
//
// 2026-09-25, between 20:10 and 20:18, the timing index went malformed. The
// hook's timing insert stepped, answered 11, and was finalized without a look.
// Sky's timing claim did the same and read the store's refusal as an empty
// queue. Forty minutes of every hook, unmeasured and unreported, until a
// person noticed the dashboard had gone quiet. "fix both"

enum sky  = import("source/sky.d");
enum hook = import("source/main.d");

static assert(!contains(sky, "claimTiming(db, pid) > 0"),
    "sky reads the claim's answer, not only its row count");
static assert(contains(sky, "claim.rc != SQLITE_DONE"),
    "sky says so when the store refuses the timing claim");
static assert(contains(hook, "insertTiming("),
    "the hook writes its row through the one function that answers");
static assert(contains(hook, "!= SQLITE_DONE"),
    "the hook says so when the store refuses its timing row");

// 2026-09-24 and 25: q-deploy fired on every push and started on none; the
// position could not be written to a malformed store. The failure went to the
// error record and the session that pushed was told nothing, because the
// caller cast the answer away.
enum post = import("source/posttooluse.d");
static assert(!contains(post, "cast(void) performFromControl"),
    "a ritual that did not start is said to the session that fired it");

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
