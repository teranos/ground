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
| x | 75 | A ritual is carried by an Agent, not a detached process | — | |
| x | 76 | — | — | |
| ✓ | 47 | A CI check is a rite like any other | — | |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | |

Row 99 — a performance whose driver is gone is halted where it stands at the
next Stop or prompt, and its agent, its parent and sentry are told. Before this
it stood live with nobody walking it, and the status line drew its rite for as
long as anybody looked. A driver ended by a signal it can catch leaves a note of
which one, and the halt names it; a write to a reader that is gone fails as an
error instead of killing the driver. Only SIGKILL is still gone without a word.

"I dont know how to explain how serious this defect is"

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
| ✓ | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | |
| ✓ | 51 | `WorktreeRemove` | — | |
| | 56 | `CwdChanged` | — | |
| | 57 | `SessionEnd` | — | |
| ✓ | 58 | `SessionStart` | — | |
