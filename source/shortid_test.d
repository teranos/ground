module shortid_test;

// A performance is `willow-1786132853`. Nobody types that, and every line of
// a trace saying only `willow` cannot be told from the next performance.

import ritual : shortId;

// Base36 of the id's own timestamp. Three characters, no new state.
static assert(shortId("willow-0").text() == "000");
static assert(shortId("willow-1").text() == "001");
static assert(shortId("willow-35").text() == "00z");
static assert(shortId("willow-36").text() == "010");
static assert(shortId("willow-1295").text() == "0zz");
static assert(shortId("willow-1296").text() == "100");

// It wraps rather than growing. Three characters hold 46656 seconds, so two
// performances collide only if they start close to thirteen hours apart.
static assert(shortId("willow-46656").text() == "000");
static assert(shortId("willow-46657").text() == "001");

// An id with no timestamp has no handle, rather than a made-up one.
static assert(shortId("willow").text() == "");
static assert(shortId("").text() == "");
