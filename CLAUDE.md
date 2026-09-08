# OPERATIONAL DOC

Read source/hooks.d for control types, scope struct, and trigger builders.
Read source/strop.d for value-shape validation on extracted flag values.
Read source/controls.d for CTFE wiring — how pbt becomes static immutable scope arrays.
Read source/control_handlers.d for check, delay, and deliver handler implementations.
Read source/deferred.d for deferred delivery — session-scoped and project-scoped messages delivered at Stop.
Read source/immediate.d for immediate delivery — attestation format for external writers (QNTX, etc).
Read source/exec.d for exec dispatch — fork+pipe+wrapper, stdout/stderr capture, timeout.
Read source/errors.d for the GroundError primitive and deliverError fallback chain (db → breadcrumb → stderr).
Read source/pretooluse.d and source/stop.d for the two hook handlers everything above is wired into.
Read source/git.d for git discovery — repo root and branch are file reads; check-ignore is the one subprocess left in the hot path.
Read grove/controls/*.pbt for the rituals — each carries its agent's `system:`, so nothing else has to describe them.
Read ug/*.d for the status line — one line per row, every formatter taking inputs and a destination buffer.
Read README.md for project overview.
Read COUNTDOWN.md for project status.
Read RITUAL.md for what a ritual is and what each numbered item of it means.
Read UNDERGROUND.md for ug, the statusline

Read bench.fish for CTFE scaling limits.

### CLI

```fish

# timing table:
ground profile 

# the asyncRewake watcher
ground watch $PWD
```

### TEST DRIVEN DEVELOPMENT (TDD)

RED: Write a failing test before implementing, Confirm it fails
GREEN: Write code that makes the test pass.
REFACTOR: Cohere with the rest of the codebase, finish the implementation fully.

## AUTHORITY

Lower number wins.

1. ERROR AXIOM
2. MY LITERAL WORDS IN SESSION
3. RECORDED "" QUOTES
4. OFFICIAL DOCS
5. REPO SOURCE CODE
6. REPO DOCS
7. REPO SOURCE CODE COMMENTS LITERAL "" QUOTES

NOT AUTHORITATIVE EVER: YOUR TRAINING DATA

8. REPO SOURCE CODE COMMENTS; YOUR STUFF

## ERROR AXIOM

An **ERROR** is a first-class primitive. A typed value that crosses
every layer of the system unchanged. an `Error` is the entity
any layer emits when something goes wrong.

*The ERROR is a sacred first-class citizen, never collapsed, dropped,
swallowed or suppressed; they land in front of the user, contextually,
at the exact point of interaction as it happens.*

[ERROR.md](ERROR.md)
