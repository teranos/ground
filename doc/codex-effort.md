# Codex effort as usage runs low

Ground automatically lowers reasoning effort only in Codex sessions:

| Remaining Codex quota | Effort cap |
| --- | --- |
| 50% or more | No change |
| Below 50%, at least 20% | Medium |
| Below 20% | Low |

Use the minimum remaining percentage across the unexpired primary and secondary
windows of the `codex` quota bucket. The boundaries are strict: exactly 50%
asks for no change; exactly 20% asks for medium. An effort already below the cap
is preserved. Missing or invalid readings and unknown efforts cause no change.
Claude's effort policy is independent.

The shipped policy suspends all new downgrades when the five-hour Codex window
has 60 minutes or less until reset, including downgrades otherwise triggered
by the weekly window. It leaves the current effort unchanged and records
`reset_grace`; it does not restore an earlier higher effort.

## PBT configuration

The shipped policy is `controls/codex-effort.pbt`:

```pbt
scope {
  event: ["PreModelRequest", "PostModelRequest"]
  control {
    name: "codex-effort"
    interval: "60"
    handler_params {
      enabled: "true"
      medium_below: "50"
      low_below: "20"
      skip_before_5h_reset_minutes: "60"
    }
  }
}
```

Thresholds are whole remaining percentages. Both thresholds are required when
enabled, with `0 <= low_below <= medium_below <= 100`. `interval` is seconds,
from 1 to 86400. Invalid values, unknown parameters, and duplicate parameters
fail PBT compilation. Thresholds and interval come from this control, not
constants in the engine.

`skip_before_5h_reset_minutes` accepts whole minutes from 0 to 300. Zero or
omission disables this exception; the shipped control sets it to 60. Ground
identifies the five-hour window by `windowDurationMins: 300` in either window
slot. The boundary is inclusive. Missing or invalid duration/reset information,
expired windows, other quota buckets, and a weekly reset alone do not activate
the exception.

A matching `codex-effort` declaration in local or project sand overrides the
floor. Within a layer the last matching declaration wins; between layers the
order is floor, local, then project comet. An absent project declaration keeps
the local policy. Each declaration supplies the complete policy. Scopes may
select `path` and `event`; a containing project's repository identity also
applies. To disable it, a declaration needs only
`handler_params { enabled: "false" }`.

PBT follows Ground's existing compilation and sand-loading workflow. Rebuild
and install the relevant sand after editing it; hooks read the loaded compiled
policy. No parallel TOML, JSON, or environment settings define these thresholds.

## Native Ground implementation

The policy lives in `source/effort.d`. `ground_hook` dispatches Codex
`PreModelRequest` and `PostModelRequest` events to `source/codexeffort.d` after
recording the event. The handler requires a session ID and a nonempty Codex
turn ID. Other events and Claude payloads do not enter this path.

`source/codexrpc.d` connects directly to the existing daemon's Unix socket,
performs the WebSocket handshake, and exchanges JSON-RPC in the hook process.
The production path uses D compiled with BetterC; it launches neither Python
nor a Codex proxy. The socket defaults to
`$CODEX_HOME/app-server-control/app-server-control.sock`, or the equivalent
under `~/.codex`. `GROUND_CODEX_SOCKET` selects a different existing socket.

The shipped control checks each session at most once per minute. Ground atomically claims a
check in `codex_effort_checks`, releases the database write lock, verifies that
the thread is already loaded, reads its effort and account quota, and lowers
its configured effort for subsequent turns. A second thread read must confirm
the requested effort before the evidence row says `lowered`.

Ground never starts a server, resumes a thread, or makes a model call through
this route. It records unloaded sessions and failures without blocking the
user. The entire socket exchange has a ten-second deadline; messages are
bounded to 2 MiB. Schema changes belong exclusively in explicit migrations.

This is a lowering policy. It does not restore higher effort after a quota
reset; a manual increase can be capped again on the next eligible check.
It does not change an already running turn. The Python prototype remains a
standalone diagnostic tool, including its experimental `--turn-id` option,
and is not needed by the native hook.

## Build, migration, and registration

Build and test:

```sh
make ground_hook
make test
make test-codex
```

Before enabling the native handler, explicitly apply its idempotent migration:

```sh
sqlite3 "$HOME/.local/share/ground/ground.db" < migrations/20261109_001_codex_effort_checks.sql
```

The normal Ground build and installation include the handler through the
hook's D imports. Register one asynchronous `ground_hook` command under each
of `PreModelRequest` and `PostModelRequest` in Codex's hooks configuration:

```json
{
  "type": "command",
  "command": "/absolute/path/to/ground_hook",
  "async": true,
  "timeout": 30
}
```

Replace the prototype's model-event entries rather than running both
controllers. Codex requires new or changed hook definitions to be reviewed
and trusted in `/hooks` before they run.

The session must be hosted by the daemon being controlled. The embedded
0.163.0 TUI examined during development had no external control socket;
full filesystem access did not make it reachable. A fresh TUI can connect to
the existing daemon explicitly:

```sh
codex --remote "unix://$HOME/.codex/app-server-control/app-server-control.sock"
```

Do not resume a currently running embedded conversation on another daemon.
A loaded-thread check will instead report `unloaded` and leave it alone.

## Verification

The native integration tests run the compiled `ground_hook` against an
independent Unix WebSocket server and an isolated migrated Ground database.
They cover thresholds, preserving lower effort, fragmented and large replies,
ping/pong, invalid handshakes, closed sockets, rejected updates, readback
mismatches, invalid quota, unloaded threads, throttling, Claude isolation,
and missing migration. D tests also cover the nearer quota window, reset
expiry, bucket isolation, and the RFC 6455 handshake example.

The PBT integration tests load a separately compiled sand into the actual hook:
70%/30% thresholds change its decisions at 60% and 25% remaining, and
`enabled: "false"` prevents both network access and an effort evidence row.

A live native test on 2026-11-09 read 26% remaining from the existing 0.167.0
daemon, changed an ephemeral thread from high to medium, verified the new
setting, and wrote row 2 in the real Ground database. The test thread was then
restored and disconnected; no model call was made.

On 2026-11-10 the final installed native hook, using the shipped PBT policy,
read 19% remaining and changed another ephemeral thread from high to low.
Readback confirmed low and the real Ground database recorded row 3. The thread
was restored and disconnected afterward. `make test` passed 43 D modules;
`make test-codex` passed nine integration tests.

The reset-grace addition passed all 43 D modules and 13 native integration
tests. Coverage includes the inclusive one-hour boundary, low weekly quota,
invalid window metadata, a loaded PBT override to 30 minutes, and disabling
the exception with zero.

The two model-event registrations now invoke only asynchronous `ground_hook`.
The daemon reports both enabled but untrusted, with no configuration errors or
warnings; the other twelve existing entries remain trusted. Automatic dispatch
therefore still needs the user's `/hooks` review and a daemon-hosted session.
