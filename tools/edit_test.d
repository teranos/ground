module edit_test;

// CTFE tests — failure shows as a compile error.

import edit : runSaying, rewriteProse, speak, ending;
import cases : splitLines;

// A save must not change how the file ended. It did: every write took the
// module's last newline off with it.
static assert(ending("a\nb\n") == "\n");
static assert(ending("a\nb") == "");
static assert(ending("") == "");

// splitLines drops exactly one, so exactly one goes back on.
static assert(join2(splitLines("a\nb\n")) ~ ending("a\nb\n") == "a\nb\n");
static assert(join2(splitLines("a\nb\n\n")) ~ ending("a\nb\n\n") == "a\nb\n\n");
static assert(join2(splitLines("a\nb")) ~ ending("a\nb") == "a\nb");

private string join2(string[] lines) {
    string out_;
    foreach (i, l; lines) {
        if (i > 0) out_ ~= "\n";
        out_ ~= l;
    }
    return out_;
}

// "THE COMMIT HASH PINS THE BOOK / NOT THE LINENUMBERS"
// A run is found by what it says. Anything above it may move.
enum src = [
    "module x;",
    "",
    "// About x.",
    "enum x = `scope { }`;",
    "static assert(f(x));",
];

static assert(runSaying(src, "About x.").from == 2);
static assert(runSaying(src, "About x.").to == 3);
static assert(runSaying(src, "About x.").found);

// The same run, after four lines were added above it. Nothing was stored, so
// nothing needs updating.
enum moved = ["import a;", "import b;", "import c;", "import d;"] ~ src;
static assert(runSaying(moved, "About x.").from == 6);
static assert(runSaying(moved, "About x.").found);

// A module that no longer says it answers that it does not, rather than
// guessing at a line and writing over whatever stands there.
static assert(!runSaying(src, "About something else.").found);

// A run is however many lines the author wrapped it to, joined the way the
// book joins them.
enum wrapped = [
    "// A control is a named rule",
    "// and a message.",
    "static assert(f(x));",
];
static assert(runSaying(wrapped, "A control is a named rule and a message.").to == 2);

// Said again, the run keeps its own indent and breaks on a word.
static assert(speak("one two three", "", 20) == ["// one two three"]);
static assert(speak("one two three four five", "", 20)
    == ["// one two three", "// four five"]);
static assert(speak("a b", "    ", 80) == ["    // a b"]);

// The rewrite replaces the run and leaves the module either side of it alone.
enum after = rewriteProse(src, "About x.", "A scope is where a rule stands.");
static assert(after.length == 5);
static assert(after[2] == "// A scope is where a rule stands.");
static assert(after[3] == "enum x = `scope { }`;");
static assert(after[0] == "module x;");

// A run of two becomes a run of one when what it says now fits on one line.
enum tightened = rewriteProse(wrapped, "A control is a named rule and a message.", "Short.");
static assert(tightened.length == 2);
static assert(tightened[0] == "// Short.");
static assert(tightened[1] == "static assert(f(x));");

// Nothing said is nothing written: a module that moved on is left as it is.
static assert(rewriteProse(src, "Not here.", "New.") == src);

// "I see, i would expect to be able to also edit the pbt left side, and also to just insert a quote or edit quote or add more pose"
// A case is three things: what was said, the note, and the example. A save
// writes all three back, and the case is found by what it was.
import edit : rewriteCase, Was;

enum full = [
    "module x;",
    "",
    "// \"the unnamed one wins\"",
    "// A bare project is the default.",
    "enum x = `",
    "project { path: \"/p\" }",
    "`;",
    "static assert(f(x));",
];

// The quote changes, a second is added, the note is rewritten, and the pbt is
// set differently. Everything either side stays.
enum edited = rewriteCase(full,
    Was("\"the unnamed one wins\"", "A bare project is the default.", "project { path: \"/p\" }"),
    Was("\"the unnamed one actually wins\"\n\"the named one is the explicit edge case\"",
        "A bare project is the default one.",
        "project {\n  path: \"/p\"\n}"));
static assert(edited == [
    "module x;",
    "",
    "// \"the unnamed one actually wins\"",
    "// \"the named one is the explicit edge case\"",
    "// A bare project is the default one.",
    "enum x = `",
    "project {",
    "  path: \"/p\"",
    "}",
    "`;",
    "static assert(f(x));",
]);

// A case with no note yet gets one written above its example.
enum bare = ["enum y = `scope { }`;", "static assert(g(y));"];
static assert(rewriteCase(bare, Was("", "", "scope { }"), Was("", "Where a rule stands.", "scope { }")) == [
    "// Where a rule stands.",
    "enum y = `scope { }`;",
    "static assert(g(y));",
]);

// A one-line literal stays on its line when the pbt is still one line.
static assert(rewriteCase(bare, Was("", "", "scope { }"), Was("", "", "scope { path: \"/\" }")) == [
    "enum y = `scope { path: \"/\" }`;",
    "static assert(g(y));",
]);

// A module that no longer holds the case is left as it is.
static assert(rewriteCase(full, Was("", "Gone.", "nope"), Was("", "New.", "nope")) == full);
