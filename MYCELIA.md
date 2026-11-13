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

`mycelia connect` signs the key mycelia asks with in to the node.

"i see, so the tmux row, would just be named like, ground_tmux"

ground_tmux draws the row from the store and asks the node nothing.

"yeah, I guess this is the clean way"
