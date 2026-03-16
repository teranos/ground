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

The user mentions "ADR" in a prompt:
```d
control("adr-reminder", userprompt("ADR"),
    msg("ADRs are in docs/adr/ — check existing decisions before proposing new ones.")),
```
Claude receives: *"ADRs are in docs/adr/ — check existing decisions before proposing new ones."*

## Install

```
claude plugin install /path/to/graunde/plugin
```

On first session, graunde detects the binary isn't installed and tells Claude how to set it up — prebuilt binaries are available from [GitHub Releases](https://github.com/teranos/graunde/releases).

To build from source instead (requires [LDC](https://dlang.org/download.html) and libsqlite3):

```
git clone https://github.com/teranos/graunde.git
cd graunde
make install
```

Installs to `~/.local/bin/graunde`. Override with `PREFIX=/usr/local make install`.

## How it works

Runs as a [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) across all events. Two actions for command controls:

- **arg** — insert missing arguments after the matched command
- **omit** — strip unwanted flags from the command

Amendments are silent — the command runs with the corrected arguments and Claude receives a message explaining why. Unmatched commands pass through unchanged. Keyword controls on UserPromptSubmit inject context when the user mentions a topic.

Controls are defined in `controls/controls.d` and compiled into the binary. The binary is the config.

## Why D

D with `-betterC`, compiled with LDC. 244KB binary, ~12ms median latency. Controls are evaluated at compile time and baked in. Linked against libsqlite3 for attestation storage.

## [Countdown](COUNTDOWN.md)
