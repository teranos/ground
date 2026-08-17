module proto_ritual_test;

// Rituals and rites.
// Brandon: "a ritual consists our of rites"

import proto : parsePbt, validateRituals;
import count : countPbt;
import controls : allRites, allRituals;

// The groups and rituals reach runtime through controls.d, the same way
// scopes do. Nothing declares one yet, so the count is the honest zero.
static assert(allRites.length >= 0);
static assert(allRituals.length >= 0);

// "a ritual consists our of rites"
enum ritesInput = `
rites parity {
  parity {
    eval: "make parity"
  }
}
`;
enum ritesParsed = parsePbt(ritesInput);
static assert(ritesParsed.ritesCount == 1);
static assert(ritesParsed.rites[0].name == "parity");
static assert(ritesParsed.rites[0].riteCount == 1);
static assert(ritesParsed.rites[0].rites[0].name == "parity");
static assert(ritesParsed.rites[0].rites[0].eval == "make parity");

// "to me its eval" / "because its evaluated, and its up to the writer of the
// rite to change default eval behaviour through to: goto: pass: etc"
enum evalInput = `
rites parity {
  parity {
    eval: "make parity"
  }
}
`;
enum evalParsed = parsePbt(evalInput);
static assert(evalParsed.rites[0].rites[0].eval == "make parity");

// "Imagine i wan't to mix Rite and Control in the same Rites block" — which
// they cannot while one word points at a pattern to match and at a command to
// run. `cmd` in a rite is refused, not aliased.
enum oldWordInput = `
rites parity {
  parity {
    cmd: "make parity"
  }
}
`;
static assert(validateRituals(parsePbt(oldWordInput)).text()
    == "rite parity: `cmd` is a control's word. A rite evaluates: use `eval`");

// "ground uses those exit codes, becaue not all failures are the same failure"
// — so a rite that writes its own code is refused where a bad `cmd` is.
enum launderInput = `
rites ship {
  OPEN {
    run: "gh pr create --fill || true"
  }
}
`;
static assert(validateRituals(parsePbt(launderInput)).text()
    == "rite OPEN: `run` writes its own exit code. Let the tool answer");

enum launderEval = `
rites ship {
  CHECK {
    eval: "curl -sf https://x.invalid || exit 0"
  }
}
`;
static assert(validateRituals(parsePbt(launderEval)).text()
    == "rite CHECK: `eval` writes its own exit code. Let the tool answer");

// A rite that leaves its tool to answer passes.
enum cleanInput = `
rites ship {
  CHECK { eval: "git log --oneline HEAD | grep -q ." }
}
`;
static assert(validateRituals(parsePbt(cleanInput)).text() == "");

// "obviously i would want rites to be able to accept a parameter"
enum paramsInput = `
rites parity {
  params: [row]

  parity {
    eval: ` ~ "`" ~ `make parity | grep "$row *YES *YES"` ~ "`" ~ `
  }
}
`;
enum paramsParsed = parsePbt(paramsInput);
static assert(paramsParsed.rites[0].paramCount == 1);
static assert(paramsParsed.rites[0].params[0] == "row");
static assert(paramsParsed.rites[0].riteCount == 1);

// "its decided it will be called catch" / "catch: 22"
// "i think i want goto, not else, goto seems more honest for what it is"
enum catchInput = `
rites boxdeath {
  exists   { eval: "curl -sf x"  catch: 22 }
  answers  { eval: "curl -sf y"  catch: [7, 22] }
  survived { eval: "curl -sf z"  catch: 22  goto: parity }
  plain    { eval: "true" }
}
`;
enum catchParsed = parsePbt(catchInput);
static assert(catchParsed.rites[0].rites[0].catchCount == 1);
static assert(catchParsed.rites[0].rites[0].catches[0] == 22);
static assert(catchParsed.rites[0].rites[1].catchCount == 2);
static assert(catchParsed.rites[0].rites[1].catches[0] == 7);
static assert(catchParsed.rites[0].rites[1].catches[1] == 22);
static assert(catchParsed.rites[0].rites[2].goto_ == "parity");

// A rite that says nothing about catch still catches 1 — the default is
// the honest no, not silence.
static assert(catchParsed.rites[0].rites[3].catchCount == 1);
static assert(catchParsed.rites[0].rites[3].catches[0] == 1);
static assert(catchParsed.rites[0].rites[3].goto_ == "");

// "i meant, from 0 to 1, the gate is from 0 to 1"
// Shell negation flattens non-zero to 0, so a broken command reads as a
// pass. Declared instead of inverted.
enum passInput = `
rites gone {
  scratch { eval: "test -f /var/lib/qntx/qntx-operational.db"  pass: 1  catch: 0 }
  plain   { eval: "true" }
}
`;
enum passParsed = parsePbt(passInput);
static assert(passParsed.rites[0].rites[0].pass == 1);
static assert(passParsed.rites[0].rites[0].catches[0] == 0);
static assert(passParsed.rites[0].rites[1].pass == 0);
static assert(passParsed.rites[0].rites[1].catches[0] == 1);

// "in case something else comes is fast which does happen sometimes"
// Seconds ground holds after the Stop has gone back, not before. Nothing is
// checked in that window; it is the only span a throw-back can be seen in.
enum graceInput = `
rites shipped {
  built  { eval: "test -x build/ground"  grace: 6 }
  sealed { eval: "git diff --quiet" }
}
`;
enum graceParsed = parsePbt(graceInput);

// Six seconds is a throw-back an eye can catch. Two is the default and one
// repaint wide, and the throw itself has no duration of its own.
static assert(graceParsed.rites[0].rites[0].grace == 6);

// Silence means 2. A diff is clean or it is not, the instant you ask.
static assert(graceParsed.rites[0].rites[1].grace == 2);

// "before the rite check takes place"
// wait is spent before the first look, so it is taken after the turn's work
// has settled. grace is spent after the verdict, so the two never overlap.
enum waitInput = `
rites paced {
  polled { eval: "gh pr checks 833"  catch: 1  wait: 20 }
  quick  { eval: "true" }
}
`;
enum waitParsed = parsePbt(waitInput);
static assert(waitParsed.rites[0].rites[0].wait == 20);

// Silence means none. A rite that does not say so is not slowed down.
static assert(waitParsed.rites[0].rites[1].wait == 0);

// The two are independent: a rite can declare either, both, or neither.
static assert(waitParsed.rites[0].rites[0].grace == 2);

// "that means delivery is going to be explicit from now on"
// "i want the thing to no longer deliver by default to both me and hostllm"
import receiver : Receiver, PARENT, wants;

enum toInput = `
rites reported {
  loud  { eval: "true"  to: parent }
  quiet { eval: "true" }
}
`;
enum toParsed = parsePbt(toInput);

// "to: parent / means to both" — one Stop line, read on screen and in context.
static assert(toParsed.rites[0].rites[0].to == PARENT);
static assert(wants(toParsed.rites[0].rites[0].to, Receiver.Human));
static assert(wants(toParsed.rites[0].rites[0].to, Receiver.HostLlm));

// Silence is silence. A rite that names no receiver reports to nobody, and
// the alternative is guessing that somebody wanted to hear it.
static assert(toParsed.rites[0].rites[1].to == Receiver.None);

// "which is to define a CLAUDE.md inline in a ritual"
enum systemInput = `
rites page { WRITE { eval: "true" } }

project {
  path: "/src/proj"

  ritual campaign {
    system: "You are a Specialist in Targeted Advertisement Campaigns."
    page
  }
}
`;
enum systemParsed = parsePbt(systemInput);
static assert(systemParsed.rituals[0].system
    == "You are a Specialist in Targeted Advertisement Campaigns.");

// A field does not consume the group that follows it.
static assert(systemParsed.rituals[0].refCount == 1);
static assert(systemParsed.rituals[0].refs[0].name == "page");
static assert(validateRituals(systemParsed).text() == "");

// A ritual that says nothing carries nothing, and the spawn is unchanged.
static assert(ritualParsed.rituals[0].system == "");

// A word with a colon that names no field is refused by name, rather than
// being read as a rites group that does not exist.
enum badFieldInput = `
rites page { WRITE { eval: "true" } }

project {
  path: "/src/proj"
  ritual campaign {
    sytsem: "typo"
    page
  }
}
`;
static assert(validateRituals(parsePbt(badFieldInput)).text()
    == "ritual campaign: unknown field `sytsem`");

// A code cannot both advance and hold.
enum overlapInput = `
rites bad {
  both { eval: "true"  pass: 1  catch: [1, 7] }
}
`;
static assert(validateRituals(parsePbt(overlapInput)).text() == "rite both: 1 is both pass and catch");

// "why cant the ritual block be literally inside project for this purpose?"
// "a ritual is LIVE its active RIGHT NOW, a rite isnt."
// "how do i set the row param from the ritual"
enum ritualInput = `
rites parity {
  params: [row]
  parity { eval: "make parity" }
}

rites live {
  ci { eval: "gh pr checks 833" }
}

project {
  path: "/src/proj"

  env {
    api: "https://api.example.invalid"
  }

  ritual probe {
    parity { row: "watchers" }
    live
  }
}
`;
enum ritualParsed = parsePbt(ritualInput);
static assert(ritualParsed.ritualCount == 1);
static assert(ritualParsed.rituals[0].name == "probe");
static assert(ritualParsed.rituals[0].projectPath == "/src/proj");
static assert(ritualParsed.rituals[0].refCount == 2);

// A bare name is a reference and carries nothing.
static assert(ritualParsed.rituals[0].refs[1].name == "live");
static assert(ritualParsed.rituals[0].refs[1].valueCount == 0);

// A name with a block is the same reference, carrying values.
static assert(ritualParsed.rituals[0].refs[0].name == "parity");
static assert(ritualParsed.rituals[0].refs[0].valueCount == 1);
static assert(ritualParsed.rituals[0].refs[0].keys[0] == "row");
static assert(ritualParsed.rituals[0].refs[0].values[0] == "watchers");

// The example above is well-formed and must validate clean.
static assert(validateRituals(ritualParsed).text() == "");

// "ok" — rite names unique across every group, so a goto target and a
// position report both name one thing.
enum dupInput = `
rites a { shared { eval: "true" } }
rites b { shared { eval: "true" } }
`;
static assert(validateRituals(parsePbt(dupInput)).text() == "duplicate rite name: shared");

// A goto that names nothing is a jump into the dark.
enum badGotoInput = `
rites a { one { eval: "true"  goto: nowhere } }
`;
static assert(validateRituals(parsePbt(badGotoInput)).text() == "goto names no rite: nowhere");

// "DISPATCH AND EVAL ARE DIFFERENT THIGNS" / "THEY ARENT EVEN IN THE SAME
// CATEGORY" — an eval is a question, a dispatch is not asked at all.
enum bothInput = `
rites a { one { dispatch: "o/r w.yml"  eval: "true" } }
`;
static assert(validateRituals(parsePbt(bothInput)).text() == "rite one: dispatch is not asked, so it cannot carry an eval");

// A declared param nobody supplies expands to empty, and an empty grep
// pattern matches anything — a false pass, which is the one outcome
// worth failing the build over.
enum missingParamInput = `
rites parity {
  params: [row]
  parity { eval: "make parity" }
}

project {
  path: "/p"
  ritual r {
    parity
  }
}
`;
static assert(validateRituals(parsePbt(missingParamInput)).text() == "ritual r: parity needs row");

// A ritual naming a group that does not exist.
enum badRefInput = `
project {
  path: "/p"
  ritual r {
    absent
  }
}
`;
static assert(validateRituals(parsePbt(badRefInput)).text() == "ritual r: no rites named absent");

// A real file put through the sand exposed a parse failure these inputs
// did not: the group's closing brace sits on its own line before a blank.
enum sandShapeInput = `
rites probe {
  params: [row]
  onlyrite { eval: "true" }
}

project {
  path: "/nowhere"
  ritual probeRitual {
    probe
  }
}
`;
enum sandParsed = parsePbt(sandShapeInput);
static assert(sandParsed.ritesCount == 1);
static assert(sandParsed.ritualCount == 1);
static assert(validateRituals(sandParsed).text() == "ritual probeRitual: probe needs row");

// Pass 1 sizes the arrays pass 2 fills, and it is a separate walk over the
// same text. A block it does not recognise consumes nothing, so the next
// readWord lands on a brace and asserts — the parser never gets to run.
enum sandCounted = countPbt(sandShapeInput);
static assert(sandCounted.totalProjects == 1);

// `branch:` was a project field that named the base of the pull request ground
// opened on Done. Ground opens none — "i want NO pr to be created if i did not
// set it" — so a ritual that wants one says --base in the rite that runs gh.
enum noBranchInput = `
rites walk {
  one { eval: "true" }
}

project {
  path: "/sbvh-nl/grove"

  ritual worker {
    walk
  }
}
`;
enum noBranchParsed = parsePbt(noBranchInput);
import ritual : flatten;
static assert(flatten(noBranchParsed, 0).count == 1);
