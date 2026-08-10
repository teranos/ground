# SUBAGENT

A subagent is a Task-tool sidechain: it runs inside its caller's session,
shares the transcript, and is refused or released through `SubagentStart` and
`SubagentStop`.

**This is its own track, and nothing here is in scope of the `rituals`
branch.** A ritual is carried by a background session — `claude -w <tree>
--bg` in `run.d:284` — which is a process of its own with its own session id,
its own transcript, and its own worktree. The two are told apart in one line of
ground's source, `sessionstart.d:316`:

> SubagentStart ... does not fire for `claude -w`

Everything here is real, tested where it says so, and reachable only by a
ritual carried the other way. This document exists so that stays visible
instead of being rediscovered as a bug.

| | nr | thing | words | notes |
|---|---|---|---|---|
| ✓ | s37 | `SubagentStart` | "you COULD if you wanted to run an agent like that, equiped with ritual" | binds the performance to the owning session and the agent, and hands it the briefing |
| ✓ | s38 | `SubagentStop` | same | exit 2 refuses an agent leaving rites unmet — the only place a subagent can be refused. Keeps `last_assistant_message` with the performance |
| | s77 | SubagentStop runs the rite and refuses the stop | "and of course handleSubagentStop" | `subagent.d:52`. It reads the position, keeps `last_assistant_message`, and returns exit 2 with the briefing — but never calls `advance`, so the rite is never evaluated and the position never moves. Every verdict lives in `stop.d`. This is the one hole between ground and a ritual that runs as a sidechain. Docs: exit 2 "Prevents the subagent from stopping" |
| | s78 | A ritual generates the subagent that performs it | "maybe the Grove CLAUDE.md should partly live in subagent, which would be in ritual block" / "there could always be a main ground subagent, or just different ones, and they are described by the ritual" | The two layers hold: the preamble is ground's own semantics (a rite is a gate, `pass` is declared, ground runs the cmd and commits on Advance, the first two sentences are carried home) and ground emits it, so no repo restates it; the ritual carries its own material. What does not hold is the mechanism this row proposed. `.claude/agents/<ritual>.md` defines a Task-tool agent, and a performance is a Fleet session (see r76), so `isolation: worktree` cannot replace `worktreePath` + `WorktreeCreate` and frontmatter `hooks` do not travel. What reaches a Fleet performance is the `--bg` prompt at spawn and `SessionStart.additionalContext` at start. Re-priming after compaction is not wanted — a ritual stops where compaction would begin — which leaves priming-once, and `spawnScript` already passes a prompt |
