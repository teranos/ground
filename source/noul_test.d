module noul_test;

// "i want jev to tell me if a Rite needs to be ran or if we can just skip it"
// "see Jev's noul as another way to set a rituals rite"
// "so instead of eval: we get noul: right ?"
// "i say Jev is optional, no Jev is autopass"
// "can you get as close to jev api as possible no inventions"

import proto : parsePbt, validateRituals;
import noul : jevBody, jevAnswer, JevAnswer;

// The key is the primitive, the value its instructions, as eval: is a command.
enum noulSrc = `
rites judged {
  NEEDED {
    noul: "This push is consequential and wants to be deployed"
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(parsePbt(noulSrc).rites[0].rites[0].noul
              == "This push is consequential and wants to be deployed");
static assert(parsePbt(noulSrc).rites[0].rites[0].criteriaCount == 0);
static assert(validateRituals(parsePbt(noulSrc)).text().length == 0);

// A score's levels are Jev's `criteria`, in order, the first one the no.
enum scoreSrc = `
rites judged {
  IMPACT {
    score: "What would installing this push change on the running system?"
    criteria: [
      "Nothing a running box would notice",
      "The web page looks different",
      "Data is stored differently"
    ]
    goto: DONE
  }
  DONE {
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(parsePbt(scoreSrc).rites[0].rites[0].score
              == "What would installing this push change on the running system?");
static assert(parsePbt(scoreSrc).rites[0].rites[0].criteriaCount == 3);
static assert(parsePbt(scoreSrc).rites[0].rites[0].criteria[2] == "Data is stored differently");
static assert(validateRituals(parsePbt(scoreSrc)).text().length == 0);

// A score without levels has no spectrum to place the state on.
enum noLevelsSrc = `
rites judged {
  X {
    score: "?"
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(validateRituals(parsePbt(noLevelsSrc)).text()
              == "rite X: a score names its levels in `criteria`");

// One rite, one way to answer.
enum bothSrc = `
rites judged {
  X {
    noul: "?"
    eval: "true"
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(validateRituals(parsePbt(bothSrc)).text()
              == "rite X: `noul` and `eval` are two answers to one question");

enum twoJevSrc = `
rites judged {
  X {
    noul: "?"
    score: "?"
    criteria: ["a", "b"]
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(validateRituals(parsePbt(twoJevSrc)).text()
              == "rite X: `noul` and `score` are two answers to one question");

// A choice's options are Jev's `criteria` map: each option a rite the walk
// can go to, its description what sends it there.
enum choiceSrc = `
rites judged {
  ROUTE {
    choice: "Which rite should this push go to next?"
    criteria {
      DEPLOY: "The node or the store changes"
      DONE: "Nothing a running box would notice"
    }
  }
  DEPLOY {
  }
  DONE {
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(parsePbt(choiceSrc).rites[0].rites[0].choice
              == "Which rite should this push go to next?");
static assert(parsePbt(choiceSrc).rites[0].rites[0].criteriaCount == 2);
static assert(parsePbt(choiceSrc).rites[0].rites[0].criteriaKeys[0] == "DEPLOY");
static assert(parsePbt(choiceSrc).rites[0].rites[0].criteria[1] == "Nothing a running box would notice");
static assert(validateRituals(parsePbt(choiceSrc)).text().length == 0);

// An option that names no rite is a place the walk cannot go.
enum strayChoiceSrc = `
rites judged {
  ROUTE {
    choice: "Where?"
    criteria {
      NOWHERE: "a rite that does not exist"
    }
  }
}
project {
  path: "/x"
  ritual r {
    judged
  }
}
`;
static assert(validateRituals(parsePbt(strayChoiceSrc)).text()
              == "rite ROUTE: choice option `NOWHERE` names no rite");

// The body on the wire: state as given, the model, the question under the
// rite's name with Jev's own fields.
unittest {
    import zbuf : ZBuf;
    ZBuf b;
    const(char)[][1] none;
    jevBody(b, `{"repo":"x"}`, "NEEDED", "noul", "Is it?", none[0 .. 0]);
    assert(b.slice() == `{"state":{"repo":"x"},"model":"jev-latest","questions":{"NEEDED":{"type":"noul","instructions":"Is it?"}}}`,
           b.slice());
    const(char)[][2] levels = ["nothing", "something"];
    jevBody(b, `{"repo":"x"}`, "IMPACT", "score", "How much?", levels[]);
    assert(b.slice() == `{"state":{"repo":"x"},"model":"jev-latest","questions":{"IMPACT":{"type":"score","instructions":"How much?","criteria":["nothing","something"]}}}`,
           b.slice());
    const(char)[][2] names = ["DEPLOY", "DONE"];
    const(char)[][2] descs = ["the node changes", "nothing changes"];
    jevBody(b, `{"repo":"x"}`, "ROUTE", "choice", "Where?", descs[], names[]);
    assert(b.slice() == `{"state":{"repo":"x"},"model":"jev-latest","questions":{"ROUTE":{"type":"choice","instructions":"Where?","criteria":{"DEPLOY":"the node changes","DONE":"nothing changes"}}}}`,
           b.slice());
}

// A choice's answer is the option's name.
unittest {
    JevAnswer a;
    assert(jevAnswer(`{"answers":{"ROUTE":{"type":"choice","choice":"DONE","confidence":0.9,"probabilities":{"DEPLOY":0.1,"DONE":0.9}}}}`, "ROUTE", a));
    assert(a.type == "choice" && a.choice == "DONE");
    assert(a.confidence > 0.89 && a.confidence < 0.91);
}

// The reply, read by the rite's name: a noul's probability; a score's score,
// confidence and the level with the most probability.
unittest {
    JevAnswer a;
    assert(jevAnswer(`{"model":"jev-1.13.0","answers":{"NEEDED":{"type":"noul","noul":0.83}},"usage":{}}`, "NEEDED", a));
    assert(a.type == "noul" && a.noul > 0.829 && a.noul < 0.831);

    assert(jevAnswer(`{"answers":{"IMPACT":{"type":"score","score":3.13,"confidence":0.87,"legend":{"0":"nothing","1":"page","2":"data"},"probabilities":{"0":0.0,"1":0.01,"2":0.99}}}}`, "IMPACT", a));
    assert(a.type == "score" && a.score > 3.12 && a.score < 3.14);
    assert(a.confidence > 0.86 && a.confidence < 0.88);
    assert(a.level == 2, "the level with the most probability");

    assert(!jevAnswer(`{"answers":{"OTHER":{"type":"noul","noul":0.2}}}`, "NEEDED", a));
    assert(!jevAnswer(`{"error":"unauthorized"}`, "NEEDED", a));
}
