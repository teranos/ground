# Controls as pbt (Protocol Buffer Text)

## Decision

Express controls in pbt format. Generate D source (`static immutable` arrays) from pbt at compile time via CTFE `import()`. No `.proto` schema file — format defined by convention.

## Why

- Controls are data, not code. 44 of 48 controls are pure name + pattern + message.
- A UI to manage controls needs a serializable format. Pbt is that format.
- The UI reads and writes the same pbt files. No separate data model.
- 4 controls need code handlers (`ciDelay`, `ciDeliver`, `binaryShadowed`, `controlsAreStale`). These register by control name in D — the pbt references the handler name, the generator emits the function pointer lookup.

## What stays in code

- Handler functions (DelayFn, DeliverFn, CheckFn) — registered by name
- The CTFE generator that parses pbt and emits Control/Scope arrays
- hooks.d structs (Control, Scope, Defer, etc.) — unchanged
- main.d event dispatch — unchanged

## What moves to pbt

- All control definitions (currently in controls.d, qntx.d, macos.d)
- Scope assignments (path, decision, control list)
- Overlay grouping (currently conditional compilation → becomes scope path filtering)
