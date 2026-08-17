# A ritual whose whole job is to watch CI it cannot influence. long-coin is a
# fair coin by default; the rigs make a red or a green available on demand,
# because building the path either one takes should not wait on chance.

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ftcasfl-fair"

  control {
    name: "coinflip-fair-multi-rites"

    ritual {
      system: "You were performed by a control, not by a person. Ground runs the rite and reads the run itself. While it passes there is nothing for you to say. When it fails, name what failed and what the logs give, and nothing beyond that."

      tree: "empty"

      toss { rig: "none" }
      toss2 { rig: "none" }
    }
  }
}

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ftcasfl-heads"

  control {
    name: "coinflip-heads"

    ritual {
      system: "You were performed by a control, not by a person. Ground runs the rite and reads the run itself. While it passes there is nothing for you to say. When it fails, name what failed and what the logs give, and nothing beyond that."

      tree: "empty"

      toss { rig: "heads" }
    }
  }
}

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ftcasfl-tails"

  control {
    name: "coinflip-tails"

    ritual {
      system: "You were performed by a control, not by a person. Ground runs the rite and reads the run itself. While it passes there is nothing for you to say. When it fails, name what failed and what the logs give, and nothing beyond that."

      tree: "empty"

      toss { rig: "tails" }
    }
  }
}

rites toss {
  params: [rig]

  T1FLIP1 {
    dispatch: "teranos/ground long-coin.yml"
    inputs:   `echo "rig=$rig"`
    to:       parent
  }
  SLEEP1 {
    run: "sleep 30"
    to:  parent
  }
  T1FLIP2 {
    dispatch: "teranos/ground long-coin.yml"
    inputs:   `echo "rig=$rig"`
    to:       parent
  }
  SLEEP2 {
    run: "sleep 2"
    to:  parent
  }
}

rites toss2 {

  T2FLIP1 {
    dispatch: "teranos/ground long-coin.yml"
    to:       parent
  }
  SLEEP1 {
    run: "sleep 2"
    to:  parent
  }
}
