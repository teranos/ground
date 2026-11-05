module rite_test;

// What a rite's exit code means.

import proto : parsePbt;
import rite : classify, Verdict;

// book: rite-defaultsInput
enum defaultsInput = `
rites d {
  plain {
    eval: "true"
  }
}
`;
enum plain = parsePbt(defaultsInput).rites[0].rites[0];
static assert(classify(0, plain) == Verdict.Advance);

// "so catch means hold, until true"
// "the rite is like a bucket we are currently intending to throw a Stop in, if the condition is not met we throw it back allowing the agent to continue, because the rite is blocking the Stop"
// book: rite-classify
static assert(classify(1, plain) == Verdict.Hold);

// "if its non 0/1 we should just stop and halt the agent and leave on the screen the non 0 non 1 was and its message"
// book: rite-classify-2
static assert(classify(2, plain) == Verdict.Halt);

// 127 is the shell saying the command does not exist. Under a two-outcome
// reading it would be indistinguishable from a finding.
static assert(classify(127, plain) == Verdict.Halt);

// 130 is SIGINT. Somebody pressed ctrl-c; the rite learned nothing.
static assert(classify(130, plain) == Verdict.Halt);

// "i meant, from 0 to 1, the gate is from 0 to 1"
// book: rite-invertedInput
enum invertedInput = `
rites g {
  scratch {
    eval: "test -f /var/lib/qntx/qntx-operational.db"
    pass: 1
    catch: 0
  }
}
`;
enum scratch = parsePbt(invertedInput).rites[0].rites[0];
static assert(classify(1, scratch) == Verdict.Advance);
static assert(classify(0, scratch) == Verdict.Hold);
static assert(classify(2, scratch) == Verdict.Halt);

// book: rite-multiInput
enum multiInput = `
rites b {
  answers {
    eval: "curl -sf x"
    catch: [7, 22]
  }
}
`;
enum answers = parsePbt(multiInput).rites[0].rites[0];
static assert(classify(0,  answers) == Verdict.Advance);
static assert(classify(7,  answers) == Verdict.Hold);
static assert(classify(22, answers) == Verdict.Hold);
static assert(classify(6,  answers) == Verdict.Halt);

// book: rite-gotoInput
enum gotoInput = `
rites b {
  target {
    eval: "true"
  }
  survived {
    eval: "curl -sf z"
    catch: 22
    goto: target
  }
}
`;
enum survived = parsePbt(gotoInput).rites[0].rites[1];
static assert(classify(22, survived) == Verdict.Hold);
static assert(classify(0,  survived) == Verdict.Advance);

// "A DISPATCH ISNT A QUESTION BEING ASKED"
// book: rite-edgeInput
enum edgeInput = `
rites toss {
  params: [rig]

  FLIP {
    dispatch: "teranos/ground long-coin.yml"
    inputs: "echo rig=$rig"
    to: parent
  }
  REST {
    run: "sleep 30"
    to: parent
  }
}
`;
// Silence about catch is not the honest no it is for an eval: sent, or not.
enum flip = parsePbt(edgeInput).rites[0].rites[0];
static assert(flip.catchCount == 0);
static assert(classify(0, flip) == Verdict.Advance);
static assert(classify(1, flip) == Verdict.Halt);

// "msg i also want as anotgher optional one"
// "i want APP to be silent about its non zero exit"
// book: rite-foreseenInput
enum foreseenInput = `
rites toss {
  params: [rig]

  FLIP {
    dispatch: "teranos/ground long-coin.yml"
    inputs: "echo rig=$rig"
    catch: 1
    goto: REST
    msg: "a coin has no edge to rig, going to: REST"
    to: parent
  }
  REST {
    run: "sleep 30"
    to: parent
  }
}
`;
enum foreseen = parsePbt(foreseenInput).rites[0].rites[0];
static assert(classify(0, foreseen) == Verdict.Advance);
static assert(classify(1, foreseen) == Verdict.Hold);
static assert(foreseen.goto_ == "REST");
static assert(foreseen.msg == "a coin has no edge to rig, going to: REST");
// A code nobody foresaw still halts.
static assert(classify(2, foreseen) == Verdict.Halt);

