module cases_test;

// CTFE tests for the pure half of press: finding the cases a test module
// already states, and rendering them as ddoc macros. Failure shows as a
// compile error from static assert.

import cases : extractCases, renderCase, caseName, subject, flow;

// The symbol under test is the first thing the assertion calls.
static assert(subject(`static assert(sessionMatches("m", "default"));`) == "sessionMatches");
static assert(subject(`assert(maxCommentRun("") == 0);`) == "maxCommentRun");

// A negated assertion is about the same symbol as a positive one.
static assert(subject(`static assert(!isWord(one, sp));`) == "isWord");

// Indentation does not change what is being asserted.
static assert(subject(`    static assert(standsAlone("x"));`) == "standsAlone");

// A line that asserts nothing names nothing.
static assert(subject("// a comment") == "");
static assert(subject("") == "");

// A case is the comment that explains it plus the assertions it explains.
// The comment is what makes an assertion readable, so a block without one is
// still a case and a comment without assertions is not.
enum one = extractCases(
    "// Manual arrives as default and never as manual.\n" ~
    `static assert(sessionMatches("m", "default"));` ~ "\n" ~
    `static assert(!sessionMatches("m", "acceptEdits"));` ~ "\n");
static assert(one.length == 1);
static assert(one[0].subject == "sessionMatches");
static assert(one[0].text ==
    "// Manual arrives as default and never as manual.\n" ~
    `static assert(sessionMatches("m", "default"));` ~ "\n" ~
    `static assert(!sessionMatches("m", "acceptEdits"));`);

// A blank line ends a case. Two paragraphs of assertions are two cases, and
// running them together would attach one comment to assertions it never made.
enum two = extractCases(
    "// First.\n" ~
    "static assert(a(1));\n" ~
    "\n" ~
    "// Second.\n" ~
    "static assert(b(2));\n");
static assert(two.length == 2);
static assert(two[0].subject == "a");
static assert(two[1].subject == "b");
static assert(two[1].text == "// Second.\nstatic assert(b(2));");

// Prose with no assertion under it is a heading. It is where the file says
// what the next stretch is about, and dropping it loses the only structure
// the author put in.
enum head = extractCases("// --- where a command actually ran ---\n// The session cwd alone was wrong.\n\n");
static assert(head.length == 1);
static assert(head[0].heading);
static assert(head[0].text ==
    "// --- where a command actually ran ---\n" ~
    "// The session cwd alone was wrong.");

// A case is not a heading.
enum notHead = extractCases("// A case.\nstatic assert(f(1));\n");
static assert(!notHead[0].heading);

// Code that is not an assertion ends the block, so a case never swallows the
// setup that happens to sit beneath it.
enum mixed = extractCases(
    "// A case.\n" ~
    "static assert(f(1));\n" ~
    "auto x = 3;\n" ~
    "static assert(g(2));\n");
static assert(mixed.length == 2);
static assert(mixed[0].text == "// A case.\nstatic assert(f(1));");
static assert(mixed[1].text == "static assert(g(2));");

// Inside a unittest the whole block is indented, and printing that indent
// would put every example in the book four columns further right than the
// last. The common indent comes off, and relative indent stays.
enum indented = extractCases(
    "    // Indented.\n" ~
    "    static assert(h(1));\n" ~
    "        static assert(h(2));\n");
static assert(indented.length == 1);
static assert(indented[0].text ==
    "// Indented.\n" ~
    "static assert(h(1));\n" ~
    "    static assert(h(2));");

// A pbt example and what is proved about it are one unit. The block literal
// spans lines and belongs to the assertions under it, so a case carries both
// and a reader sees the control before the facts about it.
enum lesson = extractCases(
    "// One scope, one control.\n" ~
    "enum singlePathInput = `\n" ~
    "scope {\n" ~
    `  path: "/ground"` ~ "\n" ~
    "}\n" ~
    "`;\n" ~
    "enum singlePathParsed = parsePbt(singlePathInput);\n" ~
    "static assert(singlePathParsed.scopeCount == 1);\n");
static assert(lesson.length == 1);
static assert(lesson[0].text ==
    "// One scope, one control.\n" ~
    "enum singlePathInput = `\n" ~
    "scope {\n" ~
    `  path: "/ground"` ~ "\n" ~
    "}\n" ~
    "`;\n" ~
    "enum singlePathParsed = parsePbt(singlePathInput);\n" ~
    "static assert(singlePathParsed.scopeCount == 1);");

// A block holding a pbt example is named for the example, so each one is
// addressable. Without it every lesson would pile up under parsePbt.
static assert(lesson[0].subject == "singlePathInput");

// A blank line between an example and its proof does not separate them. Test
// modules put one there for readability, and ending the block on it threw the
// example away and kept only the assertions.
enum split = extractCases(
    "enum contentInput = `\n" ~
    "scope {\n" ~
    "}\n" ~
    "`;\n" ~
    "enum contentParsed = parsePbt(contentInput);\n" ~
    "\n" ~
    "static assert(binaryGateApplies(contentParsed) == false);\n");
static assert(split.length == 1);
static assert(split[0].subject == "contentInput");
static assert(split[0].text ==
    "enum contentInput = `\n" ~
    "scope {\n" ~
    "}\n" ~
    "`;\n" ~
    "enum contentParsed = parsePbt(contentInput);\n" ~
    "\n" ~
    "static assert(binaryGateApplies(contentParsed) == false);");

// A second example starts a second case rather than joining the first.
enum twoEx = extractCases(
    "enum a = `x`;\n" ~
    "static assert(f(a));\n" ~
    "\n" ~
    "enum b = `y`;\n" ~
    "static assert(f(b));\n");
static assert(twoEx.length == 2);
static assert(twoEx[0].subject == "a");
static assert(twoEx[1].subject == "b");

// The example is the pbt, not the D that carries it. A reader writing a
// control needs the block, not the enum it was assigned to.
enum lifted = extractCases(
    "// A repo whose content IS the binaries declares itself.\n" ~
    "enum contentInput = `\n" ~
    "scope {\n" ~
    `  path: "/dossier"` ~ "\n" ~
    "}\n" ~
    "`;\n" ~
    "static assert(f(contentInput));\n");
static assert(lifted.length == 1);
static assert(lifted[0].pbt ==
    "scope {\n" ~
    `  path: "/dossier"` ~ "\n" ~
    "}");

// The prose above the example comes with it, and carries no marker.
static assert(lifted[0].prose == "A repo whose content IS the binaries declares itself.");

// No literal, no example.
enum noPbt = extractCases("// Just this.\nstatic assert(f(1));\n");
static assert(noPbt[0].pbt == "");
static assert(noPbt[0].prose == "Just this.");

// A block with no pbt example is still named for what it asserts.
enum plain = extractCases("static assert(sessionMatches(\"m\", \"default\"));\n");
static assert(plain[0].subject == "sessionMatches");

// A unittest is one case, whole. Its setup is what makes the assertion mean
// anything, and keeping only the assert lines throws away the command that
// went in and the comment that says who is doing what.
enum block = extractCases(
    "unittest {\n" ~
    "    // Major Tom tries --no-verify.\n" ~
    "    auto result = checkCommand(`git commit --no-verify`, OTHER);\n" ~
    "    auto amended = applyOmit(result.control, result.segment);\n" ~
    "    assert(amended.slice() == `git commit`);\n" ~
    "}\n");
static assert(block.length == 1);
static assert(block[0].text ==
    "// Major Tom tries --no-verify.\n" ~
    "auto result = checkCommand(`git commit --no-verify`, OTHER);\n" ~
    "auto amended = applyOmit(result.control, result.segment);\n" ~
    "assert(amended.slice() == `git commit`);");

// It is named for what it exercises, which is the first call it makes.
static assert(block[0].subject == "checkCommand");

// A unittest that asserts nothing is scaffolding.
static assert(extractCases("unittest {\n    setUp();\n}\n").length == 0);

// Every case for one symbol lands under one name.
static assert(caseName("sessionMatches") == "EX_SESSIONMATCHES");
static assert(caseName("maxCommentRun") == "EX_MAXCOMMENTRUN");

// Rendered as a ddoc macro, continuation lines indented by one space so ddoc
// reads them as one definition. gcode gobbles that space back off.
static assert(renderCase("f", "// A case.\nstatic assert(f(1));") ==
    "EX_F =\n" ~
    " \\begin{gcode}\n" ~
    " // A case.\n" ~
    " static assert(f(1));\n" ~
    " \\end{gcode}\n\n");

// "the first one should be about control as a concept"
// A chapter opens on a paragraph. Where a source comment wraps is a width the
// editor chose, and carrying those breaks onto the page sets prose as a list.
static assert(flow("// A control is a named rule\n// and a message.") ==
    "A control is a named rule and a message.");

// One line is already a paragraph.
static assert(flow("// A control is a named rule.") == "A control is a named rule.");

// A ddoc line is prose too, and its third slash is marker rather than text.
static assert(flow("/// A permission answers a tool call.") == "A permission answers a tool call.");

// A blank line is where the author did mean a break, so it ends the paragraph.
static assert(flow("// One.\n//\n// Two.") == "One.\n\nTwo.");

// Nothing to set is nothing on the page.
static assert(flow("") == "");

// A comment after something proved opens the next case rather than joining
// the one just proved. Every note was landing an example early.
enum pair = extractCases(
    "// About x.\n" ~
    "enum x = `scope { }`;\n" ~
    "static assert(f(x));\n" ~
    "\n" ~
    "// About y.\n" ~
    "enum y = `control { }`;\n" ~
    "static assert(g(y));\n");

static assert(pair.length == 2);
static assert(pair[0].prose == "About x.");
static assert(pair[1].prose == "About y.");
static assert(pair[0].pbt == "scope { }");
static assert(pair[1].pbt == "control { }");
