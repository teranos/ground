---
name: ground-commands
description: Every ground subcommand with a working example. Written by press from the modules that implement them.
---

```sh
# run by Claude Code on every hook event, the event's JSON on stdin:
ground < event.json

# search past hook events by wildcard pattern
# (see: ground events)
ground shovel PostToolUse "*pr create*"
# or dump a session's transcript:
ground shovel session ses90l3m

# post the pbt's attestations to their backends (make install does):
ground attest

# timing table:
ground profile
# one event, its phases and its worst runs:
ground profile PreToolUse

# the courier, with "timeout": 86400 on its hook entry
ground sky $PWD

# perform a ritual, by its name when that names one:
ground ritual grove
# or by project and ritual when it does not:
ground ritual q.sbvh.nl boxsurvival

# end a live performance, by its ritual or by the handle on the status line:
ground abort grove

# the driver ground ritual forks, one per performance, by the performance id:
ground drive ground-coinflip-1786812152

# run by the script that starts a ritual's agent, what `claude --bg` printed on stdin:
ground bind ground-coinflip-1786812152 < started.txt

# every hook event ground answers to:
ground events

# set a .pbt in the one layout, or the pbt fixtures in a .d:
ground fmt controls/controls.pbt
ground fmt source/proto_test.d

# the author's tool, in the ground checkout: every case editable in a browser
ground author

# how much of each rate limit is used, and how the week got there:
ground usage

# what ground covers of each pinned agent's hook contract, per event and version,
# and what ground code covers of the pinned ACP schema, per method:
ground parity
# one event's keys per version, covered and missing:
ground parity PostToolUse
# one ACP method's, read and written by ground code:
ground parity session/prompt

# what each build of ground cost to compile, as the node holds it:
ground ctfe
# the same rows as the book draws them:
ground ctfe tex

# an ACP client runs it and speaks JSON-RPC on its stdin and stdout:
ground code

# list tools from a stdio MCP server, in-process through libmcp:
ground mcp tools/list '{}' -- /path/to/server arg
# call a tool (no shell is used to start the server):
ground mcp tools/call '{"name":"echo","arguments":{"text":"hello"}}' -- /path/to/server

# strip the bulk out of the db (make install does):
ground decay

# what a hooks.json entry has agy run, the event's JSON on stdin:
ground hook agy PreToolUse
```
