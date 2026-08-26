module proto_span_test;

// CTFE tests — failure shows as a compile error.
//
// The parser keeps what it used to throw away. Every entity it parses
// carries two more slices of the input: `comment`, the # run immediately
// above its declaration, and `src`, the entity's own span, keyword through
// closing brace. One parser serves both consumers — enforcement reads the
// fields, presentation reads the prose and the verbatim block — so nothing
// downstream ever has cause to parse pbt again.

import proto : parsePbt;

// --- scope and control ---

private enum src1 =
    "# The law above the scope.\n" ~
    "# Its second line.\n" ~
    "scope {\n" ~
    "  event: \"PreToolUse\"\n" ~
    "\n" ~
    "  # What this control is for.\n" ~
    "  control {\n" ~
    "    name: \"x\"\n" ~
    "    cmd: \"git\"\n" ~
    "    msg: \"m\"\n" ~
    "  }\n" ~
    "}\n";

private enum r1 = parsePbt(src1);

// The comment run immediately above a declaration belongs to it, both lines.
static assert(r1.scopes[0].comment == "# The law above the scope.\n# Its second line.");
static assert(r1.ctrlPool[0].comment == "# What this control is for.");

// The span runs keyword through closing brace, verbatim.
static assert(r1.scopes[0].src[0 .. 7] == "scope {");
static assert(r1.scopes[0].src[$ - 1] == '}');
static assert(r1.ctrlPool[0].src[0 .. 9] == "control {");
static assert(r1.ctrlPool[0].src[$ - 1] == '}');

// The control's span sits inside the scope's span, because that is where
// the control sits.
static assert(r1.scopes[0].src.length > r1.ctrlPool[0].src.length);

// --- adjacency ---

// A blank line between a comment run and a declaration breaks the
// attachment: a file header belongs to the file, not to whatever block
// happens to come first.
private enum src2 =
    "# A file header, about everything below.\n" ~
    "\n" ~
    "scope {\n" ~
    "  event: \"Stop\"\n" ~
    "}\n";

private enum r2 = parsePbt(src2);

static assert(r2.scopes[0].comment == "");

// A blank line between two comment runs keeps them two runs — only the one
// touching the declaration attaches.
private enum src3 =
    "# Far away.\n" ~
    "\n" ~
    "# Touching.\n" ~
    "scope {\n" ~
    "  event: \"Stop\"\n" ~
    "}\n";

private enum r3 = parsePbt(src3);

static assert(r3.scopes[0].comment == "# Touching.");

// --- rites ---

private enum src4 =
    "# Above the group.\n" ~
    "rites sky {\n" ~
    "  # Starts every walk from nothing.\n" ~
    "  WIPE { eval: \"true\" }\n" ~
    "\n" ~
    "  MOON {\n" ~
    "    eval:  \"test -s MOON.md\"\n" ~
    "    catch: 1\n" ~
    "    msg:   \"Find out what phase the moon is in.\"\n" ~
    "  }\n" ~
    "}\n";

private enum r4 = parsePbt(src4);

static assert(r4.rites[0].comment == "# Above the group.");
static assert(r4.rites[0].src[0 .. 9] == "rites sky");
static assert(r4.rites[0].src[$ - 1] == '}');

// Each rite carries the comment above it and its own span, so a renderer
// can set moon's rites with their comments without reading the file again.
static assert(r4.rites[0].rites[0].comment == "# Starts every walk from nothing.");
static assert(r4.rites[0].rites[0].src[0 .. 4] == "WIPE");
static assert(r4.rites[0].rites[0].src[$ - 1] == '}');
static assert(r4.rites[0].rites[1].comment == "");
static assert(r4.rites[0].rites[1].src[0 .. 4] == "MOON");

// A rite's span holds its whole block even when values carry braces.
private enum src5 =
    "rites b {\n" ~
    "  W { eval: `curl -d \"{}\"` }\n" ~
    "}\n";

private enum r5 = parsePbt(src5);

static assert(r5.rites[0].rites[0].src == "W { eval: `curl -d \"{}\"` }");

// --- project ---

private enum src6 =
    "# Where the grove lives.\n" ~
    "project {\n" ~
    "  path: \"/teranos/ground\"\n" ~
    "}\n";

private enum r6 = parsePbt(src6);

static assert(r6.projects[0].comment == "# Where the grove lives.");
static assert(r6.projects[0].src[0 .. 9] == "project {");
static assert(r6.projects[0].src[$ - 1] == '}');
