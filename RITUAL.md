A performance:

"AS A USER"
"I OPEN CAUDE CODE FROM ANYWHERE"
"I TELL CLAUDE"
"ground ritual tree"
"THE AGENT STARTS AND THE WORKTREE IS THERE AND THE AGENT DOES ITS THING THERE"

Rituals are performed in the grove.

```
rites green {
  built { eval: `make build` }
  tested { eval: `make test` }
}

rites shipped {
  sealed { eval: `test -z "$(git status --porcelain)"` }
  ci     { eval: `gh pr checks ${pr}`  catch: 1 }
}

project {
  path: "/sbvh-nl/grove"

  # Per performance (a full run of a ritual) default: 16
  max_goto: 16

  env {
    pr: "1"
  }

  ritual grove {
    # The CLAUDE.md this performer additionally knows. Appended to what the
    # agent already is, not a replacement for it.
    system: "You are a release engineer. You never merge, and you say which commit you are looking at."

    green
    shipped
  }
}
```

A project block can carry a name. Several can share a path, and the name is
what tells them apart, so a setting belongs to a block rather than to a path.
Keep a low `max_goto` on the one you run all day, and a named block for the run
where many jumps are fine.

```
project {
  path: "/sbvh-nl/grove"

  ritual sun {
    daylight
  }
}

project 64gotogrove {
  path: "/sbvh-nl/grove"

  max_goto: 64

  ritual sun {
    daylight
  }
}
```

The unnamed block wins by default. A named one is the explicit edge case, asked
for by name. Ground refuses anything it cannot resolve to a single candidate —
two equal candidates means ground cannot know which one you mean.

```
# Can also be just the ritual:
# in case it resolves to only a single ritual.
ground ritual [ritual_name]

# Just the project name,
# in case it has only a single ritual.
ground ritual [project_name]

# Ritual set explicitly,
# in case two or more rituals exist in project
ground ritual [project_name] [ritual_name_in_project]
```

One argument is looked up as both a ritual name and a project name. A word that
is both is two candidates, so it is refused, and typing both words resolves it.

Parked until it is ready. It kills a live box, and nothing yet runs a rite:

```
rites parity {
  params: [row]

  parity {
    eval: `make parity | grep "$row *YES *YES"`
    msg: "Goal is to make sure $row get's implemented for our parquet backend, see ADR-024: Parquet Storage backend."
  }
}

rites live {
  sealed { eval: `test -z "$(git status --porcelain)" && git diff --quiet @ @{u}` }
  ci     { eval: `gh pr checks 833` }
  built  {
    eval: `crowbar "cat /opt/qntx/BUILD_SHA" | grep -q "$(git rev-parse HEAD)"`
    msg: "The rite is checking for QNTX to be up to date on the box, "
  }
}

rites boxdeath {
  watcher  { eval: `curl -sf -X POST ${api}/api/watchers -H 'Content-Type: application/json' -d "{\"id\":\"probe-$(git rev-parse --short HEAD)\",\"name\":\"box survival probe\",\"predicates\":[\"probe:boxdeath\"],\"action_type\":\"plugin_execute\",\"action_data\":\"{}\",\"max_fires_per_second\":1,\"enabled\":true}"` }
  exists   { eval: `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD)`  catch: 22 }
  kill     { eval: `aws lightsail delete-instance --instance-name ${instance}` }
  gone     { eval: `make plan | grep "aws_lightsail_instance.api will be created"` }
  rebuild  { eval: `make apply` }
  answers  { eval: `curl -sf ${api}/api/plugins`  catch: [7, 22] }
  new      { eval: `crowbar "uptime -s" | grep -qv "$BEFORE"` }

  survived {
    eval:  `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD)`
    catch: 22
    goto:  parity
  }
}

project {
  path: "/q.sbvh.nl"

  env {
    api:      "https://api.q.sbvh.nl"
    instance: "q-api-box"
  }

  ritual boxsurvival {
    parity { row: "watchers" }
    live
    boxdeath
  }
}
```

The status line, rendered by ug:

```
watcher > exists > [kill] > gone > rebuild > answers > new
```

Brackets say where, colour says what.

| colour | state |
|---|---|
| green | passed |
| blinking red | halted |
| blinking blue | currently running |
| darker gray | pending, never ran |
| lighter gray | pending, ran before |

A held rite is the bracketed one in lighter gray: the position is there, the
command is not running, it ran before. The same rite blinking blue is the
command running right now. No glyph carries any of this.

This table is `perf.d`, where every line of it is a `static assert`. A glyph the
build has no colour for draws nothing rather than being guessed at as pending.

| done? | nr | thing | where | quotes | notes |
|---|---|---|---|---|---|
| ✓ | 1 | `rites <name> { }` top-level block | `proto.d` | "a ritual consists out of rites" | |
| ✓ | 2 | `params: [a, b]` list field | `proto.d` | "obviously i would want rites to be able to accept a parameter" | |
| ✓ | 3 | Rite block: `<name> { eval: msg: catch: goto: }` | `proto.d` | "1. make parity YES/NO ? 2. commit, push, 3. keep checking ci" | |
| ✓ | 4 | `catch:` as int or int list | `proto.d` | "its decided it will be called catch" | |
| ✓ | 5 | `ritual <name> { }` nested in `project` | `proto.d` | "why cant the ritual block be literally inside project" | |
| ✓ | 6 | Ritual body: bare name = reference | `proto.d` | — | |
| ✓ | 7 | Ritual body: `name { k: v }` = reference with values | `proto.d` | "how do i set the row param from the ritual" | |
| ✓ | 8 | CTFE structs + arrays | `proto.d`, `controls.d` | — | |
| ✓ | 9 | Rite names must be unique inside of the same rites{} block | CTFE assert | "within a rites block, rite should be unique, yes. but in my mental image, you can have a same name rite in multiple RITES" / "so you could have a rite called SLEEP1 in two rites blocks" / "Both blocks name FLIP1, SLEEP1, FLIP2, SLEEP2 / i dont see the problem here." / "i expect to be able / using vim / press y12[DOWN_ARROW][UP_ARROW]p / change the name of only the rites block / yyp on line 18, a 2 to toss" / "jumping to other rites blocks is NOT inscope for this branch" | "ok" |
| ✓ | 10 | `goto` names a rite that exists | CTFE assert | — | |
| ✓ | 11 | Every declared `param` supplied | CTFE assert | — | |
| ✓ | 12 | Referenced group exists | CTFE assert | — | |
| ✓ | 13 | Run under `set -euo pipefail` | `rite.d` | "wouldnt the pipefail need to be present essentially everywhere?" | |
| ✓ | 14 | Params into the command's environment | `rite.d` | — | |
| ✓ | 15 | `${var}` from project env | `envSubst` | "env block right?" | |
| ✓ | 16 | Classify exit: pass / caught / halt | `rite.d` | "if its non 0/1 we should just stop and halt the agent" | |
| ✓ | 17 | Position — which ritual, which rite | `ritual.d` | "see where we are INSIDE of the ritual" | |
| ✓ | 18 | `goto` moves position | `ritual.d` | "i think i want goto, not else, goto seems more honest for what it is" | |
| ✓ | 19 | A rite that is not met throws the mic back | `stop.d` | "so catch means hold, until true" / "the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop" | |
| x | 74 | The agent carries on when the Stop goes back | — | — | |
| ✓ | 20 | Halt with code + output on screen | `stop.d`, collet | "leave on the screen the non 0 non 1 was and its message" | |
| ✓ | 21 | The current rite runs and the position moves | `ritual.d` | "it takes a super long time before an agent will reach Stop" | |
| ✓ | 22 | The agent knows where it is, what happened, and what the author said | integration | "msg i also want as anotgher optional one" | "Performing ritual willow, rite 5 of 10: MANGOx1. It is met when this exits 1: grep -qxF ... . Take the MANGO out of WILLOW.md." / "<RITE> passed." |
| ✓ | 23 | Attest each rite's outcome | `ritual.d` | — | |
| ✓ | 24 | Name a ritual | `ritual.d` | "i want to specify a ritual" | |
| ✓ | 25 | Abort a ritual | command | "it ends when it ends, not because i ran ritual stop" / "ground should take responsibility" | "claude -w <id>" |
| D | 26 | List rituals for this path | command | "ask about rituals for where we are now" | |
| D | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual" | |
| ✓ | 28 | The renderer knows where a performance is | collet, `ug/sql.d` | — | two renderers now, from one row, sharing no code |

Three rows above carry a quote, so they cannot be edited without restating it,
and what changed about them is here instead.

Row 20 — ug draws the halted rite, in blinking red. The exit code and the output
behind it are still collet's alone.

Row 73 — the tally rides inside the brackets in ug as well, in yellow. A frozen
count is the stall and a climbing one is the ping-pong, which is legible at one
frame a second.

Row 98 — this turned out to be load-bearing well outside its own row. Because
sed, awk and perl are handed the file instead of being run, none of them can
write one, which is most of why a control that rewrites what reaches a file only
had to cover Write and Edit.

Not in the example above, and therefore not implementable from it:

| | nr | thing | quotes | |
|---|---|---|---|---|
| ✓ | 30 | `pass:` | "i meant, from 0 to 1, the gate is from 0 to 1" | |
| x | 31 | `$AUTH` | — | |
| x | 49 | — | — | |
| x | 69 | — | — | |
| x | 32 | Carrying a value between rites | — | |
| ✓ | 43 | Terminal state | "it ends when it ends, not because i ran ritual stop" | |
| ✓ | 44 | Colour for a ritual that ended | "green is passed" / "blinking red is halted" | |
| ✓ | 45 | The ritual keeps moving while the agent works | "it takes a super long time before an agent will reach Stop" | |
| ✓ | 71 | A rite holds the mic for at most 2 seconds | "a rite can only take hostage for at most 2 sec" / "the white state color should be occupied for at most 2 sec" / "ground, or the rite should have no reason to keep holding the mic for longer than 2s" | |
| ✓ | 73 | The mic going back is counted, and the count is on both surfaces | "let's show a counter" / "[NEVERx3]" / "if there is back and forward, it would mean the counter increments no?" | |
| x | 80 | A performance is a row in agent view | — | |
| ✓ | 82a | Every delivery names its receiver instead of grabbing a session | "THERE ARE FOR RECEIVERS" / "PARENT: HUMAN / HOSTLLM" / "CHILD : RITE  / AGENTLLM" then corrected to "WE NEED TO SAY THAT RITUAL IS THE RECEIVER, NOT RITE, RITE IS JUST A PIECE OF THE RITUAL, RITUAL DRIVES THE CHAT VIA RITES" | |
| x | 82b | — | — | "PARENT: HUMAN / HOSTLLM" |
| ✓ | 82c | The agent's first two sentences are seen by both human and host | "AGENTLLM STOP OUTPUT FIRST TWO SENTENCES OF LAST MESSAGE NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM" | |
| ✓ | 83 | The operator reads a rite's verdict without pressing anything | "i need to see it in the transcript without me having to press ctrl-o" / "i want MessageDisplay and displayContent" | |
| ✓ | 84 | A line ground injects cannot pass for the assistant's own words | "it looks the same as your text, its as if you said it, but its coming from a rite of a ritual no?" / "is it possible to change the color" / "  ░░▒▓▏ritual" / "    ░░▏rite" | |
| x | 85 | An agent that cannot act says so in its own form | — | |
| ✓ | 87 | CI holds the mic while a run is in flight | "there needs to be a way for the ball to land in the court of ci" / "and ci keeps holding the mic in this case" / "it keeps holding the mic until ci has an outcome" / "and the outcome is what is spoken back into the mic to both the agent and parent" | |
| ✓ | 88 | A rite can speak, and what it says reaches both sides | "mic makes sure it also gets to us" / "if it goes through the mic, it means both the parent and the child agent would be receivers" / "nothing / msg / mic / msg+mic are all possible" | "CHERRY passed · The CHERRY rite is looking at WILLOW.md. · I plucked a CHERRY." |
| ✓ | 90a | A dispatched rite is over when the job is sent | "in the more sophisticated version, the ci rite happens while the agent continues onto the next rite without needing to wait for ci to finish" | "<owner>/<repo> <workflow>" |
| ✓ | 90b | A rites block does not finish while a dispatch it made is outstanding, and the next block does not start | "a rites block will not complete until each of its rite dispatch has been completed" / "in my mental model rites toss is over when both dispatches are over" / "dispatch getting a result gates the RITES block" / "RITE_B does not start until RITE_A has completely finished" / "a RITUAL is not finished until each of its rites blocks finished" / "a dispatch gates a rites block from finishing until it results something, a result" | "ci passing would still gate the end of a ritual (read ritual not rite)" |
| | 90c | A run's result reaches the parent when that run concludes | "failure needs to prop to parent immediately when i happens" / "if FLIP1 ci is red, parent should know about it on T15 and the FLIP2 ci red would surface on T2 + T15" | "90c is only halfish done, because we cant do better on a --bg agent" |
| x | 90d | The mic is taken from the agent and CI speaks, now, whether or not it is looking | — | "CI takes the mic for one announcement and hands it straight back" |
| ✓ | 97 | A rite may not write its own exit code | "ground uses those exit codes, becaue not all failures are the same failure" / "\|\| TRUE \|\| EXIT 1 \|\| EXIT 22 \|\| EXIT WHATEVER SHOUDL NOT BE A THING IN GROUND" / "i dont want \|\| true ANYWHERE" / "NOT IN GROVE NOT IN SUN NOT IN MOON NOT ANYWHERE" | |
| ✓ | 98 | A command reaching for a file gets the file | "you can use curl instead of gh+jq" is elsewhere; this is "substitute_for_read" | "sed" / "awk" / "perl" / "sed …" |
| ✓ | 90e | A tool that could not run has not answered anything | "this kind of shit, the quota error, it should not even try to continue the entire thing should just halt" / "+70% GLOBALQUOTA USE MEANS ADDING 10s BEFORE EVERY gh TOOL CALL" | "not yet" |
| ✓ | 89 | Words belong to the hold that produced them | "make the message a property of the mic" | |
| x | 93 | A ritual carries the agent's system prompt | — | |
| ✓ | 94 | `run:` — a rite does a thing before it asks anything | "I want gh invocations to be more explicit, and not assumed to be ran by the agent" / "everything gh exposes should be easily accesible from a rite, from any rite" / "i am not actually saying, use eval for it. i say use a different rite that runs a tool unconditionally, like gh, its subcommands and parameters" / "run: makes sense, i pairs well with eval:" / "let's say `run:` is unconditional, and always happens at the beginning of the rite, before eval would happen, and before the agent get's a chance to get the mic" / "a `run:` happens regardless, an `eval:` returning false, would make you redo the rite yes, but a false `eval:` doesnt mean the `run:` would occur again" / "`goto:` does trigger `run:`" / "well, it would be the rite holding it no? so that's Ground in this case" / "making a PR at the end of each DONE was a mistake" / "i want NO pr to be created if i did not set it" | "a failed run: is critical enough for us not to want to continue and return the error point blanc , keep the mic" |
| ✓ | 95 | A control performs a ritual | "so this would not be a ritual in the sense we are doing it right now where we invoke it by ground cmd" / "it performs ritual" / "this is actually the thing that would make it a total killer feature to me, because it literally is a mechanical ritual in all honesty" / "i want an agent to see it through and monitor it" / "it runs in empty space" / "dont make it investigate, its sole duty is to report back as honestly and factually as possible with zero temperature" / "i want anything else than success to report back no matter what" | "name" / "if its non 0/1 we should just stop and halt the agent" / "empty" / "these stay alive" |
| ✓ | 96 | A performance that ends ends its agent | "HOW IS THERE NOT A REAL NATIVE TRUE WAY TO KILL THE BG SESSION" / "WHY IS A STRAIGHT KILL THE ANSWER" / "nothing should be running in terms of rituals or their agents" | |
| | 92 | A rite and a control compose in the same block | "you forgot that i wasnt happy about rite's cmd being essentially a completely different thing from the control's cmd" / "Imagine i wan't to mix Rite and Control in the same Rites block" / "i want the machinery to be interchangable and composable" / "to me its eval" / "because its evaluated, and its up to the writer of the rite to change default eval behaviour through to: goto: pass: etc" | |
| | 79 | One thing advances a position | — mine, from reading the callers | "the position only advances when a turn ends, which for a working agent can be never" |
| x | 75 | A ritual is carried by an Agent, not a detached process | — | |
| x | 76 | — | — | |
| | 72 | A performance cannot outlive one compaction window | "i think a ritual cant run longer than one compaction window" / "it a high upper bound" | "did a PreCompact happen in this session after this" |
| x | 46 | A rite's verdict reaches the agent, unasked | "isnt it the perfect mechanism to fiannly use for intterupt on rite ?" / "to: agent doesnt make sense" / "no user facign i would say" / "not part of the api" / "doesnt make sense, because why would you have to specify it ? its expected, everything comes abck to causer" / "i am a user, not an agent" | |
| D | 70 | Ground's trace is on your screen as it happens | "the first two sentences of what happened in last_assistent_message pre-Stop inside of any rite as a Notification in the parent session" / "it seems like it would increase the clarity i have into ground by an absolute incredible amount" / "i believe my temporal awareness is much greater than yours" | |
| ✓ | 47 | A CI check is a rite like any other | — | |
| ✓ | 52 | A performance has its own worktree and branch | "each ritual perfomance occurs in separate named branches" | |
| x | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved" | |
| ✓ | 54 | A performance is identified by itself | "the name of the branch is not something to key on" | |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | |
| ✓ | 59 | Ground removes the tree it made | "the reason you need to remove them by hand is because?" | |
| ✓ | 60 | Ground says it made one | "I dont like that its siltent" | |
| x | 61 | The performance ends in a pull request | "did it submit a pr at the end as well?" | |
| ✓ | 62 | A `goto` cycle is bounded | "let bound it to max 16 and make it say clearly that the goto can only be invoked at most 16 times in a single ritual" | |
| x | 63 | Ground commits, not the agent | "n, i dont trust the agent with it" then "we want to get rid of the auto commit" / "make commit be done by run:" / "the ritual could make itself complete itself by asking the agent to commit while its in ask" | |

Known defects in the example:

| | nr | thing | |
|---|---|---|---|
| D | 33 | `goto: parity` | |
| D | 34 | `built` | |
| D | 35 | `catch: 22` on `survived` | |
| D | 36 | `survived` measures the API | |

Inherited by anything that rides the watcher:

| | nr | thing | |
|---|---|---|---|
| | 48 | `claimSession` is not session-scoped | |

One performance, start to finish. Columns are what fires, in order.

| | `ground ritual` | `WorktreeCreate` | `SubagentStart` | `SessionStart` | `CwdChanged` | `UserPromptSubmit` | `PreToolUse` | `PostToolUse` | watcher | `Stop` | `SubagentStop` | `SessionEnd` | |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **position** | written | path bound | — | read | re-resolved | read | read | — | stepped | read | read | decided | |
| **worktree** | — | created, path from stdout | entered | — | entered or left | — | — | — | — | — | — | — | |
| **agent knows** | — | — | given the ritual | told the rite | — | told the rite | — | — | told the verdict | told by the block | — | — | |
| **consent** | — | — | — | — | — | — | allowed while live | — | — | — | — | — | |
| **can refuse** | — | yes, creation fails | no | no | no | no | yes | yes | — | yes | yes, exit 2 | no | |

The two halves are visible in the third row. Everything in **agent knows** left of the watcher is carrying; everything right of it is interrupting. Only two columns fill it today, and neither is built.

Claude Code hook events, in the context of this feature:

| | nr | thing | quotes | |
|---|---|---|---|---|
| ✓ | 37 | `SubagentStart` | "you COULD if you wanted to run an agent like that, equiped with ritual" | |
| ✓ | 38 | `SubagentStop` | same | |
| D | 39 | `TaskCreated` | — | |
| D | 40 | `TaskCompleted` | — | |
| x | 42 | `Notification` | "Notification is one that is on my wish list actually" | "Impossible to reason about, or have a real conversation about it with CLaude Code without it confabulating and inventing and not working with me. In my session, there were multiple instances of me doing an easy ask, If Claude Code sends notifications, and this event matches on it. do it now, you are Claude Code, you can make it happen. The reality is it cant't make it happen at will on command. The basic thing required to develop this thing, i havent yet figured out how to do it, further research required before we can make definitive statements about it, never believe anything Claude is inferring from this, always consult Antropic docs as first source." |
| ✓ | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | |
| ✓ | 51 | `WorktreeRemove` | — | |
| | 56 | `CwdChanged` | — | |
| | 57 | `SessionEnd` | — | |
| ✓ | 58 | `SessionStart` | — | |
