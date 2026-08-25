rites forever {
  # One that always passes, so the walk starts and the line has somewhere to
  # have been before it stops moving.
  ALWAYS { eval: "true" }

  # And one nothing can meet. The condition is not about the tree, the agent,
  # or the world — it is false, and stays false however hard anyone works.
  NEVER {
    eval:  "false"
    catch: 1
    msg:   "This rite cannot be met. Ground will keep throwing your Stop back."
  }
}

project {
  path: "/teranos/ground"

  ritual perpetuity {
    tree: "checkout"
    system: "You are here to be refused. One rite cannot be met, and that is the point rather than a problem to solve — you do not edit the ritual, the pbt, or ground to make it pass. Each turn, say plainly that you were thrown back again and how many times."

    forever
  }
}
