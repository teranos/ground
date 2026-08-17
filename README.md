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

Runs as a [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) across all events. Every event is attested with its full payload. Actions for command controls:

- **arg** — insert missing arguments after the matched command
- **omit** — strip unwanted flags from the command
- **omitLine** — drop a whole command segment
- **clamp** — raise a numeric flag value to a floor
- **strop** — validate the shape of an extracted flag value, deny on mismatch
- **substitute_for_read** — name the utilities that mean "I was trying to read a file"; ground reads it and hands the contents over instead of running the command

Rewrites (arg/omit/omitLine/clamp) are silent — the command runs corrected and Claude receives a message explaining why. Strop denies with a message computed from the extracted value. Unmatched commands pass through unchanged. Keyword controls on UserPromptSubmit inject context when the user mentions a topic.

Controls are defined in `controls/*.pbt` and compiled into the binary. The binary is the config. A repo declared with `project { path: "..." }` contributes its own `controls/*.pbt` the same way — the pbt governing a repo lives beside the code it governs.

Ground stops rather than degrades. Its attestation store is a hard dependency: a damaged SQLite database returns zero rows to every read, which is indistinguishable from a database that is merely empty, so continuing would report an all-clear it cannot have verified. On detecting corruption ground reports on every hook and denies none of them — it refuses to operate, never to let you work, since blocking your own tool calls would take away what you need to repair it.

## Why D

D with `-betterC`, compiled with LDC. 4.9MB binary. Controls are evaluated at compile time and baked in, which is where the size goes: the binary is the config, so there is no file to find, open or parse at hook time. Linked against libsqlite3 for attestation storage.

Latency is per event, not a single figure. Run `ground profile` to see it for your own install; the numbers below are one machine over 30 days.

```
event               samples   avg   med   p95   p99   max
PostToolUse            1494    85ms    50ms    90ms  1600ms  5304ms
Stop                    500    69ms    61ms   107ms   202ms   627ms
PreToolUse             1584     5ms     4ms    11ms    36ms   288ms
```

`PreToolUse` gates every command and is the one that has to be invisible. `PostToolUse` carries the tool result, so it grows with payload size. `ground profile <event>` breaks a single event down by project and by phase. The budgets ground holds itself to, and reports against when it breaches them, are in `source/stop.d`.

## [Countdown](COUNTDOWN.md)
   