module wiring_test;

// The suite tests values, so a function with no caller passes every test it
// has. This asserts the wiring: the call site exists in the source.

private enum stopSource = import("source/stop.d");
private enum runSource  = import("source/ritual/run.d");
private enum driveSource = import("source/ritual/drive.d");
private enum skySource = import("source/sky.d");

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
static assert(!calls(skySource, "advance("),
    "the sky must not walk — it ran the same rite a second time");

// "there cannot be an instance where a ritual fires while i said rituals off"
// A performance starts in two places, and both ask the switch first.
private enum postToolUseSource = import("source/posttooluse.d");
private enum commandSource = import("source/ritual/command.d");
static assert(calls(postToolUseSource, "ritualOff("), "a control asks before it performs");
static assert(calls(commandSource, "offBecause("), "ground ritual asks before it performs");

// "it should be easy for me to switch, simply by saying the words"
private enum userPromptSource = import("source/userprompt.d");
static assert(calls(userPromptSource, "switched("), "the prompt is where the words are said");

// A ritual that opted into regoto starts no second performance, from either
// place a performance starts.
static assert(calls(postToolUseSource, "secondFire("), "a control asks before it performs");
static assert(calls(commandSource, "secondFire("), "ground ritual asks before it performs");

// And the fire lands on the live one instead: its tree onto the push, its walk
// to the regoto rite.
static assert(calls(postToolUseSource, "landOn("), "a control's second fire lands on the live one");
static assert(calls(commandSource, "landOn("), "ground ritual's second fire lands on the live one");

// "build the probe on commit, scores into QNTX"
static assert(calls(postToolUseSource, "probeDetached("), "a commit's prose is scored where the commit is heard");

// "I dont know how to explain how serious this defect is"
static assert(calls(stopSource, "sweepOrphans("), "a turn's end halts a walk whose driver is gone");
static assert(calls(userPromptSource, "sweepOrphans("), "typing halts a walk whose driver is gone");
