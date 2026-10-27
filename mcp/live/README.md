# Live checks for ground code

Each script drives a `ground_code` over ACP on stdin and stdout, against the real gateway its
build's qntx block names, with a real model. They are not run by `make test`: they spend model
tokens and need the node. A PR that changes what ground code says to a client runs the one that
checks it, and its output is the PR's evidence.

Every script takes the `ground_code` to drive and a working directory first.

| Script | Checks | First run for |
|---|---|---|
| `acp_drive.py` | any session: one stdio MCP server, a list of prompts, every update shown | #171, #172, #173, #175 |
| `acp_init.py` | initialize in both shapes, a version none fits, a v2-shaped client's elicitation | #179 |
| `acp_delete.py` | a session one process opened, deleted by another, and the refusals | #120 (part 2) |
| `acp_dirs.py` | a session's additionalDirectories kept and decoded, a relative one refused, replaced by a resume | #123 (part 4) |
| `acp_modes.py` | a session's modes offered, set by set_mode and by config option, kept across a resume | #121 (part 3), #162 |
| `acp_title.py` | a session titled by its first prompt, kept across a resume, listed | #166 |
| `acp_elicit.py` | elicitation, legacy and 2026-07-28, optionally answered late | #167, #178 |
| `acp_usage.py` | usage_update's used and size each turn | #169 |
| `acp_updated.py` | session_info_update's updatedAt each turn, and session/list's | #176 |
| `acp_cost.py` | usage_update's cumulative cost, across a resume | #177 |

The MCP servers they hand a session are the ones beside them in `mcp/`.
