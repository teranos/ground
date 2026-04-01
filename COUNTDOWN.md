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

### Four — commencing countdown ✓
Git workflow rituals and attestation-backed state. Ground evolves from stateless gate to stateful ritual tracker, writing and reading QNTX attestations via linked libsqlite3. Actor: `ground`. Source: `ground v{VERSION}`. Standalone db migration tracked in `sqlite.d`. When QNTX is online, reactive attestations can appear in real-time, injecting awareness into a running Claude session through the existing control protocol.

**Phase 1 — ritual checkpoints. ✓** Msg-only controls with `"ask"` decision for each git lifecycle moment. Branch creation: check main for unpushed commits, commit intent (documentation first), push, open draft PR. Push: pull first, resolve conflicts. Tag: check latest tag, follow semver. PR finalization: tests, review, issues, rebase, reassess.

**Phase 2 — libsqlite3 link. ✓** Linked against libsqlite3 via C interop. Attestations written to QNTX node db on every control match. Subjects: branch name. Predicates: control name. Actor: `ground`. Source: `ground v{VERSION}`.

**Phase 3 — ax controls. ✓** Controls that query the attestation trail via the QNTX ax extension. On Stop, ground loads the extension, queries attestations for the current branch, and matches against them. Deferred message queue delivers attestation-backed messages on Stop without blocking — CI nudge fires after `git push` with adaptive delay. Clippy reminder activates after push when .rs files were edited after the last `cargo clippy` run. Machine context attested on SessionStart via compile-time arch detection. PostToolUse captures full tool response. Msg-only controls emit their decision on every fire, message only on first. Future controls tracked as TODOs in `controls.d`.

**Phase 4 — groundd types. ✓** Type definitions attested on SessionStart so QNTX knows which payload fields are rich text. Every hook event stored verbatim via `attestEvent`. When ground acts, a separate `Groundd<Event>` attestation records only ground's own decisions — Claude's payload stays untouched. Old-style truncated writes removed. Deferred message infrastructure split to `deferred.d`. Project-scoped deferred messages from QNTX deliver on SessionStart and Stop on main.

### Three — engines on ✓
Register ground for all hook events. Branch on `hook_event_name` in main.d. PreToolUse keeps existing control logic and attests every tool call. PostToolUse defers CI nudge messages after `git push`. Stop runs ax controls against the attestation trail and delivers deferred messages. SessionStart attests type definitions and delivers project-scoped deferred messages. PreCompact attested as lifecycle marker. The complete attestation trail — commands, file paths, compactions, session boundaries — enables Count Four Phase 3.

### Two — check ignition ✓
Issue backlog moved to source TODOs. Standalone db with own schema. getBranch reads `.git/HEAD` directly — no subprocess per event. Subject stability via `session_project` cache table — project part fixed on SessionStart, immune to cwd drift. Compaction-aware dedup — once-per-session controls re-fire after PreCompact. PostToolUse controls with scoped matching. Permanent timing instrumentation with regression detection on Stop (350ms budget). Per-event-type budgets not yet implemented — Stop needs headroom for trail checks and CI queries, inter-event hooks should be near-instant. UserPromptSubmit controls via `userprompt()` trigger with case-insensitive matching and scope exclusion. Ego-death controls catch overconfident and dismissive language. Flake includes `controls/` directory.

### One — and may God's love ✓
The binary is the config. Distribution via Claude Code plugin — two JSON files, no binary shipped. SessionStart checks PATH for ground; if missing, tells Claude to figure out the installation. Self-verification: CTFE hash of controls source compared at runtime, warns when binary is stale. Tag staleness: baked-in `git describe` compared against GitHub Releases API on startup.

### Liftoff — be with you
Open source readiness. README, CONTRIBUTING, LICENSE review, GitHub releases, install-from-source instructions.
