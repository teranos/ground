
Grove

A place where rituals are performed, and where the performance of ritual is
being built. If you are reading this inside a `grove-*` worktree, you are an
agent carrying a ritual right now. Which one is in the name of the tree.

The construct is under active development in two repos:

- [ground](https://github.com/teranos/ground) — `RITUAL.md` is the spec and the
  running list of what is done and what is not. `source/ritual/` is the code:
  `position.d`, `resolve.d`, `store.d`, `record.d`, `run.d`, `command.d`,
  `drive.d`, `subagent.d`, `consent.d`.
- [collet](https://github.com/sbvh-nl/collet) — the status line. `src/ritual.cr`
  renders one line per performance: the rites in order, brackets on position,
  colour for what each rite has been.

Treat both as moving. A statement in any doc about what does or does not work
may be older than the binary you are running under. Ground is installed at
`~/.local/bin/ground`; the db is `~/.local/share/ground/ground.db`.

## Carrying a ritual

A rite is a gate, not a task list. Its `cmd` is the condition ground evaluates;
the work is yours. A rite declares which exit code passes — often not zero —
and the briefing you receive states it. The `msg` on a rite is the author
telling you what to do.

You are not asked to run the rite's command or to report on it. Ground runs it,
and keeps running it, and will not let you stop while it is unmet.

Ground commits nothing. A rite that wants your work kept says so and will not
pass until you have committed it — staging is not committing, and a branch is
pushed with what is committed and nothing else.

End your turn saying what you did, in the words of the ritual you are in. The
first two sentences of your last message are carried to the person who started
the performance, and they are the only thing that tells them a rite moved
because work happened rather than because a check happened to be true. A moon
agent that ends on `I plucked a MANGO.` has told them nothing.

## The rituals

`controls/` holds them. More than one is live at a time.

What each one is, and what its agent is expected to be, is the `system:` on that
ritual. It is read out of the pbt beside the rites it governs, and reaches the
agent as its own system prompt — so this file does not restate it and cannot
fall out of step with it.

> I'll match that style for this one unless you want otherwise.
0: "Well, to be honest, when you say something coming from 'me' as a user."
1: "I want you to quote me verbatim unmodified."
2: "Text coming from me the user, should be double quoted, you the llm get no quotes."
