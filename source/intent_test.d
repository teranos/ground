module intent_test;

// Brandon: "its not coming here" / "you made it at some point, and it worked
// at some point, and now its gone again"

import ritual.intent : nameable, writeIntent, takeIntent;

// A ritual name arrives from a shell command and becomes a filename.
static assert(nameable("willow"));
static assert(nameable("perpetuity"));
static assert(nameable("ci-check_2"));
static assert(!nameable(""));
static assert(!nameable("../../etc/passwd"));
static assert(!nameable("a/b"));
static assert(!nameable("a b"));

unittest {
    writeIntent("willow-test", "sess-abc");
    assert(takeIntent("willow-test") == "sess-abc");
}

// Consumed on read. The willow is performed again and again, and a leftover
// claim would report the next performance to whoever started the last one.
unittest {
    writeIntent("willow-test", "sess-abc");
    takeIntent("willow-test");
    assert(takeIntent("willow-test") is null);
}

// No claim is not an error. A ritual started by hand from a terminal has no
// session owed anything, and that must not stop it from running.
unittest {
    assert(takeIntent("never-claimed-anything") is null);
}
