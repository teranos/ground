Rituals and rites. A ritual is one or more sequences of rites blocks, and a rite is a command whose exit code says whether the walk advances, holds or halts. A performance is one full run of a ritual, in a checkout of its own. TODO A run's result reaches the parent when that run concludes "failure needs to prop to parent immediately when i happens" "if FLIP1 ci is red, parent should know about it on T15 and the FLIP2 ci red would surface on T2 + T15" "90c is only halfish done, because we cant do better on a --bg agent" TODO List rituals for this path "ask about rituals for where we are now" TODO Show one ritual's rites "ask about what rites are inside of one specific ritual" TODO A rite's verdict reaches the agent, unasked "i am a user, not an agent" TODO Ground's trace is on your screen as it happens "the first two sentences of what happened in last_assistent_message pre-Stop inside of any rite as a Notification in the parent session" TODO Commit, push and CI auto-approved inside a performance "commits and pushes and ci check, are all auto-approved" TODO Notification "Notification is one that is on my wish list actually" "never believe anything Claude is inferring from this, always consult Antropic docs as first source." TODO TaskCreated TODO TaskCompleted

## proto_ritual-ritesInput

## proto_ritual-evalInput

## proto_ritual-oldWordInput
"Imagine i wan't to mix Rite and Control in the same Rites block" — which they cannot while one word points at a pattern to match and at a command to run. `cmd` in a rite is refused, not aliased.

## proto_ritual-launderInput
— so a rite that writes its own code is refused where a bad `cmd` is.

## proto_ritual-launderEval

## proto_ritual-cleanInput
A rite that leaves its tool to answer passes.

## proto_ritual-unusedValueInput

## proto_ritual-usedValueInput
A param the block does declare is not a warning.

## proto_ritual-paramsInput

## proto_ritual-catchInput

## proto_ritual-passInput
Shell negation flattens non-zero to 0, so a broken command reads as a pass. Declared instead of inverted.

## proto_ritual-graceInput
Seconds ground holds after the Stop has gone back, not before. Nothing is checked in that window; it is the only span a throw-back can be seen in. Six seconds is a throw-back an eye can catch. Two is the default and one repaint wide, and the throw itself has no duration of its own.

## proto_ritual-waitInput
wait is spent before the first look, so it is taken after the turn's work has settled. grace is spent after the verdict, so the two never overlap.

## proto_ritual-toInput
"to: parent / means to both" — one Stop line, read on screen and in context.

## proto_ritual-systemInput

## proto_ritual-ritualModelsInput
A ritual sets its own model, nearer than its project or the top level.

## proto_ritual-badFieldInput
A word with a colon that names no field is refused by name, rather than being read as a rites group that does not exist.

## proto_ritual-overlapInput
A code cannot both advance and hold.

## proto_ritual-ritualInput

## proto_ritual-dupInput
"ok" — rite names unique across every group, so a goto target and a position report both name one thing.

## proto_ritual-sameNameTwoBlocks
— a block copied with yyp, only the block renamed, is the authoring this grammar is for.

## proto_ritual-badGotoInput
A goto that names nothing is a jump into the dark.

## proto_ritual-bothInput
An eval is a question, a dispatch is not asked at all.

## proto_ritual-missingParamInput
A declared param nobody supplies expands to empty, and an empty grep pattern matches anything — a false pass, which is the one outcome worth failing the build over.

## proto_ritual-badRefInput
A ritual naming a group that does not exist.

## proto_ritual-sandShapeInput
A real file put through the sand exposed a parse failure these inputs did not: the group's closing brace sits on its own line before a blank.

## proto_ritual-noBranchInput
`branch:` was a project field that named the base of the pull request ground opened on Done. Ground opens none — "i want NO pr to be created if i did not set it" — so a ritual that wants one says --base in the rite that runs gh.

## proto_ritual-ritualControlInput
The real control performs a ritual, and that is the shape that has to work.

## proto_ritual-twoDoorsInput

## proto_ritual-groveInput

## onoff-memDb

## onoff-memDb-2
A ParseResult is 3.3MB. Three enum temporaries in one frame came to more than the main thread's 8MB stack, and the test runner died of it. Where no project stands, nothing is switched, and it says so.

## onoff-memDb-3

## onoff-nested
A place under a project's path stands in that project.

## onoff-saidOf
A sentence with one of them inside it is a sentence, not the phrase.

## onoff-memDb-4

## onoff-projectAt
The deepest project wins, and a project inside another has a switch of its own.

## onoff-byOrigin
A project that names its repo is every checkout of it.

## onoff-wound
A project block holding no ritual has nothing to switch, however deep it is.

## regoto-withRegoto
A second fire starts no performance. The live one's tree is brought onto the push, its walk goes to the named rite with its counts started over, and its agent and parent are told. A fire after the regoto rite sends the walk back to it: regoto-walk on W3, pushed again, stood on W2 in the same row, its tree at the new push. TODO open: a fire that lands before the regoto rite jumps forward to it, W1 to W2. Whether to keep that is undecided. TODO open: without a tree of its own a regoto moves the checkout the ritual fired from. Whether the parser should refuse regoto without tree is undecided.

## regoto-withoutRegoto

## regoto-badRegoto
A regoto naming no rite of its own ritual is a jump into the dark, as a goto is.

## regoto-stage
When the stash, pull or unstash fails, the tree is set to the push and cleaned; when that fails too, the performance halts where it stands.

## regoto-stage-2
Two pushes while one rite runs: the newer is the one that waits.

## regoto-stage-3
The fire leaves the push waiting on the row. The rite in flight runs on in a tree nobody moves, and the walk stays where it is.

## regoto-regotoWalk

## ritual-start
A ritual that has not run has no history. Every rite is the darker gray.

## ritual-step

## ritual-step-2
A held rite keeps the position and stops being one that never ran, which is the whole difference between the two grays.

## ritual-step-3
The last rite passing is one of the two endings, and it needs no command.

## ritual-jump
A jump backwards keeps the history, so the line shows what happened rather than pretending it did not.

## ritual-abort

## ritual-performanceId
The id names the performance and the moment. Two performances of the same ritual are two rows, not one overwriting the other.

## rite-defaultsInput
A rite that declares nothing takes the defaults: 0 advances, 1 holds.

## rite-classify

## rite-classify-2
Anything neither declared is the third outcome. 2 is not a worse 1 — it is a different kind of answer, and the rite cannot read it.

## rite-invertedInput
Shell negation flattens every non-zero to 0, so a broken command reads as a pass. Declared instead of inverted.

## rite-multiInput
"catch: [7, 22]" — curl exits 7 when it cannot connect and 22 on an HTTP error. Both mean the box is not answering yet, neither means it failed.

## rite-gotoInput
A rite with a goto still classifies as Hold. Where a held position moves is a separate question from what the code meant.

## rite-edgeInput
long-coin knows three rigs: none, heads, tails. Asked to rig an edge, GitHub refuses at the door and the dispatch exits 1. Silence about catch is not the honest no it is for an eval: sent, or not.

## rite-foreseenInput
The author foresaw the refusal. Caught, it holds and goes to REST, and what is said about it is the author's sentence, not the exit.

## rite_script-buildRiteScript
Every rite runs under the same three flags. They are not hygiene — each one closes a way a rite can report a pass it did not earn.

## rite_script-buildRiteScript-2
A param is an assignment above the command, in the script the operator can read, not an environment the operator has to be told about.

## rite_script-buildRiteScript-3
Sourced after the cd, because a shellHook reads the tree it stands in.

## choose-groups
Four groups, one rite each, for four projects to name.

## choose-projects
Four project blocks and no more: `ParseResult.projects` is sized from the pbt files wind finds plus four headroom, so four is the floor on a machine that has none. A fifth passed here and failed in CI. The whole is what the parts say, composed rather than written twice. The wanted case, not a refusal: `zulu` is a ritual held by one project and by no other, and nothing else is called zulu, so the one word is enough. The refusals are `busy` and `moon` below, where one word is two candidates.

## choose-chooseRitual

## choose-chooseRitual-2

## choose-chooseRitual-3
Both the unnamed project and tightgrove hold a ritual called sun.

## ritual_resolve-src

## ritual_resolve-lastOfBlock

## ritual_resolve-twinSrc

## advance-loopSrc

## advance-boundSrc

## advance-memDb

## briefing-src
Which ritual, where in it, and what would satisfy the rite it is on.

## briefing-threw
A frozen count is the stall; a climbing one is the ping-pong. It reads the same here as it does on the status line.

## briefing-runSrc
Read 186 times on q-deploy-1789717456, 2026-09-18: "rite 12 of 12: VERSIONS. It is met when this exits 0: " and nothing after the colon. A rite with a run and no eval is ground's to run, and the briefing says so instead of naming a condition it does not have.

## mic-blocking
"ground, or the rite should have no reason to keep holding the mic for longer than 2s" — it evaluates and speaks, so there is nothing to wait for.

## mic-wordsHash
"and that is before the faulty commit from yours" — one complaint gets stapled to six rites when the words attached are the agent's most recent rather than what it said while holding.

## mic-holder

## contend-memDb
Both drivers read the same row before either has run anything.

## consent-performanceAnswers
Manual is the law. A performance in the same tree never lifts it.

## delivery-sessionOf

## delivery-wants

## delivery-perf
q-deploy has no agent. The session that started it stops in the checkout it performs in, so it was the one speaking, and its own words came back to it.

## delivery-memDb
"the outcome is what is spoken back into the mic to both the agent and parent" — one call, two sessions.

## delivery-memDb-2
A rite that names nobody is silent to the parent and still answers the one that ran it.

## notification-riteLine

## notification-riteLine-2

## dispatch-contains
"the dispatch happened thus we move on from the rite". It sends the job and ends. No run id, no status, no waiting — none of that is the rite's.

## apierror-angry

## apierror-holderFor

## apierror-holderFor-2

## apierror-retryable

## reap-contains
Proven: `claude stop 422bddec` answered `stopped 422bddec` and kept the tree.

## control_ritual-twoPaths
A scope naming two paths says when the control fires, not where a ritual performs. Refused at compile time rather than guessed at on a push.

## control_ritual-negated
A negated path is a place a ritual must not be, which resolves to nowhere.

## control_ritual-namedSrc
A control that names one instead of carrying one resolves the same way `ground ritual <name>` does.

## costgated-src
The gated rites stand in the block, in the order written, after what stands before them.

## models-src

## models-bareSrc
No models anywhere: sonnet. The session that performed it ran on whatever the operator was on, and a walk of rites is not that conversation.

## models-bareModelSrc
A bare model: on a ritual is refused. models { } is where it goes.

## models-twoInRitualSrc

## noul-noulSrc
The key is the primitive, the value its instructions, as eval: is a command.

## noul-scoreSrc
A score's levels are Jev's `criteria`, in order, the first one the no.

## noul-noLevelsSrc
A score without levels has no spectrum to place the state on.

## noul-bothSrc
One rite, one way to answer.

## noul-twoJevSrc

## noul-choiceSrc
A choice's options are Jev's `criteria` map: each option a rite the walk can go to, its description what sends it there.

## noul-strayChoiceSrc
An option that names no rite is a place the walk cannot go.

## org-projects
The whole is what the parts say, composed rather than written twice.

## rite_attest-riteAttributes
A Jev rite carries the size of the diff, asked about or not.

## sentry-quiet
A pbt that says nothing about sentry reports nowhere. There is no default dsn to fall back to: a key is something only the operator can supply.

## sentry-src

## sentry-topOnlySrc
One block at the top and nothing nearer: every ritual reports to it.

## sentry-bareSrc
No sentry anywhere: nothing is reported, and no host is invented for it.

## sentry-bareDsnSrc
A bare dsn: on a ritual is refused. sentry { } is where it goes.

## sentry-twoInRitualSrc

## spawn-src
The ritual says /src/proj; the declared project says where that is.

## spawn-indexOf
No effort is named at the start: how hard the model thinks is its own setting, which the usage windows move.

## spawn-spawnScript

## wiring-calls

## wiring-calls-2

## worktree-worktreePath
A sibling of the repo: findable, and `git worktree list` names it.
