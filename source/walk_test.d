module walk_test;

// Two things walked every rite — `ground drive` and `stop.d` in the agent's own
// session — and `rev` only decides whose write lands, which is after both have
// already run it. Measured as one trigger producing two GitHub runs.

import ritual.store : canClaim, WALK_LEASE_SEC;

enum now = 1_000_000L;

// Nobody holds it.
static assert(canClaim("", 0, "111", now, WALK_LEASE_SEC));

// The holder asks again. A walker re-entering its own rite is not a race.
static assert(canClaim("111", now - 5, "111", now, WALK_LEASE_SEC));

// Another walker holds it and is still within the lease. This is the case that
// was producing duplicate dispatches.
static assert(!canClaim("222", now - 5, "111", now, WALK_LEASE_SEC));
static assert(!canClaim("222", now - WALK_LEASE_SEC + 1, "111", now, WALK_LEASE_SEC));

// "a driver that dies mid-rite would otherwise park the walk forever" — so an
// expired claim is taken rather than waited on.
static assert(canClaim("222", now - WALK_LEASE_SEC, "111", now, WALK_LEASE_SEC));
static assert(canClaim("222", now - WALK_LEASE_SEC - 60, "111", now, WALK_LEASE_SEC));

// The lease outlasts a bounded dispatch: five looks two seconds apart, plus a
// 10s throttle before each of them.
static assert(WALK_LEASE_SEC > 5 * (2 + 10));

// A lease on its own only serialises. Measured after building one: FLIP1 still
// passed twice three seconds apart, because the second walker waited for the
// lease, took it, and ran the same rite.
import ritual.store : claimsOneExecution;
static assert(claimsOneExecution(7, 7));
static assert(!claimsOneExecution(8, 7));
