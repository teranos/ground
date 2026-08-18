module wiring_test;

// The suite tests values, so a function with no caller passes every test it
// has. This asserts the wiring: the call site exists in the source.

private enum stopSource = import("source/stop.d");
private enum runSource  = import("source/ritual/run.d");
private enum driveSource = import("source/ritual/drive.d");
private enum watchSource = import("source/watch.d");

private bool calls(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool hit = true;
        foreach (j; 0 .. needle.length)
            if (hay[i + j] != needle[j]) { hit = false; break; }
        if (hit) return true;
    }
    return false;
}

// "AGENTLLM STOP OUTPUT FIRST TWO SENTENCES OF LAST MESSAGE NEEDS TO BE SEEN BY
// BOTH HUMAN AND HOSTLLM". Stop is the only place the agent's last message can
// be read, so this call site is the whole channel.
static assert(calls(stopSource, "firstTwoSentences"),
    "stop.d must carry the agent's first two sentences into the rite line");

// One thing advances a position. `ground drive` is forked for every performance
// and walking is its whole job; a second walker ran every rite twice.
static assert(calls(driveSource, "advance("),
    "the driver is what walks a performance");
static assert(!calls(stopSource, "advance("),
    "stop.d must not walk — it ran the same rite a second time");
static assert(!calls(watchSource, "advance("),
    "the watcher must not walk — it ran the same rite a second time");
