rites sky {
  # Starts every walk from nothing, and is where a red CI sends the walk back
  # to. Holding JUDGE in place cannot converge: the run it reads belongs to a
  # commit that will not change.
  WIPE { eval: `rm -f MOON.md`  to: parent  mic: "Clearing MOON.md. Whatever the moon was, it is not that now." }

  # The rite does not know what the right answer is. It can see that something
  # was written and nothing more.
  MOON {
    eval:  `test -s MOON.md`
    catch: 1
    to:    parent
    msg:   "Find out what phase the moon is in right now and put exactly that in MOON.md. Nothing around it, nothing else in the file."
  }

  # "there should be an eval that checks if its true and otherwise goto: back so
  # its allowed to commit". Ground stopped committing for the rite, so without
  # this LAND pushes a branch with nothing on it.
  HOLD {
    eval: `
      test -z "$(git status --porcelain)" || exit 1
      test -n "$(git log --oneline origin/master..HEAD)" || exit 1
    `
    catch: 1
    goto:  MOON
    to:    parent
    msg:   "Commit MOON.md, new file included. LAND pushes commits, and there is nothing to push until you make one."
  }

  LAND {
    eval: `git push -q -u origin HEAD`
    to:  parent
    mic: "MOON.md is pushed. The push is what wakes CI."
  }

  JUDGE {
    eval: `
      sha=$(git rev-parse HEAD)
      id=""
      for _ in $(seq 1 30); do
        id=$(gh run list --workflow=short-moon.yml --commit="$sha" --limit 1 --json databaseId --jq '.[0].databaseId // ""')
        if [ -n "$id" ]; then break; fi
        sleep 1
      done
      if [ -z "$id" ]; then exit 3; fi
      rc=0
      gh run watch "$id" --exit-status >/dev/null || rc=$?
      gh run view "$id" --json jobs --jq '.jobs[] | "\(.name) \(.conclusion)"'
      if [ "$rc" != "0" ]; then gh run view "$id" --log-failed | tail -12; fi
      exit $rc
    `
    catch: 1
    goto:  WIPE
    wait:  20
    to:    parent
    mic:   "The ball is in CI's court. short-moon says whether the moon is right."
  }
}

project {
  path: "/teranos/ground"

  ritual moon {
    system: "You are a lunar phase recorder. You never write a phase you have not looked up, and you name where you looked whenever you report one. MOON.md holds the phase and nothing around it — no heading, no date, no sentence. No rite here knows the right answer; the short-moon workflow is the only thing that does."

    sky
  }
}
