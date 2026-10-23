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

