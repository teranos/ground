module stop_test;

// The briefing is the agent's keep-going signal. A ritual performs in the
// checkout the work happened in, so a person's own session matched the row by
// directory and was handed the rite line once per turn while the rite slept.

import stop : briefThisSession;

static assert(briefThisSession("agent-1", "agent-1"));
static assert(!briefThisSession("mine", "agent-1"));

// Before an agent binds nobody carries it, so there is nobody to brief.
static assert(!briefThisSession("mine", ""));
static assert(!briefThisSession("", ""));

// "this is costly"
// Counted 2026-09-18 on q-deploy-1789717456: 186 Stops in 17 minutes answered
// with "rite 12 of 12: VERSIONS. It is met when this exits 0: " and nothing
// after the colon, 605 assistant turns, 83M tokens read. VERSIONS is run:
// only, and the block was waiting on a dispatch. The agent is kept going only
// when the rite it stands on asks something of it and nothing gates the rite;
// otherwise its Stop goes through, and the driver's note wakes it when a rite
// opens.
import stop : agentAsked;
static assert(agentAsked(true, false), "an eval to meet, nothing in the way");
static assert(!agentAsked(false, false), "run: only, or dispatch: — ground runs it");
static assert(!agentAsked(true, true), "the block waits on a dispatch, so does the rite");
static assert(!agentAsked(false, true));

// --- The timing notice is asked for, never assumed ---

// "i dont expect normal users to drop everything they do and do ground performance work"
// "the performace notification should only apply to select projects defined in pbt"

// A budget breach used to be told to whoever hit it. The notice is now a
// control: a Stop scope naming this place and carrying timing asks for it, and
// an install declaring none never hears it.
import stop : timingAsked;
import hooks : Control;

private struct TScope {
    string[8] paths;
    ubyte pathCount;
    const(Control)[] controls;
}

// The scope names this project and asks, so the notice is owed here.
static assert(() {
    Control[2] cs;
    cs[0].name = "something-else";
    cs[1].name = "ground-timing";
    cs[1].timing = true;
    TScope[1] scs;
    scs[0].paths[0] = "/teranos/ground";
    scs[0].pathCount = 1;
    scs[0].controls = cs[];
    return timingAsked(scs[], "/home/me/teranos/ground", "/home/me/teranos/ground");
}());

// The same scope with nothing asking. This is the shipped state, and it is
// silent: no control, no notice.
static assert(() {
    Control[1] cs;
    cs[0].name = "ground-timing";
    TScope[1] scs;
    scs[0].paths[0] = "/teranos/ground";
    scs[0].pathCount = 1;
    scs[0].controls = cs[];
    return !timingAsked(scs[], "/home/me/teranos/ground", "/home/me/teranos/ground");
}());

// Asking, but for somewhere else. A stranger working in another checkout is
// not the one who wanted the performance work.
static assert(() {
    Control[1] cs;
    cs[0].name = "ground-timing";
    cs[0].timing = true;
    TScope[1] scs;
    scs[0].paths[0] = "/teranos/ground";
    scs[0].pathCount = 1;
    scs[0].controls = cs[];
    return !timingAsked(scs[], "/home/me/work/unrelated", "/home/me/work/unrelated");
}());

// "could be a global default, but i want it to be opt in, not on by default"

// A scope naming no path names every project, so the default is expressible.
// It is simply not the one that ships.
static assert(() {
    Control[1] cs;
    cs[0].name = "ground-timing";
    cs[0].timing = true;
    TScope[1] scs;
    scs[0].controls = cs[];
    return timingAsked(scs[], "/home/me/work/anywhere", "/home/me/work/anywhere");
}());

// Nothing declared at all is the same silence, with no scope to walk.
static assert(() {
    TScope[0] scs;
    return !timingAsked(scs[], "/home/me/teranos/ground", "/home/me/teranos/ground");
}());

// The pbt carries it through the parse, or the field above is unreachable.
import proto : parsePbt;

enum timingInput = `
scope {
  event: "Stop"
  path: "/teranos/ground"

  control {
    name: "ground-timing"
    timing: "true"
  }
}
`;
enum timingParsed = parsePbt(timingInput);
static assert(timingParsed.ctrlPool[0].timing);

// A scope that says nothing about timing leaves it off, rather than picking a
// default up from somewhere.
enum quietInput = `
scope {
  event: "Stop"

  control {
    name: "ground-timing"
  }
}
`;
static assert(!parsePbt(quietInput).ctrlPool[0].timing);
