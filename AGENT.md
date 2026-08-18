# AGENT

An Agent is a session ground starts to carry a performance. There are two
implementations of one idea, and both stay — "we dont lose --bg agent, but what
we do do is create another implementation alongside it".

A **--bg agent** is a background session. Anthropic's names for it are
**background session** and **agent view** (`claude agents`), as opposed to an
**interactive session**. `spawnScript` starts one with
`claude -w <tree> --bg <prompt>`. The daemon owns it, which is what gives it a
row in agent view, a peek panel, and `claude stop <id>`. Ground can watch it
and cannot address it: every channel to it is a hook, and a hook only speaks
when the agent next pauses.

A **stream-json agent** is a child on pipes. The driver forks
`claude --output-format stream-json --verbose --input-format stream-json` and
keeps both ends, so it speaks the control protocol the official SDK speaks.
Nobody else owns it, which is what costs it the agent view row and the peek
panel, and what buys the one thing the other cannot do: it can be interrupted
mid-sentence.

[INTERRUPT.md](INTERRUPT.md) is why the second one exists — "INTERRUPT happens
to be the reason for wanting its existence, it's because I want the true
unwavering reading of the original 90d". Not a migration and not a replacement.
The rows below are the `--bg` agent's record; where the stream-json agent needs
its own answer to one of them, that answer is a numbered row in INTERRUPT.md.

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
| ✓ | a95 | An Agent inside a performance is never asked for permission | "if a deny needs to be given, it should not have to come from the user, that needs to get into the stuck session" / "rites should never be stuck" | `chapter-1786287252` sat 34 minutes on `"waitingFor": "permission prompt"`, `"state": "blocked"`, and the rite never ran once. `consent.d` authorises four commands — `git commit`, `git push`, `gh pr checks`, `gh pr create` — and `CHAPTER` needs a Write, so Claude Code asked a session with nobody in it. Enumerating permitted commands guarantees the next rite is one short. The tree is the boundary that does not need enumerating: a performance has its own worktree and branch and lands as a PR, so inside it ground answers every PreToolUse with allow or deny and never leaves the decision to a human who has walked away. Built 2026-08-13: the list is gone, and the gate answers on the three paths that used to hand the question over — a control saying `ask`, a Bash command ground had nothing to say about, and the non-Bash tail every Write took. Denies are untouched; a deny is ground answering, only an ask strands the agent. Walked on `chapter-1786648619` — 35 Bash calls and 5 Reads, never blocked, where the same ritual on the same rite had to be killed by hand |
| ✓ | a93 | A ritual carries the Agent's system prompt | "there is this thing i still really want. which is to define a CLAUDE.md inline in a ritual" / `system: "What Would be the CLAUDE.md is here, like: You are a Specialist in Targeted Advertisement Campaigns. Check recent performance and suggest next steps based on provenance in the form of: - as [subject] is [predicate] of [context] attributes{k:'v'}"` | RITUAL 93 until 2026-08-11: it is about what an Agent is, not about how a walk moves. Verified 2026-08-09 that the mechanism exists — `claude --bg --append-system-prompt "You answer every question with exactly the word PINEAPPLE and nothing else." "what fruit is best"` answered PINEAPPLE, measured rather than read. `--append-system-prompt` rather than `--system-prompt` or `--system-prompt-file` is mine, on the grounds that a CLAUDE.md adds to what an agent already is instead of replacing it — say if that is wrong. Built: `system:` on `ritual { }` in `proto.d`, carried on `Flattened`, passed to `spawnScript`. Walked 2026-08-11 on `sun-1786479850`: the agent ended six messages with HELIOS and named the DONKI window unprompted, and that instruction exists nowhere but sun.pbt |
| ✓ | a75 | A ritual is carried by an Agent, not a detached process | "i want sidechain" / "so i can press donw and access it and chat in it while its happening" / "yeah, thats it" — the peek panel | RITUAL 75 until 2026-08-11. "i want FleetView" was on this row and was mine. `spawnScript` spawns `claude -w <tree> --bg`, which is what this asked for; the sidechain variant and what it would still need is SUBAGENT.md s77. Half-built already: `handleSubagentStart` binds session + agent and injects the briefing as `additionalContext`, `handleSubagentStop` refuses the stop with exit 2. Missing half: `handleSubagentStop` never calls `advance`, so the rite is never evaluated there and the position never moves — every verdict lives in `stop.d`. Ground cannot spawn a sidechain (it is a hook, only the model calls Task), so `ground ritual <name>` must hand the session a briefing instead of forking `claude -w`. Deletes `reapScript`, `agent_pid`, and the `parent` binding in `posttooluse.d`. Verified against the hook docs 2026-08-08: SubagentStop exit 2 "Prevents the subagent from stopping"; input carries `session_id` (the parent's), `agent_id`, `agent_type`, `cwd`, `last_assistant_message`; `matcher` matches `agent_type`; no `stop_hook_active` on this path. `ground watch` is a Stop hook only, so a74 is not in front of this |
| ✓ | a74 | The Agent carries on when the Stop goes back | "allowing the agent to continue" — the second half of RITUAL 19, split out 2026-08-08 because it is not in `stop.d` and not about the rite | RITUAL 74 until 2026-08-11. `watch.d`. 605, 605, 606, 607, 610, 748 seconds between Stops, transcript empty across every gap, while ground's own Stop hook measures 2s max over 126 calls. Cause NOT established. Claimed and withdrawn 2026-08-08: I said the watcher held it, because `handleWatch` has two exits, a delivered batch and an orphaned parent, and a Hold produces neither, so it loops on `nextSleep = 15` forever. The loop is real and is why ten watchers were found orphaned (`claimSession`), but it cannot be the hold: the docs say `asyncRewake` "runs in the background… Implies `async`", so Claude Code never waits on it. Measured 2026-08-08: the ground Stop hook as a process is 0.321s wall, 286ms handler, against a real live performance. It exits and holds nothing open, so it is not the 600 either. Every 605 sample was taken against `claude -w <id> -p` — print mode, detached — which a75 deleted. Measured against `--bg` on 2026-08-09: `willow-1786300247` walked ten rites in 140 seconds, sampled at 1s, with Stop-to-Stop gaps of 1 to 15 seconds and nothing near 600. Two willow walks and a chapter run, none of them stalled. The 605 was print mode, and print mode is gone |
| ✓ | a80 | A performance is a row in agent view | "i think 80 is done, because i get to see what is being executed form here, and its unrelated to subagent" | RITUAL 80 until 2026-08-11. The three quotes this row carried were "i want FleetView" / "Fleet is what i think i am referring to" / "how do we settle on Fleet", none of which appear on any user line in any transcript. Fleet was my word, taken from a string in my own system prompt. `claude agents --json` lists `perpetuity-a9r` as `kind: background`, `cwd` the perpetuity worktree, `sessionId` a44b126d — byte-for-byte the `session` column on its `ritual_position` row, so the join key was already being written. `spawnScript` is now `claude -w id --bg prompt`; `-p` was one-shot and detached, reachable by nothing but pkill. The row reads `name: "perpetuity rite logic"`, `state: working`. Not done: the registry answering is not the view rendering, and the view could not render it. Agent view filters on `--cwd` "sessions started under path", and `worktreePath` places a tree at `root-perfId`, a sibling of the repo root — so `--cwd .../q.sbvh.nl` returns 0 and `--cwd .../sbvh-nl` returns it. A ritual is invisible from the repo it belongs to. `isolation: worktree` would put the tree in `.claude/worktrees/` under the repo, but that is a Task-tool agent property and a performance is a background session (SUBAGENT.md s78), so it does not apply. Still unverified: whether Space peeks, Enter attaches, and a reply reaches. Would make `reapScript` and `agent_pid` redundant rather than orphaned, since a session is stopped with Ctrl+X |
| | a85 | An Agent that cannot act says so in its own form | "░▏(╯°□°）╯︵ ┻━┻" / "░▏Could not do shit bro." / "░▏Just didnt have the perission." | RITUAL 85 until 2026-08-11. The third gutter, one shade lighter than a rite, for the case where the agent is not refusing a rite but cannot reach one. Not built — no rite emits it and nothing detects the condition. Three times now, and every time the walk recorded passes while the agent said plainly it could not act. `willow-lkt`, 2026-08-09, delivered on the `CHECKWILLOW` line: "I could not pick the LIME. Every tool call this turn came back `No tools needed for suggestion`; the one Edit that reached the file was rejected as stale, and no Read since has been allowed through, so I have no current view of WILLOW.md and cannot make the change." And the inverse on `sun-1786389572`, 2026-08-10: "the push landed, the branch is up, and the pull request has what it needs" while the change was staged and unpushed. A performance that reports a clean walk while its agent could not act is the record lying, and one that reports work landed when it did not is the same failure from the other side |
| | a96 | Ground can see an Agent that is not working | — | Ground's only sense organ is hooks, and a blocked Agent fires none, so being stuck is an absence of events and cannot be waited for. `claude agents --json` answers it directly with `status`, `waitingFor` and `state`; nothing in ground reads them. `drive.d` already wakes every fifteen seconds and re-evaluated the rite 205 times against an Agent that could not move |
