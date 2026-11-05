A control is a named rule and a message: what it matches on, and what the operator reads at the moment it matches. The event it declares is the set that collects it, so a control nobody collects never runs, however well it matches.

TODO A sand that is there and does not load is said, and the hook runs on the floor alone: the controls, the models block and the rituals only that sand carries are gone until it loads again. Whether a hook refuses instead is undecided.

## proto-cmdInput
A control matches a command and answers with a message. omit takes a flag back out of the command it matched; bg says the work runs detached and tmo says how long it may take.

## proto-stopRepeatInput
A trigger is a phrase the answer is watched for. Written as a repeated key, each one adds to the same list rather than replacing it.

## proto-deferInput
Delivery can be put off: one handler says when the message is due, another writes what it says. A line opening with # is a comment.

## proto-checkInput
A check handler is asked, when the session opens, whether what the control has to say is still true.

## proto-defaultsInput
Left out is not the same as empty. A scope naming no path stands everywhere, and one naming no decision carries none of its own.

## proto-stopListInput
The same list of triggers, written as a list. Six phrases under one control, which is the form to reach for once a repeated key stops reading as one.

## proto-stopDeliverInput
Test Stop with deliver_handler + interval (upstream-briefing pattern)

## proto-listInput
Minimal list parse test

## proto-ctrlTopLevelInput
Top-level control (no scope) — wraps in scope with path "/"

## proto-ptuFileInput

## proto-modeInput

## proto-editedSimpleInput
Simple edited (no !) — existence check

## proto-upListInput

## proto-cmdScopeInput

## proto-multiEventInput
Single scope in parsed output, but matches both events

## proto-mcpInput

## proto-cmdArrayInput

## proto-contentInput

## proto-scopeCmdContentInput
Scope-level cmd with control-level content — cmd stays on scope, not inherited by control

## proto-handlerParamsInput

## proto-handlerParamsMultiInput
Multiple pairs — up to 8.

## proto-handlerParamsAbsentInput
No block → paramCount == 0.

## project-projectWithControlInput
Project with control directly (no scope wrapper)

## project-pathListInput
Scope with path list — OR matching

## project-singlePathInput
Scope with single path — still works

## proto_exec-execWithEnvInput
Control-level env { } block — the pbt-declarative way to configure the exec child. Same block shape as `project { env { … } }`, but attached to a control. Reads at exec-fire time; the child sees these as env vars.

## proto_ritual-projectControlInput
A control in a project that names a repo belongs to that repo. Firing is the project's property, so the control carries it and no path decides.

## proto_ritual-plainControlInput
A control in a project with no repo named is unchanged: it fires wherever it did before, and carries no repo of its own.

## playbill-sqlite3_open

## binary-contentInput
A repo whose content IS the binaries declares itself. Everywhere else the gate stands, including when no pbt says anything at all.

## binary-silentInput
Fails closed. An empty control set is not an exemption, it is the absence of one, so deleting the pbt above turns the gate back on rather than off.

## control_handlers-modelExempt
The pbt names the word; the session's model as ug wrote it is matched on it.

## exec-floorOnly

## messagedisplay-spoken

## messagedisplay-CI_GUTTER

## messagedisplay-RITE_GUTTER

## posttooluse-sessionMatches

## posttooluse-sessionMatches-2

## public-publicInput
A scope says it stands in public repositories. Not a path: a fact ground establishes about the repository the write goes into.

## public-quietInput
A scope that says nothing about it stands everywhere, as before.

## rewrite_scope-keepInput

## rewrite_scope-keepOneInput

## stop-timingInput

## stop-quietInput
A scope that says nothing about timing leaves it off, rather than picking a default up from somewhere.
