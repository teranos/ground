module consent_test;

// "agent should never be blocked, period, this is the definition and its not
// going to change" / "if a deny needs to be given, it should not have to come
// from the user, that needs to get into the stuck session"

import ritual : performanceAnswers, RitualState;
import sessionmode : SessionMode;

// The tree is the boundary. Inside a live performance ground answers, because
// the session a prompt would go to has nobody in it.
static assert(performanceAnswers(true, RitualState.Live, SessionMode.acceptEdits));
static assert(performanceAnswers(true, RitualState.Live, SessionMode.auto_));

// Manual is the law. A performance in the same tree never lifts it.
// "manual should not be overwritten by performance being active it makes no sense"
// "if i have manual on, i expect permission prompts"
static assert(!performanceAnswers(true, RitualState.Live, SessionMode.manual));
static assert(!performanceAnswers(true, RitualState.Live, SessionMode.unknown));

// Every ending stops the authorisation. It ends when the performance does,
// not when a branch is abandoned.
static assert(!performanceAnswers(true, RitualState.Done, SessionMode.acceptEdits));
static assert(!performanceAnswers(true, RitualState.Halted, SessionMode.acceptEdits));
static assert(!performanceAnswers(true, RitualState.Aborted, SessionMode.acceptEdits));

// No row is no performance. A directory that is not one gets the normal path.
static assert(!performanceAnswers(false, RitualState.Live, SessionMode.acceptEdits));

// The tree is the boundary. Inside a live performance ground answers every
// tool call itself, so nothing can name a command it forgot to permit.
static assert(!__traits(compiles, { import ritual : consented; }));
