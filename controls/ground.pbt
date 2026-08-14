rites law {
  # CLAUDE.md has mandated test-first since the repo existed and nothing has
  # ever enforced it. This is the rite that does.
  TESTFIRST {
    eval:  `test -n "$(git diff --name-only main...HEAD -- 'source/*_test.d')"`
    catch: 1
    to:    parent
    msg:   "Write the failing test first. Nothing on this branch tests anything main does not already test."
  }

  # Red. A static assert that already holds is a description of what the code
  # does, not evidence about what you are adding.
  RED {
    eval: `
      files=$(git diff --name-only main...HEAD -- 'source/*_test.d')
      test -n "$files" || exit 1
      ldc2 -c -o- -betterC -I=source -J=. $files && exit 1
      exit 0
    `
    catch: 1
    to:    parent
    msg:   "The new assertion passes already, so it is testing nothing. Make it fail before you implement."
  }

  # Green, and the same command as RED — only the expected answer changed.
  # Nothing else in this repo evaluates a CTFE assertion without a full build.
  GREEN {
    eval: `
      files=$(git diff --name-only main...HEAD -- 'source/*_test.d')
      ldc2 -c -o- -betterC -I=source -J=. $files
    `
    catch: 1
    to:    parent
    msg:   "The test is red. Write what makes it pass."
  }

  # The production config excludes source/*_test.d, so this is the half GREEN
  # cannot see: that the binary a person installs still compiles.
  BUILT {
    eval:  `make build`
    catch: 1
    to:    parent
    msg:   "The tests pass but the release build does not. Production excludes the test modules, so this is a different failure."
  }

  # No goto. A jump back to TESTFIRST would re-ask RED with the implementation
  # already written, and a rite that can never pass again is a stuck walk.
  SEALED {
    eval: `
      test -z "$(git status --porcelain)" || exit 1
      test -n "$(git log --oneline origin/main..HEAD)" || exit 1
    `
    catch: 1
    to:    parent
    msg:   "Commit what you changed, new files included. Ground does not commit for you, and what goes in the message is yours."
  }

  # Written to survive being run twice: two drivers can claim the same rite,
  # and a run: has no second chance to be idempotent.
  RAISED {
    run: `
      git push -q -u origin HEAD
      gh pr create --base main --fill --head "$(git rev-parse --abbrev-ref HEAD)" 2>&1 || true
      gh pr view --json url --jq .url
    `
    to:  parent
    mic: "The branch is pushed and the pull request is open. CI is the only thing here that runs dub test."
  }

  # The one rite that sends the walk back, because CI is the only place the
  # whole suite is ever evaluated. It goes to GREEN, which re-walks the rest.
  CHECKED {
    eval:  `gh pr checks`
    catch: 1
    goto:  GREEN
    wait:  300
    to:    parent
    msg:   "CI is not green. What it says is the authority here — this machine never ran the full suite."
  }
}

project {
  path: "/teranos/ground"

  # CI round-trips are minutes each, so a walk that has bounced eight times is
  # not converging and should stop rather than keep spending them.
  max_goto: 8

  ritual ground {
    system: "You are working on ground itself. You write the failing test before the implementation, always, and you say which assertion you made fail and what it printed when it did. You never run dub test on this machine — CI runs it, and ldc2 on the changed test modules is what you use locally."

    law
  }
}
