# A ritual whose whole job is to watch CI it cannot influence. long-coin is a
# fair coin by default; the rigs make a red or a green available on demand,
# because building the path either one takes should not wait on chance.

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ftcasfl-fair"

  control {
    name: "coinflip-fair"

    ritual {
      system: "You were performed by a control, not by a person. Ground runs the rite and reads the run itself. While it passes there is nothing for you to say. When it fails, name what failed and what the logs give, and nothing beyond that."

      tree: "empty"

      toss { rig: "none" }
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

  FLIP1 {
    dispatch: "sbvh-nl/grove long-coin.yml"
    inputs:   `echo "rig=$rig"`
    to:       parent
  }
  # Longer than the driver's 15s poll, so FLIP1's run concludes while the walk
  # is still inside this rite — which is the only way to see CI reach an agent
  # that has already moved on.
  SLEEP1 {
    run: "sleep 30"
    to:  parent
  }
  FLIP2 {
    dispatch: "sbvh-nl/grove long-coin.yml"
    inputs:   `echo "rig=$rig"`
    to:       parent
  }
  SLEEP2 {
    run: "sleep 3"
    to:  parent
  }
}
