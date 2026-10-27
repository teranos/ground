# What libacp reads and writes, per method

ground code's ACP moves into libacp one part at a time; each part ports the PR that first gave
ground code the method. A row is what libacp reads or writes of it in v1 (schema-v1.26.0), and
what v2 (schema-v2.0.0-alpha.9) says of the same method, so v2 needs no second pass.

| Method | Part | Ported from | libacp, v1 | v2 alpha.9 |
|---|---|---|---|---|
| `initialize` | 0 | #179 | reads `protocolVersion`, `clientCapabilities`; writes `protocolVersion`, `agentCapabilities`, `authMethods`, `agentInfo` | request carries `info`, `capabilities`; result `info`, `capabilities`, `authMethods`; read and written by libacp in both shapes |
| `session/resume` | 1 | #118 | reads `sessionId`, `cwd` (absolute) | request adds `replayFrom`; result drops `modes`, adds `availableCommands` |
| `session/delete` | 2 | #120 | reads `sessionId` | the same: `sessionId` required, result `_meta` only |
| `additionalDirectories` in `session/new` and `session/resume` | 4 | #123 | reads the list, each path absolute; writes it back as answered | the same in `session/new`, `session/resume` and `SessionInfo` |
| `session/set_mode` | 3 | #121 | reads `sessionId`, `modeId` | absent: v2 has no session modes |
| `modes` in `session/new` and `session/resume` | 3 | #121 | writes `currentModeId`, `availableModes` (`id`, `name`, `description`) | absent: v2's results carry `configOptions` alone |
| `session/set_config_option` | 5 | #124 | reads `sessionId`, `configId`, and `value` as a value id, or `type` boolean and a boolean | the same keys; a value id carries `type` id, and an `other` shape carries custom values |
| `configOptions` in `session/new`, `session/resume`, `session/set_config_option` | 5 | #124 | writes selects: `id`, `name`, `category`, `type`, `currentValue`, `options` (`value`, `name`, `description`) | an option's `id` is `configId` |
| `session/list` | 6 | #128 | reads `cwd` (absolute) and `cursor`, each optional; writes each `SessionInfo`: `sessionId`, `cwd`, `additionalDirectories`, `title`, `updatedAt` | the same keys in the request, the result and `SessionInfo` |
| `authenticate` | 7 | #131 | reads `methodId`, required | renamed `auth/login`, `methodId` required; `auth/logout` beside it |
| `prompt` in `session/prompt` | 8 | #135 | reads each block: `text` and its `text`; `resource_link` and its `name`, `uri`; `resource` and its `resource`'s `uri`, `text` or `blob`; any other by its `type` | the same blocks; `ResourceLink` adds `icons`, and `ContentBlock` an open variant for other types |
| `session/cancel`, `$/cancel_request` | 9 | #137 | reads a whole message: `method`, and `params`' `sessionId` or `requestId` (kept as JSON text) | the same keys; `session/cancel`'s notification is named `CancelSessionNotification` |
| `session/request_permission` | 10 | #138 | writes the request: `sessionId`, `toolCall` (`toolCallId`, `title`, `name`, `kind`, `status`, `rawInput`), `options` (`optionId`, `name`, `kind`); reads the answer's `outcome`: `selected` and its `optionId`, or `cancelled` | the request names `title`, `description` and `subject` in place of `toolCall`; an outcome may be another kind |
