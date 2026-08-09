# ERROR

## ERROR AXIOM

An **ERROR** is a first-class primitive. A typed value that crosses
every layer of the system unchanged. an `Error` is the entity
any layer emits when something goes wrong.

*The ERROR is a sacred first-class citizen, never collapsed, dropped,
swallowed or suppressed; they land in front of the user, contextually,
at the exact point of interaction.*

*An ERROR must be true, not merely delivered. It states what the emitting
code measured, never a cause inferred from a proxy. A false ERROR spends
the user's attention and teaches them to discount the channel — it costs
the axiom exactly what a swallowed one does.*

Conformance is therefore two audits, not one: that nothing is swallowed,
and that every claim an ERROR makes is answerable from what its own code
observed.

[source/errors.d](source/errors.d)

## Per file

| file | nothing swallowed | no cause inferred from a proxy |
|---|---|---|
| `source/hooks.d` | not yet | not run |
| `source/strop.d` | not yet | not run |
| `source/controls.d` | not yet | not run |
| `source/control_handlers.d` | not yet | not run |
| `source/deferred.d` | not yet | not run |
| `source/immediate.d` | not yet | not run |
| `source/watch.d` | not yet | not run |
| `source/exec.d` | ✓ | not run |
| `source/errors.d` | ✓ | not run |

| | nr | thing | words | notes |
|---|---|---|---|---|
| ✓ | e41 | `StopFailure` | "I still want to better understand before i can say a thing about it" | Cannot block — the docs say "Output and exit code are ignored". This row used to claim `error_type` and `error_message`; neither field exists. Recorded raw by `stopfailure.d` and measured 2026-08-08 by turning the wifi off: the fields are `session_id`, `transcript_path`, `cwd`, `prompt_id`, `effort`, `hook_event_name`, `error`, `last_assistant_message`, and `agent_id` only sometimes. `error` is the matcher value; a dead network arrives as `server_error`, not `unknown`. `last_assistant_message` already holds the words to speak — "API Error: Unable to connect to API (ENOTFOUND)". It fires per session and independently in each: one wifi outage produced five records across three unrelated sessions. `agent_id` is present only when the failing turn belongs to a sidechain, so one session wrote two records in the same second, one with an `agent_id` and one without, and a third ten seconds later with a different one — without reading it, a subagent's outage is attributed to the performance |
| D | e91 | An API error holds the mic and says its own name | "it is the error code that is holding the mic" / "and it is angry" / "the mic needs to speak its exact error" / "you always get one of these with the ZALGO retained" / "rate limit just means retry not now but in incremental backoff" / "oh, its api error, so its not even the agent dying per se. its claude the api dying" | `StopFailure` fires when the turn ends due to an API error. Output and exit code are ignored. The agent is not dead — process and worktree intact, it resumes when the API answers. Without it there is no `Stop`, so the row reads `mic=agent` while nothing is there. The holder is the error itself, the first holder that is a condition rather than a party. It says what the API said: summarising would be ground speaking as the error. `rate_limit`, `overloaded`, `server_error` keep the mic on incremental backoff; `authentication_failed`, `oauth_org_not_allowed`, `billing_error`, `model_not_found`, `invalid_request` hand it to `human`; `max_output_tokens` is where a ritual ends; `unknown` halts. The ten names are stored literally in `apierror.d`. Built: the recorder and the names. Not built: nothing constructs an `ApiError`, so the mic is never handed over |
