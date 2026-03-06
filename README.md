# graunde

Ground Control for Claude Code. CLAUDE.md is advisory — graunde is the control.

## Problem

Claude Code ignores CLAUDE.md instructions. You tell it "use `make test`", it runs `go test` without build tags, tests fail, and it starts "fixing" code that was never broken. You tell it "don't use `sed`", it uses `sed` with GNU syntax on macOS. The list never ends.

The only enforcement that works is at the hook level — intercepting events before, during, and after they execute. Not a suggestion. A control.

## What happens

Claude tries to commit with `--no-verify`:
```
git commit --no-verify -m "fix tests"
```
Graunde strips the flag and lets the command through:
```
git commit -m "fix tests"
```
Claude receives: *"Git hooks must not be bypassed, ever."*

Claude tries `go test ./...` in a project that needs build tags:
```
go test ./...
```
Graunde inserts the missing arguments:
```
go test -tags "rustsqlite,qntxwasm" -short ./...
```
Claude receives: *"Build tags and -short are required for go test in QNTX."*

## How it works

Runs as a [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) across all events. Two actions for command controls:

- **arg** — insert missing arguments after the matched command
- **omit** — strip unwanted flags from the command

Amendments are silent — the command runs with the corrected arguments and Claude receives a message explaining why. Unmatched commands pass through unchanged.

Controls are defined in D source and compiled into the binary. No config files — the binary is the config.

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

File-path controls match on the `file_path` field of non-Bash tools (Edit, Write, Read). Multiple file-path controls can match the same file — messages compose.

```d
static immutable qntxFiles = [
    control("web-docs-reminder", filepath("/web/"),
        msg("Read web/CLAUDE.md before editing frontend files.")),
    control("web-ts-banned", filepath("/web/ts/"),
        msg("BANNED in frontend: alert(), confirm(), prompt(), toast().")),
];

static immutable fileScopes = [
    Scope("/QNTX", "allow", qntxFiles),
];
```

## Installation

```
make install
```

Builds a release binary and copies it to `~/.local/bin/graunde`. Override with `PREFIX=/usr/local make install`.

## Hook registration

Add the `hooks` key to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "graunde" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "graunde" }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "graunde" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "graunde" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "graunde" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "graunde" }] }]
  }
}
```

## Why D

D with `-betterC`, compiled with LDC. 72KB binary, ~17ms latency. Controls are evaluated at compile time and baked in. Linked against libsqlite3 for attestation storage.

## [Countdown](COUNTDOWN.md)
