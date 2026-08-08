module mic_test;

// "i want to know who is holding the mic and if holding it is legitimate, or
// just blocking the entire performance"

import mic;

// The row reads without a decoder.
static assert(micWord(Mic.Ground) == "ground");
static assert(micWord(Mic.Agent) == "agent");
static assert(micWord(Mic.Ci) == "ci");
static assert(micWord(Mic.Human) == "human");

static assert(micFromWord("ci").valid);
static assert(micFromWord("ci").who == Mic.Ci);

// A word this build cannot read is not Ground. Defaulting would say a rite is
// speaking when nothing knows who is.
static assert(!micFromWord("").valid);
static assert(!micFromWord("qntx").valid);

// "ground, or the rite should have no reason to keep holding the mic for
// longer than 2s" — it evaluates and speaks, so there is nothing to wait for.
static assert(!blocking(Mic.Ground, 2, 0, 0));
static assert(blocking(Mic.Ground, 3, 0, 0));

// CI's bound is what that workflow takes. `long-coin` sleeps 15, so fifteen
// seconds is the job running and four hundred is the job lost.
static assert(!blocking(Mic.Ci, 15, 20, 0));
static assert(blocking(Mic.Ci, 400, 20, 0));

// An unknown expectation is not an accusation. A workflow with no history
// cannot be said to be late.
static assert(!blocking(Mic.Ci, 4000, 0, 0));

// The operator is never on a clock.
static assert(!blocking(Mic.Human, 86_400, 20, 20));

// The agent's bound is whatever is passed. Nothing measures it yet, so the
// 605-second silences would not have been called blocking by this.
static assert(!blocking(Mic.Agent, 605, 0, 0));
static assert(blocking(Mic.Agent, 605, 0, 60));
