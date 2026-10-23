# "ban commit + push in one go"
# "for this to work they need to be separated always, never be allowed as the one toolcall"
scope {
  event: "PreToolUse"
  decision: "deny"

  # One tool call is one event to ground, and one event opens one door.
  control {
    name: "commit-and-push-are-two-calls"
    cmd: "*git commit*"
    content: "git push"
    msg: "A commit and a push are two tool calls. One call is one event to ground, and one event opens one door: a push in the commit's call is never walked."
  }
}
