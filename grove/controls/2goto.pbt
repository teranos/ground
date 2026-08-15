rites twice {
  # Always met. It exists to be the place BACK sends the walk to.
  LOOP { eval: `true`  to: parent  mic: "Round again." }

  # Never met, so it always jumps. Two jumps is the whole budget.
  BACK {
    eval:  `false`
    catch: 1
    goto:  LOOP
    to:    parent
    mic:   "Spending a goto."
  }
}

project {
  path: "/teranos/ground"

  # Per performance (a full run of a ritual) default: 16
  max_goto: 2

  ritual 2goto {
    twice
  }
}
