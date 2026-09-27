module regoto_test;

// BOOK_GLOSSARY **Regoto**: The rite a ritual's live performance goes to when the ritual fires again. Without one, every fire is a performance of its own.

import proto : parsePbt, validateRituals;

// "a ritual is running"
// "the same ritual fires again, a 2nd instance"
// "the 2nd instance sees there is already one running, the ritual never runs"
// "think of it like a goto"
// "the parameter is the rite"
enum withRegoto = `
rites steps {
  STEP1 {
    eval: "echo 'step' > steps.txt"
  }
  STEP2 {
    eval: "echo 'step' > steps.txt"
  }
  STEP3 {
    eval: "echo 'step' > steps.txt"
  }
  END {
    eval: "echo 'finished' > steps.txt"
  }
}

project {
  path: "/alice/smartwatchapp"

  ritual stepcounter {
    regoto: STEP2
    steps
  }
}
`;

static assert(parsePbt(withRegoto).rituals[0].regoto == "STEP2");
static assert(validateRituals(parsePbt(withRegoto)).text() == "");

// "its an opt-in as well, this behaviour"
// "a ritual that hasnt opted in behaves like it does today, parralel agent sessions in individual rituals"
enum withoutRegoto = `
rites judged {
  ROUTE {
    eval: "true"
  }
}

project {
  path: "/teranos/QNTX"

  ritual deploy {
    judged
  }
}
`;
static assert(parsePbt(withoutRegoto).rituals[0].regoto == "");

// "why not regoto"
// A regoto naming no rite of its own ritual is a jump into the dark, as a goto is.
enum badRegoto = `
rites judged {
  ROUTE {
    eval: "true"
  }
}

project {
  path: "/teranos/QNTX"

  ritual deploy {
    regoto: nowhere
    judged
  }
}
`;
static assert(validateRituals(parsePbt(badRegoto)).text() == "ritual deploy: regoto names no rite: nowhere");
