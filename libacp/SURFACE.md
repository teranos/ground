# What libacp reads and writes, per method

ground code's ACP moves into libacp one part at a time; each part ports the PR that first gave
ground code the method. A row is what libacp reads or writes of it in v1 (schema-v1.26.0), and
what v2 (schema-v2.0.0-alpha.9) says of the same method, so v2 needs no second pass.

| Method | Part | Ported from | libacp, v1 | v2 alpha.9 |
|---|---|---|---|---|
| `initialize` | 0 | #179 | reads `protocolVersion`, `clientCapabilities`; writes `protocolVersion`, `agentCapabilities`, `authMethods`, `agentInfo` | request carries `info`, `capabilities`; result `info`, `capabilities`, `authMethods`; read and written by libacp in both shapes |
| `session/resume` | 1 | #118 | reads `sessionId`, `cwd` (absolute) | request adds `replayFrom`; result drops `modes`, adds `availableCommands` |
