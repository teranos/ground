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

import cases : extractCases, Case, splitLines, unmark, flow,
               extractGlossary, extractCommands, Entry;
import concept : conceptOf, chapters, rank, opener, chapterOf, moduleName, owners;
import fmt : isCanonical;

// Room for the canonical form of one fixture. A page holds 54 lines.
__gshared char[16384] fmtScratch;

// A case and where its chapter puts it. The rank and the file are asked once,
// when the case is collected, because the file is only known here.
struct Placed {
    size_t rank;
    string file;
    Case c;
}

// The subject a file is about, named the way concept.d names it.
alias stem = moduleName;

// A glossary line the book will not set: no term on it, or a module no chapter
// owns. Said with the file and the line, and nothing is written.
struct Refused {
    string file;
    string why;
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
    // both belong in the book. One level down as well: the ritual's own
    // modules live under source/ritual/, and the terms they define with them.
    auto files = dirEntries("source", "*.d", SpanMode.depth)
        .array
        .sort!((a, b) => a.name < b.name);

    // The glossary, by module. Set in the order owners names the modules, so
    // where a term stands in its section is decided in one place.
    Entry[][string] glossary;
    Refused[] refused;

    // The commands, each from the module that implements it, and ug and
    // wind from their own.
    Entry[] commands;
    string[] commandFiles;

    // A module's own first heading, kept by subject. A chapter opens on the
    // one belonging to the module its order names first, so the reader is told
    // what the concept is before being shown an example of it.
    string[string] leads;

    Overflow[] overflowing;

    size_t totalCases = 0;
    foreach (f; files) {
        auto text = readText(f.name);

        foreach (e; extractGlossary(text)) {
            if (e.term.length == 0) {
                refused ~= Refused(f.name, "carries a glossary line without a term: " ~ e.text);
                continue;
            }
            auto owner = chapterOf(stem(f.name));
            if (owner.length == 0) {
                refused ~= Refused(f.name, "defines " ~ e.term ~ " and no chapter owns " ~ stem(f.name));
                continue;
            }
            glossary[stem(f.name)] ~= e;
        }

        foreach (e; extractCommands(text)) {
            if (e.term.length == 0) {
                refused ~= Refused(f.name, "carries a command line without a name: " ~ e.text);
                continue;
            }
            commands ~= e;
            commandFiles ~= f.name;
        }

        auto found = extractCases(text);
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
            auto ch = chapterFor(c, stem(f.name));
            if (ch.length == 0) {
                // The operator spoke and no chapter owns the module. Said,
                // and the book stops, rather than filed somewhere plausible.
                if (c.said.length > 0 && c.pbt.length == 0)
                    refused ~= Refused(f.name, "quotes the operator and no chapter owns " ~ stem(f.name));
                continue;
            }

            auto tall = splitLines(c.pbt).length;
            if (tall > PAGE_LINES)
                overflowing ~= Overflow(baseName(f.name), ch, tall);

            // A fixture that reads badly on the page reads badly in the file
            // until fmt is run on it. The book quotes, it does not reshape.
            if (c.pbt.length > 0 && !isCanonical(c.pbt ~ "\n", fmtScratch))
                refused ~= Refused(f.name, "carries a fixture ground fmt would change: " ~ c.subject);

            if (ch !in chapters) present ~= ch;
            chapters[ch] ~= Placed(rank(ch, stem(f.name)), baseName(f.name), c);
        }

        size_t proved = 0;
        foreach (c; found) if (!c.heading) proved++;
        totalCases += proved;
        stderr.writefln("press: %s (%d cases)", baseName(f.name), proved);
    }

    // ug and wind are their own binaries, outside source/, and say what
    // they are in their own files.
    foreach (extra; ["ug/main.d", "tools/wind.d"]) {
        if (!exists(extra)) continue;
        foreach (e; extractCommands(readText(extra))) {
            if (e.term.length == 0) {
                refused ~= Refused(extra, "carries a command line without a name: " ~ e.text);
                continue;
            }
            commands ~= e;
            commandFiles ~= extra;
        }
    }

    // What main.d answers to is read from main.d. A command the book names
    // exists, and a command that exists is in the book, or the book stops.
    {
        auto answers = dispatched(readText("source/main.d"));
        foreach (a; answers)
            if (!hasTerm(commands, "ground " ~ a))
                refused ~= Refused("source/main.d", "answers to " ~ a ~ " and no module says what ground " ~ a ~ " is");
        foreach (i, c; commands) {
            if (binaryOf(c.term) != "ground" || c.term == "ground") continue;
            if (!contains(answers, c.term["ground ".length .. $]))
                refused ~= Refused(commandFiles[i], "describes " ~ c.term ~ ", which main.d does not answer to");
        }
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

    // A term the book cannot place is not filed somewhere plausible. The line
    // was written on purpose, so the book says which one and stops.
    if (refused.length > 0) {
        foreach (r; refused) stderr.writefln("press: %s %s", r.file, r.why);
        stderr.writeln("press: a line the book cannot place. Nothing written.");
        return 1;
    }

    // A chapter that stops being one would leave its file behind for an
    // \input that no longer names it. Cleared here rather than by the caller,
    // so a halt leaves the last good book standing instead of deleting it.
    foreach (e; dirEntries("doc/tex", "*.tex", SpanMode.shallow)) remove(e.name);

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

    // "i would have expeced to see the commands as a chapeter before scope"
    // The binaries first, then the grammar they read. ground's commands are
    // in the order main.d answers to them.
    string list;
    auto cmdTex = renderCommands(inDispatchOrder(commands, dispatched(readText("source/main.d"))));
    if (cmdTex.length > 0) {
        write("doc/tex/commands.tex", cmdTex);
        list ~= "\\input{tex/commands}\n";
    }

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

    // "the glossary has a section for each non glossary capter"
    // Sections run in chapter order, and a chapter with no term has none.
    auto gloss = renderGlossary(order, glossary);
    if (gloss.length > 0) {
        write("doc/tex/glossary.tex", gloss);
        list ~= "\\input{tex/glossary}\n";
    }
    write("doc/tex/chapters.tex", list);

    size_t terms = 0;
    foreach (es; glossary) terms += es.length;
    stderr.writefln("press: %d chapters, %d cases, %d terms",
        order.length, totalCases, terms);
    return 0;
}

// Where a case is set. A pbt example is placed by its block word. A case with
// none is placed by the chapter that owns its module, and only when the
// operator's words stand above it. Everything else the compiler proved stays
// off the page.
string chapterFor(const Case c, string mod) {
    auto ch = conceptOf(c.pbt);
    if (ch.length > 0) return ch;
    if (c.said.length > 0 && c.pbt.length == 0) return chapterOf(mod);
    return "";
}

// The glossary chapter. Empty when no module defines a term, so the book has
// no chapter that says nothing.
string renderGlossary(const(string)[] order, Entry[][string] glossary) {
    string out_;
    foreach (ch; order) {
        // The term that is the chapter's own word heads its section, and the
        // other terms are its subs. Without one, the word itself is the head.
        string main_;
        string section;
        foreach (o; owners) {
            if (o.chapter != ch) continue;
            foreach (m; o.mods) {
                if (m !in glossary) continue;
                foreach (e; glossary[m]) {
                    if (main_.length == 0 && isWord(e.term, ch)) {
                        main_ = "\\gmain{" ~ escape(e.term) ~ "}{" ~ escape(e.text) ~ "}\n";
                        continue;
                    }
                    section ~= "\\gterm{" ~ escape(e.term) ~ "}{" ~ escape(e.text) ~ "}\n";
                }
            }
        }
        if (main_.length == 0 && section.length == 0) continue;
        auto head = main_.length > 0 ? "\\begin{gglossary}\n" ~ main_
                                     : "\\gsection{" ~ ch ~ "}\n\\begin{gglossary}\n";
        out_ ~= head ~ section ~ "\\end{gglossary}\n\n";
    }
    if (out_.length == 0) return "";
    // Two columns, and a section is one block in them: press names the parts,
    // book.tex sets them.
    return "\\chapter{glossary}\n\n\\begin{gcolumns}\n" ~ out_ ~ "\\end{gcolumns}\n";
}

// Several quotes are several lines of the one box, in the order they were said.
string saidLines(string said) {
    string out_;
    foreach (i, line; splitLines(said)) {
        if (i > 0) out_ ~= "\\par ";
        out_ ~= escape(line);
    }
    return out_;
}

// The commands chapter. A binary heads its block and its commands are the
// subs, in the order the modules stated them. Empty when nothing says so.
string renderCommands(Entry[] cmds) {
    string[] bins;
    foreach (c; cmds) {
        auto b = binaryOf(c.term);
        if (!contains(bins, b)) bins ~= b;
    }

    string out_;
    foreach (b; bins) {
        string main_;
        string section;
        foreach (c; cmds) {
            if (binaryOf(c.term) != b) continue;
            if (c.term == b && main_.length == 0) {
                main_ = "\\gmain{" ~ escape(c.term) ~ "}{" ~ escape(c.text) ~ "}\n";
                continue;
            }
            section ~= "\\gterm{" ~ escape(c.term) ~ "}{" ~ escape(c.text) ~ "}\n";
        }
        auto head = main_.length > 0 ? "\\begin{gglossary}\n" ~ main_
                                     : "\\gsection{" ~ escape(b) ~ "}\n\\begin{gglossary}\n";
        out_ ~= head ~ section ~ "\\end{gglossary}\n\n";
    }
    if (out_.length == 0) return "";
    return "\\chapter{commands}\n\n\\begin{gcolumns}\n" ~ out_ ~ "\\end{gcolumns}\n";
}

// ground first, then its commands as main.d lists them, then every other
// binary as its file stated it.
Entry[] inDispatchOrder(Entry[] cmds, string[] answers) {
    Entry[] out_;
    foreach (c; cmds) if (c.term == "ground") out_ ~= c;
    foreach (a; answers)
        foreach (c; cmds) if (c.term == "ground " ~ a) out_ ~= c;
    foreach (c; cmds) if (binaryOf(c.term) != "ground") out_ ~= c;
    return out_;
}

private bool hasTerm(Entry[] es, string term) {
    foreach (e; es) if (e.term == term) return true;
    return false;
}

// The binary a command belongs to is its first word.
string binaryOf(string term) {
    foreach (i, c; term) if (c == ' ') return term[0 .. i];
    return term;
}

// What main.d answers to: every name it compares the first argument against.
string[] dispatched(string mainSource) {
    enum probe = "cmd == \"";
    string[] out_;
    size_t i = 0;
    while (i + probe.length <= mainSource.length) {
        if (mainSource[i .. i + probe.length] != probe) { i++; continue; }
        auto start = i + probe.length;
        auto e = start;
        while (e < mainSource.length && mainSource[e] != '"') e++;
        out_ ~= mainSource[start .. e];
        i = e;
    }
    return out_;
}

// A term is the chapter's word when it is that word with its first letter
// raised: Scope for scope.
bool isWord(string term, string chapter) {
    if (term.length != chapter.length) return false;
    foreach (i, c; term) {
        auto lower = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
        if (lower != chapter[i]) return false;
    }
    return true;
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
        // The example is the pbt. A case the operator's words earned its page
        // without one names the symbol it proves; the D stays in the source.
        // The block and what it is for are one row. A minipage is a box, so
        // the page break falls between rows and never through an example.
        // What was said hangs above the row, between the two.
        // The card and its row are one outer box, so a page never falls
        // between what was said and what was built for it.
        if (c.pbt.length == 0 && c.said.length == 0) continue;
        auto hung = c.said.length > 0;
        if (hung) out_ ~= "\n\\par\\noindent\\begin{minipage}{\\textwidth}\n\\gsaidprep{" ~ saidLines(c.said) ~ "}\n\\noindent";
        else out_ ~= "\n\\par\\noindent\n";
        out_ ~= "\\begin{minipage}[t]{\\gpbtw}\n";
        if (c.pbt.length > 0) out_ ~= "\\begin{gcode}\n" ~ c.pbt ~ "\n\\end{gcode}\n";
        else out_ ~= "\\gproved{" ~ escape(c.subject) ~ "}\n";
        out_ ~= "\\end{minipage}\\hfill\n";
        out_ ~= "\\begin{minipage}[t]{\\gnotew}\n";
        out_ ~= (hung ? "\\gsaidhung" : "") ~ "\\gnote{" ~ escape(c.prose) ~ "}\n";
        out_ ~= "\\end{minipage}\n";
        if (hung) out_ ~= "\\end{minipage}\n";
        out_ ~= "\\par\\vspace{10pt}\n";
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
    // Charter has no arrow, and a glyph the font lacks is a gap on the page
    // with a warning nobody reads. The math arrow is in every setup.
    enum arrow = "\xE2\x86\x92";
    // The status line is drawn in block elements and a check mark, and a
    // quote of it carries them. Charter has none; the code font does.
    static immutable string[4] blocks = ["\xE2\x96\x91", "\xE2\x96\x93", "\xE2\x96\x8F", "\xE2\x9C\x93"];
    size_t i = 0;
    while (i < s.length) {
        if (i + arrow.length <= s.length && s[i .. i + arrow.length] == arrow) {
            out_ ~= "$\\rightarrow$";
            i += arrow.length;
            continue;
        }
        bool drawn = false;
        foreach (b; blocks) {
            if (i + b.length <= s.length && s[i .. i + b.length] == b) {
                out_ ~= "{\\ttfamily " ~ b ~ "}";
                i += b.length;
                drawn = true;
                break;
            }
        }
        if (drawn) continue;
        auto c = s[i];
        i++;
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
