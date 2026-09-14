module byref_test;

// The parsed control set is megabytes. A helper that takes it by value puts a
// copy on the stack per call, and a performance started from a control stacked
// enough of them in one frame to pass the main thread's 8MB: SIGSEGV on every
// push, before a position was written.
//
// A set that cannot be copied compiles only where it is taken by reference.

import proto : parsePbt, ParseResult;
import ritual.resolve : chooseRitual, repoRoot, flatten;
import ritual.command : preparePerformance, Staged;

enum src = `
rites one {
  A {
    eval: "true"
  }
}

project {
  path: "/p"

  ritual sun {
    one
  }
}
`;

struct Uncopyable {
    ParseResult r;
    alias r this;
    @disable this(this);
}

static immutable Uncopyable held = Uncopyable(parsePbt(src));

static assert(__traits(compiles, chooseRitual(held, "sun", "")),
              "chooseRitual copies the parsed set");
static assert(__traits(compiles, repoRoot(held, "/p")),
              "repoRoot copies the parsed set");
static assert(__traits(compiles, flatten(held, 0)),
              "flatten copies the parsed set");
static assert(__traits(compiles, { Staged st; preparePerformance(held, 0, "/p", 1, st); }),
              "preparePerformance copies the parsed set");
