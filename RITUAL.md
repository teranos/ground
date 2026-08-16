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
| ✓ | 3 | Rite block: `<name> { eval: msg: catch: goto: }` | `proto.d` | "1. make parity YES/NO ? 2. commit, push, 3. keep checking ci" | each step became a rite |
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
| ✓ | 19 | A rite that is not met throws the mic back | `stop.d` | "so catch means hold, until true" / "the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop" | `handleStop` — a live performance is exempt from the `stop_hook_active` guard, so the rite is asked at every Stop. It writes the block, and `threw` stamps `thrown_at` and counts it. This half fires; measured stamps exist. Held open only because it has not been watched happening |
| x | 74 | The agent carries on when the Stop goes back | — | — | Moved to AGENT.md a74 on 2026-08-11. Number stays spent |
| ✓ | 20 | Halt with code + output on screen | `stop.d`, collet | "leave on the screen the non 0 non 1 was and its message" | the halted rite stays on the line in red |
| ✓ | 21 | The current rite runs and the position moves | `ritual.d` | "it takes a super long time before an agent will reach Stop" | `advance` |
| ✓ | 22 | The agent knows where it is, what happened, and what the author said | integration | "msg i also want as anotgher optional one" | The briefing carries all three: "Performing ritual willow, rite 5 of 10: MANGOx1. It is met when this exits 1: grep -qxF ... . Take the MANGO out of WILLOW.md." Where it is, how many times it has been asked, the pass code, the command, and the author's `msg`. An Advance is prefixed with "<RITE> passed." so the agent learns whether the last thing counted before being told the next thing |
| ✓ | 23 | Attest each rite's outcome | `ritual.d` | — | one row per attempt |
| ✓ | 24 | Name a ritual | `ritual.d` | "i want to specify a ritual" | naming writes a live row; is that starting? |
| ✓ | 25 | Abort a ritual | command | "it ends when it ends, not because i ran ritual stop" / "ground should take responsibility" | the exception, not the exit. `ground abort <handle>` marks the row, and the agent ends itself at its next Stop through `continue: false` — https://code.claude.com/docs/en/hooks. Verified 2026-08-08 on `willow-nhf`: aborted at position 4, agent view reported the session `idle`. `reapScript` and `agent_pid` are the earlier mechanism, `pkill -f "claude -w <id>"`, which matches nothing once the agent is a background session — `willow-ml6` was aborted under it and stayed `busy` on a finished performance |
| D | 26 | List rituals for this path | command | "ask about rituals for where we are now" | |
| D | 27 | Show one ritual's rites | command | "ask about what rites are inside of one specific ritual" | |
| ✓ | 28 | Collet knows where a performance is | collet | — | mine. READONLY could not open a WAL db, so this read nothing and neither did the ✉/⏳ counts |
| D | 29 | A state collet cannot render is a compile error | collet | "[kill] is now active because we can see the [ and ]" | it renders; an unknown glyph is refused at runtime, not at compile time. Deferred behind the migration of collet into ground as D, which is its own branch — a compile-time refusal in Crystal would be rewritten immediately after |

Not in the example above, and therefore not implementable from it:

| | nr | thing | quotes | notes |
|---|---|---|---|---|
| ✓ | 30 | `pass:` | "i meant, from 0 to 1, the gate is from 0 to 1" | the code that advances, default 0 |
| x | 31 | `$AUTH` | — | hallucinated. `qntxToken` already resolves the token |
| x | 49 | — | — | confabulated. Number burned |
| x | 69 | — | — | confabulated. Number burned |
| x | 32 | Carrying a value between rites | — | poorly defined, won't do |
| ✓ | 43 | Terminal state | "it ends when it ends, not because i ran ritual stop" | Done or Halted, reached by running |
| ✓ | 44 | Colour for a ritual that ended | "green is passed" / "blinking red is halted" | done needs no word; halted and aborted say so |
| ✓ | 45 | The ritual keeps moving while the agent works | "it takes a super long time before an agent will reach Stop" | `ground drive <tree>`. Eight rites in ten seconds against one per turn |
| ✓ | 71 | A rite holds the mic for at most 2 seconds | "a rite can only take hostage for at most 2 sec" / "the white state color should be occupied for at most 2 sec" / "ground, or the rite should have no reason to keep holding the mic for longer than 2s" | Ground has nothing to wait for: it evaluates the condition and either knows what to say or does not, so it speaks and passes the mic at once. ground's Stop hook measures 2s max over 126 calls, so it meets this by accident and nothing enforces it. Since 87 the row says who holds it. Sampled across a whole ten-rite walk, `willow-1786300247` at 1s: `mic` alternated `agent → ground → agent` and no `ground` hold survived two consecutive samples, while the only holds past two seconds were `mic=ci` at sixteen and eleven on `moon-1786216750` — which is what `micBound` exists to tell apart, a rite waiting on nothing from a rite waiting on a run. Met throughout and enforced nowhere: `blocking()` still has no caller |
| ✓ | 73 | The mic going back is counted, and the count is on both surfaces | "let's show a counter" / "[NEVERx3]" / "if there is back and forward, it would mean the counter increments no?" | `Position.throws`, stamped by `threw()` at the throw site in `stop.d`, not in `advance` — the watcher evaluates the same rite every 15s (`handleWatch`) and a count including those would read x40 where the agent was told once. Reset by `step(Advance)` and by `jump` to another rite. Agent reads `PICKx3` in its briefing, operator reads `[NEVERx3]` on the line. Both surfaces work — seen as `[NEVERx3]` on the line and `NEVERx3` in a briefing — and the number they carry does not. Watched incrementing and being wiped on `willow-1786300247`: `throws=1` at +2s, `throws=0` at +13s, and the finished row read `throws=0` after four visible holds. That is 79, and until it is fixed the count is a lower bound rather than a count |
| x | 80 | A performance is a row in agent view | — | Moved to AGENT.md a80 on 2026-08-11. Number stays spent |
| ✓ | 82a | Every delivery names its receiver instead of grabbing a session | "THERE ARE FOR RECEIVERS" / "PARENT: HUMAN / HOSTLLM" / "CHILD : RITE  / AGENTLLM" then corrected to "WE NEED TO SAY THAT RITUAL IS THE RECEIVER, NOT RITE, RITE IS JUST A PIECE OF THE RITUAL, RITUAL DRIVES THE CHAT VIA RITES" | `ritual/delivery.d`. Every delivery site used to read whichever session field was in scope, which is how one wrong field produced three separate bugs in one night: an agent handed its own last message, a user prompt signed with an agent's name, and a parent session driven as if it were the agent. `sessionOf` is the one place a receiver becomes an address. Rite is ground and has no session, so it is not one |
| x | 82b | — | — | Mine. I read `deliver` iterating `[HostLlm, AgentLlm]`, called Human a broken channel, and wrote a requirement out of it. `"PARENT: HUMAN / HOSTLLM"` names two readers of one session; it does not ask for them to be addressed separately, and nothing you said does. Number burned |
| ✓ | 82c | The agent's first two sentences are seen by both human and host | "AGENTLLM STOP OUTPUT FIRST TWO SENTENCES OF LAST MESSAGE NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM" | The one message that names two receivers, so it is what proves 82b rather than a separate feature. `last_assistant_message` is delivered by Stop alone — measured 2026-08-16 across PreToolUse, PostToolUse and Stop — and `stop.d` hashed it for `freshWords` and dropped the text, so `firstTwoSentences` had no caller and every test stayed green. `transcript_path` is on all three events, so Stop is the only place the words are handed over, not the only place they are reachable. `said` on the row holds a hash rather than the words, which is why deleting one call site erased the channel. Restored 2026-08-16 and walked twice: `willow-1786879197` carried the agent's account on all ten rites, and `coinflip-fair-1786882559` reported a red run on the rite the walk had moved to. `agentLine` rather than `riteLine` — wiring it through the verdict path stamped `FLIP1 held` on a dispatch that can never hold, which is the rite answering rather than the agent talking |
| ✓ | 83 | The operator reads a rite's verdict without pressing anything | "i need to see it in the transcript without me having to press ctrl-o" / "i want MessageDisplay and displayContent" | `messagedisplay.d` returns `hookSpecificOutput.displayContent`, which replaces what is drawn while assistant text streams. Prepended on `index:0`, because `final:true` is the closing chunk and pastes the lines into the middle of a reply. Proven 2026-08-08 by sending a city through the channel that appeared nowhere in the text and having it read back: OAXACA |
| ✓ | 84 | A line ground injects cannot pass for the assistant's own words | "it looks the same as your text, its as if you said it, but its coming from a rite of a ritual no?" / "is it possible to change the color" / "  ░░▒▓▏ritual" / "    ░░▏rite" | Colour was tried first and does not survive the channel: an ANSI escape sent through arrived on screen as the literal `[38;5;208m`, so the mark is text. Density says which level speaks — `░░▒▓▏` the performance, `░░▏` one rite. Only the rite level has been seen in real use, on every line of `willow-6i0`; the performance level has rendered once, from a probe inserted by hand, and no performance emits one — `gutterFor` picks it when a key lacks `:rite:`, and the only such note is `ritual-agent-last`, which comes from SubagentStop and never fires for a `--bg` agent. Applied to every line of a message, not only the first, or a multi-line body falls out of the margin partway through. Without it a verdict reads as something the model said, which is the echo defect of 82 in a different coat |
| x | 85 | An agent that cannot act says so in its own form | — | Moved to AGENT.md a85 on 2026-08-11. Number stays spent |
| ✓ | 87 | CI holds the mic while a run is in flight | "there needs to be a way for the ball to land in the court of ci" / "and ci keeps holding the mic in this case" / "it keeps holding the mic until ci has an outcome" / "and the outcome is what is spoken back into the mic to both the agent and parent" | The claim moved to before the rite runs: taken after, the row named the agent for the whole time the rite blocked. `holder(r.wait)` names `Mic.Ci` for a rite that declares a `wait:`, which `proto.d` had parsed and `flatten` had dropped since it was written. Observed on `moon-1786216750`: `21:20:10.208 mic=agent`, `21:20:10.737 mic=ci`, sixteen seconds, `21:20:26.262 mic=agent` on the goto. `ciSpeaks` sends what the rite printed to both sides under a `ci:` key, which is the one the `░▓▓▏` gutter draws. The pass-jump this row called a blocker was never needed — `catch:` alone gates until the failure goes away, `catch: goto:` redirects |
| ✓ | 88 | A rite can speak, and what it says reaches both sides | "mic makes sure it also gets to us" / "if it goes through the mic, it means both the parent and the child agent would be receivers" / "nothing / msg / mic / msg+mic are all possible" | `mic:` on a rite, beside `msg:`. `msg` stays private to the agent; `mic` is heard by the parent and the agent both, so the briefing carries both and the parent's line carries `mic`. Verified 2026-08-08 on `willow-nhf`: "CHERRY passed · The CHERRY rite is looking at WILLOW.md. · I plucked a CHERRY." — the rite's words first, the agent's after, from a rite declaring only `mic:` |
| ✓ | 90a | A dispatched rite is over when the job is sent | "in the more sophisticated version, the ci rite happens while the agent continues onto the next rite without needing to wait for ci to finish" | `dispatch:` on a rite, `"<owner>/<repo> <workflow>"`, with `inputs:` for the one value ground cannot know. Ground writes the script: throttle, `gh workflow run`, exit 0. No run id, no status, no waiting — the walk advances and the agent is never told. 87 is the blocking case of this, where everyone waits. Walked live 2026-08-15 from a session with no prior context: `FLIP1 → SLEEP1 → FLIP2 → SLEEP2`, the parent never blocked, two API calls for the performance |
| | 90b | A block does not complete while a dispatch is outstanding | "ci passing would still gate the end of a ritual (read ritual not rite)" / "a rites block will not complete until each of its rite dispatch has been completed" / "in my mental model rites toss is over when both dispatches are over" | Built and removed the same day. I kept the outstanding run ids in `DISPATCHED`, a file inside the worktree that nobody asked for and nobody saw, and got the ids by listing runs before and after a dispatch and assuming the difference was its own. That guess is wrong in exactly this ritual's shape — two dispatches seconds apart against one workflow. The state belongs in the position row, which already carries `states`, `gotos`, `throws` and `holds`; the id belongs to whatever dispatched it rather than being inferred from a list. Today Done is just running out of rites |
| | 90c | A run's result reaches the parent when that run concludes | "failure needs to prop to parent immediately when i happens" / "if FLIP1 ci is red, parent should know about it on T15 and the FLIP2 ci red would surface on T2 + T15" | Per run, not batched at the end of the block. Corrected 2026-08-15: green is spoken too, never silence — a run that passed is as much a result as one that failed, and a channel that only opens on failure leaves you unable to tell a green from a rite that never resolved. Never built |
| x | 90d | The mic is taken from the agent and CI speaks, now, whether or not it is looking | — | Moved to INTERRUPT.md on 2026-08-16, where it is `interrupt` and not a number. Number stays spent. It leaves as the row whose quotes were wrong: it read "CI takes the mic for one announcement and hands it straight back" and carried three quotes, one of which — the `diverts` sentence — is not the user's, and the other two answer to no transcript. That paraphrase sat at rank 3 for fourteen days and aimed the work at a weaker thing, a delivery the agent reads when it next looks rather than an interrupt it cannot avoid. Restated 2026-08-16 from session text, then taken out of the table entirely, because a row this size in a cell is how the softening happened. No channel ground has is one: `writeNote` drained as `asyncRewake` exit 2 reaches the agent at its next turn, which is a queue, and a queue is the opposite of inevitable |
| ✓ | 90e | A tool that could not run has not answered anything | "this kind of shit, the quota error, it should not even try to continue the entire thing should just halt" / "+70% GLOBALQUOTA USE MEANS ADDING 10s BEFORE EVERY gh TOOL CALL" | A `gh` call that fails on a rate limit, a 403, a 5xx or a connection error exits `RITE_UNREACHED`, which CTFE refuses as a catch, so it halts once instead of being read as "not yet". Measured before it: 73 holds and 20 throw-backs against one rate limit, and 5000 requests spent in an afternoon — partly ground's retries, partly another session polling a different repo, since the quota is per user. `gh_throttle` runs before every call: 2s past 10% of the quota, 10s past 70%, both announced. `gh api rate_limit` is exempt, verified — `used` stayed at 52 across three consecutive calls |
| ✓ | 89 | Words belong to the hold that produced them | "make the message a property of the mic" | `wordsHash` and `freshWords`, with the hash on the row. A line carries the agent's sentences only when they are new since the last hold. `willow-kkp` put one complaint on six rites — `LIME passed · I can't pluck the MANGO`, `CHECKWILLOW passed · I did not pluck the SOURSOP` — because the words attached were the most recent, not what was said while holding |
| x | 93 | A ritual carries the agent's system prompt | — | Moved to AGENT.md a93 on 2026-08-11: it is about what an Agent is, not about how a walk moves. Number stays spent |
| ✓ | 94 | `run:` — a rite does a thing before it asks anything | "I want gh invocations to be more explicit, and not assumed to be ran by the agent" / "everything gh exposes should be easily accesible from a rite, from any rite" / "i am not actually saying, use eval for it. i say use a different rite that runs a tool unconditionally, like gh, its subcommands and parameters" / "run: makes sense, i pairs well with eval:" / "let's say `run:` is unconditional, and always happens at the beginning of the rite, before eval would happen, and before the agent get's a chance to get the mic" / "a `run:` happens regardless, an `eval:` returning false, would make you redo the rite yes, but a false `eval:` doesnt mean the `run:` would occur again" / "`goto:` does trigger `run:`" / "well, it would be the rite holding it no? so that's Ground in this case" / "making a PR at the end of each DONE was a mistake" / "i want NO pr to be created if i did not set it" | Supersedes 61. `eval` asks whether the rite is met; `run` asks nothing and does the thing. A rite can carry both. Order within one rite is `run` → agent → `eval`, and the mic through it is Ground → Agent → Ground, because in all three the holder is the rite. `run` fires once per entry, so a false `eval` returns the agent to the rite and asks again without the tool firing a second time — the hold loop is agent ⇄ eval with `run` outside it. `goto` is a fresh entry and does fire it; pointing a `goto` at a rite that opens a pull request is an authoring mistake, not a grammar one. A rite with `run` and no `eval` asked nothing and advances once the tool has run. "a failed run: is critical enough for us not to want to continue and return the error point blanc , keep the mic" — so a non-zero `run` halts, whether or not an `eval` follows it, and what the tool said goes back unmodified rather than as ground's account of it. The mic is not handed on. A rite's output was lost twice over, both fixed 2026-08-10. `advance` read a run's output on the failure branch only, so a tool that succeeded had what it printed dropped before anyone asked who wanted it. Then delivery was gated on `wait > 0 && to != None` — 46 surviving at a call site, since `deliver` was fixed to never gate the causer but was not reached at all for a rite naming no receiver, which is every rite in every pbt on disk. Now: a run speaks the moment it succeeds, under its own `:run` key, because a hold sends the agent back to a rite it can only act on having read what the tool said; and any rite that printed something speaks it. `ciSpeaks` became `riteSpeaks`, keyed `ci:` when the rite waits and `rite:` otherwise — `wait:` says a rite is slow, not that it is CI, and a PR comment signed `ci all checks passed ✓` is the record lying. `gutterFor` already routed `:rite:` to the rite gutter, so the display needed nothing. `prScript`, `commitScript` and the `branch:` project field it consumed are gone as of 2026-08-13, having sat with no caller: a field that parses and steers nothing reads as a setting. A ritual that wants a base says `--base` in the rite that runs `gh`, which is where the invocation already is. `grove/controls/chapters.pbt` was the one pbt using it and now names its base inline |
| ✓ | 95 | A control performs a ritual | "so this would not be a ritual in the sense we are doing it right now where we invoke it by ground cmd" / "it performs ritual" / "this is actually the thing that would make it a total killer feature to me, because it literally is a mechanical ritual in all honesty" / "i want an agent to see it through and monitor it" / "it runs in empty space" / "dont make it investigate, its sole duty is to report back as honestly and factually as possible with zero temperature" / "i want anything else than success to report back no matter what" | `ritual: "name"` performs one declared elsewhere; `ritual { }` carries its own, registered under the control's name and located by the scope's single path. A scope naming two paths, or a negated one, is a compile error — it says when a control fires, not where a ritual performs. The scope owns `cmd`, so the control carries only what it does, the way `exec:` already did. Three exits are the vocabulary a monitor needs and the grammar already had them: 0 passes, 1 holds and asks again, anything else halts and reports — "if its non 0/1 we should just stop and halt the agent". `tree: "empty"` is an orphan branch onto the empty tree, so a performance with nothing to inspect has nothing to inspect; git 2.28 has no `worktree add --orphan`, so the empty tree is named and a commit built onto it. Walked 2026-08-14 on `grove/controls/ritual-of-control.pbt`: `echo ritual-of-control` in grove, `ritual-of-control-1786737685` reached `++` and Done with nobody typing `ground ritual`, and its branch held one root commit and the single file its agent wrote. Two defects found by firing rather than reading. The scope never matched, because `PostToolUse` tested the session cwd and the work was done by `cd`-ing elsewhere — now `effectiveCwd`, the tracking `checkAllCommands` already had. And the row was written with an empty id and worktree, because extracting `preparePerformance` left its buffers local and every slice dangled on return; `Staged` is held by the caller, and the test is a unittest because a CTFE `enum` cannot say "these stay alive". Unbuilt: the QNTX deployment ritual this was for, which is arrived at a rite at a time |
| ✓ | 96 | A performance that ends ends its agent | "HOW IS THERE NOT A REAL NATIVE TRUE WAY TO KILL THE BG SESSION" / "WHY IS A STRAIGHT KILL THE ANSWER" / "nothing should be running in terms of rituals or their agents" | `claude stop <id>`, and `claude kill <id>` is its alias. Proven 2026-08-15: `claude stop 422bddec` answered `stopped 422bddec`, named the worktree it kept, and named `claude rm <id>` for the job state. The id is the short one `claude agents --json` lists beside `cwd`, `startedAt` and `state`. `reapScript` runs `pkill -f 'claude -w <performanceId>'` and has never matched a process: sampled every second through a whole performance, `pgrep -f 'claude -w'` returned 0 at every sample, live and done. The comment above it says the id appears in the agent's command line and nowhere else, which is not so — the running agent reads `--resume <transcript>`. `agent_pid` is stored on every row, commented "the process carrying it, so an ending can end it", and read by nothing. Killing that pid is the wrong shape anyway: it drops the agent mid-turn, needs ground to win a race with whatever restarts it, and `claude stop` is an ending rather than a signal. Measured before finding it: sixteen background sessions accumulated, the oldest five days old, every one `state: blocked` on a permission prompt, ~100MB each on an 8GB machine. `claude agents --json` is a record store and not a liveness check — it listed six blocked while `ps` showed zero claude processes, so a leak check cannot be built on it; `ps` is the signal. Both `claude stop` and `claude rm` need the background service up, so they answer `couldn't confirm … the background service may be restarting` when no daemon is running. The `--cwd` flag filters by where a session was *started* and ground's spawn script cds to the repo first, so it answers `[]` for every worktree — the reap selects on the `cwd` field in the JSON instead, which is the tree. The script that runs it swallowed three failures with `|| true` and both callers threw the result away, so a reap that ended nothing read exactly like one that ended the agent; that is the axiom's own failure mode, and it is why the leak was found by a dying machine rather than by ground. Nothing is suppressed now and `drive.d` and `command.d` emit `ritual.reap` with the exit code, the tree and the script's own output. Watched on `coinflip-1786831304`: `agents-on-tree=1` while live, still 1 at the instant the row read `done`, 0 two seconds later, and 0 for the following minute |
| | 92 | A rite and a control compose in the same block | "you forgot that i wasnt happy about rite's cmd being essentially a completely different thing from the control's cmd" / "Imagine i wan't to mix Rite and Control in the same Rites block" / "i want the machinery to be interchangable and composable" / "to me its eval" / "because its evaluated, and its up to the writer of the rite to change default eval behaviour through to: goto: pass: etc" | `cmd` names two things pointing opposite ways. `struct Cmd` — `Control.cmd` is `string[8]`, patterns matched against a command the agent is about to run. `FlatRite` — the rite's was one shell command ground runs for its exit code. `eval:` is the rite's word, and it is the operation rather than a property of it: `pass:`, `catch:`, `goto:`, `to:`, `wait:` and `mic:` are all modifiers on an evaluation. Renaming frees `cmd` to keep the control meaning, which is what a rite and a control need before they can sit in one block without the word flipping direction between two lines. Predates this session and was never written down, so every scope conversation up to 2026-08-09 ran against a register missing it. Built: the rename, refused rather than aliased — `cmd` in a rite is a CTFE error naming the rite. Unbuilt: the composition itself, which still has no answer for whether a control in a rites block advances the position or fires beside it |
| | 79 | One thing advances a position | — mine, from reading the callers | `advance` is called from `stop.d`, `handleWatch`, `handleDrive` and now `subagent.d`, and nothing coordinates them. Only two stamp `threw`, which is right, but a rite the watcher advances past resets the count via `step(Advance)` with no event the operator sees. The driver exists for `handleRitual` — "the position only advances when a turn ends, which for a working agent can be never" — and that reason survives every change tonight, so this is not solved by deleting one of them. Watched happening on `willow-1786300247`, sampled at 1s: `throws=1` at +2s, `throws=0` at +13s, and the row finished at `throws=0` after four holds the delivered lines name — `CHERRY held`, `MANGO held`, `LIME held` twice. Two writers, last one wins. A counter that undercounts silently is worse than none, because a frozen one means either a stall or a race and there is no way to tell which |
| x | 75 | A ritual is carried by an Agent, not a detached process | — | Moved to AGENT.md a75 on 2026-08-11. Number stays spent |
| x | 76 | — | — | A duplicate of 58 that grew prose. Its title was mine and its quotes are about something out of scope for this branch. What was live in it is on 58. Number burned |
| | 72 | A performance cannot outlive one compaction window | "i think a ritual cant run longer than one compaction window" / "it a high upper bound" | Not a timer — ground already has the event. `precompact.d` handles PreCompact, and `attestationExists` already asks "did a PreCompact happen in this session after this". A performance is bound to the agent's session, so the bound is: PreCompact for session S ends every live performance on S |
| x | 46 | A rite's verdict reaches the agent, unasked | "isnt it the perfect mechanism to fiannly use for intterupt on rite ?" / "to: agent doesnt make sense" / "no user facign i would say" / "not part of the api" / "doesnt make sense, because why would you have to specify it ? its expected, everything comes abck to causer" / "i am a user, not an agent" | `writeNote` to the agent's session, delivered by the watcher as asyncRewake exit 2. Measured three times on 2026-08-07, real content, nobody asked for it. `handleDrive` already writes it and had never fired, because `p.session` was empty until `SessionStart` bound it. The key is done and went further than owed: `stop.d` and `drive.d` now key on performance, rite and `rev`, so a rite asked twice is two notes rather than one id already marked delivered. Walked 2026-08-08: `ci:moon-1786215134:JUDGE:22` and `:36` both landed, where the old key would have shown the first and swallowed the second. `handleDrive`'s `rite-open` and `handleDrive`'s `ritual-moved` keep their fixed keys on purpose: `rite-open` is written every fifteen seconds while a rite holds, and a unique key there wakes an agent with twenty identical briefings. A briefing is state, where only the latest is wanted; a verdict is an event, where every one is. Burned 2026-08-09. Number stays spent. `deliver` gated `AgentLlm` on `wants(to, one)` while `parseReceiver` can only return `PARENT` or `None`, so the causer was skipped for every rite in every pbt; the row said a rite had to name `AgentLlm`, which was my sentence and not read from anything here. Gate removed, `delivery_test.d` refuses a permission check on the causer's path including for a rite that names no receiver. It is not a row because it is not a feature: results come back to the causer, and that is ERROR work, not a table entry |
| D | 70 | Ground's trace is on your screen as it happens | "the first two sentences of what happened in last_assistent_message pre-Stop inside of any rite as a Notification in the parent session" / "it seems like it would increase the clarity i have into ground by an absolute incredible amount" / "i believe my temporal awareness is much greater than yours" | `Notification` exit 2 shows stderr to the user and nothing else. Built and never fired: the watcher drains the same queue every two seconds and always wins, so the lines need a record only this reads, drained in one batch per notification rather than one line. 83 is what carries the lines today and it is not this row: `handleMessageDisplay` returns unless `firstChunk(input)`, so it can only prepend to an assistant message that is already streaming. Measured 2026-08-08 — a whole walk's lines sat in the queue while the parent was inside tool calls and arrived in one batch the moment it next spoke, up to sixteen rows per call. The queue was never slow. The channel has nothing to draw on until the parent talks. Deferred into the collet-to-ground rewrite, which is its own branch: the status line is the one surface that redraws without the parent talking, which is what this row needs and what every channel tried here lacks. Collet gets no further development — the rewrite replaces our usage of it |
| ✓ | 47 | A CI check is a rite like any other | — | grove's `JUDGE` in `moon.pbt` is `eval:` + `catch: 1` + `goto: WIPE` + `wait: 20` + `to: parent` + `mic:`, and no path in ground evaluates it differently from `test -s MOON.md`. Walked 2026-08-08: found the run for its own `HEAD`, held on a real red, redirected, passed on a real green, and its stdout came home as CI's words. `handleWatch` is still hardcoded, but that is the push courier — it reports on your pushes and has never been part of a performance |
| ✓ | 52 | A performance has its own worktree and branch | "each ritual perfomance occurs in separate named branches" | `repoRoot` locates the repo |
| x | 53 | Commit, push and CI auto-approved inside a performance | "commits and pushes and ci check, are all auto-approved" | Marked done on a gate that reads the live row, but `consent.d` authorises four commands and a rite needing anything else meets a prompt nobody can answer. Disproved 2026-08-11 — see AGENT.md a95 |
| ✓ | 54 | A performance is identified by itself | "the name of the branch is not something to key on" | path is an index, not the key |
| ✓ | 55 | A performance survives losing its worktree | "item 55 approved now" | `WorktreeRemove` clears the stale path and keeps the record |
| ✓ | 59 | Ground removes the tree it made | "the reason you need to remove them by hand is because?" | the driver removes it on Done. A halt keeps its tree — what the failing rite left uncommitted is what you would look at |
| ✓ | 60 | Ground says it made one | "I dont like that its siltent" | creation was silent |
| x | 61 | The performance ends in a pull request | "did it submit a pr at the end as well?" | on Done only, and a halt opens nothing. `sbvh-nl/grove#1` was opened by a performance nobody touched after starting it |
| ✓ | 62 | A `goto` cycle is bounded | "let bound it to max 16 and make it say clearly that the goto can only be invoked at most 16 times in a single ritual" | `MAX_GOTOS`. Spending the budget halts rather than holds — holding waits on a jump that will never come |
| D | 66 | Who held the mic when each rite passed | "i want to be able to know if an agent went through the chain or ground" / "agent should be at [ ]" / "and if ground went through them it should be a different green" / "the agent [ and ] should have moved no further than apple" | the bracket is the agent's position and stops where the agent stopped. Rites past it are a darker green because ground walked them. The mic is the word for this now and it holds the live answer: walked 2026-08-08, `moon-1786216750` read `ground` while each rite ran, `ci` for the sixteen seconds `JUDGE` waited on its run, `agent` between rites, `human` once done. What it does not hold is this row's question. `takeMic` writes `Agent` whenever the performance is live, whether the advance came from an agent's Stop in `stop.d` or from the driver in `drive.d`, and both pass the same session to `advance`. One column says who holds it now; whether a given rite was passed by an agent turn or by the driver is a fact per rite, and would have to be recorded on that rite's attestation as it passed. Deferred into the collet-to-ground rewrite, which is its own branch, along with the per-rite record the different green would read |
| D | 68 | The closing sentences are on screen when the ritual ends | "i never saw the two sentences" | the agent writes minutes after DONE, the expiry counts from `updated_at`, and with no tail nothing forces a marquee. Measured: done at 75s with the agent still running and nothing written. Deferred into the collet-to-ground rewrite, which is its own branch |
| D | 64 | A completed ritual marquees the agent's closing sentences after its rites | "when a ritual ends fully, when it is fully ended and completed ... turns into this: SOURSOP > LIME > JACKFRUIT > CHECKWILLOW > DONE \| Done. All fruits are picked." / "i meant sentences" / "i dont care who owns the last rite" / "the colors should do the work" / "and the brackets" | the rite line is kept and scrolls; the sentences follow a `\|`. No prose restating position — the colours and brackets do that. Deferred into the collet-to-ground rewrite, which is its own branch |
| x | 63 | Ground commits, not the agent | "n, i dont trust the agent with it" then "we want to get rid of the auto commit" / "make commit be done by run:" / "the ritual could make itself complete itself by asking the agent to commit while its in ask" | Was one commit per rite that passed and changed the tree. Removed 2026-08-11. A commit is a rite's condition now: `KEEP` in sun and `HOLD` in moon evaluate a clean tree with a commit ahead of origin, and send the walk back to the rite that writes the file when there is none |

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
| | 48 | `claimSession` is not session-scoped | `claimSession`. A watcher for A can claim B |

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
| x | 42 | `Notification` | "Notification is one that is on my wish list actually" | "Impossible to reason about, or have a real conversation about it with CLaude Code without it confabulating and inventing and not working with me. In my session, there were multiple instances of me doing an easy ask, If Claude Code sends notifications, and this event matches on it. do it now, you are Claude Code, you can make it happen. The reality is it cant't make it happen at will on command. The basic thing required to develop this thing, i havent yet figured out how to do it, further research required before we can make definitive statements about it, never believe anything Claude is inferring from this, always consult Antropic docs as first source." |
| ✓ | 50 | `WorktreeCreate` | "should we finally adop git worktrees for this" | ground makes the tree and prints the path |
| ✓ | 51 | `WorktreeRemove` | — | no decision control; ground cannot refuse |
| | 56 | `CwdChanged` | — | `old_cwd`, `new_cwd`. The lookup-by-path event |
| | 57 | `SessionEnd` | — | a live performance in an ending session |
| ✓ | 58 | `SessionStart` | — | `briefing` goes into `additionalContext`, and the agent's session and pid are written to the row. The binding was made and then erased: `writePosition` wrote the whole row, so the driver's next write carried a copy read before the binding and blanked it, seconds after. `bindAgent` is a targeted UPDATE of those two columns and they are out of the whole-row writes. Measured 2026-08-16 — blank on every performance before, bound at spawn and still bound at done on `coinflip-fair-1786892052` and `-1786893211` |
