# Universal PreToolUse — auto-approved command controls
scope {
  path: ""
  decision: "allow"
  event: "PreToolUse"

  control {
    name: "no-skip-hooks"
    cmd: "git"
    omit: "--no-verify"
    msg: "Git hooks must not be bypassed, ever.."
  }

  control {
    name: "short-commit-message-reminder"
    cmd: "git add"
    msg: "A commit typically follows. Start thinking about the commit message — focus on why, not what."
  }

  control {
    name: "sync-main"
    cmd: "git checkout main"
    msg: "Summarize what happened upstream since the last pull."
  }

  control {
    name: "ci-check"
    cmd: "gh run list"
    msg: "Examine the result and report whether CI passed or failed."
  }

  control {
    name: "use-read-not-cat"
    cmd: "cat"
    msg: "Use the Read tool instead of cat."
  }

  control {
    name: "ci-view"
    cmd: "gh run view"
    msg: ""
  }

  control {
    name: "ci-watch"
    cmd: "gh run watch"
    msg: ""
  }

  control {
    name: "issue-list"
    cmd: "gh issue list"
    msg: ""
  }

  control {
    name: "issue-view"
    cmd: "gh issue view"
    msg: ""
  }

  control {
    name: "pr-list"
    cmd: "gh pr list"
    msg: ""
  }

  control {
    name: "pr-view"
    cmd: "gh pr view"
    msg: ""
  }

  control {
    name: "pr-ready"
    cmd: "gh pr ready"
    msg: "This means the pr is ready to merge"
  }
}

# TODO: block commits with files over 4MB
# Checkpoints — require manual approval
scope {
  path: ""
  decision: "ask"
  event: "PreToolUse"

  control {
    name: "git-commit"
    cmd: "git commit"
    msg: "Commit requires manual approval"
  }

  control {
    name: "git-push-pull-first"
    cmd: "git push"
    msg: "If you haven't pulled since the last commit, pull first and resolve conflicts before pushing"
  }

  control {
    name: "git-tag-semver"
    cmd: "git tag"
    msg: "Check the latest tag first and ensure the new version follows semver"
  }

  control {
    name: "pr-create"
    cmd: "gh pr create"
    msg: "PR creation requires manual approval. Keep the description high signal — you can refine it later with gh pr edit."
  }

  control {
    name: "pr-edit-ref-reminder"
    cmd: "gh pr edit"
    msg: "Reference any docs edited or created in this PR. Do not describe implementation details — the diff speaks for itself. Focus on why, not what."
  }

  control {
    name: "git-checkout-b"
    cmd: "git checkout -b"
    msg: "Check main for unpushed commits and push them first. Update documentation to describe intended behavior. Ask critical design questions. Then open a PR."
  }

  control {
    name: "pr-merge-checkout-main"
    cmd: "gh pr merge"
    msg: "After merge, checkout main and pull to sync local."
  }
}

# Graunde project-scoped
scope {
  path: "/graunde"
  decision: "allow"
  event: "PreToolUse"

  control {
    name: "install-after-build"
    cmd: "dub build"
    bg: true
    msg: "Run make install to update the live hook binary."
  }
}

# PostToolUse — reminders after tool execution
scope {
  path: ""
  decision: "allow"
  event: "PostToolUse"

  control {
    name: "commit-push-reminder"
    cmd: "git commit"
    msg: "A push typically follows."
  }

  control {
    name: "tag-push-reminder"
    cmd: "git tag"
    msg: "Push the tag: git push origin <tag>"
  }
}

# PostToolUseDeferred — deferred checks
scope {
  path: ""
  decision: "allow"
  event: "PostToolUseDeferred"

  control {
    name: "ci-check-defer"
    cmd: "git push"
    delay_handler: "ciDelay"
    deliver_handler: "ciDeliver"
    defer_prefix: "CI: "
  }

  control {
    name: "review-nudge"
    cmd: "gh pr"
    posttool: "@claude review"
    defer_sec: 300
    defer_prefix: "Claude left a review comment."
  }
}

# PostToolUseFailure — hints on tool failure
scope {
  path: ""
  decision: "allow"
  event: "PostToolUseFailure"

  control {
    name: "wrong-directory"
    posttool: "No rule to make target"
    msg: "Run pwd — you may be in the wrong directory."
  }
}

# PreCompact — re-inject context before compaction
scope {
  path: ""
  decision: "allow"
  event: "PreCompact"

  control {
    name: "branch-context"
    msg: "Current branch: "
    cmd: "git branch --show-current"
  }
}

# UserPromptSubmit — empty universal set
scope {
  path: ""
  decision: "allow"
  event: "UserPromptSubmit"
}

# UserPromptSubmit — graunde-excluded
scope {
  path: "!/graunde"
  decision: "allow"
  event: "UserPromptSubmit"

  control {
    name: "graunde-reminder"
    userprompt: "graunde"
    msg: "Graunde — a hook that fires on every hook event, tracks what happened in this session. Can rewrite PreToolUse hooks on the fly, nudges Claude Code into the right direction; https://github.com/teranos/graunde/tree/main"
  }
}

# UserPromptSubmit — qntx-excluded
scope {
  path: "!/QNTX"
  decision: "allow"
  event: "UserPromptSubmit"

  control {
    name: "qntx-reminder"
    userprompt: "qntx"
    msg: "QNTX — Continuous Intelligence. Domain-agnostic knowledge system built on verifiable attestations (who said what, when, in what context). Core: Attestation Type System (ATS). Query with AX. Graunde shares its node db; https://github.com/teranos/QNTX"
  }
}

# Stop — pattern matching on last assistant message
scope {
  path: ""
  decision: "allow"
  event: "Stop"

  control {
    name: "lazy-verify"
    stop: "Ready for you to verify"
    msg: "Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction."
  }

  control {
    name: "ego-death-effective-fix"
    stop: "The most effective fix is"
    msg: "You made a strong claim — according to whom? Ground it in verification or real facts."
  }

  control {
    name: "ego-death-feeling-probably"
    stop: "feeling is probably"
    msg: "Do not attribute subjective impressions to the user. They observe and report facts. Restate based on what was actually measured or said."
  }

  control {
    name: "ego-death-speculative-cause"
    stop: "likely because"
    stop: "probably because"
    msg: "That's a guess, not a diagnosis. Check the data before proposing a cause."
  }

  control {
    name: "ego-death-nothing-left"
    stop: "Nothing left to do"
    msg: "You made a completeness claim. What specifically was not verified?"
  }
}

# Stop — QNTX-scoped
scope {
  path: "/QNTX"
  decision: "allow"
  event: "Stop"

  control {
    name: "make-dev-includes-wasm"
    stop: "make wasm"
    msg: `"make dev" also rebuilds the wasm, see the Makefile.`
  }

  control {
    name: "no-stale-binary-speculation-might"
    stop: "binary might be stale"
    msg: "The developer is always running the latest version. Do not speculate about stale binaries."
  }

  control {
    name: "no-stale-binary-speculation-may"
    stop: "binary may be stale"
    msg: "The developer is always running the latest version. Do not speculate about stale binaries."
  }

  control {
    name: "port-check-am-toml-877"
    stop: "port 877"
    msg: "You mentioned a default port. Check am.toml in the project root for the actual port configuration."
  }

  control {
    name: "port-check-am-toml-8820"
    stop: "8820"
    msg: "You mentioned a default port. Check am.toml in the project root for the actual port configuration."
  }
}

# SessionStart — checks on startup
scope {
  path: ""
  decision: "allow"
  event: "SessionStart"

  control {
    name: "stale-binary-shadow"
    check_handler: "binaryShadowed"
    msg: "/usr/local/bin/graunde exists and shadows ~/.local/bin/graunde — remove it with: rm /usr/local/bin/graunde"
  }

  control {
    name: "stale-controls"
    check_handler: "controlsAreStale"
    msg: "graunde binary is out of date with source — recompile with dub test && make install"
  }
}

# SessionStart — QNTX-scoped
scope {
  path: "/QNTX"
  decision: "allow"
  event: "SessionStart"

  control {
    name: "am-toml-reminder"
    msg: "am.toml in the project root has the db path and node configuration. Check it before assuming database locations."
  }
}
