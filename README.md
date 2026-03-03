# graunde

Ground Control for Claude Code. CLAUDE.md is advisory — graunde is the control.

## Problem

Claude Code ignores CLAUDE.md instructions. You tell it "use `make test`", it runs `go test` without build tags, tests fail, and it starts "fixing" code that was never broken. You tell it "don't use `sed`", it uses `sed` with GNU syntax on macOS. The list never ends.

The only enforcement that works is at the hook level — intercepting events before, during, and after they execute. Not a suggestion. A control.

## How it works

Runs as a Claude Code hook across all events. Reads JSON from stdin, branches on `hook_event_name`. Every event is checked against controls and attested — the complete trail enables the branch story. Two actions for command controls:

- **arg** — add missing arguments after the matched command
- **omit** — strip unwanted flags from the command

Both silently amend and allow. Unmatched commands pass through (exit 0, no output). Every amendment includes an `additionalContext` message so Claude learns why the command was changed.

Controls are D source, compiled with `-betterC`. No runtime, no GC, no dependencies. The binary is the config.

## Language

D with `-betterC`. Compiled with LDC. Chosen for:
- No runtime, no GC — 8.7KB stripped binary, ~17ms latency
- CTFE — controls evaluated at compile time, baked into the binary
- `unittest` as a language keyword — tests live next to code
- C interop for stdio without overhead

## Controls

Controls are defined in `source/controls.d`. A control has:
- `name` — identifier slug
- `cmd` — command prefix to match
- `arg` — arguments to insert after the matched command
- `omit` — flag to strip from the command
- `msg` — context message sent to Claude via `additionalContext`

Controls are grouped by scope. Each scope has a `path` (where it fires) and a `decision` (`"allow"` or `"ask"`). Multiple scopes can match the same command — amendments and decisions compose.

```d
static immutable universal = [
    control("no-skip-hooks", cmd("git"), omit("--no-verify"),
        msg("Git hooks must not be bypassed, ever..")),
];

static immutable checkpoints = [
    control("commit-checkpoint", cmd("git commit"),
        msg("Commit requires manual approval")),
];

static immutable qntx = [
    control("go-test-args", cmd("go test"), arg(`-tags "rustsqlite,qntxwasm" -short`),
        msg("Build tags and -short are required for go test in QNTX")),
];

static immutable allScopes = [
    Scope("", "allow", universal),
    Scope("", "ask", checkpoints),
    Scope("/QNTX", "allow", qntx),
];
```

Commands are split on `|`, `;`, `&&` — each segment is checked independently.

## Hook protocol

JSON on stdin, JSON on stdout. Every event includes `hook_event_name`, `cwd`, `session_id`. Tool events add `tool_name`, `tool_input`, `tool_use_id`. No match: exit 0, no output. See [reference.md](reference.md) for full payload schemas, exit codes, and response fields.

## Installation

```
make install
```

Builds a release binary and copies it to `~/.local/bin/graunde`. Override with `PREFIX=/usr/local make install`.

## Hook registration

In `~/.claude/settings.json`, register graunde for all hook events:
```json
"hooks": {
  "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "graunde" }] }],
  "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "graunde" }] }],
  "PreCompact": [{ "hooks": [{ "type": "command", "command": "graunde" }] }],
  "Stop": [{ "hooks": [{ "type": "command", "command": "graunde" }] }],
  "SessionStart": [{ "hooks": [{ "type": "command", "command": "graunde" }] }]
}
```

## [Countdown](COUNTDOWN.md)
