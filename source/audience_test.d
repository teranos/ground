module audience_test;

// CTFE tests — failure shows as a compile error.

import audience : Audience, audienceFrom, internetSees;
import hooks : Visibility;

// Scratch is scratch whatever else is true of the path. A fixture carrying a
// real path belongs there, and rewriting it breaks the fixture.
static assert(audienceFrom(true, true, true, Visibility.Public) == Audience.Scratch);

// Outside any repository nothing leaves the machine.
static assert(audienceFrom(false, false, false, Visibility.Unknown) == Audience.NoRepo);
static assert(audienceFrom(false, true, false, Visibility.Public) == Audience.NoRepo);

// A file git ignores never reaches the remote, whoever sees the remote.
static assert(audienceFrom(false, true, true, Visibility.Public) == Audience.Ignored);

static assert(audienceFrom(false, false, true, Visibility.Public) == Audience.Public);
static assert(audienceFrom(false, false, true, Visibility.Private) == Audience.Private);
static assert(audienceFrom(false, false, true, Visibility.Unknown) == Audience.Unknown);

// The policy, in one place. Unknown is seen: it is where a leak costs most.
static assert(internetSees(Audience.Public));
static assert(internetSees(Audience.Unknown));
static assert(!internetSees(Audience.Private));
static assert(!internetSees(Audience.Scratch));
static assert(!internetSees(Audience.Ignored));
static assert(!internetSees(Audience.NoRepo));
