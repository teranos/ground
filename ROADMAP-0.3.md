# libMCP 0.3 release gates

Status: development started, **not a completed 0.3 release**. Version constants
remain at 0.2.0 until release preparation. The protocol target remains the exact
2026-07-28 specification and SDK revisions in [spec/PINNED.json](spec/PINNED.json).
Changing that target requires a separate review of normative changes.

The goal is a C client Ground can embed as its harness grows. The library owns
protocol mechanics; Ground owns consent, model execution, credential persistence
and application policy. Optional features must remain explicit capabilities.

## First increment: request diagnostics

- [x] Expose HTTP status, libcurl transfer code and raw authentication challenges
  on each opaque request, without changing existing public struct layouts.
- [x] Keep diagnostics after response ownership is transferred with `take`;
  reset them for a new continuation round and free them on request destruction.
- [x] Retain repeated challenge fields in order, bound their aggregate size,
  and prevent interim response headers leaking into the final response.
- [x] Verify concurrent failures, transport failures, SSE completion,
  cancellation, continuation resets and static C linkage.

This increment does not parse authentication challenges or implement OAuth.
The client-wide diagnostic accessors remain compatible, but are unsuitable for
correlating concurrent transfers. Applications needing request diagnostics use
submit/poll/take. The initial challenge remains accessible by creating an HTTP
client without discovery and submitting `server/discover` explicitly.

## Remaining release work

| Workstream | Required behavior | Release evidence |
| --- | --- | --- |
| Runtime JSON Schema | Draft 2020-12 default dialect, schema validity checks and tool input/output plus elicitation validation. Explicit unsupported-dialect errors, bounded reference/composition evaluation, and no implicit network reference fetching. Select and document a validator/dependency strategy before claiming coverage. | Pinned official JSON Schema Test Suite with vocabulary-level results and explicit exclusions; malformed/recursive schemas; resource-limit failures; independent MCP tool and elicitation tests. |
| HTTP authorization | Protected-resource and authorization-server/OIDC discovery, issuer checks, PKCE/state, resource indicators, registration choices, token refresh and scope escalation under the pinned authorization requirements. Preserve host control of browser interaction and secrets. | An independent authorization server; wrong issuer/state/resource tests; discovery and refresh failures; endpoint isolation; bounded retries; proof that ambiguous tool outcomes are never automatically replayed. |
| HTTP compatibility | Explicitly supported earlier Streamable HTTP revisions, their initialization/session/GET rules, and an observable negotiated version. No downgrade after a recognized modern response. Decide separately whether deprecated HTTP+SSE belongs in the supported profile. | Independent versioned servers, expired sessions, disconnect/resumption behavior, cancellation and negative downgrade tests. No blanket legacy-HTTP claim. |
| Harness embedding | Define event-loop integration and deferred auth/elicitation handoffs with precise ownership, cancellation and deadline rules. Add request-owned validation diagnostics when a validator exists. | Installed static C and D `-betterC` callers; Ground integration tests; close/cancel/resume races exercised without callback reentry or leaked handles. |
| Adversarial verification | Bounded parsers, SSE and headers; allocation failures; long-running multiplexed requests; disconnect and cancellation cases. Reproducible Linux/macOS checks. | Fuzz targets and retained regression corpus, sanitizer runs, fault injection and platform CI. Publish limits and unexecuted checks rather than a completeness percentage. |

## Definition of done

Before tagging 0.3, expand [CONFORMANCE.md](CONFORMANCE.md) into a requirement
ledger: each applicable MUST in the supported profile points to implementation
and test evidence; each exclusion is explicit. Recommendations and optional
features are recorded separately. Coverage counts alone are not conformance.

The end-to-end acceptance scenario uses a protected independent MCP server:
authenticate, discover tools, reject invalid tool input locally, validate tool
output, finish an elicitation round, refresh authorization, recover a
subscription according to the negotiated transport, and cancel one concurrent
call without affecting another. Assert that no possibly executed tool is
silently replayed. Run the scenario through both C and Ground's D binding.

Full runtime schema validation and authorization are release gates, not implied
by this first PR. If either remains incomplete, retain development status or
explicitly revise the release scope before assigning a 0.3 tag.
