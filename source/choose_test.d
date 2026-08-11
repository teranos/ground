module choose_test;

// "ground should refuse if it cant resolve to a single one cleanly"
// "in case of two equal candidates. ground cant know which one we mean"

import proto : parsePbt;
import ritual.resolve : chooseRitual;

// Four project blocks and no more: `ParseResult.projects` is sized from the
// pbt files wind finds plus four headroom, so four is the floor on a machine
// that has none. A fifth passed here and failed in CI.
enum src = `
rites one { A { eval: "true" } }
rites two { B { eval: "true" } }
rites three { C { eval: "true" } }
rites four { D { eval: "true" } }

project {
  path: "/p"

  ritual sun { one }
  ritual moon { two }
}

project tightgrove {
  path: "/p"

  max_goto: 2

  ritual sun { one }
}

project busy {
  path: "/r"

  ritual xray { three }
  ritual yankee { four }
}

project moon {
  path: "/s"

  ritual zulu { four }
}
`;
enum parsed = parsePbt(src);

// "# Can also be just the ritual: in case it resolves to only a single ritual."
static assert(chooseRitual(parsed, "zulu", "").ok);

// "# Just the project name, in case it has only a single ritual."
static assert(chooseRitual(parsed, "tightgrove", "").ok);
static assert(parsed.rituals[chooseRitual(parsed, "tightgrove", "").ritualIdx].name == "sun");

// A project holding two rituals is two candidates from one word.
static assert(!chooseRitual(parsed, "busy", "").ok);

// `moon` is a ritual in the unnamed project and the name of another project.
static assert(!chooseRitual(parsed, "moon", "").ok);

// "# Ritual set explicitly, in case two or more rituals exist in project"
static assert(chooseRitual(parsed, "tightgrove", "sun").ok);
static assert(chooseRitual(parsed, "tightgrove", "sun").projectIdx
              != chooseRitual(parsed, "", "sun").projectIdx);

// Two words where the project does not hold that ritual.
static assert(!chooseRitual(parsed, "tightgrove", "moon").ok);

// "the unnamed one actually wins, and the named one is the explicit edge case"
// Both the unnamed project and tightgrove hold a ritual called sun.
static assert(chooseRitual(parsed, "sun", "").ok);
static assert(parsed.projects[chooseRitual(parsed, "sun", "").projectIdx].name.length == 0);

// A word that names nothing.
static assert(!chooseRitual(parsed, "nowhere", "").ok);
