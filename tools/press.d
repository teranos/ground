/// press, the pre-build tool that sets the Book of Ground.
///
/// Each test module becomes a chapter, in the file's own order, carrying its
/// own headings. Nothing here writes prose: the text is the one already in
/// the tests, and the examples are the ones the compiler proved.

import std.file : dirEntries, readText, SpanMode, mkdirRecurse, exists, write, remove;
import std.algorithm : sort, SwapStrategy;
import std.array : array;
import std.path : baseName;
import std.stdio : stderr;

import cases : extractCases, renderCase, caseName, Case, splitLines, unmark, flow;
import concept : conceptOf, chapters, rank, opener;

// A case and where its chapter puts it. The rank and the file are asked once,
// when the case is collected, because the file is only known here.
struct Placed {
    size_t rank;
    string file;
    Case c;
}

// The subject a file is about. A module and its test are the same subject, so
// the book meets them together rather than a whole alphabet apart.
string stem(string path) {
    auto b = baseName(path);
    if (b.length > 2 && b[$ - 2 .. $] == ".d") b = b[0 .. $ - 2];
    if (b.length > 5 && b[$ - 5 .. $] == "_test") b = b[0 .. $ - 5];
    return b;
}

// An example is something a reader can see at once. The text block is 212mm
// and a set line is about 3.9mm, so a page holds 54 of them.
enum PAGE_LINES = 54;

// A literal that outgrew a page. It is not a layout problem to work around:
// nothing longer than this teaches, so the book says which one and stops.
struct Overflow {
    string file;
    string chapter;
    size_t lines;
}

int main(string[] argv) {
    if (!exists("source")) {
        stderr.writeln("press: no source/ here");
        return 1;
    }
    mkdirRecurse("doc/tex");

    // Chapter order. The command line overrides it; otherwise the chapters run
    // outermost to innermost, the way a reader meets them in a .pbt file.
    const(string)[] wanted = argv.length > 1 ? argv[1 .. $] : chapters;

    // Collected once, rendered twice. A page that read the source separately
    // could come to say something the printed book does not.
    Placed[][string] chapters;
    string[] present;

    // Every module, not only the test ones. `//` and `///` are both prose and
    // both belong in the book.
    auto files = dirEntries("source", "*.d", SpanMode.shallow)
        .array
        .sort!((a, b) => a.name < b.name);

    // Every case for one symbol also lands under a macro, so a `///` can name
    // one without the whole chapter coming with it.
    string[string] gathered;
    string[] symbols;

    // A module's own first heading, kept by subject. A chapter opens on the
    // one belonging to the module its order names first, so the reader is told
    // what the concept is before being shown an example of it.
    string[string] leads;

    Overflow[] overflowing;

    size_t totalCases = 0;
    foreach (f; files) {
        auto found = extractCases(readText(f.name));
        if (found.length == 0) continue;

        foreach (c; found) {
            if (!c.heading) continue;
            if (stem(f.name) !in leads) leads[stem(f.name)] = c.text;
            break;
        }

        // A chapter is a block you can write at the top of a .pbt. A case
        // lands in the chapter its own example is an example of, so a module
        // with no pbt form contributes to no chapter rather than becoming one.
        foreach (c; found) {
            if (c.heading) continue;
            auto ch = conceptOf(c.pbt);
            if (ch.length == 0) continue;

            auto tall = splitLines(c.pbt).length;
            if (tall > PAGE_LINES)
                overflowing ~= Overflow(baseName(f.name), ch, tall);

            if (ch !in chapters) present ~= ch;
            chapters[ch] ~= Placed(rank(ch, stem(f.name)), baseName(f.name), c);
        }

        size_t proved = 0;
        foreach (c; found) {
            if (c.heading) continue;
            proved++;
            if (c.subject !in gathered) {
                gathered[c.subject] = c.text;
                symbols ~= c.subject;
            } else {
                gathered[c.subject] ~= "\n\n" ~ c.text;
            }
        }
        totalCases += proved;
        stderr.writefln("press: %s (%d cases)", baseName(f.name), proved);
    }

    // Nothing is written while an example does not fit. A reader takes an
    // example in at a glance, so one that outruns the page is not a long
    // example: it is a fixture, and the book says so instead of setting it.
    if (overflowing.length > 0) {
        foreach (o; overflowing)
            stderr.writefln("press: %s puts a %d-line literal in %s, and a page holds %d",
                o.file, o.lines, o.chapter, PAGE_LINES);
        stderr.writeln("press: an example nobody can see at once is not an example. Nothing written.");
        return 1;
    }

    // A chapter that stops being one would leave its file behind for an
    // \input that no longer names it. Cleared here rather than by the caller,
    // so a halt leaves the last good book standing instead of deleting it.
    foreach (e; dirEntries("doc/tex", "*.tex", SpanMode.shallow)) remove(e.name);

    string macros;
    foreach (s; symbols) macros ~= renderCase(s, gathered[s]);
    write("doc/cases.ddoc", macros);

    // The chapter list, in the order asked for, then anything not named.
    string[] order;
    foreach (w; wanted) {
        if (w !in chapters) {
            stderr.writefln("press: %s named but has no cases", w);
            continue;
        }
        order ~= w;
    }
    foreach (p; present)
        if (!contains(wanted, p)) order ~= p;

    string list;
    foreach (o; order) {
        // Stable, so modules the chapter's order does not name keep the order
        // they were found in instead of trading places on every build.
        auto placed = chapters[o];
        placed.sort!((a, b) => a.rank < b.rank, SwapStrategy.stable);

        auto op = opener(o);
        string lead;
        if (op.length > 0 && op in leads) lead = "\n" ~ escape(flow(leads[op])) ~ "\n";
        else if (op.length > 0) stderr.writefln("press: %s opens %s and says nothing", op, o);

        write("doc/tex/" ~ o ~ ".tex", "\\chapter{" ~ o ~ "}\n" ~ lead ~ renderBody(placed));
        list ~= "\\input{tex/" ~ o ~ "}\n";
    }
    write("doc/tex/chapters.tex", list);

    stderr.writefln("press: %d chapters, %d cases, %d symbols",
        order.length, totalCases, symbols.length);
    return 0;
}

string numeral(size_t n) {
    if (n == 0) return "0";
    char[20] buf;
    size_t len = 0;
    while (n > 0 && len < buf.length) { buf[len++] = cast(char)('0' + n % 10); n /= 10; }
    string out_;
    foreach_reverse (i; 0 .. len) out_ ~= buf[i];
    return out_;
}

string renderBody(Placed[] found) {
    string out_;
    foreach (p; found) {
        auto c = p.c;
        if (c.heading) {
            out_ ~= "\n" ~ renderProse(c.text) ~ "\n";
            continue;
        }
        // The example is the pbt. The D that parses it and the assertions that
        // prove it are how it is checked, not what a control author reads.
        // The block and what it is for are one row. A minipage is a box, so
        // the page break falls between rows and never through an example.
        if (c.pbt.length > 0) {
            out_ ~= "\n\\par\\noindent\n";
            out_ ~= "\\begin{minipage}[t]{\\gpbtw}\n";
            out_ ~= "\\begin{gcode}\n" ~ c.pbt ~ "\n\\end{gcode}\n";
            out_ ~= "\\end{minipage}\\hfill\n";
            out_ ~= "\\begin{minipage}[t]{\\gnotew}\n";
            out_ ~= "\\gnote{" ~ escape(c.prose) ~ "}\n";
            out_ ~= "\\end{minipage}\n\\par\\vspace{10pt}\n";
            continue;
        }
        out_ ~= "\n\\begin{gcode}\n" ~ c.text ~ "\n\\end{gcode}\n";
    }
    return out_;
}

// Prose out of a comment block. The author's line breaks are kept: two TODOs
// written on two lines are two notes, and joining them made one sentence that
// nobody wrote.
string renderProse(string text) {
    string out_;
    foreach (line; splitLines(text)) {
        auto s = unmark(line);
        if (s.length == 0) continue;

        if (s.length >= 4 && s[0 .. 4] == "TODO") {
            out_ ~= "\\gtodo{" ~ escape(s) ~ "}\n";
            continue;
        }
        // \\ takes an optional length, so a line beginning with [ was read as
        // one. \newline takes nothing.
        out_ ~= escape(s) ~ "\\newline\n";
    }
    return out_;
}

// A heading is set as text, so the characters LaTeX reads as instructions
// have to arrive as characters.
string escape(string s) {
    string out_;
    foreach (c; s) {
        if (c == '\\') { out_ ~= "\\textbackslash{}"; continue; }
        if (c == '&' || c == '%' || c == '$' || c == '#' || c == '{' || c == '}')
            out_ ~= "\\";
        if (c == '~' || c == '^') { out_ ~= "\\" ~ c ~ "{}"; continue; }
        out_ ~= c;
    }
    return out_;
}

string stemOf(string file) {
    auto s = file;
    if (s.length > 2 && s[$ - 2 .. $] == ".d") s = s[0 .. $ - 2];
    if (s.length > 5 && s[$ - 5 .. $] == "_test") s = s[0 .. $ - 5];
    return s;
}

bool contains(const(string)[] xs, string x) {
    foreach (v; xs) if (v == x) return true;
    return false;
}
