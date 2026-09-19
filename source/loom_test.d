module loom_test;

// "if set, we send to loom, if not set, we dont."
import loom : loomSends, loomFits, LOOM_DATAGRAM_MAX;

static assert(!loomSends(0), "no port is no send");
static assert(loomSends(19470));
static assert(!loomSends(65536), "not a port");

// Measured 2026-09-19 on macOS: SO_SNDBUF on a fresh UDP socket is 9216, and
// a datagram past it is refused with EMSGSIZE before it leaves the process.
static assert(LOOM_DATAGRAM_MAX == 9216);
static assert(loomFits(9216));
static assert(!loomFits(9217));
