module consent_test;

// "agent should never be blocked, period, this is the definition and its not
// going to change" / "if a deny needs to be given, it should not have to come
// from the user, that needs to get into the stuck session"

import ritual : performanceAnswers, RitualState;

// The tree is the boundary. Inside a live performance ground answers, because
// the session a prompt would go to has nobody in it.
static assert(performanceAnswers(true, RitualState.Live));

// Every ending stops the authorisation. It ends when the performance does,
// not when a branch is abandoned.
static assert(!performanceAnswers(true, RitualState.Done));
static assert(!performanceAnswers(true, RitualState.Halted));
static assert(!performanceAnswers(true, RitualState.Aborted));

// No row is no performance. A directory that is not one gets the normal path.
static assert(!performanceAnswers(false, RitualState.Live));

// The enumeration is gone. `chapter-1786287252` sat on a Write that no list
// of shell commands could ever have named, and was aborted by hand.
static assert(!__traits(compiles, { import ritual : consented; }));
