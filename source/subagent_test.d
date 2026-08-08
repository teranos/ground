module subagent_test;

// A ritual carried by a sidechain instead of a detached process.
// Brandon: "i want sidechain" / "i dont want separate OS process"

import ritual : RitualState, subagentOutcome, SubagentOutcome;

// Refusing a subagent's stop is the whole mechanism. The hook docs: exit 2
// "Prevents the subagent from stopping" — the same power Stop has, on the
// event that fires when the agent believes it has finished.
static assert(subagentOutcome(RitualState.Live) == SubagentOutcome.Refuse);

// An ended performance has nothing left to hold anyone for. Refusing here
// would keep an agent inside a ritual that already reached its verdict.
static assert(subagentOutcome(RitualState.Done) == SubagentOutcome.Release);
static assert(subagentOutcome(RitualState.Halted) == SubagentOutcome.Release);

// "it ends when it ends, not because i ran ritual stop" — abort is the one
// ending a person causes, and it must let the agent go.
static assert(subagentOutcome(RitualState.Aborted) == SubagentOutcome.Release);
