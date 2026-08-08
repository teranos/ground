module ritual.delivery;

// Resolving a receiver against a performance. The names themselves live in
// `receiver.d`, which the pbt parser also reads.

import ritual.position : Position;
public import receiver;

// The session a receiver reads in. Human and HostLlm share the parent session
// and differ by channel, not address; Ritual is ground and has no session.
const(char)[] sessionOf(const Position p, Receiver one) {
    switch (one) {
    case Receiver.Human:    return p.parent;
    case Receiver.HostLlm:  return p.parent;
    case Receiver.AgentLlm: return p.agentSession;
    default:                return null;
    }
}

// A performance can be started and carried by one session. Ground's own words
// are fine there; the agent's own words handed back to it are not.
bool deliverable(const Position p, Receiver one, bool bodyIsAgents) {
    auto whom = sessionOf(p, one);
    if (whom is null || whom.length == 0) return false;
    if (bodyIsAgents && whom == p.agentSession) return false;
    return true;
}

// The one place a note about a performance is written.
bool deliver(DB)(DB db, const Position p, Receiver to,
                 const(char)[] key, const(char)[] body_, bool bodyIsAgents = false) {
    import immediate : writeNote;

    // Human is the screen, not a queue — collet and systemMessage carry it.
    // Queueing it here would deliver the same line to the model twice.
    if (!wants(to, Receiver.HostLlm) && !wants(to, Receiver.AgentLlm)) return false;

    auto one = wants(to, Receiver.HostLlm) ? Receiver.HostLlm : Receiver.AgentLlm;
    if (!deliverable(p, one, bodyIsAgents)) return false;
    writeNote(db, sessionOf(p, one), key, body_);
    return true;
}
