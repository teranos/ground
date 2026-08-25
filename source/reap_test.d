module reap_test;

// "HOW IS THERE NOT A REAL NATIVE TRUE WAY TO KILL THE BG SESSION"

import ritual.run : reapScript;

private enum driveSource = import("source/ritual/drive.d");
private enum commandSource = import("source/ritual/command.d");

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

enum r = reapScript("e5f42580-1a2b-4c3d-9e8f-0123456789ab");

// Proven: `claude stop 422bddec` answered `stopped 422bddec` and kept the tree.
static assert(contains(r.text(), "claude stop"),
    "the documented ending, not a signal");

// `pgrep -f 'claude -w'` returned 0 at every sample through a whole
// performance, live and done. It has never matched a process.
static assert(!contains(r.text(), "claude -w"),
    "the old handle is not in the agent's command line");
static assert(!contains(r.text(), "pkill"),
    "a signal drops the agent mid-turn and races whatever restarts it");

// The agent ground started is the agent ground ends. Selecting on the tree
// stopped every background session whose cwd matched, and a ritual that names
// no tree performs in a checkout a person is working in.
static assert(!contains(r.text(), ".cwd=="),
    "a directory is not an identity");
static assert(contains(r.text(), "'e5f42580-1a2b-4c3d-9e8f-0123456789ab'"));

// Nothing to reap without one, and an empty pattern would match everything.
static assert(reapScript("").text().length == 0);

// Both callers reach the reap by the session the row bound.
static assert(contains(driveSource, "reapScript(found.p.agentSession)"));
static assert(contains(commandSource, "reapScript(p.agentSession)"));
