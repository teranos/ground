# a permission that ignores the mode it was asked to follow

A permission block answers the tool call before the prompt exists. It said
which tools it spoke for and what to do with a match, and nothing about when
it applied, so a rule meant for one session mode applied in all of them.

The rule that exposed this was asked for as a grant while accept edits was on.
It had no spelling, so it went in unconditional, and manual mode stopped being
consulted for every write across two trees. Ground lives in one of them, so
the controls defining the permission system were themselves unprompted.

"goal: make sure ground is in control of it"

"goal: make sure i can reject Edits again like i used to be able to do"

## Two axes on the dot

"we have modes for rwx"

"which is one axis"

"and then there is the mode of edits or not"

    permission.rw.pa {
      allow: ["/teranos/", "/sbvh-nl/"]
    }

Tools first, session modes second.

    r   Read, Glob, Grep, LSP        m   default
    f   WebFetch, WebSearch          p   plan
    w   Edit, Write, NotebookEdit    a   acceptEdits and auto
    x   Bash                         d   dontAsk
    m   MCP                          b   bypassPermissions
    a   Agent

Letters combine on both sides. An absent tool segment means Bash and nothing
else, which is what a bare `permission` block has always meant. An absent
session segment means every mode, which is what every block written before
today means, so nothing already on disk changes meaning.

## Manual is not a value

"so manual is default"

Claude Code reports `default` for the mode its UI calls Manual. The hooks
reference says so and says why: scripts that match `default` keep working.
The letter is `m` and the wire value is `default`, so only one spelling ever
reaches the evaluator.

## Why a is two modes

acceptEdits and auto are the two permissive ones, and a rule written for one
almost always means the other.

"a = acceptEdits and or auto"

When it does not, the full name is there.

    permission.w.a      write, under acceptEdits and auto
    permission.w.auto   write, under auto alone

"but you allow both though, in case you want to seprate behaviour to just auto, you can do so by typing auto"

"im not changing the spec, this is in addition to, i epect you to hold both in context"

## Telling a letter set from a name

Every character in `{m,p,a,d,b}` means a letter set. Anything else means a
mode name. Each of the six names carries a character outside that set:
default has `e`, plan has `l`, acceptEdits has `c`, auto has `u`, dontAsk has
`o`, bypassPermissions has `y`. The rule is total and needs no lookahead.

Tool letters `m` and `a` live in the first segment and session letters in the
second. They never meet.

## What a block holds

    allow:   patterns that resolve the call
    deny:    patterns that refuse it
    ask:     patterns that hand it to the user
    msg:     what the refusal says

deny wins over ask, ask wins over allow. A deny returns immediately.

`path:` is not a permission field. It comes from the enclosing scope.
