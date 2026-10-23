module agy_test;

import agy;

// An empty decision is not agy's own: 1.4.4 reads it as the deprecated
// allowTool, false unless set, and denies the tool.
static assert(answerOf("PreToolUse") == `{"decision":"ask"}`);
static assert(answerOf("PostToolUse") == "{}");
static assert(answerOf("Stop") == "{}");

// agy's events are not Claude Code's, though they share names.
static assert({ char[64] b; return predicateOf("PreToolUse", b[]) == "AgyPreToolUse"; }());
