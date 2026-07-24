Read source/hooks.d for control types, scope struct, and trigger builders.
Read source/strop.d for value-shape validation on extracted flag values.
Read source/controls.d for CTFE wiring — how pbt becomes static immutable scope arrays.
Read source/control_handlers.d for check, delay, and deliver handler implementations.
Read source/deferred.d for deferred delivery — session-scoped and project-scoped messages delivered at Stop.
Read source/immediate.d for immediate delivery — attestation format for external writers (QNTX, etc).
Read source/watch.d for the asyncRewake watcher — how immediate messages reach running sessions.
Read README.md for project overview.
Read COUNTDOWN.md for project status.

Read bench.fish for CTFE scaling limits.

TEST DRIVEN DEVELOPMENT (TDD): write a failing test before implementing. Confirm it fails, then Green: Write code that makes the test pass.

## ERROR AXIOM

An **ERROR** is a first-class primitive. A typed value that crosses
every layer of the system unchanged. an `Error` is the entity
any layer emits when something goes wrong.

*The ERROR is a sacred first-class citizen, never collapsed, dropped,
swallowed or suppressed; they land in front of the user, contextually,
at the exact point of interaction.*
