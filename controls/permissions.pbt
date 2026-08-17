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
    substitute_for_read: ["sed", "awk", "perl"]
  }
}

permission {

  allow: ["cd *", "sleep *", "say *", "time *"]
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
