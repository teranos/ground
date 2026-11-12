module say_test;

// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"

version (Posix):

import say;
import zbuf : ZBuf;

// 「[Fable 5.2] A name is a tenant of its node's A2A, and a name of two words is written as」
// 「[Fable 5.2] an address writes one.」
unittest {
    ZBuf url;
    tenantUrl(url, "https://api.q.sbvh.nl", "Slate");
    assert(url.slice() == "https://api.q.sbvh.nl/a2a/Slate", url.slice());
    tenantUrl(url, "https://api.q.sbvh.nl", "Ada Lovelace");
    assert(url.slice() == "https://api.q.sbvh.nl/a2a/Ada%20Lovelace", url.slice());
}

// "A SESSION THATS SENDING TO ANOTHER SESSION BY NAME IS TOLD ABOUT THE MESSAGE BEING RECEIVED OR NOT"
unittest {
    assert(stateSaid("TASK_STATE_SUBMITTED") == "is not received yet");
    assert(stateSaid("TASK_STATE_COMPLETED") == "was received");
    assert(stateSaid("TASK_STATE_FAILED") == "was not received");
}

// "do you think the ground say should show near misses ?"
// 「[Fable 5.2] A name nobody holds is said so, with the names the node says are near it.」
unittest {
    ZBuf line;
    auto answer = `{"error":{"code":404,"status":"NOT_FOUND","message":"no agent is served at tenant Kwi Kwi. Near it: Kwikwi","details":[]}}`;
    assert(nobodyHolds("Kwi Kwi", answer, line) == "nobody holds the name Kwi Kwi. Near it: Kwikwi", line.slice());
    auto alone = `{"error":{"code":404,"message":"no agent is served at tenant Slate","details":[]}}`;
    assert(nobodyHolds("Slate", alone, line) == "nobody holds the name Slate", line.slice());
    assert(nobodyHolds("Slate", `{"error":{"code":404,"message":"no such task"}}`, line) == "");
}
