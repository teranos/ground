# Live checks for ground code

Each check drives a `ground_code` over ACP on stdin and stdout, against the real gateway its
build's qntx block names, with a real model. They are not run by `make test`: they spend model
tokens and need the node. A PR that changes what ground code says to a client runs the one that
checks it, and its output is the PR's evidence.

Every program here is C11 and POSIX, built by the pinned shell's compiler under libacp's warnings,
and none reads JSON with a library: what a check prints is every line as it went.

    make build/acp_live build/echo_server build/elicit_server
    build/acp_live GROUND_CODE CWD SCRIPT

A fresh CWD per run keeps a `session/list` to the sessions that run opened.

## acp_live

A script line is one of:

| Line | Does |
|---|---|
| a JSON-RPC message | sent as it is, with `$CWD`, `$SID`, `$ASKED` and `$LIVE` replaced |
| `wait ID` | reads until the answer to request ID, a line starting `{"jsonrpc":"2.0","id":ID,` |
| `expect TEXT` | reads until a line holding TEXT |
| `sleep MS` | reads for MS milliseconds |
| `restart` | closes ground code's stdin, reads it to its end, and starts another |
| `cat FILE` | prints the file, each line after `= ` |
| `# TEXT` | printed as it is |

`$SID` is the sessionId of the latest `session/new` answer, `$ASKED` the id of the latest request
ground code made of the client as it stood on the line, and `$LIVE` the directory `acp_live` is in.

Printed: `> ` before each line sent, `< ` before each line ground code writes on stdout, `! `
before each it writes on stderr. stdout and stderr are two pipes, so a `!` line's place among
the `<` lines is not the order they were written in. A `wait` or `expect` that sees nothing for
five minutes, or ground code ending first, prints `# FAILED` and exits 1.

## The MCP servers a session is handed

| Server | Does |
|---|---|
| `echo_server` | at 2025-11-25, one tool, `echo`, answering `echoed` |
| `elicit_server` | tools `ask` and `link` that elicit: `ELICIT_PROTOCOL` legacy asks with a request of its own, modern answers `input_required`; each request and answer it reads goes to `ELICIT_LOG` |

## The checks

| Script | Checks | First run for |
|---|---|---|
| `init.acp` | initialize in both shapes, a version none fits, none named; authenticate refused; a v2-shaped client's elicitation | #179, #131 (part 7) |
| `delete.acp` | a session one process opened, deleted by another, and the refusals | #120 (part 2) |
| `modes.acp` | a session's modes offered, set by set_mode and by config option, kept across a resume | #121 (part 3), #162 |
| `dirs.acp` | a session's additionalDirectories kept and decoded, a relative one refused, replaced by a resume | #123 (part 4) |
| `effort.acp` | a session's effort set, refused when unknown, boolean or missing, kept across a resume | #124 (part 5) |
| `list.acp` | session/list's entries, filtered by cwd, and its refusals | #128 (part 6) |
| `blocks.acp` | a prompt's blocks: text to the model, the kinds it cannot read refused by type, no prompt refused | #135 (part 8) |
| `cancel.acp` | a turn cancelled while it runs, by request id, a `_meta`-only cancel that is none, and cancels with no turn | #137 (part 9) |
| `permission.acp` | session/request_permission in Manual: allowed, rejected, cancelled, and an option not offered | #138 (part 10) |
| `title.acp` | a session titled by its first prompt, kept across a resume, listed | #166 |
| `elicit-legacy.acp` | elicitation from a legacy server, form then url, and the url's completion | #167 |
| `elicit-modern.acp` | elicitation from a 2026-07-28 server, answered late | #167, #178 |
| `usage.acp` | usage_update's used and size each turn | #169 |
| `updated.acp` | session_info_update's updatedAt each turn, and session/list's | #176 |
| `cost.acp` | usage_update's cumulative cost, across a resume | #177 |
