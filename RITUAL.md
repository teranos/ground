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

    # The model this performer runs on. Rules are asked before any plain model,
    # from this ritual out to its project and the top level. Nothing set anywhere,
    # it runs on the model of the session that performed it.
    models {
      model: sonnet
      seven_day: ">80"   model: haiku
    }

    green
    shipped
  }
}
```

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

| | nr | thing | quotes | |
|---|---|---|---|---|
| | 90c | A run's result reaches the parent when that run concludes | "failure needs to prop to parent immediately when i happens" / "if FLIP1 ci is red, parent should know about it on T15 and the FLIP2 ci red would surface on T2 + T15" | "90c is only halfish done, because we cant do better on a --bg agent" |
| x | 90d | The mic is taken from the agent and CI speaks, now, whether or not it is looking | — | "CI takes the mic for one announcement and hands it straight back" |
| ✓ | 97 | A rite may not write its own exit code | "ground uses those exit codes, becaue not all failures are the same failure" / "\|\| TRUE \|\| EXIT 1 \|\| EXIT 22 \|\| EXIT WHATEVER SHOUDL NOT BE A THING IN GROUND" / "i dont want \|\| true ANYWHERE" / "NOT IN GROVE NOT IN SUN NOT IN MOON NOT ANYWHERE" | |
| ✓ | 98 | A command reaching for a file gets the file | "you can use curl instead of gh+jq" is elsewhere; this is "substitute_for_read" | "sed" / "awk" / "perl" / "sed …" |
| ✓ | 90f | A dispatch lands on the target's own default branch, asked of the repo rather than guessed | — | ref=master sent QNTX-App, whose branch is main, a 422; GROUND_REF still overrides |
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
| x | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved" | |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | |
| ✓ | 59 | Ground removes the tree it made | "the reason you need to remove them by hand is because?" | |
| ✓ | 60 | Ground says it made one | "I dont like that its siltent" | |
| x | 61 | The performance ends in a pull request | "did it submit a pr at the end as well?" | |
| x | 63 | Ground commits, not the agent | "n, i dont trust the agent with it" then "we want to get rid of the auto commit" / "make commit be done by run:" / "the ritual could make itself complete itself by asking the agent to commit while its in ask" | |

Row 99 — a performance whose driver is gone is halted where it stands at the
next Stop or prompt, and its agent, its parent and sentry are told. Before this
it stood live with nobody walking it, and the status line drew its rite for as
long as anybody looked. A driver ended by a signal it can catch leaves a note of
which one, and the halt names it; a write to a reader that is gone fails as an
error instead of killing the driver. Only SIGKILL is still gone without a word.

"I dont know how to explain how serious this defect is"

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
