module control_handlers_test;

import control_handlers : containsUnanalyzableShell, countAndChains;

// --- containsUnanalyzableShell ---
// True when the command contains a shell construct Claude Code's Bash
// allowlist matcher cannot statically decompose (control flow, substitution,
// heredocs). Plain command sequences and simple pipes remain false — those
// are decomposable, so they don't trip the "cannot be statically analyzed"
// halt.

// Plain commands — false.
static assert(!containsUnanalyzableShell("git status"));
static assert(!containsUnanalyzableShell("ls -la"));
static assert(!containsUnanalyzableShell("cargo test"));

// Simple pipe — false. Pipes decompose.
static assert(!containsUnanalyzableShell("ls | grep foo"));

// Simple && chain — false here. Chain depth is a separate concern
// (countAndChains). This helper only catches the unanalyzable shapes.
static assert(!containsUnanalyzableShell("git add file && git commit -m 'msg'"));

// $(...) command substitution — true.
static assert(containsUnanalyzableShell("echo $(date)"));
static assert(containsUnanalyzableShell(`s=$(gh run view 123 --json status)`));

// while — true.
static assert(containsUnanalyzableShell("while true; do sleep 1; done"));
static assert(containsUnanalyzableShell("while read line; do echo $line; done"));

// for — true.
static assert(containsUnanalyzableShell("for i in *.md; do echo $i; done"));

// if [ — true.
static assert(containsUnanalyzableShell("if [ -f x ]; then y; fi"));

// case — true.
static assert(containsUnanalyzableShell("case $x in a) echo a;; esac"));

// heredoc — true.
static assert(containsUnanalyzableShell("cat <<EOF\ndata\nEOF"));

// until — true.
static assert(containsUnanalyzableShell("until ping -c1 host; do sleep 1; done"));

// --- countAndChains ---
// Number of top-level "&&" separators in the command. Used to enforce a
// "deep chain" threshold — pbt controls treat count >= N as too deep.

static assert(countAndChains("git status") == 0);
static assert(countAndChains("a && b") == 1);
static assert(countAndChains("a && b && c") == 2);
static assert(countAndChains("a && b && c && d") == 3);

// Single & (background) does not count.
static assert(countAndChains("a & b") == 0);

// && inside a quoted string still counts for now — v1 doesn't parse
// quoting. A false positive here is a nudge, not a wrong-shape halt,
// so it's tolerable until evidence justifies quote-aware parsing.
