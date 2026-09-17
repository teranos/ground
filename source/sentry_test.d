module sentry_test;

// BOOK_GLOSSARY **Sentry**: The one place a dsn is set, at the top level, in a project or in a ritual; the nearest one is where a performance reports.

// "the thing i wish we did better, at least for rituals, is ritual observability using sentry"
// sentry { } is the one place a dsn is set. The layers stack the way models
// does, and the nearest dsn is the one a performance reports to.

import proto : parsePbt, validateRituals;
import ritual : flatten, resolveSentry;

// "and also inside of project or ritual, like models { .. }"
// What goes: the ritual's name as the monitor, the performance id as the
// check-in, and a status — in_progress at the start, ok or error at the end.
enum globalOnly = `
sentry {
  dsn: "https://top@o1.ingest.example/1"
}
`;
static assert(parsePbt(globalOnly).sentry.present);
static assert(parsePbt(globalOnly).sentry.dsn == "https://top@o1.ingest.example/1");

// A pbt that says nothing about sentry reports nowhere. There is no default
// dsn to fall back to: a key is something only the operator can supply.
enum quiet = `
rites walk {
  ONE {
    eval: "true"
  }
}
`;
static assert(!parsePbt(quiet).sentry.present);
static assert(parsePbt(quiet).sentry.dsn == "");

enum src = `
sentry {
  dsn: "https://top@o1.ingest.example/1"
}

rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/src/grove"

  sentry {
    dsn: "https://proj@o1.ingest.example/2"
  }

  ritual grove {
    sentry { dsn: "https://rit@o1.ingest.example/3" }
    walk
  }

  ritual plain {
    walk
  }
}
`;
enum parsed = parsePbt(src);

static assert(parsed.sentry.present);
static assert(parsed.sentry.dsn == "https://top@o1.ingest.example/1");

static assert(parsed.projects[0].sentry.present);
static assert(parsed.projects[0].sentry.dsn == "https://proj@o1.ingest.example/2");

static assert(parsed.rituals[0].sentry.dsn == "https://rit@o1.ingest.example/3");
static assert(parsed.rituals[0].refCount == 1, "a sentry block is not a rites reference");
static assert(!parsed.rituals[1].sentry.present);
static assert(validateRituals(parsed).text() == "");

// flatten carries the three layers, nearest first, as it does for models.
enum grove = flatten(parsed, 0);
static assert(grove.sentry[0].dsn == "https://rit@o1.ingest.example/3");
static assert(grove.sentry[1].dsn == "https://proj@o1.ingest.example/2");
static assert(grove.sentry[2].dsn == "https://top@o1.ingest.example/1");

// The nearest dsn is the one used.
static assert(resolveSentry(grove.sentry) == "https://rit@o1.ingest.example/3");

// A ritual that sets none is not blanked by its own silence: the next layer
// out answers for it.
enum plain = flatten(parsed, 1);
static assert(resolveSentry(plain.sentry) == "https://proj@o1.ingest.example/2");

// "but for our purposes we will use it only at top level for now, but you may still do the red TDD for all"
// One block at the top and nothing nearer: every ritual reports to it.
enum topOnlySrc = `
sentry {
  dsn: "https://top@o1.ingest.example/1"
}

rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/p"
  ritual r {
    walk
  }
}
`;
enum topOnly = parsePbt(topOnlySrc);
static assert(resolveSentry(flatten(topOnly, 0).sentry) == "https://top@o1.ingest.example/1");

// No sentry anywhere: nothing is reported, and no host is invented for it.
enum bareSrc = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/p"
  ritual r {
    walk
  }
}
`;
enum bare = parsePbt(bareSrc);
static assert(!bare.sentry.present);
static assert(resolveSentry(flatten(bare, 0).sentry) == "");

// A bare dsn: on a ritual is refused. sentry { } is where it goes.
enum bareDsnSrc = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/p"
  ritual r {
    dsn: "https://k@o1.ingest.example/1"
    walk
  }
}
`;
static assert(validateRituals(parsePbt(bareDsnSrc)).text() == "ritual r: unknown field `dsn`");

// A sentry block with no dsn says nothing and is not a report address.
enum emptySrc = `
sentry {
}
`;
static assert(parsePbt(emptySrc).sentry.present);
static assert(parsePbt(emptySrc).sentry.dsn == "");

// An unknown field inside the block is refused rather than ignored: a
// misspelled key would otherwise silently report nowhere.
enum unknownFieldSrc = `
sentry {
  dns: "https://k@o1.ingest.example/1"
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(unknownFieldSrc); }));

// One sentry block at each level. Every pbt is folded into one parse, so a
// second block anywhere would replace the first without a word.
enum twoGlobalSrc = `
sentry {
  dsn: "https://a@o1.ingest.example/1"
}

sentry {
  dsn: "https://b@o1.ingest.example/2"
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoGlobalSrc); }));

enum twoInProjectSrc = `
project {
  path: "/p"

  sentry {
    dsn: "https://a@o1.ingest.example/1"
  }

  sentry {
    dsn: "https://b@o1.ingest.example/2"
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoInProjectSrc); }));

enum twoInRitualSrc = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/p"
  ritual r {
    sentry { dsn: "https://a@o1.ingest.example/1" }
    sentry { dsn: "https://b@o1.ingest.example/2" }
    walk
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoInRitualSrc); }));

// "i want to know what goes to sentry, thats importantto me"
// Not the output a rite printed, not the agent's words, and no absolute path:
// a worktree path names whose machine it is, and sentry is off that machine.
enum commentedSrc = `
sentry {
  # the key is the operator's, and this block is where it is named
  dsn: "https://top@o1.ingest.example/1"
}
`;
static assert(parsePbt(commentedSrc).sentry.dsn == "https://top@o1.ingest.example/1");
