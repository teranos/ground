# libMCP

A C11 MCP **client** library for Ground's D `-betterC` harness. Builds static
and shared libraries with a C ABI in `include/mcp.h`. Handwritten D bindings
live in [Ground](https://github.com/teranos/ground/blob/main/source/libmcp.d).
The C wrapper is MIT, like Ground. The bundled Corvus validator is Apache-2.0;
its transitive dependencies retain their own licenses under `vendor/crates`.

This is the **0.4.0-dev schema-validation increment**. See [the release notes](RELEASE-0.4.md)
for the implemented scope, dependency choice and remaining release gates.

Ground owns the connections, catalogs and dispatch. Provider adapters can use
them without owning MCP processes or introducing another language runtime.

## Build and link

```sh
nix develop
make
make test
nix build .#libmcp --no-link
make install PREFIX="$HOME/.local"
```

Outside Nix: C11, make, pkg-config, json-c, libcurl (7.85+) and Rust/Cargo
1.89 or newer; all Cargo dependencies are vendored and built offline. Tests also need
Python 3. json-c 0.18 requires the upstream fix in `json-c-strict-utf8.patch`: its
strict mode otherwise rejects valid UTF-8. The flake applies this fix to its
locked dependency. json-c 0.17 works unpatched. Validation remains strict.

Installation includes `mcp.h`, the static archive and `libmcp.pc`. The shared
library is built for tests; consumers embed the archive. Link an installed
consumer with `pkg-config --cflags --libs --static libmcp`, or use the build tree:

```sh
cc client.c build/libmcp.a -Iinclude $(pkg-config --cflags --libs json-c libcurl) -lm -lpthread -ldl
# From a Ground checkout with its D bindings:
ldc2 -betterC -I=source app.d /path/to/libmcp/build/libmcp.a -L-ljson-c -L-lcurl -L-lm -L-lpthread -L-ldl
```

The build-tree commands above are for Linux; use `-liconv` instead of `-ldl`
on macOS. Installed pkg-config metadata selects these platform libraries. The
static archive embeds the validator; downstream D consumers do not need Cargo.

## API and ownership

Initialize `mcp_options` with `mcp_options_init`, set `command`, null-terminated
`argv` (including argv[0]), and `client_name`, then call `mcp_client_open`.
Initialize each `mcp_response` to zero, consume it on success **and failure**,
and release it with `mcp_response_free` before reuse. `mcp_client_close` consumes
the handle, including on failure. [`tests/client.c`](tests/client.c) is an
executable embedding example.

Helpers cover tools, resources, resource templates, prompts, completions and
subscriptions. `mcp_client_request` waits for one response; `mcp_client_call`
also fulfills multi-round input requests through declared host handlers.
Pagination belongs to the caller. Transport failures never trigger tool retries.

For multiplexing, use `mcp_client_submit`, drive `mcp_client_poll`, then inspect,
take and destroy each `mcp_request`. Responses can arrive out of order. Each
request has its own deadline and cancellation. Completed handles count toward
`max_pending` until destroyed (64 by default). Acknowledged subscriptions remain
active until cancelled, completed or disconnected. libMCP runs on the polling thread; libcurl may use resolver threads.
All access to one client must happen on one thread at a time; independent
clients may run concurrently.

Responses retain the exact wire frame without its terminal newline. Remote
JSON-RPC errors, tool `isError` results, and input-required results have distinct
statuses and retain their full payload. System errors include errno and child
exit failures include raw waitpid status. Failed opens expose secondary rollback
failures in `error.cleanup_*`. Error message pointers have static lifetime.

Defaults: 30 seconds per call, 500 ms for discovery probing, one second per
shutdown grace interval, and 1 MiB per frame. Timeouts/limits must be positive;
zero is rejected. An absolute monotonic deadline covers writing, reading and
interleaved notifications. A timeout cancels only its request. Stdio transport, framing and incoming size
failures make the connection unusable. HTTP transfer failures are isolated to
their request. There is no silent retry
of a possibly side-effecting tool call.

Servers launch directly through argv with no shell. `envp = NULL` inherits the
environment; supplied envp replaces it. `cwd = NULL` inherits the working
directory. Stderr is inherited and never treated as proof of protocol failure.
The optional message callback observes notifications and legacy server requests
using borrowed frames; it must return promptly and cannot reenter its client.
No process-wide signal disposition is changed, including SIGPIPE. Shutdown
closes stdin, waits, then escalates TERM/KILL and reaps; forced shutdown is an
error, not success.

## Ground harness integration

Ground owns connection groups, catalogs, tool dispatch, approval policy and
credential storage. The library owns transport and protocol mechanics. D
bindings and harness integration tests belong to the Ground repository; this
standalone package exports a C ABI and adds no D runtime dependency.

## Protocol scope

The pinned target is `2026-07-28`; see the [coverage matrix](CONFORMANCE.md)
and [source pins](spec/PINNED.json). This is a broader client implementation,
with explicit remaining gaps, not a full conformance claim.

Stdio supports automatic discovery and legacy fallback, plus modern-only and
legacy-only modes. Recognized modern errors never trigger downgrade. Legacy
initialization accepts `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`.
Client capabilities default to `{}`. `mcp_client_open_ex` accepts explicit roots,
sampling and elicitation capabilities and a host handler. Modern peers use
input-required results; legacy peers receive JSON-RPC replies. Unsupported
features are never advertised automatically. Sampling and roots are deprecated
in the pinned modern revision and remain opt-in compatibility features.

`mcp_client_open_http` discovers a modern Streamable HTTP endpoint. The library
accepts JSON and request-scoped SSE, sets the required MCP headers, checks TLS,
and rejects redirects. Plain HTTP is restricted to loopback endpoints.
`mcp_client_create_http` creates the endpoint without network I/O: call
`server/discover` explicitly to observe an initial 401 and its authentication
challenge, obtain a token through your host, set it with `mcp_client_set_bearer`,
then explicitly retry discovery. The library never refreshes or stores tokens
on disk. It does not implement OAuth discovery, authorization or registration.

For concurrent HTTP operations, retain each `mcp_request` and use
`mcp_request_http_status`, `mcp_request_transport_code`, and
`mcp_request_auth_challenge` after completion. A different request cannot
replace these diagnostics, and `mcp_request_take` leaves them intact. Repeated
`WWW-Authenticate` fields are combined in wire order with comma-space separators;
the combined value has the same configured byte limit as messages. This is raw
header text, not a parsed OAuth challenge. Failed transfers may have partial
headers. Copy the borrowed challenge before resuming or destroying the request
or closing its client. A continuation resets diagnostics for its new round.

The older client-wide accessors retain their last-observed semantics and can
mix observations from concurrent transfers. Synchronous convenience calls destroy
their request handles; use submit/poll/take when request diagnostics are needed.
No HTTP error or authentication challenge automatically replays a tool call.

HTTP tool discovery builds a filtered catalog accessible through
`mcp_client_tools_catalog`. Use that catalog for tool selection; raw
`tools/list` responses preserve the original wire JSON, including rejected tool
definitions, for diagnostics. Valid `x-mcp-header` annotations are mirrored as
`Mcp-Param-*` headers. A new first page resets the catalog; subsequent pages
append. Refresh the catalog when tools change. Concurrent catalog refreshes are
not supported. No automatic replay occurs after HeaderMismatch.

Runtime JSON Schema validation is available through `mcp_schema_compile` and
`mcp_schema_validate`. The default dialect is 2020-12. Compile a discovered tool
with `mcp_tool_compile`, then use `mcp_tool_submit` or `mcp_tool_call` to validate
arguments before dispatch and structured output before success. Existing raw
request and `mcp_tools_call` APIs remain unchecked for compatibility.
See [SCHEMA.md](SCHEMA.md) for ownership, diagnostics and the supported profile.
No schema references are fetched from the network.

## Validation

`make test` runs shared C ABI subprocess tests, a static C embedding client,
multiplexing/cancellation/MRTR, legacy client-feature replies and loopback
HTTP/SSE. Linux also injects parser allocation and cancellation I/O failures.
See [validation evidence](VALIDATION.md) for executed checks and limits.

`make test-interop SDK_ROOT=/path/to/python-sdk SDK_PYTHON=/path/to/venv/bin/python`
runs independent stdio/HTTP JSON/HTTP SSE tests against the pinned official SDK
and validates its tool results against the vendored schema. See
[reproduction instructions](spec/README.md). This optional test target requires
an explicitly prepared SDK; normal builds and tests never download code.
