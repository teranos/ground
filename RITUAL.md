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
  watcher  { cmd: `curl -sf -X POST ${api}/api/watchers -H "$AUTH" -H 'Content-Type: application/json' -d "{\"id\":\"probe-$(git rev-parse --short HEAD)\",\"name\":\"box survival probe\",\"predicates\":[\"probe:boxdeath\"],\"action_type\":\"plugin_execute\",\"action_data\":\"{}\",\"max_fires_per_second\":1,\"enabled\":true}"` }
  exists   { cmd: `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD) -H "$AUTH"`  catch: 22 }
  kill     { cmd: `aws lightsail delete-instance --instance-name ${instance}` }
  gone     { cmd: `make plan | grep "aws_lightsail_instance.api will be created"` }
  rebuild  { cmd: `make apply` }
  answers  { cmd: `curl -sf ${api}/api/plugins -H "$AUTH"`  catch: [7, 22] }
  new      { cmd: `crowbar "uptime -s" | grep -qv "$BEFORE"` }

  survived {
    cmd:   `curl -sf ${api}/api/watchers/probe-$(git rev-parse --short HEAD) -H "$AUTH"`
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

| done? | nr | thing | where | quotes | notes |
|---|---|---|---|---|---|
| | 1 | `rites <name> { }` top-level block | `proto.d` | "a ritual consists our of rites" | |
| | 2 | `params: [a, b]` list field | `proto.d` | "obviously i would want rites to be able to accept a parameter" | |
| | 3 | Rite block: `<name> { cmd: msg: catch: goto: }` | `proto.d` | "1. make parity YES/NO ? 2. commit, push, 3. keep checking ci untill it passes..." | each step became a rite |
| | 4 | `catch:` as int or int list | `proto.d` | "its decided it will be called catch" / "catch: 22" | list form is mine — `answers` needed 7 and 22 |
| | 5 | `ritual <name> { }` nested in `project` | `proto.d` | "why cant the ritual block be literally inside project for this purpose?" | |
| | 6 | Ritual body: bare name = reference | `proto.d` | — | mine, from a compaction pass |
| | 7 | Ritual body: `name { k: v }` = reference with values | `proto.d` | "how do i set the row param from the ritual" | |
| | 8 | CTFE structs + arrays | `proto.d`, `controls.d` | — | mine, mechanical |
| | 9 | Rite names unique across groups | CTFE assert | "ok" | proposed by me, approved |
| | 10 | `goto` names a rite that exists | CTFE assert | — | mine |
| | 11 | Every declared `param` supplied | CTFE assert | — | mine |
| | 12 | Referenced group exists | CTFE assert | — | mine |
| | 13 | Run under `set -euo pipefail` | runtime | "wouldnt the pipefail need to be present essentially everywhere?" | |
| | 14 | Params into the command's environment | runtime | — | mine; `exec.d` has a `GROUND_` env floor |
| | 15 | `${var}` from project env | `envSubst` | "i found a TODO at the top in controls/local/sbvh.pbt" / "env block right?" | already exists |
| | 16 | Classify exit: pass / caught / halt | runtime | "if its non 0/1 we should just stop and halt the agent and leave on the screen the non 0 non 1 was and its message" | |
| | 17 | Position — which ritual, which rite | runtime | "see where we are INSIDE of the ritual" | needs storage |
| | 18 | `goto` moves position | runtime | "i think i want goto, not else, goto seems more honest for what it is" | |
| | 19 | Hold and re-run on a caught code | runtime | "so catch means hold, until true" | |
| | 20 | Halt with code + output on screen | runtime | "leave on the screen the non 0 non 1 was and its message" | |
| | 21 | Stop hook runs the current rite | integration | — | mine |
| | 22 | Report position, output and `msg` to the agent | integration | "msg i also want as anotgher optional one, i case more clarification helps, i think it really helps to shape the course of development" | |
| | 23 | Attest each rite's outcome | integration | — | mine |
| | 24 | Start a ritual | command | "Start a ritual" | |
| | 25 | Stop a ritual | command | "Stop it" | |
| | 26 | List rituals for this path | command | "ask about rituals for where we are now (path in project)" | |
| | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual in total" | |
| | 28 | Read position from ground db | collet | — | mine; prompted by "And i need you to get familliar with a project called collet" |
| | 29 | Render a ritual segment | collet | "see where we are INSIDE of the ritual" / "still be able to chat and interact WHILE IN the ritual if i want to" / "see what has happened and what will happen after" | exhaustive enum, compile error for an unrendered state |

Not in the example above, and therefore not implementable from it:

| | nr | thing | notes |
|---|---|---|---|
| | 30 | `pass:` | designed, appears in no rite in the file |
| | 31 | `$AUTH` | referenced, nothing defines it |
| | 32 | Carrying a value between rites | `new` needs `$BEFORE`; no construct provides it |

Known defects in the example:

| | nr | thing | notes |
|---|---|---|---|
| | 33 | `goto: parity` | parity passes without anything changing, so the chain re-runs identically, including `kill` |
| | 34 | `built` | reads `/opt/qntx/BUILD_SHA`, which does not exist |
| | 35 | `catch: 22` on `survived` | curl returns 22 for both 4xx and 5xx; a broken server reads as a finding |
| | 36 | `survived` measures the API | a 404 says the API did not return it, not that it is absent from the bucket |
