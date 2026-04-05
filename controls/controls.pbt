# Universal PreToolUse
scope {
  event: "PreToolUse"

  # Auto-approved command controls
  scope {
    # "omit" strips the flag from the command before execution.
    control {
      name: "no-skip-hooks"
      cmd: "git"
      omit: "--no-verify"
      msg: "Git hooks must not be bypassed, ever."
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
      name: "pr-ready"
      cmd: "gh pr ready"
      msg: "This means the pr is ready to merge"
    }
  }

  # Deny — hard blocks. "=" prefix means exact match (no trailing args).
  scope {
    decision: "deny"

    control {
      name: "no-bulk-add"
      cmd: "=git add ."
      msg: "Stage files by name. Do not use git add . — it bypasses binary file detection and may include unintended files."
    }

    control {
      name: "no-bulk-add-all"
      cmd: "=git add -A"
      msg: "Stage files by name. Do not use git add -A — it bypasses binary file detection and may include unintended files."
    }

    control {
      name: "no-bulk-add-all-long"
      cmd: "=git add --all"
      msg: "Stage files by name. Do not use git add --all — it bypasses binary file detection and may include unintended files."
    }
  }

  # Checkpoints — require manual approval
  scope {
    decision: "ask"

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
}

# Ground project-scoped
scope {
  path: "/ground"

  scope {
    event: "PreToolUse"

    control {
      name: "install-after-build"
      cmd: "dub build"
      bg: true
      msg: "Run make install to update the live hook binary."
    }
  }

  scope {
    event: "PreToolUseFile"

    control {
      name: "control-ritual"
      filepath: ".pbt"
      msg: "After writing a control, verify it works: simulate the scenario that would trigger it and confirm the control fires as expected."
    }
  }

  scope {
    event: "PostToolUse"

    control {
      name: "build-timing"
      cmd: "make install"
    }

    control.w {
      name: "rebuild-after-pbt-edit"
      filepath: ".pbt"
      msg: "Controls changed. Run make install to update the binary."
    }

    permission {
      allow: [
        "dub build*", "dub test*", "make install*",
        "ldc2*", "ground*"
      ]
    }
  }

  scope {
    event: "UserPromptSubmit"

    control {
      name: "permission-reminder"
      userprompt: "permission"
      msg: "Permissions are defined in controls/permissions.pbt — not in ~/.claude/settings.json or .claude/settings.local.json. Check permissions.pbt for existing patterns before adding new ones."
    }

    control {
      name: "dig-before-control"
      userprompt: ["create*control", "as a control", "new control"]
      msg: "Before writing a control, dig into the db: ground shovel <event> <pattern>. Check real historical matches first — no trigger without evidence."
    }
  }
}

# PostToolUse — reminders after tool execution
scope {
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
  event: "PostToolUseDeferred"

  control {
    name: "ci-check-defer"
    cmd: "git push"
    delay_handler: "ciDelay"
    deliver_handler: "ciDeliver"
  }

  control {
    name: "review-nudge"
    cmd: "gh pr"
    posttool: "@claude review"
    defer_sec: 300
    defer_msg: "Claude left a review comment."
  }
}

# PostToolUseFailure — hints on tool failure
scope {
  event: "PostToolUseFailure"

  control {
    name: "wrong-directory"
    posttool: "No rule to make target"
    msg: "Run pwd — you may be in the wrong directory."
  }
}

# PreCompact — re-inject context before compaction
scope {
  event: "PreCompact"

  control {
    name: "branch-context"
    msg: "Current branch: "
    cmd: "git branch --show-current"
  }
}

# UserPromptSubmit — empty universal set
scope {
  event: "UserPromptSubmit"
}

# UserPromptSubmit — ground-excluded
scope {
  path: "!/ground"
  event: "UserPromptSubmit"

  control {
    name: "ground-reminder"
    userprompt: "ground"
    msg: "Ground Control — a hook that fires on every hook event, tracks what happened in this session. Can rewrite PreToolUse hooks on the fly, nudges Claude Code into the right direction; https://github.com/teranos/ground/tree/main"
  }
}


# Stop — pattern matching on last assistant message
scope {
  event: "Stop"

  control {
    name: "lazy-verify"
    stop: "Ready for you to verify"
    msg: "Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction."
  }

  control {
    name: "lazy-curl"
    stop: "test*curl*http"
    msg: "You have Bash. Run the curl yourself instead of suggesting the user do it."
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
    stop: ["likely because", "probably because"]
    msg: "That's a guess, not a diagnosis. Check the data before proposing a cause."
  }

  control {
    name: "ego-death-nothing-left"
    stop: "Nothing left to do"
    msg: "You made a completeness claim. What specifically was not verified?"
  }

  control {
    name: "check-logs-yourself"
    stop: "check the*log"
    msg: "You can read logs and terminal output yourself. Use your tools instead of asking the user."
  }

  control {
    name: "stale-knowledge-as-fact"
    stop: "is*latest*no*upgrade"
    msg: "You stated stale training data as current fact. Check with tools before claiming something is or isn't the latest version."
  }

  control {
    name: "previous-conversations-accessible"
    stop: [
        "each conversation starts fresh",
        "each session starts fresh",
        "don't have access to previous conversation",
        "don't have access to previous session",
        "don't have access to conversation history",
        "dialogue isn't stored anywhere",
        "no previous conversation transcripts",
        "no previous conversation history",
        "no session history"
    ]
    msg: "Wrong. Previous conversations are accessible. JSONL transcripts are stored at ~/.claude/projects/. The ground db at ~/.local/share/ground/ground.db stores last_assistant_message in Stop attestation attributes. Check before claiming you can't."
  }
}

# QNTX project-scoped
scope {
  path: "/QNTX"

  scope {
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
      stop: ["port 877", ":877"]
      msg: "You mentioned a default port. Check am.toml in the project root for the actual port configuration."
    }

    control {
      name: "port-check-am-toml-8820"
      stop: "8820"
      msg: "You mentioned a default port. Check am.toml in the project root for the actual port configuration."
    }
  }

  scope {
    event: "SessionStart"

    control {
      name: "am-toml-reminder"
      msg: "Read am.toml in the project root and report back: port number, db path, logfile location, and enabled plugins."
    }
  }
}

# SessionStart — checks on startup
scope {
  event: "SessionStart"

  control {
    name: "stale-binary-shadow"
    check_handler: "binaryShadowed"
    msg: "/usr/local/bin/ground exists and shadows ~/.local/bin/ground — remove it with: rm /usr/local/bin/ground"
  }
}
