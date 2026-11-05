module notes_test;

// CTFE tests for the book's notes. Failure shows as a compile error.

import notes : readNote, NoteFile, Note, CaseRef, joinNotes, flowText, refuseEntry;

// "i expect to edit the book of ground by linking it via obsidia"
// A chapter's note file is its opening, then one section per case under the
// case's name. The opening is everything before the first `## `.
enum two = readNote("doc/book/scope.md", "scope",
    "A scope is where a rule stands.\n\nIt carries a path.\n\n## matcher-scopeAllow\nWhy it holds.\n\n## matcher-scopeDeny\n");
static assert(two.refused.length == 0);
static assert(flowText(two.opening) == "A scope is where a rule stands.\n\nIt carries a path.");
static assert(two.notes.length == 2);
static assert(two.notes[0] == Note("matcher-scopeAllow", "scope", "doc/book/scope.md", 5, ["Why it holds.", ""]));
// A section with nothing under it is a case with no note beside it.
static assert(two.notes[1].name == "matcher-scopeDeny" && flowText(two.notes[1].lines) == "");

// Lines join into a paragraph, as a comment's did: where a line wraps is the
// width of whatever it was typed in. A blank line is a paragraph break.
static assert(flowText(["One", "two.", "", "", "Three."]) == "One two.\n\nThree.");
static assert(flowText(["  Indented  "]) == "Indented");

// `## ` is only ever a case's name. Any other heading is refused, so a name and
// a heading cannot be taken for each other, and the line says what to write.
enum h1 = readNote("doc/book/scope.md", "scope", "Opening.\n# Scope\n");
static assert(h1.refused == ["doc/book/scope.md:2: `# Scope` is a heading, and the book sets none from a note. "
    ~ "A chapter opens on the text before its first `## `, and `## <name>` only ever names a case. Write it as a sentence."]);
static assert(readNote("doc/book/scope.md", "scope", "### Sub\n").refused.length == 1);
static assert(readNote("doc/book/scope.md", "scope", "##\n").refused == ["doc/book/scope.md:1: `##` names no case. "
    ~ "Write after it the name a case carries on its `// book:` line in source."]);

// Paragraphs of text are the subset. A construct outside it would be set as
// its characters, so it is refused with what to write instead.
static assert(readNote("doc/book/scope.md", "scope", "Text.\n- an item\n").refused == ["doc/book/scope.md:2: `- an item` is a markdown list, "
    ~ "and a note is paragraphs of text. Write it as a sentence."]);
static assert(readNote("f.md", "scope", "```\nx\n```\n").refused.length == 2);
static assert(readNote("f.md", "scope", "> quoted\n").refused.length == 1);
static assert(readNote("f.md", "scope", "| a | b |\n").refused.length == 1);
static assert(readNote("f.md", "scope", "* item\n").refused.length == 1);
static assert(readNote("f.md", "scope", "1. first\n").refused.length == 1);
static assert(readNote("f.md", "scope", "<div>\n").refused.length == 1);
// What only looks like one at a glance is text.
static assert(readNote("f.md", "scope", "1.5 seconds.\n*x* stays.\n\"a quote\"\n").refused.length == 0);

// Every case the book sets is one name in source and one section in a note.
enum notesHere = [Note("m-f", "scope", "doc/book/scope.md", 3, ["Why."])];
static assert(joinNotes([CaseRef("source/m_test.d", 10, "scope", "m-f")], notesHere).length == 0);

// A case the book sets with no `// book:` line.
static assert(joinNotes([CaseRef("source/m_test.d", 10, "scope", "")], []) == [
    "source/m_test.d:10: the book sets this case in scope and it names no note. "
    ~ "Add `// book: <name>` above it, and `## <name>` with its note in doc/book/scope.md."]);

// A `// book:` name no note has. This is what a renamed heading leaves behind.
static assert(joinNotes([CaseRef("source/m_test.d", 10, "scope", "m-g")], notesHere) == [
    "source/m_test.d:10: `// book: m-g` names no note: doc/book/scope.md has no `## m-g`. "
    ~ "Add that heading there, or rename this line to a `## ` name that file has.",
    "doc/book/scope.md:3: `## m-f` names no case: no `// book: m-f` line is in source. "
    ~ "Rename the heading back to the name a case carries, or remove its section."]);

// A note set under another chapter than its case.
static assert(joinNotes([CaseRef("source/m_test.d", 10, "control", "m-f")], notesHere) == [
    "doc/book/scope.md:3: `## m-f` is the note of a case the book sets in control (source/m_test.d:10). "
    ~ "Move the section to doc/book/control.md."]);

// A name is one case's, at both ends.
static assert(joinNotes([CaseRef("source/a_test.d", 1, "scope", "m-f"), CaseRef("source/b_test.d", 2, "scope", "m-f")], notesHere) == [
    "source/b_test.d:2: `// book: m-f` is also source/a_test.d:1, and a name is one case's. "
    ~ "Rename one, and its `## ` heading in doc/book/scope.md with it."]);
static assert(joinNotes([CaseRef("source/m_test.d", 10, "scope", "m-f")],
    notesHere ~ Note("m-f", "scope", "doc/book/scope.md", 9, [])) == [
    "doc/book/scope.md:9: `## m-f` is also doc/book/scope.md:3, and a name is one case's. "
    ~ "Remove one of the two sections."]);

// What the vault binds is the notes directly in doc/book/: nothing in a folder
// inside it, nothing but .md, and a file per chapter the book has.
enum chs = ["scope", "control"];
static assert(refuseEntry("doc/book/scope.md", false, chs) == "");
static assert(refuseEntry("doc/book/old", true, chs) == "doc/book/old: a folder inside doc/book/ is not the book's, "
    ~ "as the vault binds doc/book/ alone. Move its notes up into doc/book/.");
static assert(refuseEntry("doc/book/a.png", false, chs) == "doc/book/a.png: only .md notes are the book's. "
    ~ "Remove it from doc/book/.");
static assert(refuseEntry("doc/book/scoep.md", false, chs) == "doc/book/scoep.md names no chapter. "
    ~ "Name it for one of: scope, control.");
