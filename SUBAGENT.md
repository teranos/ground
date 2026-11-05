# SUBAGENT

A subagent is a Task-tool sidechain: it runs inside its caller's session and
shares the transcript. `SubagentStart` and `SubagentStop` are the two hook
events it fires.

Ground has no handler for either. Both are attested.

Nothing here is defined.

## The model a subagent runs on

"Subagents Alwys Opus, never Fable, Fable is for what is worth human attention span"

"and agents always on medium effort please"

"the same rules for ritual agents should apply to subagents, they should cohere"

A session starts a subagent with the Agent tool. A call that names no model
starts it on the session's own, at the session's effort. The models block
picks what a subagent runs on instead, as it picks what a ritual's agent runs
on:

    models {
      model: "opus"
      effort: "medium"
    }

One pick, `resolveModel`, is made for both. A ritual's layers are the ritual,
its project and the top level. A subagent has no ritual: its layers are the
project its session stands in and the top level. Every rule is asked before
any plain model, from the same plan and window readings, and no models block
anywhere is the same default.

`effort:` is the nearest layer's that names one. A ritual's agent is started
with it as `--effort`; an Agent call is given it as `effort`.

Ground rewrites every Agent call to the two before it runs, whatever the call
asked for, and says so to the session that made it. A fork runs on its
session's model whatever it is told, so a fork is refused. A call ground
cannot read is refused, not let through.

A message to a subagent resumes it on the model it was started on. One whose
call named no model was started on its session's own, and the session's note
of it beside the transcript (`subagents/agent-<id>.meta.json`) holds no
`model`. A SendMessage to that one is refused: a new subagent is started
instead, on what the models block picks.

| | nr |
|---|---|
| | s37 |
| | s38 |
| | s77 |
| | s78 |
