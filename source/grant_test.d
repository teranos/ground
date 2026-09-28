module grant_test;

import pretooluse : fileAnswer;

// A control that denies is the answer, whether or not a permission granted the
// path. A grant answered first and returned, so in auto mode no file control
// was asked and a quote nobody typed was written.
static assert(fileAnswer(true, true, "deny").label == "file-control");
static assert(fileAnswer(true, true, "deny").decision == "deny");
static assert(fileAnswer(false, true, "deny").label == "file-control");
static assert(fileAnswer(false, true, "deny").decision == "deny");

// Advice beside a grant is delivered, and the grant still allows.
static assert(fileAnswer(true, true, "").label == "file-control");
static assert(fileAnswer(true, true, "").decision == "allow");

// Advice with no grant stays advice: ground never says ask.
static assert(fileAnswer(false, true, "ask").label == "file-control");
static assert(fileAnswer(false, true, "ask").decision == "");

// A grant no control spoke against allows.
static assert(fileAnswer(true, false, "").label == "file-perm-allow");
static assert(fileAnswer(true, false, "").decision == "allow");

// Neither spoke, so nothing is answered here and the rest of the handler is.
static assert(fileAnswer(false, false, "").label.length == 0);
