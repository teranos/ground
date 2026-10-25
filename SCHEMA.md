# Runtime schemas and checked tools

`mcp_schema_compile` compiles a JSON Schema into an opaque reusable handle;
`mcp_schema_validate` checks a JSON instance without coercing it. Destroy the
handle with `mcp_schema_destroy`. Standalone instances are passed directly to
the validator; MCP tool definitions and protocol values pass through json-c,
with its existing numeric representation limits.

The default dialect is JSON Schema 2020-12. The standard draft-04, draft-06,
draft-07 and 2019-09 dialect URIs are also accepted by the backend. Only 2020-12
has been exercised through the full standard-keyword fixture set here. Unknown
and custom dialect URIs are rejected with `MCP_UNSUPPORTED`, including custom
metaschemas supplied in the resource registry. Unknown required vocabularies
are rejected. Optional unknown keywords are annotations. In 2020-12, `format`
is an annotation, not an assertion. This is not a claim of support for every
custom vocabulary or optional JSON Schema test profile.

Schemas are checked against their standard metaschema before compilation.
Local references, recursive/dynamic references, applicators, and unevaluated
keywords are delegated to the pinned Corvus engine. Explicit external documents
can be supplied as `resources_json`, an object mapping absolute document URIs
to schema values. The registry is borrowed only during compilation. Referenced
external documents are checked against standard metaschemas. Missing documents
fail compilation; there is no HTTP/file resolver or implicit network access.

## Checked call lifecycle

1. Compile each complete tool definition from `tools/list` with `mcp_tool_compile`.
   Keep its server identity in the host's catalog; the handle itself has no client
   identity. Refresh handles when the server changes its definitions.
2. Call `mcp_tool_submit(client, tool, arguments, timeout_ms, &request, &error)`.
   Return `MCP_OK` means a request handle exists, possibly already terminal.
   Inspect `mcp_request_status`: schema-invalid arguments complete locally with
   `MCP_VALIDATION_ERROR` and send no request bytes. Malformed argument JSON or
   a non-object argument is rejected before creating a handle.
3. Drive `mcp_client_poll` normally. The request retains its own output-schema
   reference, so destroying the tool after submission is safe. Concurrent requests
   retain independent diagnostics. The original deadline includes input validation
   after handle creation; an elapsed deadline prevents dispatch. Validation is
   synchronous and cannot be preempted by polling.
4. A successful result with an output schema must contain `structuredContent`,
   which may be any JSON value. It is validated before reporting success.
   `isError:true` remains `MCP_TOOL_ERROR` and does not require success-shaped output.
   Remote JSON-RPC errors retain their existing status. A schema failure does not
   break the connection or trigger an automatic retry.
5. Inspect `mcp_request_validation_json` for borrowed JSON diagnostics. Use
   `mcp_request_take` for the original response, including on failure. Taking a
   response does not clear validation diagnostics; resume, destroy or client close
   invalidates the borrowed diagnostic pointer. Resume retains the output schema
   and validates only the eventual complete result.
6. `mcp_tool_call` is the synchronous convenience form. Pass **distinct, zeroed**
   response/report objects and free both with `mcp_response_free`. It returns
   `MCP_INPUT_REQUIRED` without running host handlers; use the submit/resume API
   to retain a multi-round request. Ground's companion patch still uses this
   synchronous path and does not add an elicitation UI or ACP cancellation pump.

## Error model and limits

`MCP_SCHEMA_ERROR` means the schema could not be compiled or is not metaschema
valid. `MCP_VALIDATION_ERROR` means the instance failed an evaluated constraint.
`MCP_VALIDATION_LIMIT` means evaluation hit an engine depth/pattern limit and
must not be interpreted as invalid data. Engine reports use `valid:null`.

Reports contain `phase` (`schema`, `instance`, `input`, `output`), `valid`, and
an `errors` array with instance/schema/evaluation locations and engine messages.
Engine failures retain a code, message and offset. Early argument/dialect errors
may have only the ordinary typed `mcp_error`, with no report. Failure to allocate
or fit a report is returned as its own error; reports are never silently truncated.
The original peer response remains independently available.

Default limits are 1 MiB each for schema, resource registry, instance and report,
128 engine recursion depth, and 50 ms per regex match. All option limits must be
positive. The C JSON parser additionally bounds schema nesting to 128. Engine
recursion depth protects in-place reference cycles; it is not a universal instance
nesting or instruction budget. Report limits apply to the serialized report;
the backend collector can allocate before this check. Regex limits are per match,
not a total validation deadline. These controls are **not a hard CPU/memory sandbox**.
Rust allocation failure may abort; the backend does not guarantee typed OOM for
all internal allocations. Use process isolation for hostile unbounded workloads.

## Minimal C use

```c
mcp_schema *schema = NULL;
mcp_response report = {0};
mcp_error error = {0};
mcp_status status = mcp_schema_compile(
    "{\"type\":\"integer\",\"minimum\":1}", NULL, &schema, &report, &error);
if (status == MCP_OK)
    status = mcp_schema_validate(schema, "0", &report, &error);
/* status == MCP_VALIDATION_ERROR; report.json describes the failed minimum. */
mcp_response_free(&report);
mcp_schema_destroy(schema);
```
