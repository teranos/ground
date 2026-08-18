module sentences_test;

// What the agent said at the end of a rite, cut to two sentences and carried
// to the parent session. The source is the Stop payload's
// last_assistant_message — a field Claude Code hands us, not a file on disk.

import sentences : firstTwoSentences;

// Two sentences of many.
static assert(firstTwoSentences("Took the APPLE out. The tree has six left. Moving on.")
    == "Took the APPLE out. The tree has six left.");

// Fewer than two is what there is, not an error.
static assert(firstTwoSentences("Done.") == "Done.");
static assert(firstTwoSentences("Took the APPLE out. The tree has six left.")
    == "Took the APPLE out. The tree has six left.");

// A terminator with nothing after it still ends a sentence.
static assert(firstTwoSentences("Removed it.  ") == "Removed it.");

// Questions and exclamations end sentences too.
static assert(firstTwoSentences("Which fruit? The APPLE. Then ORANGE.")
    == "Which fruit? The APPLE.");
static assert(firstTwoSentences("Done! Next. Then more.") == "Done! Next.");

// Text with no terminator at all is one sentence.
static assert(firstTwoSentences("still working on it") == "still working on it");

// Nothing said is nothing carried. A notice with an empty body is worse than
// no notice: it says the agent spoke when it did not.
static assert(firstTwoSentences("") == "");
static assert(firstTwoSentences("   ") == "");

// A decimal is not a sentence end — no whitespace follows the dot.
static assert(firstTwoSentences("Version 0.19.1 is built. Tests pass. Pushing.")
    == "Version 0.19.1 is built. Tests pass.");

// Leading whitespace is not part of the first sentence.
static assert(firstTwoSentences("\n  Took it out. Done.") == "Took it out. Done.");
