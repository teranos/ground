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

## Countdown

### Ten — core engine ✓
Stdin JSON parsing, control matching, arg amendment, pipe splitting, unit tests. One control (`go-test-args`) end to end.

### Nine — betterC ✓
Drop the D runtime. No GC, no `std.json`, no exceptions. Hand-rolled JSON parsing. 8.7KB binary, ~17ms latency.

### Eight — omit + additionalContext ✓
Strip unwanted flags from commands. `omit("--no-verify")` removes the flag, lets the command through. `additionalContext` teaches Claude why commands were amended.

### Seven — make install + versioning ✓
Makefile with `build`, `test`, `install`. Version baked in from `git describe` at compile time. TTY detection prints version when run interactively.

### Six — the Ïúíþ incident ✓
Live testing in QNTX revealed two bugs. First: `cmd("go test")` used substring matching, so `git commit -m "run go test before merging"` triggered the go-test-args control — corrupting a heredoc commit into the Ïúíþ artifact (`60b8829`). Fix: `commandMatch` does prefix-only matching — the command must start with the `cmd` string, followed by a space or end of segment. Second: JSON escape sequences (`\n`, `\t`, `\r`) in `extractCommand` were passed through as literal characters instead of being unescaped, breaking heredoc newlines in amended commands. Fix: proper escape handling in both `extractCommand` (unescape) and `writeJsonString` (re-escape).

### Five — scoped controls ✓
Controls grouped by scope. Each scope has a path (where it fires) and a decision (`"allow"` or `"ask"`). Universal controls fire everywhere, project-specific controls only when `cwd` matches. Scopes compose — for a given command, all matching scopes contribute: the first amendment wins, the most restrictive decision wins. `git commit --no-verify` gets the flag stripped (universal/allow) AND the permission prompt (checkpoint/ask). Msg-only controls match without amending — just decision + context. Extracts `cwd` from the hook payload.

### Four — commencing countdown
Git workflow rituals and attestation-backed state. Graunde evolves from stateless gate to stateful ritual tracker, writing and reading QNTX attestations via linked libsqlite3. Actor: `graunde`. Source: `graunde v{VERSION}`. No standalone db — attestations live in QNTX's node db. When QNTX is online, reactive attestations can appear in real-time, injecting awareness into a running Claude session through the existing control protocol.

**Phase 1 — ritual checkpoints. ✓** Msg-only controls with `"ask"` decision for each git lifecycle moment. Branch creation: check main for unpushed commits, commit intent (documentation first), push, open draft PR. Push: pull first, resolve conflicts. Tag: check latest tag, follow semver. PR finalization: tests, review, issues, rebase, reassess.

**Phase 2 — libsqlite3 link. ✓** Linked against libsqlite3 via C interop. Attestations written to QNTX node db on every control match. Subjects: branch name. Predicates: control name. Actor: `graunde`. Source: `graunde v{VERSION}`.

**Phase 3 — branch story.** Depends on Count Three. On control match, query all attestations for the branch and include the story in `additionalContext`. The story surfaces what has and hasn't happened — "Rust files edited but clippy hasn't run", "tests passed but no push since." Scoped: each project cares about different observations.

**Phase 4 — QNTX conduit.** Deferred to #2 (`e27dd9e`). CI attestations into graunde's read path.

### Three — engines on
Register graunde for all hook events. Branch on `hook_event_name` in main.d. PreToolUse keeps existing control logic and attests every tool call. PostToolUse, PreCompact, Stop, SessionStart attested as lifecycle markers — control stubs present but no matching logic yet. The complete attestation trail — commands, file paths, compactions, session boundaries — enables Count Four Phase 3.

### Two — check ignition

### One — and may God's love
The binary is the config. Users define controls in D source and compile their own graunde. Self-recompilation: hash controls source at compile time via CTFE, compare at runtime, rebuild on mismatch. Claude edits `controls.d`, next hook invocation detects staleness, rebuilds, new control is live — no manual step. Tag staleness: compare baked-in `git describe` against upstream. Figure out fork ergonomics — how do users customize and stay upstream-compatible.

### Liftoff — be with you
Open source readiness. README, CONTRIBUTING, LICENSE review, GitHub releases, install-from-source instructions.
