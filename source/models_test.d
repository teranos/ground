module models_test;

// BOOK_GLOSSARY **Models**: The one place a model is set, at the top level, in a project or in a ritual; rules are asked before any plain model.

// models { } is the one place a model is set: at the top level, in a project,
// or in a ritual. The layers stack. Every rule from the ritual out to the top
// level is asked before any plain model, and the nearest plain model wins.

import proto : parsePbt, validateRituals;
import ritual : flatten, resolveModel, ModelInputs, DEFAULT_MODEL;

// "i do want layering"
// A rule is a condition and the model it picks. Every rule is asked before the
// plain model, and the first that holds wins.
enum globalRules = `
models {
  model: "opus"
  five_hour: ">90"  model: "haiku"
  seven_day: ">80"  model: "sonnet"
}
`;
static assert(parsePbt(globalRules).models.ruleCount == 2);
static assert(parsePbt(globalRules).models.rules[0].model == "haiku");

// "i wamt to set model globally to opus by default so all rituals run under that unless otherwise specified"
// Every ritual runs under this model unless its project or the ritual sets one.
enum globalDefault = `
models {
  model: "opus"
}
`;
static assert(parsePbt(globalDefault).models.model == "opus");

enum src = `
models {
  model: "opus"
  five_hour: ">90"  model: "haiku"
  seven_day: ">80"  model: "sonnet"
}

rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/src/grove"

  models {
    plan: "pro"  model: "sonnet"
  }

  ritual grove {
    models { model: "fable" }
    walk
  }

  ritual plain {
    walk
  }
}
`;
enum parsed = parsePbt(src);

static assert(parsed.models.present);
static assert(parsed.models.model == "opus");
static assert(parsed.models.ruleCount == 2);
static assert(parsed.models.rules[0].input == "five_hour");
static assert(parsed.models.rules[0].value == ">90");
static assert(parsed.models.rules[0].model == "haiku");
static assert(parsed.models.rules[1].input == "seven_day");
static assert(parsed.models.rules[1].model == "sonnet");

static assert(parsed.projects[0].models.present);
static assert(parsed.projects[0].models.model == "");
static assert(parsed.projects[0].models.ruleCount == 1);
static assert(parsed.projects[0].models.rules[0].input == "plan");
static assert(parsed.projects[0].models.rules[0].value == "pro");

static assert(parsed.rituals[0].models.model == "fable");
static assert(parsed.rituals[0].refCount == 1, "a models block is not a rites reference");
static assert(!parsed.rituals[1].models.present);
static assert(validateRituals(parsed).text() == "");

// flatten carries the three layers, nearest first.
enum grove = flatten(parsed, 0);
static assert(grove.models[0].model == "fable");
static assert(grove.models[1].rules[0].input == "plan");
static assert(grove.models[2].model == "opus");

ModelInputs quiet() {
    ModelInputs i;
    i.planKnown = true;
    i.plan = "max";
    i.fiveKnown = true;
    i.fiveTenths = 100;
    i.sevenKnown = true;
    i.sevenTenths = 500;
    return i;
}

// Nothing over a limit: the nearest plain model.
static assert(resolveModel(grove.models, quiet()).model == "fable");

// The five-hour window over 90 drops grove to haiku, from the top-level rule.
static assert(() { auto i = quiet(); i.fiveTenths = 950; return resolveModel(grove.models, i).model == "haiku"; }());

// The weekly window over 80, and the rule that chose is named.
static assert(() {
    auto i = quiet();
    i.sevenTenths = 820;
    auto r = resolveModel(grove.models, i);
    return r.model == "sonnet" && r.ruleInput == "seven_day" && r.ruleValue == ">80";
}());

// Exactly 80 is not over it.
static assert(() { auto i = quiet(); i.sevenTenths = 800; return resolveModel(grove.models, i).model == "fable"; }());

// The project's plan rule is nearer than the top level's, so it is asked first.
static assert(() {
    auto i = quiet();
    i.plan = "pro";
    i.fiveTenths = 950;
    return resolveModel(grove.models, i).model == "sonnet";
}());

// A ritual that names no model takes the nearest one out: the top level's.
enum plain = flatten(parsed, 1);
static assert(resolveModel(plain.models, quiet()).model == "opus");
static assert(resolveModel(plain.models, quiet()).ruleInput == "");

// A rule whose input was never recorded does not match, and says which it was.
static assert(() {
    auto i = quiet();
    i.sevenKnown = false;
    auto r = resolveModel(grove.models, i);
    return r.model == "fable" && r.missing == "seven_day";
}());

// "make the default for ritual runs Sonnet, not Opus"
// No models anywhere: sonnet. The session that performed it ran on whatever
// the operator was on, and a walk of rites is not that conversation.
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
static assert(!bare.models.present);
static assert(resolveModel(flatten(bare, 0).models, quiet()).model == DEFAULT_MODEL);
static assert(DEFAULT_MODEL == "sonnet");

// The four comparisons.
enum opsSrc = `
models {
  five_hour: ">=50"   model: a
  seven_day: "<10"    model: b
  five_hour: "<=5"    model: c
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
enum ops = parsePbt(opsSrc);
static assert(() { auto i = quiet(); i.fiveTenths = 500; return resolveModel(flatten(ops, 0).models, i).model == "a"; }());
static assert(() {
    auto i = quiet();
    i.fiveTenths = 499;
    i.sevenTenths = 99;
    return resolveModel(flatten(ops, 0).models, i).model == "b";
}());
static assert(() { auto i = quiet(); i.fiveTenths = 50; return resolveModel(flatten(ops, 0).models, i).model == "c"; }());

// A bare model: on a ritual is refused. models { } is where it goes.
enum bareModelSrc = `
rites walk {
  ONE {
    eval: "true"
  }
}

project {
  path: "/p"
  ritual r {
    model: sonnet
    walk
  }
}
`;
static assert(validateRituals(parsePbt(bareModelSrc)).text() == "ritual r: unknown field `model`");

// One models block at each level. Every pbt is folded into one parse, so a
// second block anywhere would replace the first without a word.
enum twoGlobalSrc = `
models {
  model: "opus"
}

models {
  model: "sonnet"
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoGlobalSrc); }));

enum twoInProjectSrc = `
project {
  path: "/p"

  models {
    model: "opus"
  }

  models {
    model: "sonnet"
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
    models { model: "opus" }
    models { model: "sonnet" }
    walk
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoInRitualSrc); }));
