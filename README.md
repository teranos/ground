# ground

Ground Control for Agentic AI.

## Problem

You tell an agent "use `make test`", it runs `go test` without build tags, tests fail, and it starts "fixing" code that was never broken. You tell it "don't use `sed`", it uses `sed` with GNU syntax on macOS. The list never ends.

## What happens

Agent tries to commit with `--no-verify`:
```
git commit --no-verify -m "fix tests"
```
Ground strips the flag and lets the command through:
```
git commit -m "fix tests"
```
Agent receives: *"Git hooks must not be bypassed, ever."*

Agent tries `go test ./...` in a project that needs build tags:
```
go test ./...
```
Agent inserts the missing arguments:
```
go test -tags "rustsqlite,myapiwasm" -short ./...
```
Agent receives: *"Build tags and -short are required for go test in myapi."*

The user mentions "ground" in a prompt:
```
scope {
  event: "UserPromptSubmit"

  control {
    name: "ground-reminder"
    userprompt: "ground"
    msg: "ground_hook fires on every hook event..."
  }
}
```
Agent receives the context before it starts responding.

Agent says "each conversation starts fresh":
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
Agent corrects itself and checks the transcripts.

## Install as a plugin for Claude Code. 

```
claude /plugin marketplace add teranos/ground
claude /plugin install ground@teranos-ground
```

On first session, ground detects the binary isn't installed and tells Claude how to set it up — prebuilt binaries are available from [GitHub Releases](https://github.com/teranos/ground/releases).

To build from source instead (requires [Nix](https://nixos.org/download/); `flake.lock` pins LDC, dub, libsqlite3, libcurl and libgit2):

```
git clone https://github.com/teranos/ground.git
cd ground
make install
```

Installs `ground`, `ground_hook`, `ground_code`, `ground_sky` and `ground_drive` to `~/.local/bin`. Override with `PREFIX=/usr/local make install`. `ground_hook` answers the hook events, `ground_sky` is the courier the hooks spawn, `ground_drive` keeps a ritual's performance moving, `ground_code` is the agent an ACP client runs, and `ground` is every other command.

If you are developing ground, `make install-parity` also installs `ground_parity`. It is its own binary because it reads the pinned agents' schemas and libmcp's C at compile time, which the hook binary does not need to carry; `make install` neither builds nor needs it.

## How it works

`ground_hook` runs as a Claude Code hook across all events. The contract it answers is the pinned agent binaries' own: `ground_parity` shows how much of each version's ground covers. Every event is attested with its full payload, and goes to QNTX without its tool payloads. Actions for command controls:

- **arg** — insert missing arguments after the matched command
- **omit** — strip unwanted flags from the command
- **omitLine** — drop a whole command segment
- **clamp** — raise a numeric flag value to a floor
- **strop** — validate the shape of an extracted flag value, deny on mismatch
- **substitute_for_read** — name the utilities that mean "I was trying to read a file"; ground reads it and hands the contents over instead of running the command

- **substitute_for_cmd** — name the command the author meant; ground replaces the matched segment whole and runs that instead

Rewrites (arg/omit/omitLine/clamp/substitute_for_cmd) are silent — the command runs corrected and Claude receives a message explaining why. Strop denies with a message computed from the extracted value. Unmatched commands pass through unchanged. Keyword controls on UserPromptSubmit inject context when the user mentions a topic.

Controls are defined in `controls/*.pbt` and compiled into the binary. The binary is the config. A repo declared with `project { path: "..." }` contributes its own `controls/*.pbt` the same way — the pbt governing a repo lives beside the code it governs.

A control that only one machine should run is declared in that machine's `controls/local/*.pbt`, which is not tracked. A scope names paths and events, never a host, so the local directory is how a machine opts in: the install that declares it is the install that has it, and every other one does not. A deny is the strongest reason to want this — one operator's guard is another's blocked tool call — so a control that stops a tool outright belongs there rather than in the shared pbt.

Ground stops rather than degrades. Its attestation store is a hard dependency: a damaged SQLite database returns zero rows to every read, which is indistinguishable from a database that is merely empty, so continuing would report an all-clear it cannot have verified. On detecting corruption ground reports on every hook and denies none of them — it refuses to operate, never to let you work, since blocking your own tool calls would take away what you need to repair it.

   
