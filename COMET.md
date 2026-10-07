# Comet

"the feature i am imagining is called comet"

"if QNTX is heaven"

"and ground is here, as in earth"

"Comets is what slowly creates a body in earth, like space, right?"

"instead of remembering to run make install for ground, i want to flip the model"

"optionally"

The node builds ground and the build lands here. QNTX's side is ADR-050
(teranos/QNTX docs/adr/ADR-050-comet.md).

## What a comet is made of

"i want a coment per project essentially"

"or like, a generalised project, like universal ground"

"that is normal ground"

"btu also, tailed to the repo ground, wich has more CTFE'able material potentially"

"so we can still have super fast hooks, and actually even faster when the builds are done by QNTX"

wind folds the sand from three places: controls/, controls/local/, and each
declared project's controls/ with its `git ls-files`. A comet is that sand
folded on the node instead of on this disk: ground's controls from this
repository, the user's preferences from a record on the node, the project's
controls from its repository at a rev.

## Building for a Mac on the box

"I dont know if i will be able to build a D program for mac M1 on a lightsail box"

Read in LDC's driver source, 2026-10-07:

| | |
|---|---|
| Darwin target | LDC runs `cc -target <triple>` and adds `-lpthread -lm -lobjc`; no SDK, no sysroot (driver/tool.cpp, driver/linker-gcc.cpp) |
| -betterC | no druntime, no Phobos linked (driver/linker.cpp) |
| what ground links | sqlite3, curl (dub.json); libSystem, libobjc (the binary) |
| linker | ld64.lld, in nixpkgs lld 21.1.8 |
| stubs | libSystem, libobjc, libsqlite3, libcurl, libpthread, libm as .tbd, and SDKSettings.json: 15 MB under MacOSX.sdk/usr/lib |
| headers | none: ground is extern(C) throughout |

Not run end to end. The binary built here is ad-hoc, linker-signed by Apple's
ld; whether the kernel runs one ld64.lld signed is untested. Linked against
Apple's stubs, ground loads /usr/lib's sqlite3 and curl and depends on no Nix
store path at run time.

## The ROOT agent

"to get ground setup for the ROOT agent"

The ROOT agent's Claude Code on the box runs with no hooks and no ground. Its
comet is x86_64-linux, native, with a qntx block naming the node's own URL and
the agent's token.

## Per user

"Well, each user has different preferences, so in reality you build ground per user per their project"

One sand for one user, one project and one platform. The hook is `exec ground`
on PATH, one binary path-matching every project. Per project it is one binary
per repository, and a hook per repository is not built.

## Landing

"Yes, custoner uses ground, but they dont think about it because it just lands via comet"

- Pulled, never pushed: sky every five seconds, ug on the status line,
  SessionStart once a day. The node reaches no machine.
- Every row sky streams carries its version in the source column, as
  `ground <version>` (db.d), which is how the node knows what landed.
- The plugin is the first landing. Its SessionStart hook answers a
  systemMessage that the plugin is installed and not yet functional when no
  ground is on PATH (plugin/hooks/hooks.json). The customer installs the
  plugin and presents a token; the hook says the platform and pulls.
- Renamed into place, never copied over (Makefile, 2026-09-14).

## The stubs

"i see, those stubs, why not send to s3 in a manner that is documented"

They go to the bootstrap bucket the box's role already reads, as a build
input, from the deploy repository.

## Rituals

"another thing i want is that rituals run on the box from now on, not locally on my machine per se."

A ritual's driver and performer move to the box with its comet: today
`spawnScript` runs `claude -w <tree> --bg` here (source/ritual/run.d); the
node runs Claude Code with `-p` (QNTX internal/claudecode/run.go).

## Pi

"and another thing i want, but that is a way bigger item, is for ground to be usage usable with coding agent pi"

ground speaks Claude Code's hook protocol. Pi's extensions
(docs/extensions.md): `pi.on("tool_call")` mutates input or blocks,
`before_agent_start` carries the prompt, `session_start` and `agent_end`
exist, `pi.sendMessage()` puts content into model context; loaded from the
extensions directory or `-e <path>`; sessions are JSONL under the session dir.
