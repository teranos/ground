# libACP

A C11 [Agent Client Protocol](https://agentclientprotocol.com) library, agent side,
with a C ABI in `include/acp.h`. Ground's `ground code` speaks ACP through it, as it
speaks MCP through [libmcp](https://github.com/teranos/libmcp). MIT, like Ground.

It is held to two schemas: v1 at
[schema-v1.26.0](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.26.0),
and v2 at
[schema-v2.0.0-alpha.9](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.9).

## Build and link

```sh
nix develop
make
make test
nix build .#libacp --no-link
make install PREFIX="$HOME/.local"
```

Outside Nix: C11, make, pkg-config and json-c.

## Versions

One protocol version per connection, chosen at `initialize`, as the
[migration guide](https://agentclientprotocol.com/protocol/v2/migration#supporting-v1-and-v2-side-by-side)
asks of an agent that implements v2:

- `acp_initialize_read` reads the request in the shape of the version the client
  asked for: `clientCapabilities` for v1, `capabilities` for v2.
- It selects the highest version the agent supports at or below the one requested.
  None at or below it is a `-32022` error, with `requested` and `supported` in its data.
- `acp_initialize_result` writes the result in the selected version's shape:
  `agentCapabilities` and `agentInfo` for v1, `capabilities` and `info` for v2.

The agent names the versions it supports. An agent that names only 1 answers a
v2 client with v1, which the guide allows of a v1-only agent.

## Scope

`initialize` and version selection. The rest of the agent side follows from
`ground code`, which still writes them itself.
