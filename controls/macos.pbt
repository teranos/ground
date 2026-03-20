# macOS — graunde-scoped denials
scope {
  path: "/graunde"
  decision: "deny"
  event: "PreToolUse"

  control {
    name: "no-dub-test"
    cmd: "dub test"
    msg: "Do not run dub test locally — syspolicyd provenance check adds minutes to every recompilation on macOS. CI handles testing. Use make install directly."
  }
}

# macOS — UserPromptSubmit
scope {
  path: ""
  decision: "allow"
  event: "UserPromptSubmit"

  control {
    name: "timer-reminder"
    userprompt: "timer for"
    msg: `You can set a timer on macOS. Run in background: sleep <seconds> && say "time" &`
  }
}
