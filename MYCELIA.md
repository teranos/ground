### mycelia

"so, why would the part that asks the node, not be able to be its own tiny binary"

mycelia is the one process on a machine that asks the node. What it learns it
writes into ground's store, and every surface reads it there:

```
ag           above the prompt, per session
             the prompt
ug           the statusline, per session
ground_tmux  the tmux row
mycelia      asks the node, writes the store
```

It asks the node for:

- the node's row, with each plugin's deploy
- what the node left on its status row as news, which sky hands to the session
- what is collected for an agent (QNTX `server/collected.go`): what waits for
  each session, and what each session said that waits for another

"i see, so the tmux row, would just be named like, ground_tmux"

ground_tmux draws the row from the store and asks the node nothing.

"yeah, I guess this is the clean way"
