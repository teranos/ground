module rite_error_test;

// A rite that could not run has no exit code, and must not be given one.
// The ERROR AXIOM's truthfulness clause: an ERROR states what the emitting
// code measured, never a cause inferred from a proxy.

import rite : Waited, fromPclose, RunFailure, RiteRun, runRite, buildRiteScript;

// pclose hands back a wait status, not an exit code.
static assert(fromPclose(0).valid);
static assert(fromPclose(0).code == 0);
static assert(fromPclose(256).code == 1);
static assert(fromPclose(32512).code == 127);

// pclose returns -1 when it could not wait for the child at all. Shifting
// that gives 255 — a code no process returned, which classify would read as
// a halt and report to the operator as the rite's answer.
static assert(!fromPclose(-1).valid);
static assert(fromPclose(-1).code == 0);

// A run that reached a process carries no failure.
unittest {
    auto r = runRite(buildRiteScript("", "false", [], []).text());
    assert(r.failure == RunFailure.None);
    assert(r.ran);
    assert(r.code == 1);
}

// The sentinel is gone: a RiteRun that did not run says so in its own field
// rather than in a code that classify cannot tell from a real one.
unittest {
    RiteRun r;
    assert(!r.ran);
    assert(r.failure == RunFailure.None);
}
