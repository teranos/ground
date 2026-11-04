# SUBAGENT

A subagent is a Task-tool sidechain: it runs inside its caller's session and
shares the transcript. `SubagentStart` and `SubagentStop` are the two hook
events it fires.

Ground has no handler for either. Both are attested.

Nothing here is defined.

## The model a subagent runs on

"Subagents Alwys Opus, never Fable, Fable is for what is worth human attention span"

"and agents always on medium effort please"

A session starts a subagent with the Agent tool. A call that names no model
starts it on the session's own, at the session's effort. A models block names
what a subagent runs on instead:

    models {
      subagent: "opus"
      subagent_effort: "medium"
    }

Ground rewrites every Agent call to those two before it runs, whatever the
call asked for. A fork runs on its session's model whatever it is told, so a
fork is refused. A call ground cannot read is refused, not let through.

| | nr |
|---|---|
| | s37 |
| | s38 |
| | s77 |
| | s78 |
