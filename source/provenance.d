module provenance;

// A quoted span is a claim about who said something. This module finds the
// claims; checking them against what the user typed is the caller's job.

struct Span {
    bool ok;
    size_t start;   // first char inside the quotes
    size_t end;     // one past the last char inside the quotes
}

// Find the next quoted span at or after `from`. An unpaired quote is not a
// span: it closes nothing, so it claims nothing.
Span nextQuotedSpan(const(char)[] s, size_t from) {
    size_t i = from;
    while (i < s.length && s[i] != '"') i++;
    if (i >= s.length) return Span(false, 0, 0);

    size_t start = i + 1;
    size_t j = start;
    while (j < s.length && s[j] != '"') j++;
    if (j >= s.length) return Span(false, 0, 0);

    return Span(true, start, j);
}

// Index of the first entry that sits earlier in the record than the one before
// it, or -1. Equal is not out of order: one prompt can say two things.
ptrdiff_t firstOutOfOrder(const(long)[] said) {
    foreach (i; 1 .. said.length)
        if (said[i] < said[i - 1]) return cast(ptrdiff_t) i;
    return -1;
}

unittest {
    // Spans carry the position of the prompt that said them. Document order
    // has to agree with said order.
    long[3] rising = [1, 2, 3];
    assert(firstOutOfOrder(rising[]) == -1);

    long[2] swapped = [3, 1];
    assert(firstOutOfOrder(swapped[]) == 1);

    // Names the first span that breaks the run, not the last.
    long[4] late = [1, 5, 2, 9];
    assert(firstOutOfOrder(late[]) == 2);

    // The same prompt said twice over is not out of order.
    long[3] equal = [4, 4, 4];
    assert(firstOutOfOrder(equal[]) == -1);

    long[0] none;
    assert(firstOutOfOrder(none[]) == -1);
}

// Attestation attributes are stored as JSON, where a backslash and a quote mark
// each take two characters there and one here. A span compared raw against that
// text cannot match if it carries either, so a sourced quote reads as unsourced.
ptrdiff_t jsonEscapeInto(const(char)[] s, char[] dst) {
    size_t o = 0;
    foreach (c; s) {
        if (c == '\\' || c == '"') {
            if (o + 2 > dst.length) return -1;
            dst[o++] = '\\';
            dst[o++] = c;
        } else {
            if (o + 1 > dst.length) return -1;
            dst[o++] = c;
        }
    }
    return cast(ptrdiff_t) o;
}

unittest {
    char[32] buf;

    // Ordinary text is itself.
    auto n = jsonEscapeInto("plain", buf[]);
    assert(n == 5 && buf[0 .. 5] == "plain");

    // The two characters JSON spends twice.
    n = jsonEscapeInto(`a\|b`, buf[]);
    assert(n == 5 && buf[0 .. 5] == `a\\|b`);

    n = jsonEscapeInto(`say "hi"`, buf[]);
    assert(n == 10 && buf[0 .. 10] == `say \"hi\"`);

    // Nothing to say is said in nothing.
    assert(jsonEscapeInto("", buf[]) == 0);

    // A span too long to encode is not truncated into a different span.
    char[3] tiny;
    assert(jsonEscapeInto("abcd", tiny[]) == -1);
    assert(jsonEscapeInto(`\\`, tiny[]) == -1);
}

private bool isWs(char c) {
    return c == ' ' || c == '\t' || c == '\r';
}

// True when the span's own two lines carry nothing but the quote. A comment
// marker is where the line begins, so it is the one prefix that is not company.
bool standsAlone(const(char)[] s, Span sp, const(char)[] marker = "") {
    size_t open = sp.start - 1;
    size_t lineStart = open;
    while (lineStart > 0 && s[lineStart - 1] != '\n') lineStart--;

    size_t b = lineStart;
    size_t e = open;
    while (b < e && isWs(s[b])) b++;
    while (e > b && isWs(s[e - 1])) e--;
    auto prefix = s[b .. e];
    if (prefix.length != 0 && prefix != marker) return false;

    size_t j = sp.end + 1;
    while (j < s.length && s[j] != '\n') {
        if (!isWs(s[j])) return false;
        j++;
    }
    return true;
}

unittest {
    // A quote owns its line. Whitespace around it is not company.
    assert(standsAlone(`"a"`, Span(true, 1, 2)));
    assert(standsAlone(`   "a"   `, Span(true, 4, 5)));

    // Commentary on either side is what this refuses.
    assert(!standsAlone(`x "a"`, Span(true, 3, 4)));
    assert(!standsAlone(`"a" x`, Span(true, 1, 2)));

    // In a comment the line begins after the marker, and the marker is the
    // one that language uses. A SQL comment is not company either.
    assert(standsAlone(`# "a"`, Span(true, 3, 4), "#"));
    assert(standsAlone(`// "a"`, Span(true, 4, 5), "//"));
    assert(standsAlone(`-- "a"`, Span(true, 4, 5), "--"));
    assert(!standsAlone(`# x "a"`, Span(true, 5, 6), "#"));

    // A marker from another language is just text in front of the quote.
    assert(!standsAlone(`# "a"`, Span(true, 3, 4), "//"));

    // The span crosses newlines; only its two edges are the line question.
    assert(standsAlone("\"a\nb\"", Span(true, 1, 4)));
    assert(!standsAlone("pre \"a\nb\"", Span(true, 5, 8)));
    assert(!standsAlone("\"a\nb\" post", Span(true, 1, 4)));
}

// What opens a comment, per language. A union of every marker is not a table:
// `#` opens a comment in Python and an include in C, and accepting both denied
// every `#include` ever written.

static immutable string[] SLASH = [
    ".d", ".rs", ".go", ".c", ".h", ".cc", ".cpp", ".hpp", ".java", ".js",
    ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".swift", ".kt", ".cs", ".scala",
    ".php", ".zig", ".dart", ".proto",
];

static immutable string[] HASH = [
    ".py", ".sh", ".bash", ".fish", ".zsh", ".pbt", ".pl", ".pm", ".rb",
    ".cr", ".yaml", ".yml", ".toml", ".nix", ".r", ".jl", ".ex", ".exs",
];

static immutable string[] DASHES = [".sql", ".lua", ".hs", ".elm", ".adb"];
static immutable string[] SEMI = [".el", ".lisp", ".clj", ".cljs", ".scm"];
static immutable string[] QUOTE = [".vim", ".vimrc"];
static immutable string[] ANGLE = [".html", ".htm", ".xml", ".svg", ".vue"];
static immutable string[] STAR = [".css", ".scss", ".less"];
static immutable string[] PAREN = [".ml", ".mli"];
static immutable string[] DOCS = [".md", ".txt", ".rst", ".adoc", ".org"];

private const(char)[] extensionOf(const(char)[] path) {
    size_t i = path.length;
    while (i > 0) {
        i--;
        if (path[i] == '/') return "";
        if (path[i] == '.') return path[i .. $];
    }
    return "";
}

private bool listed(const(char)[] ext, const(string)[] set) {
    foreach (x; set) if (ext == x) return true;
    return false;
}

// A document carries prose on every line, with no marker in front of it.
bool isDocument(const(char)[] path) {
    return listed(extensionOf(path), DOCS);
}

// What starts a comment that runs to end of line, or "" when the language has
// none and when ground has no entry for it.
const(char)[] lineComment(const(char)[] path) {
    auto e = extensionOf(path);
    if (listed(e, SLASH)) return "//";
    if (listed(e, HASH)) return "#";
    if (listed(e, DASHES)) return "--";
    if (listed(e, SEMI)) return ";";
    if (listed(e, QUOTE)) return `"`;
    return "";
}

const(char)[] blockOpen(const(char)[] path) {
    auto e = extensionOf(path);
    if (listed(e, ANGLE)) return "<!--";
    if (listed(e, PAREN)) return "(*";
    if (listed(e, SLASH) || listed(e, STAR)) return "/*";
    return "";
}

const(char)[] blockClose(const(char)[] path) {
    auto o = blockOpen(path);
    if (o == "<!--") return "-->";
    if (o == "(*") return "*)";
    if (o == "/*") return "*/";
    return "";
}

private bool startsAt(const(char)[] s, size_t at, const(char)[] what) {
    if (what.length == 0 || at + what.length > s.length) return false;
    return s[at .. at + what.length] == what;
}

// Whether an unclosed block comment stands open at `at`. Nesting is not read:
// no language in the table nests these, and a second open inside one is text.
private bool insideBlock(const(char)[] s, size_t at, const(char)[] open, const(char)[] close) {
    bool inside = false;
    size_t i = 0;
    while (i < at) {
        if (!inside && startsAt(s, i, open)) { inside = true; i += open.length; continue; }
        if (inside && startsAt(s, i, close)) { inside = false; i += close.length; continue; }
        i++;
    }
    return inside;
}

// Whether the span begins somewhere prose is written. Every line of a document
// is; in code it is a line opened by that language's marker, or anywhere
// inside a block comment.
bool onProseLine(const(char)[] s, Span sp, const(char)[] path) {
    if (isDocument(path)) return true;
    if (!sp.ok) return false;

    auto marker = lineComment(path);
    if (marker.length > 0) {
        size_t lineStart = sp.start;
        while (lineStart > 0 && s[lineStart - 1] != '\n') lineStart--;
        while (lineStart < s.length && isWs(s[lineStart])) lineStart++;
        if (startsAt(s, lineStart, marker)) return true;
    }

    auto open = blockOpen(path);
    return open.length > 0 && insideBlock(s, sp.start, open, blockClose(path));
}

unittest {
    // The marker is the language's, not a union of every language's. `#` opens
    // a comment in Python and opens an include in C, and one table that
    // accepted both denied every include ever written.
    assert(lineComment("source/provenance.d") == "//");
    assert(lineComment("src/execution.rs") == "//");
    assert(lineComment("app/main.go") == "//");
    assert(lineComment("src/parser.c") == "//");
    assert(lineComment("src/parser.h") == "//");

    assert(lineComment("Widget.java") == "//");
    assert(lineComment("app.ts") == "//");
    assert(lineComment("app.tsx") == "//");
    assert(lineComment("app.js") == "//");

    assert(lineComment("hooks/hook.py") == "#");
    assert(lineComment("run.sh") == "#");
    assert(lineComment("controls/x.pbt") == "#");
    assert(lineComment("script.pl") == "#");
    assert(lineComment("src/collet.cr") == "#");
    assert(lineComment("am.toml") == "#");
    assert(lineComment("flake.nix") == "#");
    assert(lineComment("build.bash") == "#");
    assert(lineComment("bench.fish") == "#");

    assert(lineComment("engine.cpp") == "//");
    assert(lineComment("index.php") == "//");

    // HTML has no line comment. Without the block markers every attribute in
    // every tag reads as a quoted span.
    assert(lineComment("page.html") == "");
    assert(blockOpen("page.html") == "<!--");
    assert(blockClose("page.html") == "-->");

    // Vimscript opens a comment with the same character a quote opens with.
    assert(lineComment("plugin.vim") == `"`);

    assert(lineComment("schema.sql") == "--");
    assert(lineComment("plugin.lua") == "--");
    assert(lineComment("init.el") == ";");

    // A language ground has no entry for is one it cannot read prose out of,
    // so it reads none rather than guessing at a marker.
    assert(lineComment("thing.cobol") == "");
    assert(lineComment("README") == "");
}

unittest {
    assert(isDocument("UNDERGROUND.md"));
    assert(isDocument("notes.txt"));
    assert(!isDocument("source/provenance.d"));
    assert(!isDocument("README"));
}

unittest {
    // A string literal is code, and code is not a claim. The same bytes in a
    // document are prose, because a document has no code in it.
    enum code = `enum x = "abc";`;
    assert(!onProseLine(code, nextQuotedSpan(code, 0), "a.d"));
    assert(onProseLine(code, nextQuotedSpan(code, 0), "a.md"));

    enum slashes = `// "abc"`;
    assert(onProseLine(slashes, nextQuotedSpan(slashes, 0), "a.d"));

    enum hash = `  # "abc"`;
    assert(onProseLine(hash, nextQuotedSpan(hash, 0), "a.py"));

    // The marker belongs to one language. Python's opens nothing in Rust.
    assert(!onProseLine(hash, nextQuotedSpan(hash, 0), "a.rs"));

    // A quote welded into a comment is on a prose line. Being checkable is
    // what lets the standing-alone rule refuse it.
    enum welded = `// x "abc"`;
    assert(onProseLine(welded, nextQuotedSpan(welded, 0), "a.rs"));

    // The line the span opens on is the question, not the first line of input.
    enum second = "int y;\n// \"abc\"";
    assert(onProseLine(second, nextQuotedSpan(second, 0), "a.c"));
}

unittest {
    // The line that started all of this. `#` opens nothing in C, so the header
    // is code and the include is written.
    enum include = `#include "stdio.h"`;
    assert(!onProseLine(include, nextQuotedSpan(include, 0), "a.c"));

    // The same line in a shell script is a comment, and its quote is prose.
    assert(onProseLine(include, nextQuotedSpan(include, 0), "a.sh"));
}

unittest {
    // Inside a block comment is prose wherever it falls, including lines that
    // carry no marker of their own.
    enum block = "/* the note says\n   \"a\" here\n*/\nint x = 1;";
    assert(onProseLine(block, nextQuotedSpan(block, 0), "a.c"));

    // Past the close it is code again.
    enum after = "/* note */\nchar* s = \"abc\";";
    assert(!onProseLine(after, nextQuotedSpan(after, 0), "a.c"));

    // OCaml and HTML carry their own forms.
    enum ml = "(* the note says \"a\" *)";
    assert(onProseLine(ml, nextQuotedSpan(ml, 0), "a.ml"));

    enum html = "<a href=\"x\">";
    assert(!onProseLine(html, nextQuotedSpan(html, 0), "a.html"));
}

// A correction is one character substituted, dropped, or added against what
// the user typed. The budget is four corrections per forty characters of the
// span, floored, and never more than that rate.
size_t correctionBudget(size_t spanLength) {
    return spanLength * 4 / 40;
}

// The band above the correction budget that still passes, warned about
// instead of denied: five and six corrections per forty. Past this the span
// does not pass at all.
size_t warnBudget(size_t spanLength) {
    return spanLength * 6 / 40;
}

// The longest span the check ever carries this far: quoteProvenance denies
// anything its 8192-byte escape buffer cannot hold before searching for it.
enum SPAN_MAX = 8192;

// Whether some stretch of `text` sits within `budget` corrections of `span`.
// One column of edit distance per character of text, free to start anywhere
// and end anywhere, so the span is measured against the stretch it matches
// best rather than against the whole prompt.
bool withinCorrections(const(char)[] text, const(char)[] span, size_t budget) {
    // An empty span asserts the user said nothing, and nothing can source it
    // here any more than it can be sourced verbatim.
    if (span.length == 0 || span.length > SPAN_MAX) return false;

    __gshared int[SPAN_MAX + 1] colA;
    __gshared int[SPAN_MAX + 1] colB;
    auto m = span.length;
    auto prev = colA[0 .. m + 1];
    auto cur = colB[0 .. m + 1];

    foreach (i; 0 .. m + 1) prev[i] = cast(int) i;

    foreach (c; text) {
        cur[0] = 0;
        foreach (i; 1 .. m + 1) {
            int changed = prev[i - 1] + (c == span[i - 1] ? 0 : 1);
            int dropped = prev[i] + 1;
            int added = cur[i - 1] + 1;
            int best = changed;
            if (dropped < best) best = dropped;
            if (added < best) best = added;
            cur[i] = best;
        }
        if (cur[m] <= budget) return true;
        auto swap = prev;
        prev = cur;
        cur = swap;
    }
    return false;
}

unittest {
    // Four corrections per forty characters, floored, and never more. A span
    // under ten characters buys none and must be verbatim.
    assert(correctionBudget(40) == 4);
    assert(correctionBudget(39) == 3);
    assert(correctionBudget(41) == 4);
    assert(correctionBudget(80) == 8);
    assert(correctionBudget(10) == 1);
    assert(correctionBudget(9) == 0);
    assert(correctionBudget(1) == 0);
    assert(correctionBudget(0) == 0);
}

unittest {
    // A budget of zero is exact substring matching.
    assert(withinCorrections("the user typed this", "typed", 0));
    assert(!withinCorrections("the user typed this", "tyPed", 0));

    // One changed character rides on a budget of one. Two do not.
    assert(withinCorrections("the user typed this", "tyPed", 1));
    assert(!withinCorrections("the user typed this", "tYPed", 1));
    assert(withinCorrections("the user typed this", "tYPed", 2));

    // A dropped character and an added one are corrections too.
    assert(withinCorrections("the user typd this", "typed", 1));
    assert(withinCorrections("the user typeed this", "typed", 1));

    // The stretch matched is the prompt's, wherever it falls.
    assert(withinCorrections("prefix middle suffix", "middle", 0));
    assert(withinCorrections("middle", "middle", 0));

    // A span nothing in the prompt comes near is out of budget however the
    // corrections are spent.
    assert(!withinCorrections("the user typed this", "wrote that", 2));

    // An empty span is not brought in budget by an empty need.
    assert(!withinCorrections("anything", "", 4));
    assert(!withinCorrections("", "a", 0));
}

unittest {
    // The rule as stated: four corrected characters per forty, never more. A
    // forty-character span carries four corrections and not five.
    enum said = "this is what the user actually typed ok!";
    static assert(said.length == 40);

    enum four = "This is what the user actuaIIy typed ok?";
    enum five = "This is what the user actuaIIy tiped ok?";
    assert(withinCorrections(said, four, correctionBudget(four.length)));
    assert(!withinCorrections(said, five, correctionBudget(five.length)));
}

unittest {
    // The warn band above it: six per forty, floored. Where the two budgets
    // meet, the band is empty and there is nothing to warn about.
    assert(warnBudget(40) == 6);
    assert(warnBudget(39) == 5);
    assert(warnBudget(80) == 12);
    assert(warnBudget(20) == 3);
    assert(warnBudget(10) == 1);
    assert(correctionBudget(10) == warnBudget(10));
    assert(warnBudget(0) == 0);
}

unittest {
    // Five and six corrections per forty sit inside the warn budget and
    // outside the correction budget. Seven sits outside both.
    enum said = "this is what the user actually typed ok!";
    static assert(said.length == 40);

    enum five  = "This is what the user actuaIIy tiped ok?";
    enum six   = "This is What the user actuaIIy tiped ok?";
    enum seven = "This is What the User actuaIIy tiped ok?";

    assert(!withinCorrections(said, five, correctionBudget(five.length)));
    assert(withinCorrections(said, five, warnBudget(five.length)));

    assert(!withinCorrections(said, six, correctionBudget(six.length)));
    assert(withinCorrections(said, six, warnBudget(six.length)));

    assert(!withinCorrections(said, seven, warnBudget(seven.length)));
}

unittest {
    // Nothing to claim.
    assert(!nextQuotedSpan("no quotes here", 0).ok);

    // One span, and the offsets are the interior, not the quotes.
    auto one = nextQuotedSpan(`say "hello" now`, 0);
    assert(one.ok);
    assert(one.start == 5);
    assert(one.end == 10);

    // Walking continues past the closing quote.
    auto two = nextQuotedSpan(`"a" and "b"`, 0);
    assert(two.ok && two.start == 1 && two.end == 2);
    auto three = nextQuotedSpan(`"a" and "b"`, two.end + 1);
    assert(three.ok && three.start == 9 && three.end == 10);

    // A span crosses newlines, because a quote is free to.
    auto multi = nextQuotedSpan("\"a\nb\" tail", 0);
    assert(multi.ok && multi.start == 1 && multi.end == 4);

    // An unpaired quote claims nothing and is out of scope.
    assert(!nextQuotedSpan(`"never closed`, 0).ok);

    // An empty span is still a claim, and it is one nothing can source.
    auto empty = nextQuotedSpan(`""`, 0);
    assert(empty.ok && empty.start == 1 && empty.end == 1);
}
