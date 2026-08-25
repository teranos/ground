rites daylight {
  # Starts every walk from nothing. The sun does not stay where it was, so a
  # SUN.md left over from the last performance is not evidence of anything.
  BURN { eval: `rm -f SUN.md`  to: parent  mic: "Clearing SUN.md. Whatever the sun was doing, it is not doing that now." }

  # The rite does not know which flares are burning. It can see that something
  # was written and nothing more — the same as MOON, and for the same reason.
  SUN {
    eval:  `test -s SUN.md`
    catch: 1
    to:    parent
    msg:   "Find the ten solar flares NASA recorded most recently and put them in SUN.md, one per line, oldest first, as `<flrID> <classType>` and nothing else."
  }

  # "there should be an eval that checks if its true and otherwise goto: back so
  # its allowed to commit". --porcelain and not `git diff`, because diff is
  # blind to an untracked file and a never-added SUN.md read as a clean tree.
  KEEP {
    eval: `
      test -z "$(git status --porcelain)"
      git log --oneline HEAD --not --remotes | grep -q .
    `
    catch: 1
    goto:  SUN
    to:    parent
    msg:   "Commit what you changed, new files included. Nothing downstream can push what is not committed, and what goes in the commit is yours to decide."
  }

  RISE {
    eval: `git push -q -u origin HEAD`
    to:  parent
    mic: "SUN.md is pushed. The push is what opens the pull request."
  }

  # A pull request is a thing to open, not a question to answer, so it is a run.
  # A second walk on the same branch finds one already there and gh says so on
  # exit 1, which is not a failure of the rite.
  OPEN {
    run: `
      if ! gh pr view --json url >/dev/null; then
        gh pr create --fill --head "$(git rev-parse --abbrev-ref HEAD)"
      fi
      gh pr view --json url --jq .url
    `
    to:  parent
    mic: "The pull request is open. What it says next comes from a person."
  }

  # "r3 would be allowed to not be fulfilled, and the agent can actually
  # continue to r4". It asks nothing, so it advances; what it read goes back.
  LOOK {
    run: `gh pr view --json comments --jq '.comments[-1].body // "no comment yet"'`
    to:  parent
    mic: "Reading the pull request for anything a person has said."
  }

  # "there could be a run: that itself sleeps 20s". The waiting is a rite doing
  # a thing, not an eval holding the mic while it sleeps.
  REST {
    run: `sleep 20`
    to:  parent
    mic: "Nothing said yet. Twenty seconds, then round again."
  }

  # "in r5 there could be a check if a comment was left at all, if the comment
  # was not left, it sends back to r3" — and the loop is r3, r4, r5.
  HEED {
    eval:  `test "$(gh pr view --json comments --jq '.comments | length')" != "0"`
    catch: 1
    goto:  LOOK
    to:    parent
    msg:   "Nobody has commented on the pull request yet."
  }

  # Nothing is merged by a ritual. A comment landed, which is the prerequisite
  # for reaching the end, and what happens to the branch after that is yours.
  SET {
    run: `gh pr view --json url,state --jq '"\(.url) \(.state)"'`
    to:  parent
    mic: "A comment landed. The pull request is where it was left."
  }
}

project 2gotogrove {
  path: "/teranos/ground"

  # "define a CLAUDE.md inline in a ritual" — appended to what the agent
  # already is, so this says what this performer additionally knows.
  ritual sun {
    tree: "checkout"
    system: "You are a heliophysics recorder. DONKI is the only source you accept for a flare, and you name the exact window you queried whenever you report one. You end every message you write with the word HELIOS on its own line, so it is visible that this instruction reached you."

    daylight
  }
}
