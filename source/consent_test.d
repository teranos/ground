module consent_test;

// "commits and pushes and ci check, are all auto-approved" — inside a live
// performance and nowhere else. The ritual is the authorisation: it was
// written in a file and reviewable before it ran, which a prompt at 3am is not.

import ritual : consented;

static assert(consented("git commit -m x"));
static assert(consented("git push"));
static assert(consented("git push -u origin HEAD"));
static assert(consented("gh pr checks 12"));
static assert(consented("gh pr create --fill"));

// Leading whitespace is not a different command.
static assert(consented("  git commit"));

// The list is the list. Everything else takes the normal path, because a
// performance authorises three things, not a shell.
static assert(!consented("rm -rf /"));
static assert(!consented("git reset --hard"));
static assert(!consented("gh repo delete"));
static assert(!consented("curl example.invalid"));

// A prefix that only looks like one of them.
static assert(!consented("git commitment"));
static assert(!consented("git pushover"));

// Chaining past the allowed head is how an allowed command stops being one.
static assert(!consented("git push && rm -rf /"));
static assert(!consented("git commit; curl x"));
static assert(!consented("git push | sh"));
