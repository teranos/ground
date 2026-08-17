# Permissions — auto-allow/deny for permission dialogs

permission {

  allow: ["find *", "grep *"]
}

permission {

  deny: ["sed *", "awk *", "perl *"]
  msg: "Use Edit tool instead of sed/awk/perl"
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
