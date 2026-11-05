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
starts it on the session's own, at the session's effort. A ritual's agent is
started on neither: its model is the models block's pick, and its effort is
that model's own setting, `modelSettings.<model>.effortLevel`, which the usage
windows move (source/effort.d). A subagent is started the same way.

    models {
      model: "opus"
    }

One pick, `resolveModel`, is made for both. A ritual's layers are the ritual,
its project and the top level. A subagent has no ritual: its layers are the
project its session stands in and the top level. Every rule is asked before
any plain model, from the same plan and window readings, and no models block
anywhere is the same default.

Ground rewrites every Agent call before it runs, whatever the call asked for:
its model is the pick, and an effort the call names is dropped, so the model's
own setting holds. The session that made the call is told. A fork runs on its
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
