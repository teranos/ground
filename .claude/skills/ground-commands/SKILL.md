---
name: ground-commands
description: Every ground subcommand with a working example. Written by press from the modules that implement them.
---

```sh
# search past hook events by wildcard pattern
# (see: ground events)
ground shovel PostToolUse "*pr create*"
# or dump a session's transcript:
ground shovel session ses90l3m

# post the pbt's attestations to their backends (make install does):
ground attest

# 「[Fable 5.2] the session this ground runs in takes a name at its node, by its own key;」
# 「[Fable 5.2] a name another agent holds is refused, and so is what the node holds to be no name:」
「[Fable 5.2] ground name Alder」

# 「[Fable 5.2] the Authorization line for one request to a node, signed by ~/.qntx/key,」
# 「[Fable 5.2] for curl -H "$(ground sign <url>)" <url>:」
「[Fable 5.2] ground sign https://api.q.sbvh.nl/n/l/api/plugins」

# 「[Fable 5.2] say something to the session that holds a name, as this session, by its own key:」
「[Fable 5.2] ground say Slate "the build on k is red"」

# 「[Fable 5.2] whether what was said was received, by the Task the saying answered with:」
「[Fable 5.2] ground heard Slate 01a1d0c3-0922-759f-a495-a1e92e3a6851」

# 「[Fable 5.2] say by hand that this session received what a Task said to its name; sky」
# 「[Fable 5.2] says so itself as it hands the words over:」
「[Fable 5.2] ground received 01a1d0c3-0922-759f-a495-a1e92e3a6851」

# 「[Fable 5.2] where a rule in Claude Code's settings JSON says other than ground says:」
「[Fable 5.2] ground disagreements」

# 「[Fable 5.2] take those rules out of the JSON, so only ground's stand:」
「[Fable 5.2] ground agree」

# timing table:
ground profile
# one event, its phases and its worst runs:
ground profile PreToolUse

# perform a ritual, by its name when that names one:
ground ritual grove
# or by project and ritual when it does not:
ground ritual q.sbvh.nl boxsurvival

# end a live performance, by its ritual or by the handle on the status line:
ground abort grove

# run by the script that starts a ritual's agent, what `claude --bg` printed on stdin:
ground bind ground-coinflip-1786812152 < started.txt

# every hook event ground answers to:
ground events

# set a .pbt in the one layout, or the pbt fixtures in a .d:
ground fmt controls/controls.pbt
ground fmt source/proto_test.d

# how much of each rate limit is used, and how the week got there:
ground usage

# what each build of ground cost to compile, as the node holds it:
ground ctfe
# the same rows as the book draws them:
ground ctfe tex

# list tools from a stdio MCP server, in-process through libmcp:
ground mcp tools/list '{}' -- /path/to/server arg
# call a tool (no shell is used to start the server):
ground mcp tools/call '{"name":"echo","arguments":{"text":"hello"}}' -- /path/to/server

# a text with fixtures in place of what names a person, what was found on stderr:
ground scrub < text

# strip the bulk out of the db (make install does):
ground decay

# what a hooks.json entry has agy run, the event's JSON on stdin:
ground_hook agy PreToolUse

# an ACP client runs it and speaks JSON-RPC on its stdin and stdout:
ground_code
# sign in to the qntx block's node: approve the link it prints with your passkey:
ground_code login

# run by Claude Code and codex on every hook event, the event's JSON on stdin:
ground_hook < event.json

# what ground covers of each pinned agent's hook contract, per event and version,
# and what ground code and libacp's client side cover of the pinned ACP schema, per method:
ground_parity
# one event's keys per version, covered and missing:
ground_parity PostToolUse
# one ACP method's, read and written by ground code, and by libacp's client side:
ground_parity session/prompt

# the driver a ritual forks, one per performance, by the performance id:
ground_drive ground-coinflip-1786812152

# the courier, with "timeout": 86400 on its hook entry
ground_sky $PWD
```
