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

// `speaker` is the session whose words these are; ground's own are nobody's.
// A speaker is never their own audience: the parent of an agentless ritual
// stops in the checkout it performs in, and heard itself four times.
bool deliverable(const Position p, Receiver one, const(char)[] speaker) {
    auto whom = sessionOf(p, one);
    if (whom is null || whom.length == 0) return false;
    if (speaker.length > 0 && whom == speaker) return false;
    return true;
}

bool deliver(DB)(DB db, const Position p, Receiver to,
                 const(char)[] key, const(char)[] body_, const(char)[] speaker = null) {
    import immediate : writeNote;

    // "the outcome is what is spoken back into the mic to both the agent and
    // parent"
    static immutable Receiver[2] SIDES = [Receiver.HostLlm, Receiver.AgentLlm];

    bool sent;
    foreach (one; SIDES) {
        // "why would you have to specify it? its expected, everything comes
        // back to causer" — `to:` gates the parent. The agent caused the rite.
        if (one != Receiver.AgentLlm && !wants(to, one)) continue;
        if (!deliverable(p, one, speaker)) continue;
        writeNote(db, sessionOf(p, one), key, body_);
        sent = true;
    }
    return sent;
}
