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
| ✓ | 19 | A rite that is not met throws the mic back | `stop.d` | "so catch means hold, until true" / "the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop" | `stop.d:154` — a live performance is exempt from the `stop_hook_active` guard, so the rite is asked at every Stop. `stop.d:268` writes the block, `stop.d:205` stamps `thrown_at`, `threw()` counts it. This half fires; measured stamps exist. Held open only because it has not been watched happening |
| | 74 | The agent carries on when the Stop goes back | `watch.d` | "allowing the agent to continue" — the second half of 19, split out 2026-08-08 because it is not in `stop.d` and not about the rite | 605, 605, 606, 607, 610, 748 seconds between Stops, transcript empty across every gap, while ground's own Stop hook measures 2s max over 126 calls. Cause NOT established. Claimed and withdrawn 2026-08-08: I said the watcher held it, because `handleWatch` has two exits — a batch (`watch.d:443`) and an orphaned parent (`watch.d:454`) — and a Hold produces neither, so it loops on `nextSleep = 15` forever. The loop is real and is why ten watchers were found orphaned (`watch.d:106`), but it cannot be the hold: the docs say `asyncRewake` "runs in the background… Implies `async`", so Claude Code never waits on it. Measured 2026-08-08: the ground Stop hook as a process is 0.321s wall, 286ms handler, against a real live performance. It exits and holds nothing open, so it is not the 600 either. Every 605 sample was taken against `claude -w <id> -p` — print mode, detached — which item 75 deletes. Whether it exists against `claude --bg` is unmeasured, and that is where to measure it |
| ✓ | 20 | Halt with code + output on screen | `stop.d`, collet | "leave on the screen the non 0 non 1 was and its message" | the halted rite stays on the line in red |
| ✓ | 21 | The current rite runs and the position moves | `ritual.d` | "it takes a super long time before an agent will reach Stop" | `advance` |
| ✓ | 22 | The agent knows where it is, what happened, and what the author said | integration | "msg i also want as anotgher optional one" | The briefing carries all three: "Performing ritual willow, rite 5 of 10: MANGOx1. It is met when this exits 1: grep -qxF ... . Take the MANGO out of WILLOW.md." Where it is, how many times it has been asked, the pass code, the command, and the author's `msg`. An Advance is prefixed with "<RITE> passed." so the agent learns whether the last thing counted before being told the next thing |
| ✓ | 23 | Attest each rite's outcome | `ritual.d` | — | one row per attempt |
| ✓ | 24 | Name a ritual | `ritual.d` | "i want to specify a ritual" | naming writes a live row; is that starting? |
| ✓ | 25 | Abort a ritual | command | "it ends when it ends, not because i ran ritual stop" / "ground should take responsibility" | the exception, not the exit. `ground abort <handle>` marks the row, and the agent ends itself at its next Stop through `continue: false` — https://code.claude.com/docs/en/hooks. Verified 2026-08-08 on `willow-nhf`: aborted at position 4, Fleet reported the session `idle`. `reapScript` and `agent_pid` are the earlier mechanism, `pkill -f "claude -w <id>"`, which matches nothing once the agent is a background session — `willow-ml6` was aborted under it and stayed `busy` on a finished performance |
| D | 26 | List rituals for this path | command | "ask about rituals for where we are now" | |
| D | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual" | |
| ✓ | 28 | Collet knows where a performance is | collet | — | mine. READONLY could not open a WAL db, so this read nothing and neither did the ✉/⏳ counts |
| D | 29 | A state collet cannot render is a compile error | collet | "[kill] is now active because we can see the [ and ]" | it renders; an unknown glyph is refused at runtime, not at compile time. Deferred behind the migration of collet into ground as D, which is its own branch — a compile-time refusal in Crystal would be rewritten immediately after |

Not in the example above, and therefore not implementable from it:

| | nr | thing | quotes | notes |
|---|---|---|---|---|
| ✓ | 30 | `pass:` | "i meant, from 0 to 1, the gate is from 0 to 1" | the code that advances, default 0 |
| x | 31 | `$AUTH` | — | hallucinated. `attest.d:13` already resolves the token |
| x | 49 | — | — | confabulated. Number burned |
| x | 69 | — | — | confabulated. Number burned |
| x | 32 | Carrying a value between rites | — | poorly defined, won't do |
| ✓ | 43 | Terminal state | "it ends when it ends, not because i ran ritual stop" | Done or Halted, reached by running |
| ✓ | 44 | Colour for a ritual that ended | "green is passed" / "blinking red is halted" | done needs no word; halted and aborted say so |
| ✓ | 45 | The ritual keeps moving while the agent works | "it takes a super long time before an agent will reach Stop" | `ground drive <tree>`. Eight rites in ten seconds against one per turn |
| | 71 | A rite holds the mic for at most 2 seconds | "a rite can only take hostage for at most 2 sec" / "the white state color should be occupied for at most 2 sec" / "ground, or the rite should have no reason to keep holding the mic for longer than 2s" | Ground has nothing to wait for: it evaluates the condition and either knows what to say or does not, so it speaks and passes the mic at once. ground's Stop hook measures 2s max over 126 calls, so it meets this by accident and nothing enforces it. Since 87 the row says who holds it, and `moon-1786216750` was sampled at 0.4s: every `mic=ground` hold sat between two samples, under a second, and the only holds past two seconds were `mic=ci` at sixteen and eleven — which is what `micBound` exists to tell apart, a rite waiting on nothing versus a rite waiting on a run. Still nothing enforces the bound; `blocking()` has no caller. Measured against it: Stop-to-Stop gaps of 605, 605, 606, 607, 610, 748 with empty transcripts across every gap. Claude Code's documented default hook timeout is 600s |
| | 73 | The mic going back is counted, and the count is on both surfaces | "let's show a counter" / "[NEVERx3]" / "if there is back and forward, it would mean the counter increments no?" | `Position.throws`, stamped by `threw()` at the throw site in `stop.d`, not in `advance` — the watcher evaluates the same rite every 15s (`watch.d:375`) and a count including those would read x40 where the agent was told once. Reset by `step(Advance)` and by `jump` to another rite. Agent reads `PICKx3` in its briefing, operator reads `[NEVERx3]` on the line. Built and installed, and wrong: 79 loses increments to a stale writer, so the number is a lower bound rather than a count and a frozen one no longer distinguishes a stall from a race. Seen live as `[NEVERx3]` and as `NEVERx3` in a briefing, so both surfaces work; the count they carry does not yet |
| ✓ | 80 | A performance is a row in Fleet | "i want FleetView" / "Fleet is what i think i am referring to" / "how do we settle on Fleet" | `claude agents --json` lists `perpetuity-a9r` as `kind: background`, `cwd` the perpetuity worktree, `sessionId` a44b126d — byte-for-byte the `session` column on its `ritual_position` row, so the join key was already being written. `spawnScript` is now `claude -w id --bg prompt`; `-p` was one-shot and detached, reachable by nothing but pkill. The row reads `name: "perpetuity rite logic"`, `state: working`. Not done: the registry answering is not the view rendering, and the view could not render it. Agent view filters on `--cwd` "sessions started under path", and `worktreePath` places a tree at `root-perfId`, a sibling of the repo root — so `--cwd .../q.sbvh.nl` returns 0 and `--cwd .../sbvh-nl` returns it. A ritual is invisible from the repo it belongs to. `isolation: worktree` would put the tree in `.claude/worktrees/` under the repo, but that is a Task-tool agent property and a performance is a Fleet session (SUBAGENT.md s78), so it does not apply. Marked 2026-08-08: "i think 80 is done, because i get to see what is being executed form here, and its unrelated to subagent". The `--cwd` filter is a view's question, not this row's. Still unverified: whether Space peeks, Enter attaches, and a reply reaches. Would make `reapScript` and `agent_pid` redundant rather than orphaned, since Fleet stops a session with Ctrl+X |
| | 82 | Four receivers, named, and a message may name several | "THERE ARE FOR RECEIVERS" / "PARENT: HUMAN / HOSTLLM" / "CHILD : RITE  / AGENTLLM" then corrected to "WE NEED TO SAY THAT RITUAL IS THE RECEIVER, NOT RITE, RITE IS JUST A PIECE OF THE RITUAL, RITUAL DRIVES THE CHAT VIA RITES" / "AGENTLLM STOP OUTPUT FIRST TWO SENTENCES OF LAST MESSAGE NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM" | `ritual/delivery.d`. Every delivery site used to read whichever session field was in scope, which is how one wrong field produced three separate bugs in one night: an agent handed its own last message, a user prompt signed with an agent's name, and a parent session driven as if it were the agent. Human and HostLlm share the parent session and differ by channel, not address — the immediate queue reaches the model as a system reminder and the operator never sees it, which is why the walk was on screen and the agent's words were not. Rite is ground and has no session. Not done: the Human channel is unbuilt, so SAID_TO currently reaches only HostLlm |
| ✓ | 83 | The operator reads a rite's verdict without pressing anything | "i need to see it in the transcript without me having to press ctrl-o" / "i want MessageDisplay and displayContent" | `messagedisplay.d` returns `hookSpecificOutput.displayContent`, which replaces what is drawn while assistant text streams. Prepended on `index:0`, because `final:true` is the closing chunk and pastes the lines into the middle of a reply. Proven 2026-08-08 by sending a city through the channel that appeared nowhere in the text and having it read back: OAXACA |
| ✓ | 84 | A line ground injects cannot pass for the assistant's own words | "it looks the same as your text, its as if you said it, but its coming from a rite of a ritual no?" / "is it possible to change the color" / "  ░░▒▓▏ritual" / "    ░░▏rite" | Colour was tried first and does not survive the channel: an ANSI escape sent through arrived on screen as the literal `[38;5;208m`, so the mark is text. Density says which level speaks — `░░▒▓▏` the performance, `░░▏` one rite. Only the rite level has been seen in real use, on every line of `willow-6i0`; the performance level has rendered once, from a probe inserted by hand, and no performance emits one — `gutterFor` picks it when a key lacks `:rite:`, and the only such note is `ritual-agent-last`, which comes from SubagentStop and never fires for a `--bg` agent. Applied to every line of a message, not only the first, or a multi-line body falls out of the margin partway through. Without it a verdict reads as something the model said, which is the echo defect of 82 in a different coat |
| | 85 | An agent that cannot act says so in its own form | "░▏(╯°□°）╯︵ ┻━┻" / "░▏Could not do shit bro." / "░▏Just didnt have the perission." | The third gutter, one shade lighter than a rite, for the case where the agent is not refusing a rite but cannot reach one. Not built — no rite emits it and nothing detects the condition. There was a real instance to hang it on: `willow-3g9` reported "Every tool call — Read, Edit, Bash — is being rejected by the harness with: No tools needed for suggestion" and the walk completed anyway, so a performance can read as ten passes while its agent was disabled throughout |
| ✓ | 87 | CI holds the mic while a run is in flight | "there needs to be a way for the ball to land in the court of ci" / "and ci keeps holding the mic in this case" / "it keeps holding the mic until ci has an outcome" / "and the outcome is what is spoken back into the mic to both the agent and parent" | The claim moved to before the rite runs: taken after, the row named the agent for the whole time the rite blocked. `holder(r.wait)` names `Mic.Ci` for a rite that declares a `wait:`, which `proto.d` had parsed and `flatten` had dropped since it was written. Observed on `moon-1786216750`: `21:20:10.208 mic=agent`, `21:20:10.737 mic=ci`, sixteen seconds, `21:20:26.262 mic=agent` on the goto. `ciSpeaks` sends what the rite printed to both sides under a `ci:` key, which is the one the `░▓▓▏` gutter draws. The pass-jump this row called a blocker was never needed — `catch:` alone gates until the failure goes away, `catch: goto:` redirects |
| ✓ | 88 | A rite can speak, and what it says reaches both sides | "mic makes sure it also gets to us" / "if it goes through the mic, it means both the parent and the child agent would be receivers" / "nothing / msg / mic / msg+mic are all possible" | `mic:` on a rite, beside `msg:`. `msg` stays private to the agent; `mic` is heard by the parent and the agent both, so the briefing carries both and the parent's line carries `mic`. Verified 2026-08-08 on `willow-nhf`: "CHERRY passed · The CHERRY rite is looking at WILLOW.md. · I plucked a CHERRY." — the rite's words first, the agent's after, from a rite declaring only `mic:` |
| | 90 | A latent CI rite interrupts an agent that has moved on | "in the more sophisticated version, the ci rite happens while the agent continues onto the next rite without needing to wait for ci to finish" / "ci is able to interrupt the agent with a ci failure, and as such the agent diverts back to the main tasks" / "ci passing would still gate the end of a ritual (read ritual not rite)" / "a ci rite from inside of a rite can interrupt an agent that has already moven on to other rites but is still inside of the same ritual" / "the latent ci rite **takes** the mic from the agent to announce failure and immediately gives it back" | 87 is the blocking case of this: the walk stops and everyone waits. Here the rite dispatches and the walk advances, and the rite is latent — dispatched, unresolved, still owed. Needs a fourth `RiteState` beside Passed, Ran and Halted; a `runRite` that returns before its command does, since `advance` assumes the verdict is known when the rite returns; resolution in `drive.d`, which already polls; and `step()` refusing Done while any rite is latent, because today Done is just running out of rites. The mic is not held for the duration — the agent holds it throughout and CI takes it for one announcement. Only on failure: green resolves in silence, because nothing changed. The interrupt is 46's mechanism, `writeNote` to the agent's session drained as `asyncRewake` exit 2, which is built and has never been shown to interrupt rather than deliver |
| | 91 | An API error holds the mic and says its own name | "it is the error code that is holding the mic" / "and it is angry" / "the mic needs to speak its exact error" / "you always get one of these with the ZALGO retained" / "rate limit just means retry not now but in incremental backoff" / "oh, its api error, so its not even the agent dying per se. its claude the api dying" | `StopFailure`, which the docs say fires "When the turn ends due to an API error" and whose "Output and exit code are ignored". The agent is not dead — its process and worktree are intact and it can carry on the moment the API answers again — so this is an outage, not a death, and reaping would be wrong. Without it there is no `Stop`, so the row sits `live` with `mic=agent` while nothing is there: the lie the mic exists to remove, and `blocking(Mic.Agent, …)` is the function that would catch it, with no caller. The holder is neither ground, agent, ci nor human but the error itself — the first holder that is a condition rather than a party — and it says what the API said, unparaphrased, since summarising it would be ground taking the mic and speaking as the error. The matcher filters on error type, so each gets its own control: `rate_limit`, `overloaded` and `server_error` are the API being busy and the error keeps the mic on incremental backoff (`adaptive.d` already does that shape for CI); `authentication_failed`, `oauth_org_not_allowed`, `billing_error`, `model_not_found` and `invalid_request` need a person, so the mic goes to `human`; `max_output_tokens` is not an outage at all but the turn hitting its ceiling, which is where a ritual ends; `unknown` halts, because `rite.d:10` already says "Halt is the refusal to guess". The nine are drawn with one overlay mark per character and nothing above or below the baseline, so the line box does not grow and the gutter stays a fixed column: R̶A̸T̵E̵_̴L̸I̵M̸I̷T̶ · O̶V̸E̴R̷L̸O̵A̷D̶E̸D̵ · A̷U̷T̴H̶E̴N̴T̷I̸C̵A̵T̴I̵O̸N̶_̸F̸A̵I̴L̷E̸D̴ · O̶A̸U̸T̷H̶_̸N̵O̶T̸_̴A̵L̴L̶O̸W̴E̷D̷ · B̶I̷L̷L̵I̶N̶G̵_̶E̷R̷R̷O̸R̶ · M̷O̸D̸E̷L̴_̵N̶O̷T̷_̷F̷O̸U̵N̴D̶ · I̷N̴V̴A̵L̶I̷D̴_̴R̸E̶Q̵U̴E̸S̷T̷ · M̷A̴X̶_̸O̵U̸T̶P̶U̵T̵_̸T̴O̵K̵E̶N̸S̵ · U̴N̶K̶N̶O̷W̷N̸ — stored literally, not generated, because the set rotates through five marks and a generator would only resemble it. The path preserves them: `parse.d:213` escapes five ASCII bytes and writes the rest through one at a time, `immediate.d:568` drops only `"` and `\`, and `gutter()` reacts only to `\n`. Registered in `plugin/hooks/hooks.json` and recorded raw by `stopfailure.d`, which is how 41 got its real fields. Five records landed on 2026-08-08 from one wifi outage. What is built is the recording; nothing constructs an `ApiError` from what arrives, so the mic is still never handed to the error and none of the three shapes is acted on |
| ✓ | 89 | Words belong to the hold that produced them | "make the message a property of the mic" | `wordsHash` and `freshWords`, with the hash on the row. A line carries the agent's sentences only when they are new since the last hold. `willow-kkp` put one complaint on six rites — `LIME passed · I can't pluck the MANGO`, `CHECKWILLOW passed · I did not pluck the SOURSOP` — because the words attached were the most recent, not what was said while holding |
| | 79 | One thing advances a position | — mine, from reading the callers | `advance` is called from `stop.d`, `watch.d:370`, `drive.d:86` and now `subagent.d`, and nothing coordinates them. Only two stamp `threw`, which is right, but a rite the watcher advances past resets the count via `step(Advance)` with no event the operator sees. The driver exists for `command.d:200` — "the position only advances when a turn ends, which for a working agent can be never" — and that reason survives every change tonight, so this is not solved by deleting one of them. Observed 2026-08-08 on `perpetuity-a9r`, first run of the first background session: the note reached the parent reading `NEVER held` with the agent's own sentences, which only `stop.d` and `subagent.d` attach, so `stop.d` ran and stamped `throws=1` — and the row read `throws=0`. Two writers, last one wins. Minutes later the same row read `throws=2`, so increments survive when `stop.d` happens to write last and are lost when it does not: the number on the line is a lower bound on the times the mic went back, not a count of them. A counter that undercounts silently is worse than none, because a frozen one now means either a stall or a race |
| | 75 | A ritual is carried by a managed background session, not a detached process | "i want sidechain" / "i want FleetView" / "so i can press donw and access it and chat in it while its happening" / "yeah, thats it" — the peek panel | Half-built already: `subagent.d:11` binds session + agent and injects the briefing as `additionalContext`, `subagent.d:52` refuses the stop with exit 2. Missing half: `handleSubagentStop` never calls `advance`, so the rite is never evaluated there and the position never moves — every verdict lives in `stop.d`. Ground cannot spawn a sidechain (it is a hook, only the model calls Task), so `ground ritual <name>` must hand the session a briefing instead of forking `claude -w`. Deletes `reapScript`, `agent_pid`, and the `parent` binding in `posttooluse.d`. Verified against the hook docs 2026-08-08: SubagentStop exit 2 "Prevents the subagent from stopping"; input carries `session_id` (the parent's), `agent_id`, `agent_type`, `cwd`, `last_assistant_message`; `matcher` matches `agent_type`; no `stop_hook_active` on this path. `ground watch` is a Stop hook only, so 74 is not in front of this |
| ✓ | 76 | SessionStart binds the performance and briefs the agent | "both SubagentStart and SubagentStop missing is a nightmare for ritual" / "update spec with them" | This row said SubagentStart did it. It does not: `sessionstart.d:316` — SubagentStart "does not fire for `claude -w`". A performance is spawned by `run.d:284` as `claude -w <tree> --bg <prompt>`, which is a Fleet session and not a Task-tool sidechain, so `handleSubagentStart` is registered, is correct, and never runs on this path. `sessionstart.d:314` is what binds it: it reads the row by worktree, writes the session, and takes `agentPid` from `getppid()` because with `--bg` the process is Fleet's. SubagentStart still holds for a ritual carried by a sidechain, and `agent_type` is what a `matcher` matches there |
| | 72 | A performance cannot outlive one compaction window | "i think a ritual cant run longer than one compaction window" / "it a high upper bound" | Not a timer — ground already has the event. `precompact.d` handles PreCompact, and `db.d:365` already asks "did a PreCompact happen in this session after this". A performance is bound to the agent's session, so the bound is: PreCompact for session S ends every live performance on S |
| | 46 | A rite's verdict reaches the agent, unasked | "isnt it the perfect mechanism to fiannly use for intterupt on rite ?" | `writeNote` to the agent's session, delivered by the watcher as asyncRewake exit 2. Measured three times on 2026-08-07, real content, nobody asked for it. `drive.d:87` already writes it and had never fired, because `p.session` was empty until `SessionStart` bound it. The key is done and went further than owed: `stop.d` and `drive.d` now key on performance, rite and `rev`, so a rite asked twice is two notes rather than one id already marked delivered. Walked 2026-08-08: `ci:moon-1786215134:JUDGE:22` and `:36` both landed, where the old key would have shown the first and swallowed the second. `drive.d:96` and `drive.d:103` keep their fixed keys on purpose: `rite-open` is written every fifteen seconds while a rite holds, and a unique key there wakes an agent with twenty identical briefings. A briefing is state, where only the latest is wanted; a verdict is an event, where every one is. Still owed is the second half — a verdict reaches the agent only where a rite names `AgentLlm`, no grove rite does, and `ciSpeaks` is the only thing that adds it |
| | 70 | Ground's trace is on your screen as it happens | "the first two sentences of what happened in last_assistent_message pre-Stop inside of any rite as a Notification in the parent session" / "it seems like it would increase the clarity i have into ground by an absolute incredible amount" / "i believe my temporal awareness is much greater than yours" | `Notification` exit 2 shows stderr to the user and nothing else. Built and never fired: the watcher drains the same queue every two seconds and always wins, so the lines need a record only this reads, drained in one batch per notification rather than one line. 83 is what carries the lines today and it is not this row: `handleMessageDisplay` returns unless `firstChunk(input)`, so it can only prepend to an assistant message that is already streaming. Measured 2026-08-08 — a whole walk's lines sat in the queue while the parent was inside tool calls and arrived in one batch the moment it next spoke, up to sixteen rows per call. The queue was never slow. The channel has nothing to draw on until the parent talks |
| ✓ | 47 | A CI check is a rite like any other | — | grove's `JUDGE` in `moon.pbt` is `cmd:` + `catch: 1` + `goto: WIPE` + `wait: 20` + `to: parent` + `mic:`, and no path in ground evaluates it differently from `test -s MOON.md`. Walked 2026-08-08: found the run for its own `HEAD`, held on a real red, redirected, passed on a real green, and its stdout came home as CI's words. `watch.d:331-361` is still hardcoded, but that is the push courier — it reports on your pushes and has never been part of a performance |
| ✓ | 52 | A performance has its own worktree and branch | "each ritual perfomance occurs in separate named branches" | `repoRoot` locates the repo |
| ✓ | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved" | the gate reads the live row, not a name |
| ✓ | 54 | A performance is identified by itself | "the name of the branch is not something to key on" | path is an index, not the key |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | `WorktreeRemove` clears the stale path and keeps the record |
| ✓ | 59 | Ground removes the tree it made | "the reason you need to remove them by hand is because?" | the driver removes it on Done. A halt keeps its tree — what the failing rite left uncommitted is what you would look at |
| ✓ | 60 | Ground says it made one | "I dont like that its siltent" | creation was silent |
| ✓ | 61 | The performance ends in a pull request | "did it submit a pr at the end as well?" | on Done only, and a halt opens nothing. `sbvh-nl/grove#1` was opened by a performance nobody touched after starting it |
| ✓ | 62 | A `goto` cycle is bounded | "let bound it to max 16 and make it say clearly that the goto can only be invoked at most 16 times in a single ritual" | `MAX_GOTOS`. Spending the budget halts rather than holds — holding waits on a jump that will never come |
| | 66 | Who held the mic when each rite passed | "i want to be able to know if an agent went through the chain or ground" / "agent should be at [ ]" / "and if ground went through them it should be a different green" / "the agent [ and ] should have moved no further than apple" | the bracket is the agent's position and stops where the agent stopped. Rites past it are a darker green because ground walked them. The mic is the word for this now and it holds the live answer: walked 2026-08-08, `moon-1786216750` read `ground` while each rite ran, `ci` for the sixteen seconds `JUDGE` waited on its run, `agent` between rites, `human` once done. What it does not hold is this row's question. `takeMic` writes `Agent` whenever the performance is live, whether the advance came from an agent's Stop in `stop.d` or from the driver in `drive.d`, and both pass the same session to `advance`. One column says who holds it now; whether a given rite was passed by an agent turn or by the driver is a fact per rite, and would have to be recorded on that rite's attestation as it passed |
| | 68 | The closing sentences are on screen when the ritual ends | "i never saw the two sentences" | the agent writes minutes after DONE, the expiry counts from `updated_at`, and with no tail nothing forces a marquee. Measured: done at 75s with the agent still running and nothing written |
| | 64 | A completed ritual marquees the agent's closing sentences after its rites | "when a ritual ends fully, when it is fully ended and completed ... turns into this: SOURSOP > LIME > JACKFRUIT > CHECKWILLOW > DONE \| Done. All fruits are picked." / "i meant sentences" / "i dont care who owns the last rite" / "the colors should do the work" / "and the brackets" | the rite line is kept and scrolls; the sentences follow a `\|`. No prose restating position — the colours and brackets do that |
| ✓ | 63 | Ground commits, not the agent | "n, i dont trust the agent with it" | one commit per rite that passed and changed the tree. Eight commits for ten rites — START and CHECKTREE changed nothing |

Known defects in the example:

| | nr | thing | notes |
|---|---|---|---|
| D | 33 | `goto: parity` | parity passes without anything changing, so the chain re-runs identically, including `kill`. Deferred into a production try run of boxdeath |
| D | 34 | `built` | reads `/opt/qntx/BUILD_SHA`, which does not exist. Deferred into a production try run of boxdeath |
| D | 35 | `catch: 22` on `survived` | curl returns 22 for both 4xx and 5xx; a broken server reads as a finding. Deferred into a production try run of boxdeath |
| D | 36 | `survived` measures the API | a 404 says the API did not return it, not that it is absent from the bucket. Deferred into a production try run of boxdeath |

Inherited by anything that rides the watcher:

| | nr | thing | notes |
|---|---|---|---|
| | 48 | `claimSession` is not session-scoped | `watch.d:100`. A watcher for A can claim B |

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
| ✓ | 37 | `SubagentStart` | "you COULD if you wanted to run an agent like that, equiped with ritual" | SUBAGENT.md, s37. Does not fire for `claude -w`, so no performance reaches it |
| ✓ | 38 | `SubagentStop` | same | SUBAGENT.md, s38 |
| D | 39 | `TaskCreated` | — | inbound only. No use found. Deferred to TASK.md |
| D | 40 | `TaskCompleted` | — | inbound only. Deferred to TASK.md |
| | 41 | `StopFailure` | "I still want to better understand before i can say a thing about it" | Cannot block — the docs say "Output and exit code are ignored". This row used to claim `error_type` and `error_message`; neither field exists. Recorded raw by `stopfailure.d` and measured 2026-08-08 by turning the wifi off: the fields are `session_id`, `transcript_path`, `cwd`, `prompt_id`, `effort`, `hook_event_name`, `error`, `last_assistant_message`, and `agent_id` only sometimes. `error` is the matcher value; a dead network arrives as `server_error`, not `unknown`. `last_assistant_message` already holds the words to speak — "API Error: Unable to connect to API (ENOTFOUND)". It fires per session and independently in each: one wifi outage produced five records across three unrelated sessions. `agent_id` is present only when the failing turn belongs to a sidechain, so one session wrote two records in the same second, one with an `agent_id` and one without, and a third ten seconds later with a different one — without reading it, a subagent's outage is attributed to the performance |
| | 42 | `Notification` | "Notification is one that is on my wish list actually" | carries `notification_type`, `message`. Cannot block |
| ✓ | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | ground makes the tree and prints the path |
| ✓ | 51 | `WorktreeRemove` | — | no decision control; ground cannot refuse |
| | 56 | `CwdChanged` | — | `old_cwd`, `new_cwd`. The lookup-by-path event |
| | 57 | `SessionEnd` | — | a live performance in an ending session |
| ✓ | 58 | `SessionStart` | — | `briefing` goes into `additionalContext` |
