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
