# Live test for regoto. A push to ground starts it; a push while it walks
# sends it to W2, its tree brought onto the new push.

project {
  path: "/teranos/ground"

  control {
    name: "regoto-walk"
    event: "PostToolUse"
    cmd: "git push"

    ritual {
      system: "You came into existence because of a git push to teranos/ground. You do nothing to the tree; each turn, say which rite the walk is on."
      regoto: W2
      # Its own tree, so a regoto moves that tree and never this checkout.
      tree: "checkout"

      walk
    }
  }
}

rites walk {
  W1 {
    run: `sleep 10`
  }
  W2 {
    run: `sleep 10`
  }
  W3 {
    run: `sleep 10`
  }
  W4 {
    run: `sleep 10`
  }
}
