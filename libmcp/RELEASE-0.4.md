# 0.4.0-dev: validated tool dispatch

Ground's landed ACP/model/tool loop makes tool execution the immediate integration
boundary. This increment prevents schema-invalid model arguments from reaching a
server and prevents invalid structured output from being reported as a success.
It adds a reusable C ABI validator and checked asynchronous/synchronous tool APIs,
plus a companion Ground patch that compiles discovered schemas and carries errors
back through the existing ACP/model history path.

Existing C public structure layouts and status values remain unchanged. Three
statuses are appended, and new opaque handles/options/functions are additive.
Ground's internal `callMcpTool` signature changes to return a separate validation
report. Its D bindings include the new APIs and the previously missing 0.3 HTTP
diagnostic accessors. C/D layout tests cover 30 size/offset comparisons.

## Dependency decision

libmcp's implementation and public ABI remain C. Full schema semantics use the
Corvus native C ABI over Rust, statically incorporated into libmcp.a. This adds a
Rust build dependency and archive size, but no Rust toolchain requirement for D
consumers, interpreter, managed runtime or validator network access. All source
and Cargo dependencies are pinned and vendored for offline builds. The wrapper
is MIT; Corvus is Apache-2.0 and other dependency notices are retained.
See `spec/SCHEMA-PINNED.json`, `vendor/README.md` and `SCHEMA.md`.

## Release gates still open

- Ground's ACP turn loop is synchronous. End-to-end `session/cancel`, interruptible
  model calls, elicitation/sampling UX and retained MRTR ownership need a separate
  harness change. The low-level libmcp cancellation/MRTR APIs already exist.
- OAuth discovery, authorization, token refresh/storage and authorization-server
  interoperability remain host-owned and unimplemented here.
- Custom JSON Schema dialects, optional format assertion profiles and exhaustive
  old-draft integration are not claimed. No full-method MCP-schema validator or
  elicitation-content integration is added.
- Ground must deliberately refresh compiled catalogs after tool-list changes.
  This patch compiles the catalog at session setup; it adds no refresh automation.
- macOS and non-x86_64 builds still need CI execution. Review the new compiled
  dependency, binary size and resource-limit behavior before tagging 0.4.0.

This is a reviewable development package, not a published or fully conformant
0.4.0 release. The existing protocol target remains 2026-07-28; a library version
bump does not silently change negotiation behavior. See `VALIDATION.md` for fresh
checks, with older results clearly separated.
