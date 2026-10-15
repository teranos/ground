# Live-test fixture for the held nix shell. It performs in ground's own
# checkout, which has a flake.nix, so every rite should print a /nix/store ldc2.

scope {
  path:  "/teranos/ground"
  event: "PostToolUse"
  cmd:   "echo held-shell"

  control {
    name: "held-shell"

    ritual {
      system: "You were performed by a control, not by a person. Do what each rite asks and nothing else."

      shelled
    }
  }
}

rites shelled {
  # The session's own Bash, not a rite's: only the agent can write this file.
  # First, because the opening prompt is the briefing an agent acts on.
  SESSION {
    eval: `test -s SESSION.txt`
    msg:  `With your Bash tool, run exactly this one command: { echo "IN_NIX_SHELL=$IN_NIX_SHELL"; command -v ldc2; } > SESSION.txt`
    to:   parent
  }

  SAID {
    run: `cat SESSION.txt; rm -f SESSION.txt`
    to:  parent
  }

  ENTERED {
    run: `echo "IN_NIX_SHELL=$IN_NIX_SHELL"; command -v ldc2`
    to:  parent
  }

  HELD {
    run: "sleep 20"
    to:  parent
  }

  AGAIN {
    run: `echo "IN_NIX_SHELL=$IN_NIX_SHELL"; command -v ldc2`
    to:  parent
  }
}
