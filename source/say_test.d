module say_test;

// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"

version (Posix):

import say;
import zbuf : ZBuf;

// A name is a tenant of its node's A2A, and a name of two words is written as
// an address writes one.
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
