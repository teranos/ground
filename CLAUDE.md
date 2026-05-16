Read source/hooks.d for control types, scope struct, and trigger builders.
Read source/controls.d for CTFE wiring — how pbt becomes static immutable scope arrays.
Read source/control_handlers.d for check, delay, and deliver handler implementations.
Read source/deferred.d for deferred delivery — session-scoped and project-scoped messages delivered at Stop.
Read source/immediate.d for immediate delivery — attestation format for external writers (QNTX, etc).
Read source/watch.d for the asyncRewake watcher — how immediate messages reach running sessions.
Read README.md for project overview.
Read COUNTDOWN.md for project status.

Read bench.fish for CTFE scaling limits.

TDD: write a failing CTFE test before implementing. Show the test, confirm it fails, then make it pass.
