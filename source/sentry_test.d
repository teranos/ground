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

// Pass 1 walks the same text before the parser does, and every test above went
// straight to parsePbt. The first real sentry block stopped the build in
// countPbt: the word was skipped and the next readWord landed on its brace.
import count : countPbt;
static assert(countPbt(topOnlySrc).totalProjects == 1);
static assert(countPbt(src).totalProjects == 1);

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

// "do we send things to sentry yet?"
// A dsn is three things a sender needs apart: the key, the host and the
// project. Anything that is not all three is nowhere to send.
import sentry : parseDsn, envelopeUrl, traceId, riteEnvelope, performanceEnvelope;
import rite : Verdict;

enum sendDsn = "https://key123@o1.ingest.example/42";
enum parts = parseDsn(sendDsn);
static assert(parts.ok);
static assert(parts.key == "key123");
static assert(parts.host == "o1.ingest.example");
static assert(parts.project == "42");
static assert(envelopeUrl(parts).text() == "https://o1.ingest.example/api/42/envelope/");

static assert(!parseDsn("").ok);
static assert(!parseDsn("o1.ingest.example/42").ok, "no scheme");
static assert(!parseDsn("https://o1.ingest.example/42").ok, "no key");
static assert(!parseDsn("https://key123@o1.ingest.example/").ok, "no project");
static assert(!parseDsn("https://key123@/42").ok, "no host");

// One performance is one trace, so its rites thread together. The id is the
// performance's own, read the same way every time, and sentry wants 32 hex.
static assert(traceId("coinflip-1000").text().length == 32);
static assert(traceId("coinflip-1000").text() == traceId("coinflip-1000").text());
static assert(traceId("coinflip-1000").text() != traceId("coinflip-1001").text());
static assert(() {
    foreach (c; traceId("coinflip-1000").text())
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}());

// "you would say, we can send some things to sentry before the end of a ritual right?"
// A rite's verdict goes when it lands. An ending that never arrives then costs
// only the ending, and the last rite sent is where the walk stood.
import sentry : RiteReport;

// "BUT I CARE ABOUT HOW LONG INDIVIDUAL RITES TAKE AND WHAT THEIR CATCHES ARE AND IF WE HIT MAX_GOTO"
// How long the command ran this time, how long the rite has been open, what
// the author declared it passes and catches on, and how far into its bounds
// the walk is. A bound that was spent says so as a fact of its own.
private RiteReport said(const(char)[] rite, Verdict v, int code) {
    RiteReport r;
    r.performance = "coinflip-1000";
    r.ritual = "coinflip";
    r.rite = rite;
    r.verdict = v;
    r.code = code;
    r.pass = 0;
    r.catches[0] = 1;
    r.catches[1] = 22;
    r.catchCount = 2;
    r.tookMs = 250;
    r.openMs = 31000;
    r.evals = 3;
    r.gotos = 2;
    r.maxGoto = 16;
    return r;
}

enum riteSent = riteEnvelope(sendDsn, 1000, said("T1FLIP1", Verdict.Advance, 0));
static assert(riteSent.text() ==
    `{"dsn":"https://key123@o1.ingest.example/42"}` ~ "\n"
    ~ `{"type":"log","item_count":1,"content_type":"application/vnd.sentry.items.log+json"}` ~ "\n"
    ~ `{"items":[{"timestamp":1000,"trace_id":"` ~ traceId("coinflip-1000").text()
    ~ `","level":"info","body":"coinflip T1FLIP1 advance","attributes":{`
    ~ `"performance":{"value":"coinflip-1000","type":"string"},`
    ~ `"ritual":{"value":"coinflip","type":"string"},`
    ~ `"rite":{"value":"T1FLIP1","type":"string"},`
    ~ `"verdict":{"value":"advance","type":"string"},`
    ~ `"catches":{"value":"1,22","type":"string"},`
    ~ `"code":{"value":0,"type":"integer"},`
    ~ `"pass":{"value":0,"type":"integer"},`
    ~ `"took_ms":{"value":250,"type":"integer"},`
    ~ `"open_ms":{"value":31000,"type":"integer"},`
    ~ `"evals":{"value":3,"type":"integer"},`
    ~ `"gotos":{"value":2,"type":"integer"},`
    ~ `"max_goto":{"value":16,"type":"integer"},`
    ~ `"max_goto_hit":{"value":false,"type":"boolean"},`
    ~ `"max_evals_hit":{"value":false,"type":"boolean"}}}]}` ~ "\n");

// A hold is the rite working as written. A halt is the one that needs a person.
import matcher : contains;
static assert(contains(riteEnvelope(sendDsn, 1000, said("R", Verdict.Hold, 1)).text(),
                       `"level":"info"`));
static assert(contains(riteEnvelope(sendDsn, 1000, said("R", Verdict.Halt, 127)).text(),
                       `"level":"error"`));
static assert(contains(riteEnvelope(sendDsn, 1000, said("R", Verdict.Halt, 127)).text(),
                       `"code":{"value":127,"type":"integer"}`));

// A name is the author's, and a quote in one must not end the string early.
static assert(contains(riteEnvelope(sendDsn, 1000, said(`R"x`, Verdict.Advance, 0)).text(),
                       `"rite":{"value":"R\"x","type":"string"}`));

// A jump that was taken names where it went, in the line a person reads and
// in a field a query can group on.
enum jumped = () {
    auto r = said("BACK", Verdict.Hold, 1);
    r.jumpedTo = "HERE";
    return riteEnvelope(sendDsn, 1000, r);
}();
static assert(contains(jumped.text(), `"body":"coinflip BACK hold, goto HERE"`));
static assert(contains(jumped.text(), `"goto":{"value":"HERE","type":"string"}`));
static assert(!contains(riteSent.text(), `"goto":`), "no jump, no field saying there was one");

// The bound that ended a walk is the reason it ended, so it is said where the
// halt is said rather than left to be worked out from two numbers.
enum spentGoto = () {
    auto r = said("BACK", Verdict.Halt, 1);
    r.gotos = 16;
    r.gotoSpent = true;
    return riteEnvelope(sendDsn, 1000, r);
}();
static assert(contains(spentGoto.text(), `"body":"coinflip BACK halt, max_goto spent"`));
static assert(contains(spentGoto.text(), `"max_goto_hit":{"value":true,"type":"boolean"}`));
static assert(contains(spentGoto.text(), `"level":"error"`));

enum spentEvals = () {
    auto r = said("ASKS", Verdict.Halt, 1);
    r.evalsSpent = true;
    return riteEnvelope(sendDsn, 1000, r);
}();
static assert(contains(spentEvals.text(), `"body":"coinflip ASKS halt, max_evals spent"`));
static assert(contains(spentEvals.text(), `"max_evals_hit":{"value":true,"type":"boolean"}`));

// A rite that declares no catch still has the one silence gives it, and a
// rite that catches nothing says so with an empty list, not a missing field.
enum noCatch = () {
    auto r = said("R", Verdict.Advance, 0);
    r.catchCount = 0;
    return riteEnvelope(sendDsn, 1000, r);
}();
static assert(contains(noCatch.text(), `"catches":{"value":"","type":"string"}`));

// The start and the ending of a performance, in the ending's own word.
enum began = performanceEnvelope(sendDsn, 1000, "coinflip-1000", "coinflip", "started");
static assert(contains(began.text(), `"body":"coinflip started"`));
static assert(contains(began.text(), `"level":"info"`));
static assert(contains(began.text(), `"state":{"value":"started","type":"string"}`));
static assert(contains(began.text(), `"trace_id":"` ~ traceId("coinflip-1000").text() ~ `"`));
static assert(contains(performanceEnvelope(sendDsn, 1000, "c-1", "c", "done").text(), `"level":"info"`));
static assert(contains(performanceEnvelope(sendDsn, 1000, "c-1", "c", "halted").text(), `"level":"error"`));
static assert(contains(performanceEnvelope(sendDsn, 1000, "c-1", "c", "aborted").text(), `"level":"warn"`));

// "what also sucks is missing sentry data about this"
// An ending says what became of the agent. One left running is the failure a
// person otherwise meets as a machine out of memory, so it is an error even
// when the ritual itself is done.
enum endedClean = performanceEnvelope(sendDsn, 1000, "c-1", "c", "done", "stopped");
static assert(contains(endedClean.text(), `"body":"c done"`));
static assert(contains(endedClean.text(), `"level":"info"`));
static assert(contains(endedClean.text(), `"agent":{"value":"stopped","type":"string"}`));

enum leaked = performanceEnvelope(sendDsn, 1000, "c-1", "c", "done", "unbound");
static assert(contains(leaked.text(), `"body":"c done, agent unbound"`));
static assert(contains(leaked.text(), `"level":"error"`));
static assert(contains(leaked.text(), `"agent":{"value":"unbound","type":"string"}`));

enum refusedStop = performanceEnvelope(sendDsn, 1000, "c-1", "c", "halted", "failed");
static assert(contains(refusedStop.text(), `"body":"c halted, agent failed"`));
static assert(contains(refusedStop.text(), `"level":"error"`));

// A start has no agent to have stopped, and says nothing about one.
static assert(!contains(began.text(), `"agent":`));

// "You know how something a msg appears about ground performance hook budgets?"
// "it should send to sentry"
// The notice a session reads once per window, kept where it can be counted:
// which event, against which budget, over how many runs, on which build, and
// where the time went. A session id threads a session's notices together.
import sentry : budgetEnvelope;
import phases : PhaseMeans;

enum overBudget = () {
    PhaseMeans means;
    means.add("stdin=100us attest=44400us handler=6200us total=50700us exit=none");
    means.add("stdin=100us attest=44400us handler=6200us total=50700us exit=none");
    return budgetEnvelope(sendDsn, 1000, "sess-1", "UserPromptSubmit", 50, 50,
                          "v0.19.1-309-gb39da59\n", "teranos/ground", means);
}();
static assert(contains(overBudget.text(), `"level":"warn"`));
static assert(contains(overBudget.text(),
    `"body":"UserPromptSubmit averages 50ms against a budget of 50ms"`));
static assert(contains(overBudget.text(), `"trace_id":"` ~ traceId("sess-1").text() ~ `"`));
static assert(contains(overBudget.text(), `"event":{"value":"UserPromptSubmit","type":"string"}`));
static assert(contains(overBudget.text(), `"project":{"value":"teranos/ground","type":"string"}`));
static assert(contains(overBudget.text(), `"version":{"value":"v0.19.1-309-gb39da59","type":"string"}`),
              "the newline the version file ends with is not part of the version");
static assert(contains(overBudget.text(), `"avg_ms":{"value":50,"type":"integer"}`));
static assert(contains(overBudget.text(), `"budget_ms":{"value":50,"type":"integer"}`));
static assert(contains(overBudget.text(), `"runs":{"value":2,"type":"integer"}`));
static assert(contains(overBudget.text(), `"phase_us.attest":{"value":44400,"type":"integer"}`));
static assert(contains(overBudget.text(), `"phase_us.handler":{"value":6200,"type":"integer"}`));
static assert(contains(overBudget.text(), `"phase_us.stdin":{"value":100,"type":"integer"}`));

// A notice is not a ritual's, so no ritual says where it goes. The project the
// session stands in does, and the top level answers where no project does.
import ritual : dsnAt;
static assert(dsnAt(parsed, "/home/u/src/grove") == "https://proj@o1.ingest.example/2");
static assert(dsnAt(parsed, "/home/u/src/grove/deep/inside") == "https://proj@o1.ingest.example/2");
static assert(dsnAt(parsed, "/home/u/src/grove-other") == "https://top@o1.ingest.example/1",
              "a sibling directory is not the project");
static assert(dsnAt(parsed, "/somewhere/else") == "https://top@o1.ingest.example/1");
static assert(dsnAt(bare, "/p") == "");

// A dsn that is not one builds nothing, so nothing is posted anywhere.
static assert(riteEnvelope("not a dsn", 1000, said("R", Verdict.Advance, 0)).text().length == 0);
static assert(performanceEnvelope("", 1000, "c-1", "c", "done").text().length == 0);
