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
