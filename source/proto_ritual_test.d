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
    cmd: "make parity"
  }
}
`;
enum ritesParsed = parsePbt(ritesInput);
static assert(ritesParsed.ritesCount == 1);
static assert(ritesParsed.rites[0].name == "parity");
static assert(ritesParsed.rites[0].riteCount == 1);
static assert(ritesParsed.rites[0].rites[0].name == "parity");
static assert(ritesParsed.rites[0].rites[0].cmd == "make parity");

// "obviously i would want rites to be able to accept a parameter"
enum paramsInput = `
rites parity {
  params: [row]

  parity {
    cmd: ` ~ "`" ~ `make parity | grep "$row *YES *YES"` ~ "`" ~ `
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
  exists   { cmd: "curl -sf x"  catch: 22 }
  answers  { cmd: "curl -sf y"  catch: [7, 22] }
  survived { cmd: "curl -sf z"  catch: 22  goto: parity }
  plain    { cmd: "true" }
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

// "why cant the ritual block be literally inside project for this purpose?"
// "a ritual is LIVE its active RIGHT NOW, a rite isnt."
// "how do i set the row param from the ritual"
enum ritualInput = `
rites parity {
  params: [row]
  parity { cmd: "make parity" }
}

rites live {
  ci { cmd: "gh pr checks 833" }
}

project {
  path: "/q.sbvh.nl"

  env {
    api: "https://api.q.sbvh.nl"
  }

  ritual boxsurvival {
    parity { row: "watchers" }
    live
  }
}
`;
enum ritualParsed = parsePbt(ritualInput);
static assert(ritualParsed.ritualCount == 1);
static assert(ritualParsed.rituals[0].name == "boxsurvival");
static assert(ritualParsed.rituals[0].projectPath == "/q.sbvh.nl");
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
static assert(validateRituals(ritualParsed) == "");

// "ok" — rite names unique across every group, so a goto target and a
// position report both name one thing.
enum dupInput = `
rites a { shared { cmd: "true" } }
rites b { shared { cmd: "true" } }
`;
static assert(validateRituals(parsePbt(dupInput)) == "duplicate rite name: shared");

// A goto that names nothing is a jump into the dark.
enum badGotoInput = `
rites a { one { cmd: "true"  goto: nowhere } }
`;
static assert(validateRituals(parsePbt(badGotoInput)) == "goto names no rite: nowhere");

// A declared param nobody supplies expands to empty, and an empty grep
// pattern matches anything — a false pass, which is the one outcome
// worth failing the build over.
enum missingParamInput = `
rites parity {
  params: [row]
  parity { cmd: "make parity" }
}

project {
  path: "/p"
  ritual r {
    parity
  }
}
`;
static assert(validateRituals(parsePbt(missingParamInput)) == "ritual r: parity needs row");

// A ritual naming a group that does not exist.
enum badRefInput = `
project {
  path: "/p"
  ritual r {
    absent
  }
}
`;
static assert(validateRituals(parsePbt(badRefInput)) == "ritual r: no rites named absent");

// A real file put through the sand exposed a parse failure these inputs
// did not: the group's closing brace sits on its own line before a blank.
enum sandShapeInput = `
rites probe {
  params: [row]
  onlyrite { cmd: "true" }
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
static assert(validateRituals(sandParsed) == "ritual probeRitual: probe needs row");

// Pass 1 sizes the arrays pass 2 fills, and it is a separate walk over the
// same text. A block it does not recognise consumes nothing, so the next
// readWord lands on a brace and asserts — the parser never gets to run.
enum sandCounted = countPbt(sandShapeInput);
static assert(sandCounted.totalProjects == 1);
