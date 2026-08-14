module ground_ritual_test;

// The ritual ground performs on itself. The pbt is read here rather than
// described, so a file that stops parsing stops the build instead of shipping
// a law nothing can walk.

import proto : parsePbt, validateRituals;
import ritual.resolve : flatten, indexOfRite;

private enum parsed = parsePbt(import("controls/ground.pbt"));

static assert(validateRituals(parsed) == "", validateRituals(parsed));

private enum idx = () {
    foreach (i; 0 .. parsed.ritualCount)
        if (parsed.rituals[i].name == "ground") return cast(long) i;
    return -1L;
}();
static assert(idx >= 0, "controls/ground.pbt declares no ritual named ground");

private enum flat = flatten(parsed, cast(size_t) idx);

// The order is the law: a test that cannot be shown to fail is not evidence,
// so RED sits between the test arriving and anything implementing it.
static assert(flat.count == 7);
static assert(flat.rites[0].name == "TESTFIRST");
static assert(flat.rites[1].name == "RED");
static assert(flat.rites[2].name == "GREEN");
static assert(flat.rites[3].name == "BUILT");
static assert(flat.rites[4].name == "SEALED");
static assert(flat.rites[5].name == "RAISED");
static assert(flat.rites[6].name == "CHECKED");

// CI is the only thing that runs dub test, so the rite that reads it is the
// one allowed to send the walk back. A cycle with nowhere to go is a halt.
static assert(indexOfRite(flat, "GREEN") == 2);
static assert(flat.rites[6].goto_ == "GREEN");

// Every rite reports. A walk nobody can see is the black box this is against.
static assert(flat.rites[0].to != 0);
static assert(flat.rites[6].to != 0);
