# graunde

Ground Control for Claude Code. CLAUDE.md is advisory — graunde is the gate.

## Problem

Claude Code ignores CLAUDE.md instructions. You tell it "use `make test`", it runs `go test` without build tags, tests fail, and it starts "fixing" code that was never broken. You tell it "don't use `sed`", it uses `sed` with GNU syntax on macOS. The list never ends.

The only enforcement that works is at the tool level — a PreToolUse hook that intercepts commands before they execute. Not a suggestion. A gate.

## How it works

Runs as a Claude Code `PreToolUse` hook on `Bash`. Reads JSON from stdin, extracts the command, checks it against controls compiled into the binary. Two actions:

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
- `cmd` — command prefix to match (must be at start of segment, followed by space or end)
- `arg` — arguments to insert after the matched command, OR
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
    control("push-checkpoint", cmd("git push"),
        msg("Pull first and resolve conflicts before pushing")),
    control("tag-checkpoint", cmd("git tag"),
        msg("Check the latest tag first and ensure the new version follows semver")),
    control("pr-checkpoint", cmd("gh pr create"),
        msg("PR creation requires manual approval")),
    control("branch-checkpoint", cmd("git checkout -b"),
        msg("Check main for unpushed commits and push them first. After creating the branch, push it and open a draft PR with a minimal description.")),
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

**Input** (JSON on stdin):
```json
{
  "tool_input": {
    "command": "go test ./..."
  }
}
```

**Output** (amendment):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": {
      "command": "go test -tags \"rustsqlite,qntxwasm\" -short ./..."
    },
    "additionalContext": "Build tags and -short are required for go test in QNTX"
  }
}
```

**Output** (no match): exit 0, no output.

## Installation

```
make install
```

Builds a release binary and copies it to `~/.local/bin/graunde`. Override with `PREFIX=/usr/local make install`.

## Hook registration

In `~/.claude/settings.json`:
```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "graunde"
        }
      ]
    }
  ]
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

### Four — commencing countdown, engines on
Git workflow rituals and attestation-backed state. Graunde evolves from stateless gate to stateful ritual tracker, writing and reading QNTX attestations via linked libsqlite3. Actor: `graunde`. Source: `graunde v{VERSION}`. No standalone db — attestations live in QNTX's node db. When QNTX is online, reactive attestations can appear in real-time, injecting awareness into a running Claude session through the existing control protocol.

**Phase 1 — ritual checkpoints. ✓** Msg-only controls with `"ask"` decision for each git lifecycle moment. Branch creation: check main for unpushed commits, commit intent (documentation first), push, open draft PR. Push: pull first, resolve conflicts. Tag: check latest tag, follow semver. PR finalization: tests, review, issues, rebase, reassess.

**Phase 2 — libsqlite3 link. ✓** Linked against libsqlite3 via C interop. Attestations written to QNTX node db on every control match. Subjects: branch name. Predicates: control name. Actor: `graunde`. Source: `graunde v{VERSION}`.

**Phase 3 — ritual diff.** Define expected ritual steps per workflow. On merge-gate controls (`gh pr merge`), query all attestations for the branch, diff against expected steps, nudge Claude about gaps. The ritual isn't a hardcoded sequence — it's emergent from what happened vs what should have.

**Phase 4 — QNTX conduit.** Deferred to #2 (`e27dd9e`). CI attestations into graunde's read path.

### Three
Register graunde for all tools, not just Bash. Currently graunde only sees shell commands — file edits, reads, and other tool operations are invisible. Attestation coverage is incomplete. Requires handling `tool_name` and `hook_event_name` in the payload to decide what to observe and what to gate. Track context compactions — when Claude's working memory is compressed, an attestation should mark the boundary so post-compaction sessions know what was lost.

### Two — check ignition

### One — and may God's love

### Liftoff — be with you
