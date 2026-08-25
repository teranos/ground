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
