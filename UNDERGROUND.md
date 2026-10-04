This document is governed by the ground control: controls/ug-docs-adherence.pbt
Spec: <https://code.claude.com/docs/en/statusline>

### 1.a — parity is the gate

"i need to lose 0 parity on collet, everything about it is load-bearing and i cant do without"

> Nothing switches over on a row that looks close. It switches on a row that is
> the same bytes, which is answerable because collet is stdin to stdout and
> nothing else.

#### 1.a2 ✓ — the capture is the reference

"just snapshot what collet sees now, and use that"

> Collet runs against the real world and the harness records around it, so
> nothing is injected and no fixture has to be pointed at. Sandwiching the spawn
> bounds the tick, which brings the marquee, the blink and the scan back into
> byte coverage.

#### 1.a3 ✓ — ug is its own binary

> Separate from ground, still in -betterC. Said in an earlier session, and the
> store is searched one session at a time, so it stands here unquoted.

### 1.b ✓ — collet keeps rendering the whole time

"while we develop the D replacememt, i need the old collet to keep working basically"

### 1.c ✓ — this directory only, for now

"but also, making sure it only affects this dir sessions for now"

"dir restriction is lifted. ug is set globally, its good enough for being a replacement to collet."

The rug items came out of RITUAL.md, where they sat deferred among ritual
mechanics they are not. Each one is something the status line draws, so each one
is ug's to answer. The original numbers are kept and prefixed rug.

### rug29 — a state collet cannot render is a compile error

"[kill] is now active because we can see the [ and ]"

### rug64 — a completed ritual shows the closing sentences after its rites

"when a ritual ends fully, when it is fully ended and completed ... turns into this: SOURSOP > LIME > JACKFRUIT > CHECKWILLOW > DONE \| Done. All fruits are picked."

"i meant sentences"

"i dont care who owns the last rite"

"the colors should do the work"

"and the brackets"

### rug66 — who held the mic when each rite passed

"i want to be able to know if an agent went through the chain or ground"

"agent should be at [ ]"

"and if ground went through them it should be a different green"

"the agent [ and ] should have moved no further than apple"

### Limitation — the node's news reaches a session only through `ug tmux`

> What a built-in on the node concludes, a CI verdict or a quote with no source,
> is left on the node's status row for two minutes. `newsPass` in `ug/tmux.d` is
> the only thing that asks the row for it and writes it into ground's store,
> where sky hands it to the session. With no tmux drawing `ug tmux`, nothing
> writes it down, and the session is never told.

