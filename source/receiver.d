module receiver;

// Who a message is for, named rather than looked up.
//
// THERE ARE FOR RECEIVERS

// PARENT: HUMAN / HOSTLLM
// CHILD : RITUAL / AGENTLLM
enum Receiver {
    None     = 0,
    Human    = 1,  // the operator's screen: collet, and systemMessage
    HostLlm  = 2,  // the model in the parent session: the immediate queue
    Ritual   = 4,  // the performance, which drives the chat through its rites
    AgentLlm = 8,  // the model carrying the performance
}

// AgentLlm is not a `to:` value. A rite is already a conversation with the
// agent — the briefing and the block go there by construction — so writing it
// would declare the one channel that cannot be switched off.

// "to: parent / means to both" — a side, not a reader. The two readers of the
// parent session are named separately when only one of them is meant.
enum PARENT = cast(Receiver)(Receiver.Human | Receiver.HostLlm);

Receiver both(Receiver a, Receiver b) { return cast(Receiver)(a | b); }

bool wants(Receiver set, Receiver one) { return (set & one) != 0; }

// `parent` is the only parent-side value. The Stop line lands in the session,
// where the human reads it on screen and the model reads it in context — one
// mechanism, two readers, so splitting them was a state with no delivery.
Receiver parseReceiver(const(char)[] word) {
    if (word == "parent") return PARENT;
    return Receiver.None;
}
