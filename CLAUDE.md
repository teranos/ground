Read source/hooks.d for control types, scope struct, and trigger builders.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/strop.d for value-shape validation on extracted flag values.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/controls.d for CTFE wiring — how pbt becomes static immutable scope arrays.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/control_handlers.d for check, delay, and deliver handler implementations.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/deferred.d for deferred delivery — session-scoped and project-scoped messages delivered at Stop.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/immediate.d for immediate delivery — attestation format for external writers (QNTX, etc).
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/watch.d for the asyncRewake watcher — how immediate messages reach running sessions.
  - ERROR AXIOM Not Conformant yet. Remove this line when done
Read source/exec.d for exec dispatch — fork+pipe+wrapper, stdout/stderr capture, timeout.
Read source/errors.d for the GroundError primitive and deliverError fallback chain (db → breadcrumb → stderr).
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

*An ERROR must be true, not merely delivered. It states what the emitting
code measured, never a cause inferred from a proxy. A false ERROR spends
the user's attention and teaches them to discount the channel — it costs
the axiom exactly what a swallowed one does.*

Conformance is therefore two audits, not one: that nothing is swallowed,
and that every claim an ERROR makes is answerable from what its own code
observed.
