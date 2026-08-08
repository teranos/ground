module ritual.delivery;

// "IS THE PROBLEM THAT WE DONT HAVE THE NAMES FOR THE RECEIVER STANDARDISED ?"
// "WHY DONT WE HAVE MORE ABSOLUTE CONTROL OVER WHAT GOES WHERE"

import ritual.position : Position;
public import receiver;

const(char)[] sessionOf(const Position p, Receiver one) {
    switch (one) {
    case Receiver.Human:    return p.parent;
    case Receiver.HostLlm:  return p.parent;
    case Receiver.AgentLlm: return p.agentSession;
    default:                return null;
    }
}

bool deliverable(const Position p, Receiver one, bool bodyIsAgents) {
    auto whom = sessionOf(p, one);
    if (whom is null || whom.length == 0) return false;
    if (bodyIsAgents && whom == p.agentSession) return false;
    return true;
}

bool deliver(DB)(DB db, const Position p, Receiver to,
                 const(char)[] key, const(char)[] body_, bool bodyIsAgents = false) {
    import immediate : writeNote;

    if (!wants(to, Receiver.HostLlm) && !wants(to, Receiver.AgentLlm)) return false;

    auto one = wants(to, Receiver.HostLlm) ? Receiver.HostLlm : Receiver.AgentLlm;
    if (!deliverable(p, one, bodyIsAgents)) return false;
    writeNote(db, sessionOf(p, one), key, body_);
    return true;
}
