# A value shaped like what names a person is written as a fixture, before the
# tool runs: a mail address, an IPv4 address, a phone number, a Dutch postal
# code (source/pii.d). The agent reads back what is there.

scope {
  event: "PreToolUse"

  control {
    name: "fixtures-only"
    scrub: "true"

    # The mail addresses a fixture may carry. One not listed is written as one of these.
    allowed: [
      "tim@example.com",
      "spike@example.com",
      "jenny@example.com",
      "ada@example.com",
      "grace@example.com",
      "linus@example.com",
      "you@example.com",
      "noreply@anthropic.com"
    ]

    msg: "ground wrote fixtures in place of what names a person; what you read back is what is there."
  }
}

# What a tool ground never saw put in a file still does not leave: a commit
# with such a line staged, or a push carrying one, is refused by name.
scope {
  event: "PreToolUse"
  decision: "deny"

  control {
    name: "staged-names-nobody"
    cmd: "git commit"
    check_handler: "stagedNamesPerson"
    msg: "a staged line names a person; write the fixture instead."
  }

  control {
    name: "pushed-names-nobody"
    cmd: "git push"
    check_handler: "pushNamesPerson"
    msg: "a commit about to be pushed names a person; amend it with the fixture instead."
  }
}
