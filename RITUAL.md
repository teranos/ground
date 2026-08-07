A performance, in the user's words:

> AS A USER
>
> I OPEN CAUDE CODE FROM ANYWHERE
>
> I TELL CLAUDE
>
> ground ritual tree
>
> THE SUBAGENT STARTS AND THE WORKTREE IS THERE AND THE AGENT DOES ITS THING THERE
> AND THE AGENT DOES A COMMIT AT THE END OF EAH RITE

Settled:

1. Invoked from anywhere. The ritual's `project { path: }` is the locator. It is not a test against cwd.
2. Ground starts the agent and its worktree — `claude -w <name> -p`, dispatched the way `exec.d` already dispatches.
3. The agent does the work of each rite, in that worktree.
4. The agent commits at the end of each rite. The branch's history is the record of the walk, and the `goto` shows as the walk starting over.
5. A rite's `cmd` is the success condition ground evaluates, not the work.
6. The performance is identified by itself. The worktree is where it happens, not what it is.
7. What you come back to and merge is the branch.

Rituals are performed in the grove.

```
rites green {
  built { cmd: `make build` }
  tested { cmd: `make test` }
}

rites shipped {
  sealed { cmd: `test -z "$(git status --porcelain)"` }
  ci     { cmd: `gh pr checks ${pr}`  catch: 1 }
}

project {
  path: "/sbvh-nl/grove"

  env {
    pr: "1"
  }

  ritual grove {
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
    cmd: `make parity | grep "$row *YES *YES"`
    msg: "Goal is to make sure $row get's implemented for our parquet backend, see ADR-024: Parquet Storage backend."
  }
}

rites live {
  sealed { cmd: `test -z "$(git status --porcelain)" && git diff --quiet @ @{u}` }
  ci     { cmd: `gh pr checks 833` }
  built  {
    cmd: `crowbar "cat /opt/qntx/BUILD_SHA" | grep -q "$(git rev-parse HEAD)"`
    msg: "The rite is checking for QNTX to be up to date on the box, "
  }
}

rites boxdeath {
  watcher  { cmd: `curl -sf -X POST ${api}/api/watchers -H 'Content-Type: application/json' -d "{\"id\":\"probe-$(git rev-parse --short HEAD)\",\"name\":\"box survival probe\",\"predicates\":[\"probe:boxdeath\"],\"action_type\":\"plugin_execute\",\"action_data\":\"{}\",\"max_fires_per_second\":1,\"enabled\":true}"` }
  exists   { cmd: `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD)`  catch: 22 }
  kill     { cmd: `aws lightsail delete-instance --instance-name ${instance}` }
  gone     { cmd: `make plan | grep "aws_lightsail_instance.api will be created"` }
  rebuild  { cmd: `make apply` }
  answers  { cmd: `curl -sf ${api}/api/plugins`  catch: [7, 22] }
  new      { cmd: `crowbar "uptime -s" | grep -qv "$BEFORE"` }

  survived {
    cmd:   `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD)`
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

The status line, rendered by collet:

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

| done? | nr | thing | where | quotes | notes |
|---|---|---|---|---|---|
| ✓ | 1 | `rites <name> { }` top-level block | `proto.d` | "a ritual consists out of rites" | |
| ✓ | 2 | `params: [a, b]` list field | `proto.d` | "obviously i would want rites to be able to accept a parameter" | |
| ✓ | 3 | Rite block: `<name> { cmd: msg: catch: goto: }` | `proto.d` | "1. make parity YES/NO ? 2. commit, push, 3. keep checking ci" | each step became a rite |
| ✓ | 4 | `catch:` as int or int list | `proto.d` | "its decided it will be called catch" | list form is mine |
| ✓ | 5 | `ritual <name> { }` nested in `project` | `proto.d` | "why cant the ritual block be literally inside project" | |
| ✓ | 6 | Ritual body: bare name = reference | `proto.d` | — | mine, from a compaction pass |
| ✓ | 7 | Ritual body: `name { k: v }` = reference with values | `proto.d` | "how do i set the row param from the ritual" | |
| ✓ | 8 | CTFE structs + arrays | `proto.d`, `controls.d` | — | mine, mechanical |
| ✓ | 9 | Rite names unique across groups | CTFE assert | "ok" | proposed by me, approved |
| ✓ | 10 | `goto` names a rite that exists | CTFE assert | — | mine |
| ✓ | 11 | Every declared `param` supplied | CTFE assert | — | mine |
| ✓ | 12 | Referenced group exists | CTFE assert | — | mine |
| ✓ | 13 | Run under `set -euo pipefail` | `rite.d` | "wouldnt the pipefail need to be present essentially everywhere?" | a test per flag |
| ✓ | 14 | Params into the command's environment | `rite.d` | — | assignments in the script, not a hidden env |
| ✓ | 15 | `${var}` from project env | `envSubst` | "env block right?" | unresolved leaves the rite unready |
| ✓ | 16 | Classify exit: pass / caught / halt | `rite.d` | "if its non 0/1 we should just stop and halt the agent" | |
| ✓ | 17 | Position — which ritual, which rite | `ritual.d` | "see where we are INSIDE of the ritual" | per-rite, not a cursor |
| ✓ | 18 | `goto` moves position | `ritual.d` | "i think i want goto, not else, goto seems more honest for what it is" | `indexOfRite` maps name to index |
| | 19 | A rite that is not met throws the Stop back and the agent carries on | `stop.d` | "so catch means hold, until true" / "the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop" | `stop.d` blocks once and `stop_hook_active` ends the turn. Nothing to do with polling |
| ✓ | 20 | Halt with code + output on screen | `stop.d`, collet | "leave on the screen the non 0 non 1 was and its message" | the halted rite stays on the line in red |
| ✓ | 21 | The current rite runs and the position moves | `ritual.d` | "it takes a super long time before an agent will reach Stop" | `advance` |
| | 22 | The agent knows where it is, what happened, and what the author said | integration | "msg i also want as anotgher optional one" | |
| ✓ | 23 | Attest each rite's outcome | `ritual.d` | — | one row per attempt |
| ✓ | 24 | Name a ritual | `ritual.d` | "i want to specify a ritual" | naming writes a live row; is that starting? |
| | 25 | Abort a ritual | command | "it ends when it ends, not because i ran ritual stop" | the exception, not the exit |
| | 26 | List rituals for this path | command | "ask about rituals for where we are now" | |
| | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual" | |
| ✓ | 28 | Collet knows where a performance is | collet | — | mine. READONLY could not open a WAL db, so this read nothing and neither did the ✉/⏳ counts |
| | 29 | A state collet cannot render is a compile error | collet | "[kill] is now active because we can see the [ and ]" | it renders; an unknown glyph is refused at runtime, not at compile time |

Not in the example above, and therefore not implementable from it:

| | nr | thing | quotes | notes |
|---|---|---|---|---|
| ✓ | 30 | `pass:` | "i meant, from 0 to 1, the gate is from 0 to 1" | the code that advances, default 0 |
| x | 31 | `$AUTH` | — | hallucinated. `attest.d:13` already resolves the token |
| | 32 | Carrying a value between rites | — | `new` needs `$BEFORE` |
| ✓ | 43 | Terminal state | "it ends when it ends, not because i ran ritual stop" | Done or Halted, reached by running |
| ✓ | 44 | Colour for a ritual that ended | "green is passed" / "blinking red is halted" | done needs no word; halted and aborted say so |
| ✓ | 45 | The ritual keeps moving while the agent works | "it takes a super long time before an agent will reach Stop" | `ground drive <tree>`. Eight rites in ten seconds against one per turn |
| | 46 | A rite's verdict reaches the agent without waiting for a turn to end | — | as an immediate row |
| | 47 | A CI check is a rite like any other | — | `watch.d:331-361` is one hardcoded in D, with its own four outcomes and adaptive retry |
| ✓ | 52 | A performance has its own worktree and branch | "each ritual perfomance occurs in separate named branches" | `repoRoot` locates the repo |
| ✓ | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved" | the gate reads the live row, not a name |
| ✓ | 54 | A performance is identified by itself | "the name of the branch is not something to key on" | path is an index, not the key |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | `WorktreeRemove` clears the stale path and keeps the record |
| ✓ | 59 | Ground removes the tree it made | "the reason you need to remove them by hand is because?" | the driver removes it on Done. A halt keeps its tree — what the failing rite left uncommitted is what you would look at |
| ✓ | 60 | Ground says it made one | "I dont like that its siltent" | creation was silent |
| ✓ | 61 | The performance ends in a pull request | "did it submit a pr at the end as well?" | on Done only, and a halt opens nothing. `sbvh-nl/grove#1` was opened by a performance nobody touched after starting it |
| ✓ | 62 | A `goto` cycle is bounded | "let bound it to max 16 and make it say clearly that the goto can only be invoked at most 16 times in a single ritual" | `MAX_GOTOS`. Spending the budget halts rather than holds — holding waits on a jump that will never come |
| | 66 | Who passed each rite: the agent or ground | "i want to be able to know if an agent went through the chain or ground" / "agent should be at [ ]" / "and if ground went through them it should be a different green" / "the agent [ and ] should have moved no further than apple" | the bracket is the agent's position and stops where the agent stopped. Rites past it are a darker green because ground walked them. `advance` is called from `stop.d` for an agent turn and from `drive.d` for the driver and the row cannot tell them apart — today only the session on each rite attestation can |
| | 68 | The closing sentences are on screen when the ritual ends | "i never saw the two sentences" | the agent writes minutes after DONE, the expiry counts from `updated_at`, and with no tail nothing forces a marquee. Measured: done at 75s with the agent still running and nothing written |
| | 64 | A completed ritual marquees the agent's closing sentences after its rites | "when a ritual ends fully, when it is fully ended and completed ... turns into this: SOURSOP > LIME > JACKFRUIT > CHECKWILLOW > DONE \| Done. All fruits are picked." / "i meant sentences" / "i dont care who owns the last rite" / "the colors should do the work" / "and the brackets" | the rite line is kept and scrolls; the sentences follow a `\|`. No prose restating position — the colours and brackets do that |
| ✓ | 63 | Ground commits, not the agent | "n, i dont trust the agent with it" | one commit per rite that passed and changed the tree. Eight commits for ten rites — START and CHECKTREE changed nothing |

Known defects in the example:

| | nr | thing | notes |
|---|---|---|---|
| | 33 | `goto: parity` | parity passes without anything changing, so the chain re-runs identically, including `kill` |
| | 34 | `built` | reads `/opt/qntx/BUILD_SHA`, which does not exist |
| | 35 | `catch: 22` on `survived` | curl returns 22 for both 4xx and 5xx; a broken server reads as a finding |
| | 36 | `survived` measures the API | a 404 says the API did not return it, not that it is absent from the bucket |

Inherited by anything that rides the watcher:

| | nr | thing | notes |
|---|---|---|---|
| | 48 | `claimSession` is not session-scoped | `watch.d:100`. A watcher for A can claim B |

Not known:

| | nr | thing | notes |
|---|---|---|---|
| | 49 | Does asyncRewake reach a mid-turn session | the code cannot answer it. It decides whether the watcher fixes the loop or only the walk-away |

One performance, start to finish. Columns are what fires, in order.

| | `ground ritual` | `WorktreeCreate` | `SubagentStart` | `SessionStart` | `CwdChanged` | `UserPromptSubmit` | `PreToolUse` | `PostToolUse` | watcher | `Stop` | `SubagentStop` | `SessionEnd` | `WorktreeRemove` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **position** | written | path bound | — | read | re-resolved | read | read | — | stepped | read | read | decided | route lost |
| **worktree** | — | created, path from stdout | entered | — | entered or left | — | — | — | — | — | — | — | removed |
| **agent knows** | — | — | given the ritual | told the rite | — | told the rite | — | — | told the verdict | told by the block | — | — | — |
| **consent** | — | — | — | — | — | — | allowed while live | — | — | — | — | — | ends |
| **can refuse** | — | yes, creation fails | no | no | no | no | yes | yes | — | yes | yes, exit 2 | no | no |

The two halves are visible in the third row. Everything in **agent knows** left of the watcher is carrying; everything right of it is interrupting. Only two columns fill it today, and neither is built.

Claude Code hook events, in the context of this feature:

| | nr | thing | quotes | notes |
|---|---|---|---|---|
| ✓ | 37 | `SubagentStart` | "you COULD if you wanted to run an agent like that, equiped with ritual" | binds the performance to the owning session and the agent, and hands it the briefing |
| ✓ | 38 | `SubagentStop` | same | exit 2 refuses an agent leaving rites unmet — the only place a subagent can be refused. Keeps `last_assistant_message` with the performance |
| | 39 | `TaskCreated` | — | inbound only. No use found |
| | 40 | `TaskCompleted` | — | inbound only |
| | 41 | `StopFailure` | "I still want to better understand before i can say a thing about it" | carries `error_type`, `error_message`. Cannot block |
| | 42 | `Notification` | "Notification is one that is on my wish list actually" | carries `notification_type`, `message`. Cannot block |
| ✓ | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | ground makes the tree and prints the path |
| ✓ | 51 | `WorktreeRemove` | — | no decision control; ground cannot refuse |
| | 56 | `CwdChanged` | — | `old_cwd`, `new_cwd`. The lookup-by-path event |
| | 57 | `SessionEnd` | — | a live performance in an ending session |
| ✓ | 58 | `SessionStart` | — | `briefing` goes into `additionalContext` |
