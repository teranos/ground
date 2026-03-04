# Countdown

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

**Phase 3 — ax controls. ✓** Controls that query the attestation trail via the QNTX ax extension. On Stop, graunde loads the extension, queries attestations for the current branch, and matches against them. Future controls:
- Clippy control on Stop activates after the first push, matches when .rs files were edited after the last `cargo clippy` run on the current branch.
- Stale binary correction on Stop.
- Increase signal to noise ratio.
- Catch hardcoded URLs in error messages that claim to report runtime values.
- Reminder to look at a Nix flake when editing CI that touches said flake.
- Direct ego-death when faced with confident claims about niche/untrained topics — trigger grace and humility as the function of control.

**Phase 4 — QNTX conduit.** Deferred to #2 (`e27dd9e`). CI attestations into graunde's read path.

### Three — engines on ✓
Register graunde for all hook events. Branch on `hook_event_name` in main.d. PreToolUse keeps existing control logic and attests every tool call. PostToolUse, PreCompact, Stop, SessionStart attested as lifecycle markers — control stubs present but no matching logic yet. The complete attestation trail — commands, file paths, compactions, session boundaries — enables Count Four Phase 3.

### Two — check ignition

### One — and may God's love
The binary is the config. Users define controls in D source and compile their own graunde. Self-recompilation: hash controls source at compile time via CTFE, compare at runtime, rebuild on mismatch. Claude edits `controls.d`, next hook invocation detects staleness, rebuilds, new control is live — no manual step. Tag staleness: compare baked-in `git describe` against upstream. Figure out fork ergonomics — how do users customize and stay upstream-compatible.

### Liftoff — be with you
Open source readiness. README, CONTRIBUTING, LICENSE review, GitHub releases, install-from-source instructions.
