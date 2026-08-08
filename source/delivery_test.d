module delivery_test;

// Brandon: "WHY DONT WE HAVE MORE ABSOLUTE CONTROL OVER WHAT GOES WHERE"

import ritual.position : Position, start;
import ritual.delivery : Receiver, sessionOf, deliverable, wants, both, PARENT;

private Position perf() {
    auto p = start("willow", 10);
    p.id = "willow-1";
    p.parent = "parent-session";
    p.agentSession = "agent-session";
    return p;
}

enum p = perf();

// Two sides, two readers each. Human and HostLlm read the same session and
// differ by channel; that is the distinction the old two-value enum lost.
static assert(sessionOf(p, Receiver.Human) == "parent-session");
static assert(sessionOf(p, Receiver.HostLlm) == "parent-session");
static assert(sessionOf(p, Receiver.AgentLlm) == "agent-session");

// The ritual is the receiver, not a rite — a rite is a piece of it, and the
// ritual is what drives the chat through them. It has no session of its own,
// so naming it as an address is a mistake with an answer.
static assert(sessionOf(p, Receiver.Ritual) is null);

// "NEEDS TO BE SEEN BY BOTH HUMAN AND HOSTLLM"
static assert(wants(PARENT, Receiver.Human));
static assert(wants(PARENT, Receiver.HostLlm));
static assert(!wants(PARENT, Receiver.AgentLlm));

static assert(both(Receiver.Human, Receiver.HostLlm) == PARENT);

// Nobody to tell is not a delivery. A performance started from a terminal has
// no parent, and the rite lines it produces have nowhere to go.
enum orphan = { auto q = perf(); q.parent = ""; return q; }();
static assert(!deliverable(orphan, Receiver.HostLlm, false));
static assert(deliverable(orphan, Receiver.AgentLlm, false));

// The bug this exists to make unwriteable: an agent handed its own last
// message, framed as somebody quoting it and asking for work.
enum solo = { auto q = perf(); q.parent = "same"; q.agentSession = "same"; return q; }();
static assert(!deliverable(solo, Receiver.HostLlm, true));

// Ground's own words to that same session are fine — a briefing is not a
// quotation, and the agent has to be told which rite is open.
static assert(deliverable(solo, Receiver.HostLlm, false));
static assert(deliverable(solo, Receiver.AgentLlm, false));
