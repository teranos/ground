module press_test;

// CTFE tests — failure shows as a compile error.
//
// press turns the _test.d files into the Book of Ground: each comment block
// and the asserts beneath it are one example — the comment is the prose, the
// assert is the proven statement. Parsing keeps slices of the input, and
// rendering writes into a Sink, so the same functions run at CTFE and at
// runtime under -betterC alike.

import press : Example, Chapter, Lang, Part, Counts, Sink, parseChapter,
               texEscapeInto, countStaticAsserts, countRuntimeAsserts,
               countControls, countRitesBlocks,
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

// --- parseChapter, pbt ---

// The pbt is the book too — "the literal pbt examples and fixtures being
// extracted out". Same anatomy, different grammar: prose is the # comment
// block above a top-level block, and the example is that block whole,
// verbatim, inner comments and blank lines included.
private enum pbtSample =
    "# The law above the block.\n" ~
    "scope {\n" ~
    "  event: \"PreToolUse\"\n" ~
    "\n" ~
    "  control {\n" ~
    "    name: \"x\"\n" ~
    "  }\n" ~
    "}\n" ~
    "\n" ~
    "# A second block.\n" ~
    "rites r {\n" ~
    "  A { eval: \"true\" }\n" ~
    "}\n";

private enum chPbt = parseChapter("law", pbtSample, Lang.pbt);

static assert(chPbt.count == 2);
static assert(chPbt.examples[0].prose == "# The law above the block.");
static assert(chPbt.examples[0].code ==
    "scope {\n  event: \"PreToolUse\"\n\n  control {\n    name: \"x\"\n  }\n}");
static assert(chPbt.examples[1].prose == "# A second block.");
static assert(chPbt.examples[1].code == "rites r {\n  A { eval: \"true\" }\n}");

// A backtick eval carrying JSON braces, and a double-quoted value carrying
// escaped quotes, must not move the depth counter — boxdeath's watcher rite
// posts exactly such a body, and splitting it would tear the block apart.
private enum pbtQuoted =
    "rites b {\n" ~
    "  W { eval: `curl -d \"{\\\"id\\\":1}\"` }\n" ~
    "  X { msg: \"brace { in text\" }\n" ~
    "}\n";

private enum chQuoted = parseChapter("b", pbtQuoted, Lang.pbt);

static assert(chQuoted.count == 1);
static assert(chQuoted.examples[0].code[0 .. 8] == "rites b ");
static assert(chQuoted.examples[0].code[$ - 1] == '}');

// A backtick string spans lines — HOLD's eval does — and the braces of the
// lines inside it stay words, not structure.
private enum pbtMultiline =
    "rites m {\n" ~
    "  H {\n" ~
    "    eval: `\n" ~
    "      test -z \"$(git status --porcelain)\"\n" ~
    "    `\n" ~
    "  }\n" ~
    "}\n";

static assert(parseChapter("m", pbtMultiline, Lang.pbt).count == 1);

// A leading comment block with no block under it introduces the chapter —
// coinflip.pbt and ritual-of-control.pbt open exactly like this.
private enum pbtIntro =
    "# A ritual whose whole job is to watch CI it cannot influence.\n" ~
    "\n" ~
    "scope {\n" ~
    "  event: \"PostToolUse\"\n" ~
    "}\n";

private enum chPbtIntro = parseChapter("coin", pbtIntro, Lang.pbt);

static assert(chPbtIntro.intro == "# A ritual whose whole job is to watch CI it cannot influence.");
static assert(chPbtIntro.count == 1);

// A # comment inside a block belongs to the block: the rites of moon carry
// their comments with them onto the page.
private enum pbtInner =
    "rites sky {\n" ~
    "  # Starts every walk from nothing.\n" ~
    "  WIPE { eval: \"true\" }\n" ~
    "}\n";

private enum chInner = parseChapter("sky", pbtInner, Lang.pbt);

static assert(chInner.count == 1);
static assert(chInner.examples[0].code ==
    "rites sky {\n  # Starts every walk from nothing.\n  WIPE { eval: \"true\" }\n}");

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

// The fleet is counted the same way: standing controls and rites blocks.
static assert(countControls(pbtSample) == 1);
static assert(countControls(pbtQuoted) == 0);
static assert(countRitesBlocks(pbtSample) == 1);
static assert(countRitesBlocks(pbtQuoted) == 1);
static assert(countRitesBlocks("  rites indented {\n}\n") == 0);

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

// A pbt chapter's prose sheds its # the way a D chapter's sheds its //.
static assert(chapterTex(chPbt).count("The law above the block.") == 1);
static assert(chapterTex(chPbt).count("# The law") == 0);

// The book is one self-contained document: class, fonts, title page with the
// impression, parts holding chapters, colophon with the counts, the closing.
private Sink!65536 bookTex() {
    Chapter[1] pbtCs = [chPbt];
    Chapter[2] codeCs = [ch, chIntro];
    Part[2] parts = [Part("The Controls", pbtCs[]),
                     Part("Laws and Practices", codeCs[])];
    Sink!65536 k;
    renderBookInto(k, parts[], "v0.9.0-test", "2026-08-25",
                   Counts(313, 42, 7, 5));
    return k;
}

private enum book = bookTex();

static assert(book.count("\\documentclass") == 1);
static assert(book.count("\\begin{document}") == 1);
static assert(book.count("\\end{document}") == 1);
static assert(book.count("\\part{The Controls}") == 1);
static assert(book.count("\\part{Laws and Practices}") == 1);
static assert(book.count("\\chapter{law}") == 1);
static assert(book.count("\\chapter{x}") == 1);
static assert(book.count("\\chapter{y}") == 1);
static assert(book.count("The Book of Ground") == 1);
static assert(book.count("v0.9.0-test") == 1);
static assert(book.count("313") == 1);
static assert(book.count("42") == 1);
static assert(book.count("7 controls") == 1);
static assert(book.count("5 rites") == 1);
