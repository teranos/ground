rites orchard {
  # A rite reports to nobody unless it says so. `to: parent` is both readers
  # of the session that started the performance: the human and the host model.
  START { eval: "test -f WILLOW.md"  to: parent }

  APPLE     { eval: `grep -qxF "  - APPLE" WILLOW.md`      pass: 1  catch: 0  to: parent  msg: "Take the APPLE out of WILLOW.md." }
  ORANGE    { eval: `grep -qxF "  - ORANGE" WILLOW.md`     pass: 1  catch: 0  to: parent  msg: "Take the ORANGE out of WILLOW.md." }
  CHERRY    { eval: `grep -qxF "  - CHERRY" WILLOW.md`     pass: 1  catch: 0  to: parent  mic: "The CHERRY rite is looking at WILLOW.md." }
  MANGO     { eval: `grep -qxF "  - MANGO" WILLOW.md`      pass: 1  catch: 0  to: parent  msg: "Take the MANGO out of WILLOW.md." }
  SOURSOP   { eval: `grep -qxF "  - SOURSOP" WILLOW.md`    pass: 1  catch: 0  to: parent  msg: "Take the SOURSOP out of WILLOW.md." }
  LIME      { eval: `grep -qxF "  - LIME" WILLOW.md`       pass: 1  catch: 0  to: parent  msg: "Take the LIME out of WILLOW.md."  mic: "LIME is the sixth of seven." }
  JACKFRUIT { eval: `grep -qxF "  - JACKFRUIT" WILLOW.md`  pass: 1  catch: 0  to: parent  msg: "Take the JACKFRUIT out of WILLOW.md." }

  CHECKWILLOW {
    eval:  `test "$(grep -cF "  - " WILLOW.md || true)" = "0"`
    catch: 1
    goto:  START
    to:    parent
    mic:   "Counting what still hangs in WILLOW.md. Anything left sends the walk back to START."
  }

  # It asks nothing — it writes the file. As an eval its exit code was read as
  # a verdict about a question nobody put; as a run, a printf that fails halts.
  DONE {
    run: `printf '# WILLOW\n\nIn this WILLOW hangs:\n\n  - APPLE\n  - ORANGE\n  - CHERRY\n  - MANGO\n  - SOURSOP\n  - LIME\n  - JACKFRUIT\n' > WILLOW.md`
    to:  parent
    msg: "The willow grows back, so the next performance has a full walk."
  }
}

project {
  path: "/teranos/ground"

  ritual willow {
    system: "You tend a willow. You take exactly the fruit the rite names and nothing else, one at a time, leaving every other line of WILLOW.md as you found it — you never rewrite the file wholesale to reach a state faster. You say which fruit you took and what still hangs there."

    orchard
  }
}
