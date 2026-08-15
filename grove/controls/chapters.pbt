# A chapter is written, committed, and proposed onto the chapters branch.
# Every step that reaches outside the worktree names what it is doing.

rites page {
  CHAPTER {
    eval:  `test -s CHAPTER.md`
    catch: 1
    to:    parent
    msg:   "Write the chapter into CHAPTER.md. Nothing in this rite knows what it should say."
  }

  # Ground commits nothing, so a rite that does not ask for one pushes a branch
  # that holds none. Measured on chapter-1786648619: CHAPTER passed on a file
  # in the worktree, and the worktree was deleted on Done with the file in it.
  KEPT {
    eval: `
      test -z "$(git status --porcelain)" || exit 1
      test -n "$(git log --oneline origin/chapters..HEAD)" || exit 1
    `
    catch: 1
    goto:  CHAPTER
    to:    parent
    msg:   "Commit CHAPTER.md, new file included. Nothing downstream can push what is not committed, and what goes in the message is yours."
  }

  # The base is written here, in the invocation that uses it. A rite that opens
  # a pull request is the only thing that needs to know where it lands.
  BOUND {
    run: `
      git push -q -u origin HEAD
      gh pr create --base chapters --fill --head "$(git rev-parse --abbrev-ref HEAD)" 2>&1 || true
      gh pr view --json url,baseRefName --jq '"\(.url) -> \(.baseRefName)"'
    `
    to:  parent
    mic: "The pull request is open against chapters, which this rite names and nothing else does."
  }
}

project {
  path: "/teranos/ground"

  ritual chapter {
    system: "You write a chapter about what ground actually did, taken from the record — the performances, rites and outcomes in ~/.local/share/ground/ground.db and in the repos themselves. You quote what you read rather than describing it. You are not auditing ground's source: read it only when the record points you at a line, and never write a claim about code you have not opened."

    page
  }
}
