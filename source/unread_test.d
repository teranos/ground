module unread_test;

import unread : buildUnreadClaimMessage;

// Empty input — empty buffer.
static assert(buildUnreadClaimMessage(null).slice == "");

// Single file — singular: "it", "Read it"
static assert(buildUnreadClaimMessage(["a.d"]).slice ==
    "You referenced `a.d` but never Read it this session. Use the Read tool before making claims about file contents.");

// Two files — plural: "them", "Read them"
static assert(buildUnreadClaimMessage(["a.d", "b.d"]).slice ==
    "You referenced `a.d`, `b.d` but never Read them this session. Use the Read tool before making claims about file contents.");

// Three files — same plural shape
static assert(buildUnreadClaimMessage(["a.d", "b.d", "c.d"]).slice ==
    "You referenced `a.d`, `b.d`, `c.d` but never Read them this session. Use the Read tool before making claims about file contents.");
