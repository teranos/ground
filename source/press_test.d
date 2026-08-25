module press_test;

// CTFE tests — failure shows as a compile error.
//
// press turns the _test.d files into the Book of Ground: each comment block
// and the asserts beneath it are one example — the comment is the prose, the
// assert is the proven statement. Parsing keeps slices of the input, and
// rendering writes into a Sink, so the same functions run at CTFE and at
// runtime under -betterC alike.

import press : Example, Chapter, Sink, parseChapter, texEscapeInto,
               countStaticAsserts, countRuntimeAsserts,
               renderChapterInto, renderBookInto;

// --- parseChapter ---

// A comment block and the code beneath it are one example. The module line
// and the import are neither prose nor proof, so they are not on the page.
private enum sample =
    "module x_test;\n" ~
    "\n" ~
    "import a : b;\n" ~
    "\n" ~
    "// First truth.\n" ~
    "// Second line of it.\n" ~
    "static assert(b(1) == 2);\n" ~
    "static assert(b(1) != 3);\n" ~
    "\n" ~
    "// Another truth.\n" ~
    "static assert(b(2) == 3);\n";

private enum ch = parseChapter("x", sample);

static assert(ch.name == "x");
static assert(ch.count == 2);
static assert(ch.examples[0].prose == "// First truth.\n// Second line of it.");
static assert(ch.examples[0].code == "static assert(b(1) == 2);\nstatic assert(b(1) != 3);");
static assert(ch.examples[1].prose == "// Another truth.");
static assert(ch.examples[1].code == "static assert(b(2) == 3);");

// A leading comment block with no code under it is the chapter's own
// introduction, not an example — perf_test.d opens exactly like this.
private enum introSample =
    "module y_test;\n" ~
    "\n" ~
    "// CTFE tests — failure shows as a compile error.\n" ~
    "\n" ~
    "import p : q;\n" ~
    "\n" ~
    "// One truth.\n" ~
    "static assert(q);\n";

private enum chIntro = parseChapter("y", introSample);

static assert(chIntro.intro == "// CTFE tests — failure shows as a compile error.");
static assert(chIntro.count == 1);
static assert(chIntro.examples[0].prose == "// One truth.");

// A multi-line import — strop_test.d imports across four lines — is skipped
// through its closing semicolon, not just its first line.
private enum multiImport =
    "module z_test;\n" ~
    "\n" ~
    "import strop : matchLiteral, matchLetters,\n" ~
    "               Part, PartKind,\n" ~
    "               letters, digits;\n" ~
    "\n" ~
    "// Truth after the long import.\n" ~
    "static assert(1 == 1);\n";

private enum chMulti = parseChapter("z", multiImport);

static assert(chMulti.count == 1);
static assert(chMulti.examples[0].prose == "// Truth after the long import.");
static assert(chMulti.examples[0].code == "static assert(1 == 1);");

// Code with no comment above it is still an example — an unexplained proof
// is a proof, and dropping it would make the book lie by omission.
private enum bare =
    "module w_test;\n" ~
    "\n" ~
    "static assert(2 + 2 == 4);\n";

private enum chBare = parseChapter("w", bare);

static assert(chBare.count == 1);
static assert(chBare.examples[0].prose == "");
static assert(chBare.examples[0].code == "static assert(2 + 2 == 4);");

// A comment block directly after code starts the next example even with no
// blank line between them, rather than gluing onto the previous one.
private enum backToBack =
    "module v_test;\n" ~
    "\n" ~
    "// First.\n" ~
    "static assert(true);\n" ~
    "// Second, no blank line above.\n" ~
    "static assert(true);\n";

private enum chB2B = parseChapter("v", backToBack);

static assert(chB2B.count == 2);
static assert(chB2B.examples[1].prose == "// Second, no blank line above.");

// --- texEscapeInto ---

// Prose goes through LaTeX, so the ten specials are escaped. Code does not —
// it is set verbatim inside lstlisting — so only prose pays this toll.
private Sink!128 esc(string s) {
    Sink!128 k;
    texEscapeInto(k, s);
    return k;
}

static assert(esc("a_b").eq("a\\_b"));
static assert(esc("50%").eq("50\\%"));
static assert(esc("A & B").eq("A \\& B"));
static assert(esc("#4").eq("\\#4"));
static assert(esc("$x$").eq("\\$x\\$"));
static assert(esc("{x}").eq("\\{x\\}"));
static assert(esc("\\").eq("\\textbackslash{}"));
static assert(esc("~").eq("\\textasciitilde{}"));
static assert(esc("^").eq("\\textasciicircum{}"));
static assert(esc("plain").eq("plain"));

// --- counting, for the colophon ---

// The colophon states what the book contains because it counted, not because
// somebody remembered. static asserts are laws; runtime asserts practices.
static assert(countStaticAsserts(sample) == 3);
static assert(countStaticAsserts("assert(x);") == 0);
static assert(countRuntimeAsserts("assert(x);\nstatic assert(y);") == 1);
static assert(countRuntimeAsserts(sample) == 0);

// --- rendering ---

private Sink!16384 chapterTex(Chapter c) {
    Sink!16384 k;
    renderChapterInto(k, c);
    return k;
}

private enum chT = chapterTex(ch);

// The chapter opens as a chapter, carries the prose with its // stripped,
// and sets the code verbatim.
static assert(chT.len > 0);
static assert(chT.count("\\chapter{x}") == 1);
static assert(chT.count("First truth.") == 1);
static assert(chT.count("// First truth.") == 0);
static assert(chT.count("static assert(b(1) == 2);") == 1);
static assert(chT.count("\\begin{lstlisting}") == 2);
static assert(chT.count("\\end{lstlisting}") == 2);

// An underscore in prose reaches LaTeX escaped, or the build of the book
// dies inside pdflatex where nobody is looking.
private enum chUnderscore = parseChapter("u",
    "module u_test;\n\n// about strop_test rules\nstatic assert(true);\n");
static assert(chapterTex(chUnderscore).count("strop\\_test") == 1);

// The book is one self-contained document: class, fonts, title page with the
// impression, every chapter, colophon with the counts, and the closing.
private Sink!65536 bookTex() {
    Chapter[2] cs = [ch, chIntro];
    Sink!65536 k;
    renderBookInto(k, cs[], "v0.9.0-test", "2026-08-25", 313, 42);
    return k;
}

private enum book = bookTex();

static assert(book.count("\\documentclass") == 1);
static assert(book.count("\\begin{document}") == 1);
static assert(book.count("\\end{document}") == 1);
static assert(book.count("\\chapter{x}") == 1);
static assert(book.count("\\chapter{y}") == 1);
static assert(book.count("The Book of Ground") == 1);
static assert(book.count("v0.9.0-test") == 1);
static assert(book.count("313") == 1);
static assert(book.count("42") == 1);
