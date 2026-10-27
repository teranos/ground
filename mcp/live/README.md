# Live checks for ground code

Each check drives a `ground_code` over ACP on stdin and stdout, against the real gateway its
build's qntx block names, with a real model. They are not run by `make test`: they spend model
tokens and need the node. A PR that changes what ground code says to a client runs the one that
checks it, and its output is the PR's evidence.

## acp_live

`acp_live` is C11 and POSIX, built by `make build/acp_live` with the pinned shell's compiler and
libacp's warnings. It reads no JSON: what it prints is every line as it went.

    build/acp_live GROUND_CODE CWD SCRIPT

A fresh CWD per run keeps a `session/list` to the sessions that run opened. A script line is one of:

| Line | Does |
|---|---|
| a JSON-RPC message | sent as it is, with `$CWD` and `$SID` replaced |
| `wait ID` | reads until the answer to request ID, a line starting `{"jsonrpc":"2.0","id":ID,` |
| `expect TEXT` | reads until a line holding TEXT |
| `sleep MS` | reads for MS milliseconds |
| `restart` | closes ground code's stdin, reads it to its end, and starts another |
| `# TEXT` | printed as it is |

Printed: `> ` before each line sent, `< ` before each line ground code writes on stdout, `! `
before each it writes on stderr. stdout and stderr are two pipes, so a `!` line's place among
the `<` lines is not the order they were written in. `$SID` is the sessionId of the latest
`session/new` or `session/resume` answer. A `wait` or `expect` that sees nothing for five
minutes, or ground code ending first, prints `# FAILED` and exits 1.

| Script | Checks | First run for |
|---|---|---|
| `init.acp` | initialize in both shapes, a version none fits, none named; authenticate refused | #179, #131 (part 7) |
| `delete.acp` | a session one process opened, deleted by another, and the refusals | #120 (part 2) |
| `modes.acp` | a session's modes offered, set by set_mode and by config option, kept across a resume | #121 (part 3), #162 |
| `dirs.acp` | a session's additionalDirectories kept and decoded, a relative one refused, replaced by a resume | #123 (part 4) |
| `effort.acp` | a session's effort set, refused when unknown, boolean or missing, kept across a resume | #124 (part 5) |
| `list.acp` | session/list's entries, filtered by cwd, and its refusals | #128 (part 6) |
| `blocks.acp` | a prompt's blocks: text to the model, the kinds it cannot read refused by type, no prompt refused | #135 (part 8) |
| `cancel.acp` | a turn cancelled while it runs, by request id, a `_meta`-only cancel that is none, and cancels with no turn | #137 (part 9) |

## The checks before acp_live

| Script | Checks | First run for |
|---|---|---|
| `acp_drive.py` | any session: one stdio MCP server, a list of prompts, every update shown | #171, #172, #173, #175 |
| `acp_title.py` | a session titled by its first prompt, kept across a resume, listed | #166 |
| `acp_elicit.py` | elicitation, legacy and 2026-07-28, optionally answered late | #167, #178 |
| `acp_usage.py` | usage_update's used and size each turn | #169 |
| `acp_updated.py` | session_info_update's updatedAt each turn, and session/list's | #176 |
| `acp_cost.py` | usage_update's cumulative cost, across a resume | #177 |

They take the `ground_code` to drive and a working directory first. The MCP servers they hand a
session are the ones beside them in `mcp/`.
