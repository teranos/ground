module rite_test;

// What a rite's exit code means.
// Brandon: "if its non 0/1 we should just stop and halt the agent and leave
// on the screen the non 0 non 1 was and its message"

import proto : parsePbt;
import rite : classify, Verdict;

// A rite that declares nothing takes the defaults: 0 advances, 1 holds.
enum defaultsInput = `
rites d {
  plain { cmd: "true" }
}
`;
enum plain = parsePbt(defaultsInput).rites[0].rites[0];
static assert(classify(0, plain) == Verdict.Advance);

// "so catch means hold, until true"
static assert(classify(1, plain) == Verdict.Hold);

// Anything neither declared is the third outcome. 2 is not a worse 1 —
// it is a different kind of answer, and the rite cannot read it.
static assert(classify(2, plain) == Verdict.Halt);

// 127 is the shell saying the command does not exist. Under a two-outcome
// reading it would be indistinguishable from a finding.
static assert(classify(127, plain) == Verdict.Halt);

// 130 is SIGINT. Somebody pressed ctrl-c; the rite learned nothing.
static assert(classify(130, plain) == Verdict.Halt);

// "i meant, from 0 to 1, the gate is from 0 to 1"
// Shell negation flattens every non-zero to 0, so a broken command reads as
// a pass. Declared instead of inverted.
enum invertedInput = `
rites g {
  scratch { cmd: "test -f /var/lib/qntx/qntx-operational.db"  pass: 1  catch: 0 }
}
`;
enum scratch = parsePbt(invertedInput).rites[0].rites[0];
static assert(classify(1, scratch) == Verdict.Advance);
static assert(classify(0, scratch) == Verdict.Hold);
static assert(classify(2, scratch) == Verdict.Halt);

// "catch: [7, 22]" — curl exits 7 when it cannot connect and 22 on an HTTP
// error. Both mean the box is not answering yet, neither means it failed.
enum multiInput = `
rites b {
  answers { cmd: "curl -sf x"  catch: [7, 22] }
}
`;
enum answers = parsePbt(multiInput).rites[0].rites[0];
static assert(classify(0,  answers) == Verdict.Advance);
static assert(classify(7,  answers) == Verdict.Hold);
static assert(classify(22, answers) == Verdict.Hold);
static assert(classify(6,  answers) == Verdict.Halt);

// A rite with a goto still classifies as Hold. Where a held position moves
// is a separate question from what the code meant.
enum gotoInput = `
rites b {
  target   { cmd: "true" }
  survived { cmd: "curl -sf z"  catch: 22  goto: target }
}
`;
enum survived = parsePbt(gotoInput).rites[0].rites[1];
static assert(classify(22, survived) == Verdict.Hold);
static assert(classify(0,  survived) == Verdict.Advance);
