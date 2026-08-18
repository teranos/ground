# Live-test fixture for a control that performs a ritual. Fires on a benign
# marker command in grove. A performance row appearing that nobody typed
# `ground ritual` for is the whole proof.

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ritual-of-control"

  control {
    name: "ritual-of-control"

    ritual {
      system: "You were started by a control, not by a person typing a command. You do the one thing the rite names and you say that you were performed rather than invoked."

      # Nothing here is about grove's contents, so the tree holds none of them.
      tree: "empty"

      obedience
    }
  }
}

rites obedience {
  MARK {
    eval: `test -s CONTROL.md`
    to:   parent
    msg:  "Write into CONTROL.md what triggered this performance. Nobody ran `ground ritual` for it."
  }

  CLEAR {
    run: `rm -f CONTROL.md`
    to:  parent
    mic: "CONTROL.md is cleared, so the next trigger has a full walk."
  }
}
