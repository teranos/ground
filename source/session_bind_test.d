module session_bind_test;

// A performance whose row names no session cannot be spoken to. The driver's
// note, the agent's last message and who walked each rite all key on it.
// Measured: willow-1786123344 ran to APPLE with session empty.

import ritual.position : Position, start, bindSession;

// The first session to start in the tree owns the performance.
enum bound = bindSession(start("willow", 10), "sess-a");
static assert(bound.agentSession == "sess-a");

// A second session does not take it over. Ownership moving under the driver
// would send the notes somewhere else mid-performance.
enum again = bindSession(bound, "sess-b");
static assert(again.agentSession == "sess-a");

// Nothing to bind is not a binding.
enum blank = bindSession(start("willow", 10), "");
static assert(blank.agentSession.length == 0);
