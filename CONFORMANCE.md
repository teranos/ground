# libMCP coverage (0.3 development)

Target: MCP **2026-07-28**, specification commit
`dae694f61a31f7a3ec2af3aff709e11f70f61e48`. This is an implementation coverage
record, not certification or a percentage score. “Implemented” means the
behavior and tests named here exist; it does not imply exhaustive testing of
all adversarial inputs, platforms or optional extensions.

| Area | Implementation | Evidence / boundary |
| --- | --- | --- |
| JSON-RPC framing | Implemented | Bounded newline stdio frames; UTF-8/RFC 8259 checks; IDs and error/result exclusivity; wire error payload retained. `test_mcp.py`, `tests/json.c`. |
| Modern versioning | Implemented | Discovery and required per-request metadata; recognized modern errors prohibit downgrade. `test_mcp.py`, official SDK. |
| Legacy lifecycle | Implemented on stdio | Four supported legacy versions, initialized notification, ping and host feature replies. `test_mcp.py`, `test_features.py`, SDK. |
| Concurrent requests | Implemented | Poll-driven, out-of-order completion and independent deadlines; no libMCP background thread. `test_runtime.py`; D integration lives in Ground. |
| Cancellation | Implemented | Stdio cancellation notifications; queued unsent requests removed; HTTP transfer/stream closed; stale responses ignored using monotonic issued IDs. `test_runtime.py`, `test_http.py`. Legacy initialize is not cancelled on wire. |
| Progress | Implemented | Unique active string/integer tokens; finite numeric and increasing progress; float values and origin correlation. `test_runtime.py`. |
| Multi-round input | Implemented | Three permitted originating methods; declared capability checks; exact opaque state, fresh IDs, scoped inputs, original deadline; explicit resume or host callbacks. `test_runtime.py`; D integration lives in Ground. |
| Roots | Host callback | Opt-in modern compatibility/MRTR and legacy requests; host supplies roots and enforces URI/access policy. Legacy callback test. Deprecated in modern target. |
| Sampling | Host callback | Capability-gated request dispatch, including tools capability; host runs models and validates results. Legacy callback test. Deprecated in modern target. |
| Elicitation | Host callback | Explicit form/URL capabilities, MRTR and legacy dispatch; host owns UI, consent and content validation. Form MRTR and legacy tests; URL flow is not independently integration-tested. |
| Tools | Implemented wire API | Paged list, call, separate tool/JSON-RPC/input-required errors, content passed through intact. Deterministic and official SDK tests. Opt-in compiled input/output validation is implemented; see SCHEMA.md. Raw calls remain unchecked. |
| Resources and templates | Implemented wire API | List/read/templates, cursors and MRTR envelope support. Resource read/list tests; generic raw API preserves embedded text/blob data. Template helper lacks independent SDK coverage. |
| Prompts | Implemented wire API | List/get, cursors and MRTR envelope support. Deterministic list/get tests. |
| Completion | Implemented wire API | Capability-gated `completion/complete`; host owns argument/context construction. Helper coverage is not exhaustive. |
| Modern subscriptions | Implemented | Correlated acknowledgment, acknowledged subset, URI filtering, parallel requests, indefinite acknowledged lifetime and cancellation. Stdio and chunked HTTP tests. No reconnect/resubscribe automation. |
| Legacy resource subscriptions and logging | Implemented wire helpers | `resources/subscribe`, `resources/unsubscribe`, `logging/setLevel`; disabled for modern peers, which use subscription requests and per-request metadata. No independent legacy subscription server test. |
| Modern HTTP JSON/SSE | Implemented | POST, both Accept types, fragmented UTF-8 SSE/CRLF/comments/BOM, request correlation, response completion and cancellation. Loopback tests and official SDK JSON/SSE. |
| HTTP MCP headers | Implemented | Version/method/name; sentinel Base64; static primitive `Mcp-Param-*` mirroring; invalid tool exclusion in filtered catalog. Raw wire response intentionally retained separately. HeaderMismatch refresh/retry is host-owned. |
| HTTP authentication boundary | Implemented | Caller-provided endpoint bearer, request-owned status/transport code/challenge and raw body, explicit replacement, TLS verification and no redirects. Concurrency, repeated challenge fields, aggregate limits and continuation resets: `test_http.py`. Tokens never persisted or forwarded to redirects. No actual OAuth authorization server test. |
| OAuth authorization | **Absent** | Protected-resource metadata, AS/OIDC discovery, issuer validation, resource indicators, PKCE, state, registration and token storage are host-owned. Not an OAuth-conformant standalone client. |
| JSON Schema 2020-12 | Standard-dialect runtime profile | Pinned Corvus C ABI, metaschema checks, references and unevaluated keywords; 1,297 standard-keyword cases pass. Two custom-dialect groups explicitly rejected; optional fixtures not run. See SCHEMA.md for limits. Elicitation integration remains absent. |
| Legacy HTTP and HTTP+SSE | **Absent** | Modern-only HTTP; no old session/GET transport or automatic HTTP-era fallback. |
| Extensions | **Absent** | No task extension, experimental features or automatic caching policy. Raw methods and metadata are available for host-managed extensions. |
| ABI and packaging | Implemented | C11 static/shared, pkg-config, D `-betterC`, 30 C/D layout comparisons, static C and live D callers. Linux tested here; macOS still requires CI execution. |

The runtime does not yet validate every method-specific result against the full
schema. Callbacks must return promptly; the library can reject a continuation
after a slow callback but cannot preempt host code. The wire error response is
retained byte-for-byte; on a synchronous host-handler error the supplied handler
JSON is returned instead, including its data. libcurl transfer codes and HTTP
status are exposed separately from OS errno.

Bounded resources: one configurable limit per incoming/outgoing frame and SSE
event, a handle limit, bounded work per stdio poll, and constant-memory stale-response detection. Progress after cancellation is a peer protocol violation. HTTP response
headers are additionally subject to libcurl's own header limits. Pending handles
are owned by the client and invalidated on client close.
