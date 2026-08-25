module press;

// The press for the Book of Ground.
//
// The book is already written — it sits in the pbt files and the _test.d
// files, where every contiguous comment block is prose and the block
// beneath it is the statement the prose explains. In pbt the statement is
// "the literal pbt examples and fixtures being extracted out": a control or
// a rites block, whole and verbatim. In the test files it is the asserts,
// proven where they live. press does not author anything: it sets that type
// into LaTeX at CTFE, so the binary carries its own pages and `ground
// press` at runtime only runs them off. A page that stops being true stops
// the build.
//
// "Can't we use .tex to generate the Book of Ground?" — the book contains
// each and every example, and it contains them because it counted, not
// because somebody remembered.
//
// Rendering follows the ug idiom — formatters take inputs and a destination
// buffer — because -betterC has no GC to concatenate strings with, at CTFE
// exactly as at runtime. The same functions run in both worlds; the book is
// pressed once, at compile time, into a right-sized static immutable.

// --- parsed shape ---

struct Example {
    string prose; // the comment block, prefixes still on, slice of the file
    string code;  // the block beneath it, verbatim, slice of the file
}

// 512 is capacity, not a cap: parseChapter asserts when a file outgrows it,
// so the book can never silently drop an example — the build dies instead.
enum MAX_EXAMPLES = 512;

struct Chapter {
    string name;
    string intro; // leading comment block with nothing under it
    Example[MAX_EXAMPLES] examples;
    size_t count;
}

// The two grammars the tree writes its book in. dtest groups by blank
// lines; pbt groups by top-level braced blocks, since a block carries blank
// lines and its own comments inside itself.
enum Lang { dtest, pbt }

// A part of the book: a titled run of chapters.
struct Part {
    string title;
    const(Chapter)[] chapters;
}

// What the colophon states. Filled by counting, never by hand.
struct Counts {
    size_t laws;      // static asserts — proven at compile time
    size_t practices; // runtime asserts — proven when the tests run
    size_t controls;  // control blocks standing watch
    size_t rites;     // rites blocks
}

// --- destination buffer ---

// Overflow is an assert, not a truncation: a book with a missing corner
// would still look finished, so the build dies instead.
struct Sink(size_t N) {
    char[N] buf = 0;
    size_t len;

    void put(const(char)[] s) {
        assert(len + s.length <= N);
        foreach (c; s) buf[len++] = c;
    }

    void putc(char c) {
        assert(len < N);
        buf[len++] = c;
    }

    bool eq(const(char)[] s) const {
        if (len != s.length) return false;
        foreach (i; 0 .. len) if (buf[i] != s[i]) return false;
        return true;
    }

    size_t count(const(char)[] needle) const {
        if (needle.length == 0) return 0;
        size_t n = 0, i = 0;
        while (i + needle.length <= len) {
            bool hit = true;
            foreach (j; 0 .. needle.length)
                if (buf[i + j] != needle[j]) { hit = false; break; }
            if (hit) { n++; i += needle.length; }
            else i++;
        }
        return n;
    }
}

// --- small helpers, slices only ---

private bool startsWith(const(char)[] s, const(char)[] prefix) {
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

private const(char)[] trimLeft(const(char)[] s) {
    size_t i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) i++;
    return s[i .. $];
}

private bool contains(const(char)[] s, char c) {
    foreach (ch; s) if (ch == c) return true;
    return false;
}

// --- parsing ---

Chapter parseChapter(string name, string text, Lang lang = Lang.dtest) {
    final switch (lang) {
        case Lang.dtest: return parseDtest(name, text);
        case Lang.pbt:   return parsePbt(name, text);
    }
}

// One pass over a test file. The module line and imports are neither prose
// nor proof, so they are not on the page; blank lines separate examples; a
// comment line after code opens the next example even with no blank between.
private Chapter parseDtest(string name, string text) {
    Chapter ch;
    ch.name = name;

    size_t proseStart, proseEnd, codeStart, codeEnd;
    bool haveProse, haveCode;
    bool inImport;

    void flush() {
        if (!haveProse && !haveCode) return;
        if (haveProse && !haveCode && ch.count == 0 && ch.intro.length == 0) {
            ch.intro = text[proseStart .. proseEnd];
        } else {
            assert(ch.count < MAX_EXAMPLES);
            ch.examples[ch.count] = Example(
                haveProse ? text[proseStart .. proseEnd] : "",
                haveCode ? text[codeStart .. codeEnd] : "");
            ch.count++;
        }
        haveProse = false;
        haveCode = false;
    }

    size_t pos = 0;
    while (pos < text.length) {
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n') nl++;
        auto line = text[pos .. nl];
        auto t = trimLeft(line);

        if (inImport) {
            if (contains(line, ';')) inImport = false;
        } else if (startsWith(t, "module ")) {
            // not on the page
        } else if (startsWith(t, "import ")) {
            inImport = !contains(line, ';');
        } else if (t.length == 0) {
            flush();
        } else if (startsWith(t, "//")) {
            if (haveCode) flush();
            if (!haveProse) { proseStart = pos; haveProse = true; }
            proseEnd = nl;
        } else {
            if (!haveCode) { codeStart = pos; haveCode = true; }
            codeEnd = nl;
        }

        pos = nl + 1;
    }
    flush();

    return ch;
}

// One pass over a pbt file. An example is a top-level braced block, whole:
// blank lines and # comments inside it belong to it, the way the rites of
// moon carry their comments with them. Braces inside backtick evals and
// double-quoted values are words, not structure — boxdeath's watcher posts
// a JSON body, and counting its braces would tear the block apart. A
// backtick string spans lines; a double-quoted one does not.
private Chapter parsePbt(string name, string text) {
    Chapter ch;
    ch.name = name;

    size_t proseStart, proseEnd, codeStart, codeEnd;
    bool haveProse, haveCode;
    int depth;
    bool inBacktick;

    void flushProse() {
        if (!haveProse) return;
        if (ch.count == 0 && ch.intro.length == 0) {
            ch.intro = text[proseStart .. proseEnd];
        } else {
            assert(ch.count < MAX_EXAMPLES);
            ch.examples[ch.count] = Example(text[proseStart .. proseEnd], "");
            ch.count++;
        }
        haveProse = false;
    }

    void flushExample() {
        assert(ch.count < MAX_EXAMPLES);
        ch.examples[ch.count] = Example(
            haveProse ? text[proseStart .. proseEnd] : "",
            text[codeStart .. codeEnd]);
        ch.count++;
        haveProse = false;
        haveCode = false;
    }

    void scanLine(const(char)[] line) {
        bool inDouble = false;
        size_t i = 0;
        while (i < line.length) {
            auto c = line[i];
            if (inBacktick) {
                if (c == '`') inBacktick = false;
            } else if (inDouble) {
                if (c == '\\') i++;
                else if (c == '"') inDouble = false;
            } else if (c == '`') {
                inBacktick = true;
            } else if (c == '"') {
                inDouble = true;
            } else if (c == '#') {
                break;
            } else if (c == '{') {
                depth++;
            } else if (c == '}') {
                depth--;
            }
            i++;
        }
    }

    size_t pos = 0;
    while (pos < text.length) {
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n') nl++;
        auto line = text[pos .. nl];
        auto t = trimLeft(line);

        bool atTop = depth == 0 && !inBacktick && !haveCode;

        if (atTop && t.length == 0) {
            flushProse();
        } else if (atTop && startsWith(t, "#")) {
            if (!haveProse) { proseStart = pos; haveProse = true; }
            proseEnd = nl;
        } else {
            if (!haveCode) { codeStart = pos; haveCode = true; }
            scanLine(line);
            codeEnd = nl;
            if (depth == 0 && !inBacktick) flushExample();
        }

        pos = nl + 1;
    }
    flushProse();

    // A block the file never closed would fall off the page unnoticed.
    assert(!haveCode && depth == 0 && !inBacktick);

    return ch;
}

// --- counting, for the colophon ---

// Laws hold at compile time, practices when the tests run; controls stand
// watch and rites walk. The colophon states all four from measurement.
size_t countStaticAsserts(string text) {
    enum needle = "static assert";
    size_t n = 0, i = 0;
    while (i + needle.length <= text.length) {
        if (text[i .. i + needle.length] == needle) { n++; i += needle.length; }
        else i++;
    }
    return n;
}

size_t countRuntimeAsserts(string text) {
    enum needle = "assert(";
    enum prefix = "static ";
    size_t n = 0, i = 0;
    while (i + needle.length <= text.length) {
        if (text[i .. i + needle.length] == needle) {
            bool isStatic = i >= prefix.length && text[i - prefix.length .. i] == prefix;
            if (!isStatic) n++;
            i += needle.length;
        } else {
            i++;
        }
    }
    return n;
}

size_t countControls(string text) {
    enum needle = "control {";
    size_t n = 0, i = 0;
    while (i + needle.length <= text.length) {
        if (text[i .. i + needle.length] == needle) { n++; i += needle.length; }
        else i++;
    }
    return n;
}

// A rites block opens at column zero — an indented mention is a reference,
// not a declaration.
size_t countRitesBlocks(string text) {
    enum needle = "rites ";
    size_t n = 0, pos = 0;
    while (pos < text.length) {
        size_t nl = pos;
        while (nl < text.length && text[nl] != '\n') nl++;
        if (startsWith(text[pos .. nl], needle)) n++;
        pos = nl + 1;
    }
    return n;
}

// --- rendering ---

// Prose passes through LaTeX, so its specials are escaped. Code never comes
// here — it is set verbatim inside lstlisting and pays no toll.
void texEscapeInto(size_t N)(ref Sink!N k, const(char)[] s) {
    foreach (ch; s) {
        switch (ch) {
            case '\\': k.put("\\textbackslash{}"); break;
            case '~':  k.put("\\textasciitilde{}"); break;
            case '^':  k.put("\\textasciicircum{}"); break;
            case '&': case '%': case '$': case '#': case '_': case '{': case '}':
                k.putc('\\');
                k.putc(ch);
                break;
            default:
                k.putc(ch);
        }
    }
}

// The comment marker comes off each line here and only here — the parser
// keeps slices of the file untouched so nothing is lost between reading and
// setting. Both grammars shed their marker the same way.
private void proseInto(size_t N)(ref Sink!N k, string prose) {
    size_t pos = 0;
    bool first = true;
    while (pos <= prose.length) {
        size_t nl = pos;
        while (nl < prose.length && prose[nl] != '\n') nl++;
        auto line = trimLeft(prose[pos .. nl]);
        if (startsWith(line, "// ")) line = line[3 .. $];
        else if (startsWith(line, "//")) line = line[2 .. $];
        else if (startsWith(line, "# ")) line = line[2 .. $];
        else if (startsWith(line, "#")) line = line[1 .. $];
        if (!first) k.putc('\n');
        first = false;
        texEscapeInto(k, line);
        if (nl >= prose.length) break;
        pos = nl + 1;
    }
}

private void numInto(size_t N)(ref Sink!N k, size_t n) {
    char[20] digits;
    size_t d = 0;
    if (n == 0) { k.putc('0'); return; }
    while (n > 0) { digits[d++] = cast(char)('0' + n % 10); n /= 10; }
    while (d > 0) k.putc(digits[--d]);
}

void renderChapterInto(size_t N)(ref Sink!N k, ref const Chapter ch) {
    k.put("\\chapter{");
    texEscapeInto(k, ch.name);
    k.put("}\n\n");
    if (ch.intro.length > 0) {
        proseInto(k, ch.intro);
        k.put("\n\n");
    }
    foreach (i; 0 .. ch.count) {
        if (ch.examples[i].prose.length > 0) {
            proseInto(k, ch.examples[i].prose);
            k.putc('\n');
        }
        if (ch.examples[i].code.length > 0) {
            k.put("\\begin{lstlisting}\n");
            k.put(ch.examples[i].code);
            k.put("\n\\end{lstlisting}\n");
        }
        k.putc('\n');
    }
}

void renderBookInto(size_t N)(ref Sink!N k, const(Part)[] parts,
                              const(char)[] version_, const(char)[] date,
                              Counts counts) {
    // The em dash is the one character the tree writes that pdflatex's
    // verbatim cannot set; literate maps it to a typeset dash.
    k.put("\\documentclass[10pt,twoside]{memoir}\n"
        ~ "\\usepackage[T1]{fontenc}\n"
        ~ "\\usepackage[utf8]{inputenc}\n"
        ~ "\\usepackage{tgpagella}\n"
        ~ "\\usepackage{tgcursor}\n"
        ~ "\\usepackage{microtype}\n"
        ~ "\\usepackage{listings}\n"
        ~ "\\setlrmarginsandblock{3.2cm}{2.6cm}{*}\n"
        ~ "\\setulmarginsandblock{3.0cm}{3.2cm}{*}\n"
        ~ "\\checkandfixthelayout\n"
        ~ "\\chapterstyle{ell}\n"
        ~ "\\lstset{basicstyle=\\ttfamily\\small, breaklines=true,\n"
        ~ "  columns=fullflexible, keepspaces=true,\n"
        ~ "  literate={—}{{---}}1,\n"
        ~ "  frame=leftline, framerule=0.4pt,\n"
        ~ "  xleftmargin=1em, aboveskip=0.6em, belowskip=0.9em}\n"
        ~ "\\begin{document}\n"
        ~ "\\frontmatter\n"
        ~ "\\begin{titlingpage}\n"
        ~ "\\begin{center}\n"
        ~ "\\vspace*{4cm}\n"
        ~ "{\\HUGE The Book of Ground\\par}\n"
        ~ "\\vspace{1.2cm}\n"
        ~ "{\\Large every example the tree can prove\\par}\n"
        ~ "\\vfill\n"
        ~ "{\\large pressed from ");
    texEscapeInto(k, version_);
    k.put(" on ");
    texEscapeInto(k, date);
    k.put("\\par}\n"
        ~ "\\vspace*{2cm}\n"
        ~ "\\end{center}\n"
        ~ "\\end{titlingpage}\n"
        ~ "\\tableofcontents*\n"
        ~ "\\mainmatter\n\n");

    foreach (p; 0 .. parts.length) {
        k.put("\\part{");
        texEscapeInto(k, parts[p].title);
        k.put("}\n\n");
        foreach (i; 0 .. parts[p].chapters.length)
            renderChapterInto(k, parts[p].chapters[i]);
    }

    k.put("\\backmatter\n"
        ~ "\\chapter{Colophon}\n\n"
        ~ "This impression was pressed by ground from its own tree.\n"
        ~ "Nothing in it was authored for the page: every passage is a\n"
        ~ "comment block, and every listing beneath one is the block it\n"
        ~ "explains — a control standing watch, a ritual's rites, or an\n"
        ~ "assertion proven where it lives.\n\n"
        ~ "It contains ");
    numInto(k, counts.controls);
    k.put(" controls and ");
    numInto(k, counts.rites);
    k.put(" rites blocks, set verbatim; ");
    numInto(k, counts.laws);
    k.put(" laws --- statements the compiler re-proves at compile time on\n"
        ~ "every build, so a page that stops being true stops the build ---\n"
        ~ "and ");
    numInto(k, counts.practices);
    k.put(" practices, asserted when the tests run.\n\n"
        ~ "The counts are measured, not remembered.\n"
        ~ "\\end{document}\n");
}

// --- the first impression ---

// The chapters of this impression, one array per part. Adding a chapter is
// one line: name it, string-import its file. The text is baked in at
// compile time, so the installed binary presses this book from anywhere,
// checkout or not.

private static immutable string[2][6] CONTROLS_PBT = [
    ["controls",           import("controls/controls.pbt")],
    ["commits",            import("controls/commits.pbt")],
    ["comments",           import("controls/comments.pbt")],
    ["permissions",        import("controls/permissions.pbt")],
    ["symbol-not-address", import("controls/symbol-not-address.pbt")],
    ["ug-docs-adherence",  import("controls/ug-docs-adherence.pbt")],
];

private static immutable string[2][9] RITUALS_PBT = [
    ["grove",             import("grove/controls/grove.pbt")],
    ["sun",               import("grove/controls/sun.pbt")],
    ["moon",              import("grove/controls/moon.pbt")],
    ["perpetuity",        import("grove/controls/perpetuity.pbt")],
    ["coinflip",          import("grove/controls/coinflip.pbt")],
    ["ritual-of-control", import("grove/controls/ritual-of-control.pbt")],
    ["jump",              import("grove/controls/jump.pbt")],
    ["2goto",             import("grove/controls/2goto.pbt")],
    ["chapters",          import("grove/controls/chapters.pbt")],
];

private static immutable string[2][3] CODE_TESTS = [
    ["strop", import("source/strop_test.d")],
    ["exec",  import("source/exec_test.d")],
    ["perf",  import("ug/perf_test.d")],
];

private size_t sumCount()(const string[2][] entries, size_t function(string) f) {
    size_t n = 0;
    foreach (e; entries) n += f(e[1]);
    return n;
}

private string trimEnd(string s) {
    size_t end = s.length;
    while (end > 0 && (s[end - 1] == '\n' || s[end - 1] == '\r' || s[end - 1] == ' '))
        end--;
    return s[0 .. end];
}

// Working room for one pressing. The exact length is measured below and the
// stored book is right-sized; this is scaffolding the finished binary drops.
private enum PRESS_CAP = 1 << 20;

private Sink!PRESS_CAP pressOnce()() {
    Chapter[CONTROLS_PBT.length] controlChapters;
    foreach (i, e; CONTROLS_PBT)
        controlChapters[i] = parseChapter(e[0], e[1], Lang.pbt);

    Chapter[RITUALS_PBT.length] ritualChapters;
    foreach (i, e; RITUALS_PBT)
        ritualChapters[i] = parseChapter(e[0], e[1], Lang.pbt);

    Chapter[CODE_TESTS.length] codeChapters;
    foreach (i, e; CODE_TESTS)
        codeChapters[i] = parseChapter(e[0], e[1]);

    Part[3] parts = [Part("The Controls", controlChapters[]),
                     Part("The Rituals", ritualChapters[]),
                     Part("Laws and Practices", codeChapters[])];

    Counts counts = {
        laws:      sumCount(CODE_TESTS[], &countStaticAsserts),
        practices: sumCount(CODE_TESTS[], &countRuntimeAsserts),
        controls:  sumCount(CONTROLS_PBT[], &countControls)
                 + sumCount(RITUALS_PBT[], &countControls),
        rites:     sumCount(CONTROLS_PBT[], &countRitesBlocks)
                 + sumCount(RITUALS_PBT[], &countRitesBlocks),
    };

    Sink!PRESS_CAP k;
    renderBookInto(k, parts[],
                   trimEnd(import(".version")),
                   trimEnd(import(".builddate")),
                   counts);
    return k;
}

private enum BOOK_LEN = pressOnce().len;

private char[BOOK_LEN] pressExact()() {
    auto k = pressOnce();
    char[BOOK_LEN] page = 0;
    foreach (i; 0 .. BOOK_LEN) page[i] = k.buf[i];
    return page;
}

// The book, set at compile time. The binary is the config; here it is also
// the edition.
static immutable char[BOOK_LEN] BOOK = pressExact();

// --- runtime: run off the pages ---

int handlePress() {
    import core.stdc.stdio : stdout, fwrite;
    fwrite(BOOK.ptr, 1, BOOK.length, stdout);
    return 0;
}
