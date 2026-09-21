# Permissions — auto-allow/deny for permission dialogs

permission {

  allow: ["find *", "grep *"]
}

# The file that was being read gets Read into Claude as it tries to use one of
# these. Replaces a deny, which took the method away without giving the file.
scope {
  event: "PreToolUse"

  control {
    name:                "ReadReplacements"
    substitute_for_read: ["awk", "perl"]
  }

  # A range read is not refused; it is widened. From line 1, and ten past
  # where it was aimed, so the file arrives as normal output instead of a
  # deny carrying a cut-off copy.
  #
  # "if our weekly is over 40% it should start to taper down in how much it
  # gives back with 70%+ weekly usage going back to what the model normally
  # does. so at 70% the sed rewrite rule would not even be applied anymore."
  # The week is the higher of the account's and Fable's, as ug recorded them.
  control {
    name:  "sed-from-the-top"
    cmd:   "sed -n"
    range: "1,+10"
    taper: "40,70"
    msg:   "The range was widened to start at line 1 and run ten lines past its end. A fraction of a file is how a file gets spoken about unread."
  }
}

# substitute_for_read hands over the file when sed is used to read one. Writing
# in place is a different act and went through untouched, so a script could be
# rewritten by a tool the transcript never shows editing it. Edit shows the
# before and the after.
permission {

  deny: ["sed -i*", "* sed -i*"]
  msg:  "Edit writes files here. sed -i rewrites one without showing what changed."
}

permission {

  allow: ["cd *", "sleep *", "say *", "time *"]
}

# A grant per invocation is a prompt per invocation. Claude Code's own list had
# accumulated four literal spellings of the same command, one per redirect and
# pipe that had ever been typed. These generalise instead.
permission {

  allow: ["make test*", "echo *"]
}

permission {

  allow: ["cargo build*"]
}

permission {

  allow: [
    "gh run list*", "gh run view*", "gh run watch*",
    "gh issue list*", "gh issue view*", "gh release list*",
    "gh pr list*", "gh pr view*", "gh pr ready*"
  ]
}

permission.r {
  deny: [".env", ".env.*", "secrets/*"]
  msg: "Secrets are off-limits"
}

# The session scratchpad is outside every workspace root, so acceptEdits does
# not reach it and each write asks. Nothing there is tracked or published.
permission.w {
  allow: ["/private/tmp/claude-*", "/tmp/claude-*"]
}


permission.x.a {
  allow: ["git commit*", "rm -f*index.lock", "rm *index.lock"]
}

# "i expect no prompt and everything accepted"
permission.x.a {
  allow: ["*"]
}

# "I DONT WANT AGENTS TO SPAWN WITHOUT MY PERMISSION IN MANUAL MODE"
permission.a.m {
  ask: ["*"]
  msg: "A session wants to start an agent. Deny it and the session reads the source itself."
}
