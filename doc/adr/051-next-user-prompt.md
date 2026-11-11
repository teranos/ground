# Background reminders at the next user prompt

A Stop control can select `handler_params { delivery: "next_user_prompt" }`.
Its message is queued for that session without blocking Stop or waking the agent.
The next nonempty UserPromptSubmit includes the message in additionalContext and
records the existing delivery receipt. The user's prompt is not rewritten.

The queue remains Ground's attestation queue. Background watchers and their
backlog counter exclude messages addressed to this route. A reminder is queued
once per control per session; compaction does not replay an already delivered
background reminder. Existing controls retain their immediate Stop behavior.
