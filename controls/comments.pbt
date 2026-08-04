scope {
  event: "PreToolUse"
  decision: "deny"

  control {
    name: "no-comment-blocks"
    comment_run: 4
    msg: "Four or more consecutive comment lines in one edit. A block that arrives whole can only be accepted or rejected whole — there is no line left to disagree with, and the reviewer has to take it apart before they can answer it. Land the claim where it can be argued with one at a time, or make the failure it describes loud instead of written down."
  }
}
