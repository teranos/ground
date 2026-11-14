### mycelia

"so, why would the part that asks the node, not be able to be its own tiny binary"

mycelia is the one process on a machine that asks the node. What it learns it
keeps under `~/.local/state/ug/`, or writes into ground's store, and every
surface reads it there:

```
ag           above the prompt, per session
             the prompt
ug           the statusline, per session
ground_tmux  the tmux row
mycelia      asks the node, writes the store
```

It asks the node for:

- the node's row, with each plugin's deploy, kept in `mycelia`
- what the node left on its status row as news, written into ground's store,
  which sky hands to the session
- what is collected for an agent (QNTX `server/collected.go`), kept whole in
  `collected`: what waits for each session, and what each session said that
  waits for another

"i see, so the tmux row, would just be named like, ground_tmux"

ground_tmux draws the row from the store and asks the node nothing.

"yeah, I guess this is the clean way"

"i want both incomign and outgoing"

`ground collected` reads what mycelia kept for the session it runs in, by the
DID of the session's own key: one line a message, due on this machine's clock,
`<--` for what comes in and `-->` for what goes out. `ground collected json`
is the same for ag, which draws it above the prompt.

"kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"

"next reboot i expect to have to put my finger again."

What a person does with what waits (release, hold, later, cancel, edit) is the
person's to say, and the node refuses it from any key an agent on the machine
can read. So the person has a key of their own, kept where only mycelia sees
it:

- `mycelia connect` makes it, keeps the seed in the Keychain behind Touch ID,
  writes its DID to `~/.local/state/ug/person`, and signs it in to the node.
- A press is handed to mycelia over `~/.local/state/ug/mycelia.sock`, which
  only the person's user opens. On the first press since it started, mycelia
  takes the seed out, with a touch, and holds it until it stops. It signs
  only what a person does with what is collected.

"i want to get past it"

Only a binary signed with the team's profile and its Keychain group sees the
seed, so mycelia is built as `Mycelia.app` and signed: `make ug/Mycelia.app`,
with how this machine signs in `~/.config/mycelia/signing.mk`, outside the
repository. `~/.local/bin/mycelia` points into it.
