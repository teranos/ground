module receiver;

// BOOK_GLOSSARY **Receiver**: Who a message is for: human, host, ritual, or agent. Parent is human and host together.

// "THERE ARE FOR RECEIVERS"

// "PARENT: HUMAN / HOSTLLM"
// "CHILD : RITUAL / AGENTLLM"
enum Receiver {
    None     = 0,
    Human    = 1,
    HostLlm  = 2,
    Ritual   = 4,
    AgentLlm = 8,
}

// "to: agent doesnt make sense" / "no user facign i would say"
// "not part of the api"

// "to: parent" / "means to both"
enum PARENT = cast(Receiver)(Receiver.Human | Receiver.HostLlm);

Receiver both(Receiver a, Receiver b) { return cast(Receiver)(a | b); }

bool wants(Receiver set, Receiver one) { return (set & one) != 0; }

// "there is actually no instance where i want it to return only to me"
// "if routed" / "both me and you reeive it"
Receiver parseReceiver(const(char)[] word) {
    if (word == "parent") return PARENT;
    return Receiver.None;
}
