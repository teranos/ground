# A ritual whose whole job is to watch CI it cannot influence. long-coin fails
# about half the time on purpose, so the agent meets a real red rather than a
# slow green.

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo ftcasfl"

  control {
    name: "coinflip"

    ritual {
      system: "You were performed by a control, not by a person. Ground runs the rite and reads the run itself. While it passes there is nothing for you to say. When it fails, name what failed and what the logs give, and nothing beyond that."

      tree: "empty"

      toss
    }
  }
}

rites toss {
  FLIP1 {
    dispatch: "sbvh-nl/grove long-coin.yml"
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
    to:       parent
  }
  SLEEP2 {
    run: "sleep 3"
    to:  parent
  }
}
