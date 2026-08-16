# INTERRUPT

The mic is taken from the agent and CI speaks, now, whether or not it is
looking.

"BY ANY MEANS"

> The constraint that this had to go through Claude Code's hook API was mine.
> It is not in a word you wrote.

"90d is like CI TAKING THE MIC AND SCREAMING INTO THE AGENTS FACE"

> CI is a party that can speak, not a status the agent looks up.

"HEY DUDE, SHITS FUCKED UP, OR FINE"

> Both outcomes, one treatment.

"it was always an abrupt thing that happen to an agent"

> It happens *to* it. Nothing the agent does causes it or delays it.

"the fucking mic is TAKEN"

> Taken. Not handed over, and not requested.

"INTERRUPTED"

> The word I kept softening into "delivered".

"as in, interrupt, as in disrupt, as in inevitable, as in , no way to stop
this, as in , this is really going to happen and it is going to happen now no
matter what"

> Rules out every queue, including the three I built.

"the fucking point is we get to see what happens AT THE END OF IT"

> The end of the run, not the end of the walk.

"AT THE END OF THE CI"

"WHILE IT S STILL GOING"

> The walk is still going. The run has ended. Both at once is the whole point.

"SO NOT AT END OF RITUAL"

> Batching to the end of a performance is the failure, not the fallback.

"BUT END OF THE CI ITSELF"

> The run concluding is the event. Nothing else is.

"agent gets to wake in the 15th second of the first sleep"

> The acceptance test. FLIP1 dispatches, SLEEP1 is 30s, long-coin takes about
> 15.

"coinflip GREEN, don't care, still abruptly notifies the agent"

> No filter, no tier, no urgency class.

"agent has no choice here"

> Not a message it drains when it next acts.

"and the parent also received the dispatch result, as something that can
disrupt and interrupt, and the human sees it as well"

> All three receivers, same treatment.

"and it doesn't matter if it passed or not, we care about the result, always,
unconditionally"

> The result is the event, not the verdict. So there is no branch on green
> versus red anywhere in this.

"nothing is more important than adhering to the ERROR principle, this feature
not being here is worse than P0 level of bad"

> It is the axiom's own clause — at the exact point of interaction as it
> happens — and until it exists that sentence is aspirational.

"there is a native way to interrupt an agent at will, whenever i want"

> There is. I said there was not, from having read one page.

"take the mic mid-sentence style"

> Anthropic's word for it is `aborted_streaming`.


## What it looks like

```
⏺ Bash(bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo A; sleep 3;
      done')
  ⎿  Interrupted · What should Claude do instead?
```

## The mechanism

<https://code.claude.com/docs/en/agent-sdk/python#example-using-interrupts>

```python
import asyncio
from claude_agent_sdk import ClaudeSDKClient, ClaudeAgentOptions, ResultMessage


async def interruptible_task():
    options = ClaudeAgentOptions(allowed_tools=["Bash"], permission_mode="acceptEdits")

    async with ClaudeSDKClient(options=options) as client:
        # Start a long-running task
        await client.query("Count from 1 to 100 slowly, using the bash sleep command")

        # Let it run for a bit
        await asyncio.sleep(2)

        # Interrupt the task
        await client.interrupt()
        print("Task interrupted!")

        # Drain the interrupted task's messages (including its ResultMessage)
        async for message in client.receive_response():
            if isinstance(message, ResultMessage):
                print(f"Interrupted task: terminal_reason={message.terminal_reason!r}")
                # terminal_reason is "aborted_streaming" or "aborted_tools"
                # for interrupted turns

        # Send a new command
        await client.query("Just say hello instead")

        # Now receive the new response
        async for message in client.receive_response():
            if isinstance(message, ResultMessage) and message.subtype == "success":
                print(f"New result: {message.result}")


asyncio.run(interruptible_task())
```

## Run and observed

**The wire is one line.**
`{"type":"control_request","request_id":"req_1_deadbeef","request":{"subtype":"interrupt"}}`
written to the CLI's stdin. Nothing else — no handshake before it, no pty, no keypress, no tmux.
Read from the SDK source, then sent by hand and answered.

**It lands mid-sentence.** Sent eight seconds into a 3000-word essay. The CLI answered
`control_response` `subtype: success` with `still_queued: []`, wrote `[Request interrupted by user]`
into the transcript as a user turn, and closed the turn with `terminal_reason:
"aborted_streaming"`, `subtype: "error_during_execution"`, `is_error: true`.

**The session survives it.** The process stayed alive and waiting for the next line until I killed
it. The mic is taken and handed back, not broken.

**The invocation.** `claude --output-format stream-json --verbose --input-format stream-json`. No
`--print` — the SDK doesn't pass one.

**The mic comes back.** Second run, same process: `aborted_streaming`, then a fresh `system: init`,
then a new instruction answered — `OAXACA`, `terminal_reason: "completed"`. Taken and handed back
inside one session, which is what makes it an interrupt rather than a kill.

**Ground's hooks run in it.** `SessionStart:startup` fired in the child and its
`hookSpecificOutput.additionalContext` was accepted, which is the channel 58 binds through.
`Stop` fires there too, proven separately under i1 — but the stream never says so, and reports
only `SessionStart`. A hook log read off the stream would be wrong.

## The direction

"so, it seems like --bg is no longer the way i want to build rituals anymore"

"the way to go is via c51dd8c"

"in all honestly this is a big direction change, but its decided"

"i say i describe it as a stream-json agent"

"we dont lose --bg agent, but what we do do is create another implementation alongside it"

"INTERRUPT happens to be the reason for wanting its existence, it's because I want the true
unwavering reading of the original 90d"

The driver forks the agent as its own child on pipes and speaks stream-json to it. The interrupt
is a property of holding that stdin, and `--bg` hands the session to the daemon and exits, so
there is no stdin to hold. That is the whole reason for a second implementation, and the reason it
is a second one rather than a migration: the `--bg` agent keeps the daemon's row, its peek panel
and `claude stop`, and gives up being addressable. Nothing else about the walk changes shape —
rites, verdicts, positions and the pbt are untouched by either.

Anthropic names the mode and not the agent. `is_streaming_mode` gates the control protocol
outright — "Control requests require streaming mode" — and its own gloss reads
`Whether using streaming (bidirectional) mode`. Bidirectional is the property; **stream-json
agent** is the name it goes under here.

## The protocol

`interrupt` is one subtype of one message type. The rest of the vocabulary, read from the same SDK
source, is what ground becomes a second implementation of.

Driver → agent, each one line of `{"type":"control_request","request_id":"req_<n>_<hex>","request":{…}}`:

| subtype | what it is | ground |
|---|---|---|
| `initialize` | first line of the session; carries `hooks`, `agents`, `skills` | hooks are already in settings, so this may stay empty |
| `interrupt` | take the mic | the whole of this document |
| `set_permission_mode` | change the mode mid-session | a rite could tighten or loosen |
| `set_model` | change the model mid-session | a rite could name the model it wants |
| `stop_task` | end one task | — |
| `get_context_usage` | breakdown of the context window | 72 asks this instead of inferring it from PreCompact |
| `mcp_status`, `mcp_reconnect`, `mcp_toggle` | MCP servers | — |
| `rewind_files` | undo file state | — |

A plain instruction is not a control request. It is
`{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null,"session_id":"default"}`
— the briefing, a rite's `msg`, or CI's words go down this line.

Agent → driver, and the ones marked must be answered or the agent stalls:

| subtype | what it is | ground |
|---|---|---|
| `can_use_tool` | **must answer** — permission, with `tool_name`, `input`, `tool_use_id`, `suggestions`, `blocked_path`, `decision_reason` | a95. Answered `{"behavior":"allow","updatedInput":…}` or `{"behavior":"deny","message":…,"interrupt":…}`. Note deny carries its own interrupt |
| `hook_callback` | **must answer** — a hook registered through `initialize` | not needed while hooks stay in settings |
| `mcp_message` | **must answer** — an in-process MCP server | — |

And plain output lines, no answer owed: `system` (`init`, `hook_started`, `hook_response`,
`thinking_tokens`), `assistant`, `user`, `result` (`terminal_reason`, `subtype`, `is_error`),
`rate_limit_event`, and task events `task_started` / `task_notification` / `task_updated`.

Every response the driver sends back is the same envelope:
`{"type":"control_response","response":{"subtype":"success","request_id":"<the one asked>","response":{…}}}`,
or `subtype: "error"` with an `error` string.

## Affected work

Audited against RITUAL.md and AGENT.md. Nothing here is superseded — the `--bg` agent keeps every
answer it has. These are the rows that need a second answer for the second implementation, and the
two that a stream-json agent gives up outright.

| | nr | thing | under a stream-json agent |
|---|---|---|---|
| given up | a80 | A performance is a row in agent view | A child on pipes is not a background session, so `claude agents` will not list it. The daemon's registry is the `--bg` agent's advantage and this one does without it. What it has instead is not a registry: the child's own stream is the view, live, and answers without being asked |
| given up | a75 | A ritual is carried by an Agent, not a detached process | The peek panel this row was written for — Space to peek, Enter to attach — addresses a background session. A child is not detached and is owned harder, but nothing renders it |
| second answer | a96 | Ground can see an Agent that is not working | For `--bg` the answer is `claude agents --json` and its `status`, `waitingFor`, `state`, which nothing reads yet. For a pipe there is nothing to poll: `can_use_tool`, `hook_started`, `assistant` and `result` arrive as they happen, and a stall is an outstanding `request_id` rather than an absence of events |
| second answer | 96 | A performance that ends ends its agent | `claude stop <id>` addresses the daemon and is right for `--bg`. A child is ended by the parent that forked it, where `agent_pid` stops being ornamental — a real pid of a real child rather than a number `pkill` never matched. i7 |
| second answer | 46 | A rite's verdict reaches the agent, unasked | Burned already. Its mechanism — `writeNote` drained as `asyncRewake` exit 2 — remains the only way to reach a `--bg` agent, and is exactly the queue this document exists to get out of. On a pipe a verdict is written into stdin |
| second answer | 48 | `claimSession` is not session-scoped | Inherited by anything riding the watcher, which stays the `--bg` agent's courier and the parent's. A stream-json agent does not ride it, so it does not inherit it |
| second answer | 25 | Abort a ritual | `continue: false` at the next Stop is a queue — abort waits for the agent to stop talking. On a pipe an abort is `interrupt` and then nothing. i8 |
| second answer | a95 | An Agent inside a performance is never asked for permission | `consent.d` answers PreToolUse for `--bg`, from inside a session it does not own. On a pipe permission is a `can_use_tool` request addressed to the driver, and unanswered it stalls. i6 |
| holds for both | 45 | The ritual keeps moving while the agent works | The driver already existed for this. For one flavour it drives beside the agent; for the other it drives the agent |
| holds for both | 79 | One thing advances a position | Four callers of `advance` with nothing coordinating them, and unchanged by any of this. The driver holding the process does not by itself make it the only walker |
| holds for both | 82c | The agent's first two sentences are seen by both human and host | Stop fires in a stream-json child, verified, so the path that carries this is intact for both. The pipe adds a second one the `--bg` agent has no equivalent of: the words arrive as `assistant` messages while they stream, and the driver is holding them. i9 |
| holds for both | 58 | `SessionStart` | Verified firing in a stream-json child with `additionalContext` accepted, so the binding is unchanged. The pid it writes finally means something — the driver's own child |
| holds for both | 90c | A run's result reaches the parent when that run concludes | The parent's half is identical either way. The agent's half is a note it drains for `--bg` and an interrupt on a pipe. i4 |
| untouched | 37 | `SubagentStart` | Did not fire for `claude -w` and does not fire for a child on pipes. A performance reaches it under neither |

One line elsewhere goes stale: 84 notes that `ritual-agent-last` comes from SubagentStop and
"never fires for a `--bg` agent", which is now half a sentence — it fires for neither. AGENT.md
carries both definitions as of this commit.

## Backlog

| done? | nr | thing | quotes | notes |
|---|---|---|---|---|
| ✓ | i1 | Whether `Stop` fires in a stream-json child | — | Mine, and in front of everything else, because the walk moves when `stop.d` calls `advance` at the agent's Stop. It fires. Answered 2026-08-16 by adding a second Stop hook through `--settings` that leaves a file, so the answer did not rest on what the stream chooses to report — and it does not report this: `SessionStart` arrives as `hook_started` and `hook_response`, and the Stop hook that demonstrably ran produced no stream event whatever. The stream is not a hook log, and reading one from it would have been a false negative on the first try |
| ✓ | i2 | Whether `-w <tree>` composes with `--input-format stream-json` | — | Mine, since a performance has its own worktree and branch and that flag is what puts the agent in it. It composes. `claude -w probe-i2` against a scratch repo answered `init` with `cwd` already the tree, ground's own WorktreeCreate fired and placed it as the sibling `<repo>-probe-i2`, and the turn completed. One thing to look at rather than assert: the reply came back as ground's own announcement — `░░▒▓▏ground made a worktree at …` — followed by the word asked for, so ground's line was in the agent's own text, and that performance-level gutter is the one 84 says has never rendered from a real performance |
| | i3 | The driver owns the agent as a child on pipes | "the way to go is via c51dd8c" / "in all honestly this is a big direction change, but its decided" | `spawnScript` stops writing `claude -w <tree> --bg <prompt>` and the driver forks `claude --output-format stream-json --verbose --input-format stream-json`, keeping both ends. The prompt stops being argv and becomes a `user` line, which also ends the overflow refusal that a too-large briefing hits today |
| | i4 | A run's outcome takes the mic from the agent | "agent gets to wake in the 15th scond of the first sleep" / "coinflip GREEN, dont care, still abruptly notifies the agent" / "agent has no choice here" / "and it doesnt matter if it passed or not, we care about the result, always, unconditionally" | The row this document is named for. `interrupt`, then the outcome as a `user` line. No branch on green versus red anywhere in it. The acceptance test is coinflip: FLIP1 dispatches, SLEEP1 is 30s, the run takes about 15, and the agent is interrupted at 15 rather than told at 30 |
| | i5 | The parent and the human get the same result at the same time | "and the parent also received the dispatch resutl, as something that can disrupt and interrupt, and the human sees it as well" | Three receivers, one treatment. The parent is not on the pipe — it is the session ground is a hook inside — so this half stays on the channels 82a addresses and 83 draws |
| | i6 | The driver answers `can_use_tool` | "if a deny needs to be given, it should not have to come from the user, that needs to get into the stuck session" | a95 on the pipe. Unanswered, the agent stalls with a `request_id` outstanding — the same sixteen blocked sessions, except addressed to ground rather than to nobody. `deny` carries its own `interrupt` field, so a refusal can take the mic in the same breath |
| | i7 | An ending ends the child | "HOW IS THERE NOT A REAL NATIVE TRUE WAY TO KILL THE BG SESSION" / "nothing should be running in terms of rituals or their agents" | 96 answered this with `claude stop <id>`, which addresses the daemon. A child is ended by its parent, and `agent_pid` becomes the pid of a real child rather than a number `pkill` never matched |
| | i8 | Abort is an interrupt | "it ends when it ends, not because i ran ritual stop" / "ground should take responsibility" | 25 ends the agent through `continue: false` at its next Stop, so an abort waits for the agent to stop talking. An abort is `interrupt` and then nothing |
| | i10 | The build is pinned, and a performance says which one it ran on | "pin pathToClaudeCodeExecutable against a known build ?" / "ALWAYS pin exact versions" | Ground drives a wire protocol now, so the binary is a dependency and `claude` on PATH is not one — it is a symlink the updater moves. Measured 2026-08-16: `~/.local/bin/claude` points at `~/.local/share/claude/versions/2.1.233` and that link was moved the previous evening, mid-branch, with five builds retained. Pin the versioned path, once for ground rather than per pbt. A pinned build that is gone halts with a `GroundError` naming it — falling back to whatever PATH answers is the axiom's own failure, an error swallowed into a spawn that looks fine on a build nobody chose. The resolved version goes on the performance row, because today a walk cannot say what produced it. The SDK is the weaker model here and is not the one to copy: its minimum is `2.0.0` and `_check_claude_version` warns rather than refuses |
| | i9 | The agent's words are read off the stream | "AGENTLLM STOP OUTPUT FIRST TWO SENTENCES OF LAST MESSAGE NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM" | 82c takes `last_assistant_message` from Stop, which is one hook call site whose deletion silently erased the channel once already. On the pipe the words arrive as `assistant` messages while they stream, and the driver is holding them |
