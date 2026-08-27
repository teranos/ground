module sessionmode_test;

import sessionmode : SessionMode, parseSessionMode, grants, letterOf;

// The six Claude Code reports, parsed at the boundary the way an event is.
static assert(parseSessionMode("default") == SessionMode.manual);
static assert(parseSessionMode("plan") == SessionMode.plan);
static assert(parseSessionMode("acceptEdits") == SessionMode.acceptEdits);
static assert(parseSessionMode("auto") == SessionMode.auto_);
static assert(parseSessionMode("dontAsk") == SessionMode.dontAsk);
static assert(parseSessionMode("bypassPermissions") == SessionMode.bypassPermissions);

// Manual is the wire value default. The word manual never arrives.
static assert(parseSessionMode("manual") == SessionMode.unknown);

// An absent or unrecognised mode is its own value, not a mode that happens to
// match nothing. The empty string was doing both jobs.
static assert(parseSessionMode("") == SessionMode.unknown);
static assert(parseSessionMode("sideways") == SessionMode.unknown);

// Manual grants nothing. No block reaches it, qualified or not, because in
// manual the operator sees and approves each and every call.
static assert(!grants(SessionMode.manual));
static assert(!grants(SessionMode.unknown));

// Every other mode can be granted by a block that names it.
static assert(grants(SessionMode.plan));
static assert(grants(SessionMode.acceptEdits));
static assert(grants(SessionMode.auto_));
static assert(grants(SessionMode.dontAsk));
static assert(grants(SessionMode.bypassPermissions));

// The pbt letter for each, so a block's session segment resolves without
// comparing strings after the boundary.
static assert(letterOf(SessionMode.manual) == 'm');
static assert(letterOf(SessionMode.plan) == 'p');
static assert(letterOf(SessionMode.acceptEdits) == 'a');
static assert(letterOf(SessionMode.auto_) == 'a');
static assert(letterOf(SessionMode.dontAsk) == 'd');
static assert(letterOf(SessionMode.bypassPermissions) == 'b');

// Unknown has no letter, so no letter set can name it.
static assert(letterOf(SessionMode.unknown) == '\0');
