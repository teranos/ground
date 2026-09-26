module quiet_test;

// "SKY SHOULD NOT SPEAK TO THE SESSION" / "SENTRY SHOULD BE WHERE IT ENDS UP"
// "this isnt a nice thing to receive into the session."
//
// A worker whose failure is its own — a courier's retry, a background
// reading's DNS miss — tells sentry and wakes nobody. emitError is the loud
// path: a delivery row every session reads. A module that has no business
// waking a session names it nowhere, so putting it back is a visible act.

enum sky = import("source/sky.d");
static assert(!contains(sky, "emitError"), "sky whispers; sentry is where its own failures end up");

// The org's Actions minutes feed a table the tmux bar reads. No session asked,
// and no session can act on the ask going wrong. Seen 2026-09-24: "exec
// org-minutes: minutes.ask: Could not resolve host: api.github.com", into a
// session, over a background reading's DNS miss.
enum minutes = import("source/minutes.d");
static assert(!contains(minutes, "emitError"), "a reading that feeds a table speaks to no session");

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
