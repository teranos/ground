module unread_test;

import unread : buildUnreadClaimMessage;

// Empty input — empty buffer.
static assert(buildUnreadClaimMessage(null).slice == "");

// The control fires on a MENTION — it matches a filename in the assistant's
// text and checks for a Read attestation. It has nothing to say about whether
// a claim was made about the contents.
//
// Telling the reader otherwise taught a narrower rule than the one enforced.
// A reader who checks themselves against the stated rule — "did I claim
// anything about that file's contents? no" — concludes false positive and
// argues with the control instead of complying. That is the ERROR AXIOM's
// truthfulness clause violated by ground itself: reporting a cause it never
// measured, and being discounted for it.

// Single file — singular: "it", "Read it"
static assert(buildUnreadClaimMessage(["a.d"]).slice ==
    "You referenced `a.d` but never Read it this session. Naming a file is claiming it — Read it in full before you mention it, including in passing or in pasted output.");

// Two files — plural: "them", "Read them"
static assert(buildUnreadClaimMessage(["a.d", "b.d"]).slice ==
    "You referenced `a.d`, `b.d` but never Read them this session. Naming a file is claiming it — Read them in full before you mention them, including in passing or in pasted output.");

// Three files — same plural shape
static assert(buildUnreadClaimMessage(["a.d", "b.d", "c.d"]).slice ==
    "You referenced `a.d`, `b.d`, `c.d` but never Read them this session. Naming a file is claiming it — Read them in full before you mention them, including in passing or in pasted output.");
