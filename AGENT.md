# AGENT

An Agent is a background session. Anthropic's names for it are **background
session** and **agent view** (`claude agents`), as opposed to an **interactive
session**. `run.d:355` spawns one with `claude -w <tree> --bg <prompt>`.

A subagent is a different thing and ground does not build on it. See
[SUBAGENT.md](SUBAGENT.md).

## Never in question

"agent should never be blocked, period, this is the definition and its not going to change"

"ground doesnt keep agent hostage ever, it doesnt happen its not part of the spec"

"things either fail or pass, nothing is ever stuck"

"inside of a ritual, no blocking occurs for failed rites, it doesnt happen"

"ritual is hands-off, walk away"

"if a deny needs to be given, it should not have to come from the user, that needs to get into the stuck session"

What a rite holds is the Stop, never the agent:

"the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop"

"a rite can only take hostage for at most 2 sec"

| | nr | thing | words | notes |
|---|---|---|---|---|
| | a1 | An Agent inside a performance is never asked for permission | "if a deny needs to be given, it should not have to come from the user, that needs to get into the stuck session" / "rites should never be stuck" | `chapter-1786287252` sat 34 minutes on `"waitingFor": "permission prompt"`, `"state": "blocked"`, and the rite never ran once. `consent.d:5` authorises four commands — `git commit`, `git push`, `gh pr checks`, `gh pr create` — and `CHAPTER` needs a Write, so Claude Code asked a session with nobody in it. Enumerating permitted commands guarantees the next rite is one short. The tree is the boundary that does not need enumerating: a performance has its own worktree and branch and lands as a PR, so inside it ground answers every PreToolUse with allow or deny and never leaves the decision to a human who has walked away |
| | a2 | Ground can see an Agent that is not working | — | Ground's only sense organ is hooks, and a blocked Agent fires none, so being stuck is an absence of events and cannot be waited for. `claude agents --json` answers it directly with `status`, `waitingFor` and `state`; nothing in ground reads them. `drive.d` already wakes every fifteen seconds and re-evaluated the rite 205 times against an Agent that could not move |
