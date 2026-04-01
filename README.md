# ground

Ground Control for Claude Code. CLAUDE.md is advisory — ground is the control.

## Problem

Claude Code ignores CLAUDE.md instructions. You tell it "use `make test`", it runs `go test` without build tags, tests fail, and it starts "fixing" code that was never broken. You tell it "don't use `sed`", it uses `sed` with GNU syntax on macOS. The list never ends.

The only enforcement that works is at the hook level — intercepting events before, during, and after they execute. Not a suggestion. A control.

## What happens

Claude tries to commit with `--no-verify`:
```
git commit --no-verify -m "fix tests"
```
Ground strips the flag and lets the command through:
```
git commit -m "fix tests"
```
Claude receives: *"Git hooks must not be bypassed, ever."*

Claude tries `go test ./...` in a project that needs build tags:
```
go test ./...
```
Ground inserts the missing arguments:
```
go test -tags "rustsqlite,qntxwasm" -short ./...
```
Claude receives: *"Build tags and -short are required for go test in QNTX."*

The user mentions "ground" in a prompt:
```
scope {
  event: "UserPromptSubmit"

  control {
    name: "ground-reminder"
    userprompt: "ground"
    msg: "Ground Control — a hook that fires on every hook event..."
  }
}
```
Claude receives the context before it starts responding.

Claude says "each conversation starts fresh":
```
scope {
  event: "Stop"

  control {
    name: "previous-conversations-accessible"
    stop: [
        "each conversation starts fresh",
        "each session starts fresh",
        "don't have access to previous conversation",
        "don't have access to previous session",
        "don't have access to conversation history",
        "dialogue isn't stored anywhere"
    ]
    msg: "Wrong. Previous conversations are accessible. JSONL transcripts are stored at ~/.claude/projects/."
  }
}
```
Claude corrects itself and checks the transcripts.

## Install

```
claude /plugin marketplace add teranos/ground
claude /plugin install ground@teranos-ground
```

On first session, ground detects the binary isn't installed and tells Claude how to set it up — prebuilt binaries are available from [GitHub Releases](https://github.com/teranos/ground/releases).

To build from source instead (requires [LDC](https://dlang.org/download.html) and libsqlite3):

```
git clone https://github.com/teranos/ground.git
cd ground
make install
```

Installs to `~/.local/bin/ground`. Override with `PREFIX=/usr/local make install`.

## How it works

Runs as a [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) across all events. Two actions for command controls:

- **arg** — insert missing arguments after the matched command
- **omit** — strip unwanted flags from the command

Amendments are silent — the command runs with the corrected arguments and Claude receives a message explaining why. Unmatched commands pass through unchanged. Keyword controls on UserPromptSubmit inject context when the user mentions a topic.

Controls are defined in `controls/*.pbt` and compiled into the binary. The binary is the config.

## Why D

D with `-betterC`, compiled with LDC. 244KB binary, ~12ms median latency. Controls are evaluated at compile time and baked in. Linked against libsqlite3 for attestation storage.

## [Countdown](COUNTDOWN.md)
