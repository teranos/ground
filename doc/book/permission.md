A permission answers a tool call before the prompt exists.

A block says which tools it speaks for and what to do with a match. Until the session axis it said nothing about $(I when) it applied, so a rule meant for one session mode applied in all of them. The rule that exposed this was asked for as a grant while accept edits was on. It had no spelling, so it went in unconditional, and manual mode stopped being consulted for every write across two trees. Ground lives in one of them, so the controls defining the permission system were themselves unprompted.

"goal: make sure ground is in control of it"

"goal: make sure i can reject Edits again like i used to be able to do"

"we have modes for rwx"

"which is one axis"

"and then there is the mode of edits or not"

permission.rw.pa { allow: ["/teranos/", "/sbvh-nl/"] }

$(EX_TOOLSEGMENT)

$(EX_SESSIONSEGMENT)

$(EX_MODEMATCHES)

"so manual is default"

$(EX_SESSIONMATCHES)

"a = acceptEdits and or auto"

"but you allow both though, in case you want to seprate behaviour to just auto, you can do so by typing auto"

"im not changing the spec, this is in addition to, i epect you to hold both in context"

## permission-namedPermPbt
Explicit name overrides inference

## permission-pathPermPbt
.env at project root

## permission-gitCPermPbt
"git -C /path log" should match "git log*" permission Direct git command — matches

## permission-fetchPermPbt
f mode implies trailing /* — bare domains match any path WebFetch with allowed domain — bare domain matches subpaths

## permission-compoundPermPbt
cd && git log — both sides allowed → allow

## permission-sessionPermPbt
`a` is both permissive modes.

## permission-agentPbt
Agent spawn A rule's ask ignores the session segment, so the mode is decided by agentPermission and not by the rule. Manual asks, carrying the reason the rule wrote.

## permission-agentDenyPbt
A deny holds in every mode; only the question is confined to manual.

## decide-combine
A permission's allow stands over a control's ask: the person granted it.

## project-projectWithChildrenInput
Project with children — scopes, controls, permissions all work inside

## proto-permInput

## proto-permFullInput
Permission with all three decision types

## proto-permMixedInput
Permissions coexist with controls in the same scope

## proto-permMultiInput
Multiple permissions in one scope

## proto-permTopLevelInput
Top-level permission (no scope) — defaults to path "/"

## proto-permModeInput
permission with mode
