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
| ✓ | 3 | Rite block: `<name> { cmd: msg: catch: goto: }` | `proto.d` | "1. make parity YES/NO ? 2. commit, push, 3. keep checking ci untill it passes..." | each step became a rite |
| ✓ | 4 | `catch:` as int or int list | `proto.d` | "its decided it will be called catch" / "catch: 22" | list form is mine — `answers` needed 7 and 22 |
| ✓ | 5 | `ritual <name> { }` nested in `project` | `proto.d` | "why cant the ritual block be literally inside project for this purpose?" | |
| ✓ | 6 | Ritual body: bare name = reference | `proto.d` | — | mine, from a compaction pass |
| ✓ | 7 | Ritual body: `name { k: v }` = reference with values | `proto.d` | "how do i set the row param from the ritual" | |
| ✓ | 8 | CTFE structs + arrays | `proto.d`, `controls.d` | — | mine, mechanical |
| ✓ | 9 | Rite names unique across groups | CTFE assert | "ok" | proposed by me, approved |
| ✓ | 10 | `goto` names a rite that exists | CTFE assert | — | mine |
| ✓ | 11 | Every declared `param` supplied | CTFE assert | — | mine |
| ✓ | 12 | Referenced group exists | CTFE assert | — | mine |
| ✓ | 13 | Run under `set -euo pipefail` | `rite.d` | "wouldnt the pipefail need to be present essentially everywhere?" | each flag has a test proving the false pass it closes |
| ✓ | 14 | Params into the command's environment | `rite.d` | — | assignments in the script text, not a hidden environment |
| ✓ | 15 | `${var}` from project env | `envSubst` | "i found a TODO at the top in controls/local/sbvh.pbt" / "env block right?" | existed; wired in. An unresolved `${key}` leaves the rite unready rather than running with a hole |
| ✓ | 16 | Classify exit: pass / caught / halt | `rite.d` | "if its non 0/1 we should just stop and halt the agent and leave on the screen the non 0 non 1 was and its message" | |
| ✓ | 17 | Position — which ritual, which rite | `ritual.d` | "see where we are INSIDE of the ritual" | per-rite, not a cursor: the status line needs both pendings. `ritual_position`, keyed on project |
| | 18 | `goto` moves position | runtime | "i think i want goto, not else, goto seems more honest for what it is" | |
| | 19 | Hold and re-run on a caught code | `adaptive.d` | "so catch means hold, until true" | `pickAdaptiveSleep` is the interval, already CTFE-tested against real CI durations |
| | 20 | Halt with code + output on screen | runtime | "leave on the screen the non 0 non 1 was and its message" | |
| | 21 | The watcher runs the current rite | `watch.d` | "it takes a super long time before an agent will reach Stop, sometimes it never gets there and is stuck in a loop even though the objective has been cleared" | Stop is the last-resort gate, not where the rite runs |
| | 22 | Report position, output and `msg` to the agent | integration | "msg i also want as anotgher optional one, i case more clarification helps, i think it really helps to shape the course of development" | |
| | 23 | Attest each rite's outcome | integration | — | mine |
| | 24 | Start a ritual by naming it | command | "i want to specify a ritual" | `ground ritual boxsurvival`; naming it is starting it |
| | 25 | Abort a ritual | command | "it ends when it ends, not because i ran ritual stop" | the exception, not the exit |
| | 26 | List rituals for this path | command | "ask about rituals for where we are now (path in project)" | |
| | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual in total" | |
| | 28 | Read position from ground db | collet | — | mine; prompted by "And i need you to get familliar with a project called collet" |
| | 29 | Render a ritual segment | collet | "watcher > exists > [kill] > gone > rebuild > answers > new" / "[kill] is now active because we can see the [ and ]" / "i hate the hourglass emoji" | the spec above; exhaustive enum, compile error for an unrendered state |

Not in the example above, and therefore not implementable from it:

| | nr | thing | notes |
|---|---|---|---|
| ✓ | 30 | `pass:` | the code that advances, default 0; a code cannot be both pass and catch |
| x | 31 | `$AUTH` | hallucinated. I put `$AUTH` in the example and then filed its absence as a gap in the spec. Ground already resolves the token in `attest.d:13` — env, then `~/.qntx/ground-token` — and `buildCurlConfig` keeps it out of argv. No pbt change was ever needed. Removed from the rites |
| | 32 | Carrying a value between rites | `new` needs `$BEFORE`; no construct provides it |
| ✓ | 43 | Terminal state | "it ends when it ends". Two endings: the last rite passes, or a rite halts. Item 16 classifies a rite, item 17 tracks position — neither has a value for the ritual being over |
| | 44 | Colour for a ritual that ended | the five colours cover a ritual in progress. Done is all green and no brackets; aborted has none |
| | 45 | A watcher that outlives one delivery | `watch.d:384` returns 2 after a batch, so a watcher delivers once and dies. The next one exists only because Stop spawned it |
| | 46 | The verdict as an immediate row | how a rite reaches the agent without waiting for a turn boundary |
| | 47 | `ci-status` replaced by a rite | `watch.d:331-361` is a hardcoded rite — cmd, four outcomes, adaptive retry. Ritual generalises it into the pbt |
| | 52 | A performance has its own worktree and branch | "each ritual perfomance occurs in separate named branches" / "the name of the branch is not something to key on". The tree is the identity; the branch is what it is on. `writePosition` already stores cwd, `scopeMatches` already keys on cwd, `runRite` already inherits it — under worktrees all three are right without a change |
| | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved". `Scope.decision` already does `"allow"`. The gate reads the live row, not a branch name, so authorisation ends when the performance does |
| | 54 | A performance is identified by itself, not by where it happens | the worktree is where it is being performed, not what it is. The key is a performance id; repo, ritual, branch and worktree path are columns. Lookup by path when you stand in it, by repo when the tree is gone — losing the path loses a route to the record, not the record |
| | 55 | A performance closed out on `WorktreeRemove` | ground cannot refuse the removal, so it writes down that the route is gone. Without 54 this only records the death; with it, the record survives |

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
| | 48 | `claimSession` is not session-scoped | `watch.d:100`. The glob lists every session's claim file, so a watcher spawned for session A can claim session B. Measured 2026-08-06: 151 `watch-*` files, 4 live watchers, 3 orphaned at ppid 1, oldest 5d10h |

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
| | 37 | `SubagentStart` | "they arent REUIRED, but you COULD if you wanted to run an agent like that, equiped with ritual" | starting an agent with a ritual |
| | 38 | `SubagentStop` | same | stopping an agent with a ritual |
| | 39 | `TaskCreated` | — | inbound only. Blocks a delegation while a rite is held |
| | 40 | `TaskCompleted` | — | inbound only. Attests what the agent did while a rite was held |
| | 41 | `StopFailure` | "I still want to better understand before i can say a thing about it" | fires when the turn ends on an API error. Payload adds `error_type` (`"rate_limit"`, `"overloaded"`, `"authentication_failed"`) and `error_message`. Cannot block, exit code ignored, output ignored |
| | 42 | `Notification` | "Notification is one that is on my wish list actually" | fires when Claude Code sends a notification. Payload adds `notification_type` (`"permission_prompt"`, `"idle_prompt"`, `"auth_success"`) and `message`. Cannot block. Honors `systemMessage`, `terminalSequence` |
| | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | fires only for Claude Code's own trees — `--worktree`, `isolation: "worktree"`, a background session. Not for a `git worktree add` you type. stdout prints the path; hook failure or no path fails the creation |
| | 51 | `WorktreeRemove` | — | fires at session exit, when a subagent finishes, when a background session is deleted. No decision control; ground cannot refuse it |
| | 56 | `CwdChanged` | — | payload `old_cwd`, `new_cwd`. How ground learns you stepped into or out of a performance's tree, instead of re-deriving it every hook. The lookup-by-path event |
| | 57 | `SessionEnd` | — | a live performance in an ending session needs an answer, and this is what forces the question |
| | 58 | `SessionStart` | — | a new session in a repo whose live performance has no tree: reattach or report. The same hook the carrying half needs, for a second reason |
