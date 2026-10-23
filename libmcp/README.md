# libMCP

A C11 MCP **client** library for Ground's D `-betterC` harness. Builds static
and shared libraries with a C ABI in `include/mcp.h` and handwritten bindings
in [`source/libmcp.d`](../source/libmcp.d). MIT, like Ground.

Ground owns the connections, catalogs and dispatch. Provider adapters can use
them without owning MCP processes or introducing another language runtime.

## Build and link

```sh
nix develop
make -C libmcp
make test-mcp
nix build .#libmcp --no-link
make -C libmcp install PREFIX="$HOME/.local"
```

Outside Nix: C11, make, pkg-config and json-c; tests also need Python 3 and
LDC. json-c 0.18 requires the upstream fix in `json-c-strict-utf8.patch`: its
strict mode otherwise rejects valid UTF-8. The flake applies this fix to its
locked dependency. json-c 0.17 works unpatched. Validation remains strict.

Installation includes `mcp.h`, both libraries, `libmcp.pc`, and the D binding
under `include/d`. Link shared consumers using `pkg-config --cflags --libs
libmcp`. For static linkage select the archive explicitly and include json-c:

```sh
cc client.c libmcp/build/libmcp.a -Ilibmcp/include $(pkg-config --cflags --libs json-c)
ldc2 -betterC -I=source app.d libmcp/build/libmcp.a -L-ljson-c
```

## API and ownership

Initialize `mcp_options` with `mcp_options_init`, set `command`, null-terminated
`argv` (including argv[0]), and `client_name`, then call `mcp_client_open`.
Initialize each `mcp_response` to zero, consume it on success **and failure**,
and release it with `mcp_response_free` before reuse. `mcp_client_close` consumes
the handle, including on failure. [`tests/client.c`](tests/client.c) and
[`examples/client.d`](examples/client.d) are executable examples.

Helpers cover tool/resource/prompt lists, tool calls, resource reads and prompt
retrieval. `mcp_client_request` handles additional methods and caller-managed
continuation parameters. Pagination belongs to the caller. Calls are never
automatically retried. Requests on one client must be serialized; independent
clients may run concurrently.

Responses retain the exact wire frame without its terminal newline. Remote
JSON-RPC errors, tool `isError` results, and input-required results have distinct
statuses and retain their full payload. System errors include errno and child
exit failures include raw waitpid status. Failed opens expose secondary rollback
failures in `error.cleanup_*`. Error message pointers have static lifetime.

Defaults: 30 seconds per call, 500 ms for discovery probing, one second per
shutdown grace interval, and 1 MiB per frame. Timeouts/limits must be positive;
zero is rejected. An absolute monotonic deadline covers writing, reading and
interleaved notifications. Transport, timeout, framing and size failures make
the client unusable; close it before opening another. There is no silent retry
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

ACP `session/new` now connects the stdio servers in `params.mcpServers`.
Each configuration has `name`, `command`, `args` and `env`; environment entries
are `{ "name": "KEY", "value": "value" }` and override inherited keys.
Processes run in the session's `cwd`.

Configuration is validated before spawning. Limits: 32 unique server names per
session, 128 arguments and 128 environment entries per server. A session owns
every connection and all initial `tools/list` pages (maximum 128 pages, repeated
cursor rejected). Partial setup rolls back. `session/close` and host EOF close
and reap the children. Cleanup errors reach stderr and the ACP response; large
error payloads grow the reply buffer instead of being cut to 4096 bytes.

[`source/code/mcp.d`](../source/code/mcp.d) exposes `McpGroup`,
`McpServer.tools` and `callMcpTool(group, serverName, toolName, arguments,
response, error)` to the harness. The `(server, tool)` pair prevents collisions
between servers exposing identically named tools.

This change supplies the MCP client layer. Ground's model/provider loop,
`session/prompt`, tool approval policy and ACP tool-call updates remain separate
harness work. No custom ACP tool-dispatch method is added.

For direct diagnostics, Ground and the standalone D client use the same ABI:

```sh
make -C libmcp test-d
libmcp/build/mcp-client tools/list '{}' -- /path/to/mcp-server
ground mcp tools/call '{"name":"echo","arguments":{"text":"hello"}}' -- /path/to/mcp-server
```

## Protocol scope

POSIX stdio, Linux and macOS. Automatic mode probes `server/discover` with
per-request metadata for `2026-07-28`, falling back on legacy probe errors or
timeout. Recognized modern errors never trigger downgrade. Explicit modern-only
and legacy-only modes are available. Legacy initialization accepts
`2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`, then sends
`notifications/initialized`. Unknown versions fail visibly.

Client capabilities are `{}`. Legacy pings are answered; unprovided methods
receive MethodNotFound and remain observable through the callback. Modern
input-required responses are surfaced intact. This is a working stdio client
foundation, not a complete SDK/conformance claim: no automatic sampling,
elicitation, roots service, subscription pump, JSON Schema validation, HTTP,
SSE or OAuth implementation.

References: [stdio and compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio),
[request metadata](https://modelcontextprotocol.io/specification/2026-07-28/basic),
[discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
[legacy lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).

## Validation

`make test-mcp`: shared C ABI subprocess tests, a static C client, measured C/D
layouts, D round trips and the D harness's tool-dispatch boundary.
`python3 libmcp/tests/test_ground.py ./ground`: actual ACP session ownership,
pagination, env/cwd, rollback, malformed configuration, large errors and EOF
cleanup. CI runs the package and ACP checks on Linux and macOS.
