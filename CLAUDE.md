New sessions should always read: README.md

# OPERATIONAL DOC

Read the following files:

- source/hooks.d for control types, scope struct, and trigger builders.
- source/strop.d for value-shape validation on extracted flag values.
- source/controls.d for CTFE wiring — how pbt becomes static immutable scope arrays.
- source/control_handlers.d for check, delay, and deliver handler implementations.
- source/deferred.d for deferred delivery
- source/immediate.d for immediate delivery — attestation format for external writers (QNTX, etc).
- source/exec.d for exec dispatch — fork+pipe+wrapper, stdout/stderr capture, timeout.
- source/errors.d for the GroundError primitive and deliverError fallback chain (db → breadcrumb → stderr).
- source/pretooluse.d and source/stop.d for the two hook handlers everything above is wired into.
- source/git.d for git discovery — repo root and branch are file reads; check-ignore is the one subprocess left in the hot path.
- grove/controls/*.pbt for the rituals — each carries its agent's `system:`, so nothing else has to describe them.
- RITUAL.md for what a ritual is and what each numbered item of it means.

Read UNDERGROUND.md for ug, the statusline, ug/*.d

Read bench.fish for CTFE scaling limits.

The commands are the ground-commands skill, written by press from the
modules that implement them.

## TEST DRIVEN DEVELOPMENT (TDD)

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

An **ERROR** is a first-class primitive. Error is data.
A typed value that crosses every layer of the system unchanged.
An `Error` is the entity any layer emits when something breaks intention.

*The ERROR is never collapsed, dropped, swallowed, truncated or suppressed;
it lands in front of the user, contextually at the exact point of interaction as it happens.*

[ERROR.md](ERROR.md)
