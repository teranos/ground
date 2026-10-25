# Ground companion for libmcp 0.4.0-dev

This patch follows Ground's landed ACP model/tool loop. Each server catalog now
owns compiled tool definitions alongside the original paginated response data.
Discovery fails explicitly on invalid/unsupported schemas or duplicate tool names;
partially opened servers are rolled back through the existing cleanup path.
A dispatch must match a known server and compiled tool. Invalid model arguments
never execute. Invalid successful structured output returns a typed failure with
the original response and a separate validation report. ACP tool updates and model
history include that report. A server `isError` result remains a tool error.

The D ABI adds all schema/checked-call functions and the 0.3 request diagnostics.
Existing public C layouts are unchanged; `mcp/abi.d` now checks 30 C/D size/offset
values. The static-link flags include the embedded validator's platform libraries.

Use the libmcp source included beside this checkout; the existing `flake.lock`
intentionally still names the published upstream dependency. From the package root:

```sh
nix develop path:./ground --override-input libmcp path:./libmcp \
  --no-write-lock-file --command sh -c 'cd ground && make test-mcp'
```

After libmcp lands, update the actual libmcp flake input to that published revision
and commit the resulting lockfile. Do not merge a lockfile pointing at a local path.
The package does not invent a future upstream commit or publish either repository.

`mcp/test_checked.py` drives a real stdio fixture through Ground's D dispatch and
verifies its execution log: an invalid argument has zero executions, a corrected
call succeeds, invalid structured output retains the response, and close succeeds.
`mcp/test_ground.py` covers the actual ACP executable's session/server ownership.
The new ACP validation-to-model-history branch is compiled but does not yet have
an end-to-end model-provider fixture dedicated to invalid output.

Remaining harness work is explicit: the turn loop is synchronous; this patch does
not implement `session/cancel`, asynchronous model calls, MRTR continuation UI,
form/URL elicitation or runtime catalog refresh. Those must preserve request and
schema lifetimes and route cancellation while a turn is still active.
