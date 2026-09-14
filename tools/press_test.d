module press_test;

// CTFE tests for what press sets. Failure shows as a compile error.

import press : renderGlossary, chapterFor;
import cases : Entry, Case;

// "try to increase coverage"
// A pbt example is placed by its block word. A case with none is placed by
// the chapter that owns its module, and only when the operator's words stand
// above it; without either it stays off the page.
static assert(chapterFor(Case("f", "", false, "scope {\n  path: \"/x\"\n}", ""), "zbuf") == "scope");
static assert(chapterFor(Case("f", "", false, "", "", `"so"`), "matcher") == "scope");
static assert(chapterFor(Case("f", "", false, "", "", ""), "matcher") == "");
static assert(chapterFor(Case("f", "", false, "", "", `"so"`), "zbuf") == "");

// "why not like this:"
// A row with a quote sets it hung above, between the example and the note.
// A row without one is the two columns it always was.
// "can you see the issue i spot here?"
// The card and its row are one box, so a page never falls between them.
import press : renderBody, Placed;
enum hung = renderBody([Placed(0, "f.d", Case("f", "", false, "scope {\n}", "Why.", `"so"`))]);
static assert(hung ==
    "\n\\par\\noindent\\begin{minipage}{\\textwidth}\n"
    ~ "\\gsaidprep{\"so\"}\n"
    ~ "\\noindent\\begin{minipage}[t]{\\gpbtw}\n"
    ~ "\\begin{gcode}\nscope {\n}\n\\end{gcode}\n"
    ~ "\\end{minipage}\\hfill\n"
    ~ "\\begin{minipage}[t]{\\gnotew}\n"
    ~ "\\gsaidhung\\gnote{Why.}\n"
    ~ "\\end{minipage}\n"
    ~ "\\end{minipage}\n\\par\\vspace{10pt}\n");

// "arent most of these just D code ?"
// The proof of a case with no pbt is D about names a control author never
// meets. The page names the symbol proved and keeps the D in the source.
enum proved = renderBody([Placed(0, "f.d", Case("step", "", false, "", "Why.", `"so"`))]);
static assert(proved ==
    "\n\\par\\noindent\\begin{minipage}{\\textwidth}\n"
    ~ "\\gsaidprep{\"so\"}\n"
    ~ "\\noindent\\begin{minipage}[t]{\\gpbtw}\n"
    ~ "\\gproved{step}\n"
    ~ "\\end{minipage}\\hfill\n"
    ~ "\\begin{minipage}[t]{\\gnotew}\n"
    ~ "\\gsaidhung\\gnote{Why.}\n"
    ~ "\\end{minipage}\n"
    ~ "\\end{minipage}\n\\par\\vspace{10pt}\n");
enum plain = renderBody([Placed(0, "f.d", Case("f", "", false, "scope {\n}", "Why.", ""))]);
static assert(plain ==
    "\n\\par\\noindent\n"
    ~ "\\begin{minipage}[t]{\\gpbtw}\n"
    ~ "\\begin{gcode}\nscope {\n}\n\\end{gcode}\n"
    ~ "\\end{minipage}\\hfill\n"
    ~ "\\begin{minipage}[t]{\\gnotew}\n"
    ~ "\\gnote{Why.}\n"
    ~ "\\end{minipage}\n\\par\\vspace{10pt}\n");

// "tha page should be two cols"
// "scope, control, project and ritual and attestation should each be their own col width sized things"
// "the defintion should be in a subcol next to the term."
// "the first definiton and the name of the chapter seem to always be consitently the same"
// "make one definition be the main definition, and be the other terms be sub's of that"
// The term that is the chapter's word heads the section; the rest are its subs.
enum one = renderGlossary(["scope"],
    ["matcher": [Entry("Scope", "Where a rule stands."), Entry("Scratch", "A directory.")]]);
static assert(one ==
    "\\chapter{glossary}\n\n\\begin{gcolumns}\n"
    ~ "\\begin{gglossary}\n"
    ~ "\\gmain{Scope}{Where a rule stands.}\n"
    ~ "\\gterm{Scratch}{A directory.}\n"
    ~ "\\end{gglossary}\n\n"
    ~ "\\end{gcolumns}\n");

// The main term heads the section wherever its module put it.
static assert(renderGlossary(["scope"],
    ["matcher": [Entry("Scratch", "A directory."), Entry("Scope", "Where a rule stands.")]]) == one);

// A chapter with no term has no section, and no term at all is no chapter.
static assert(renderGlossary(["scope", "control"],
    ["matcher": [Entry("Scope", "Where a rule stands."), Entry("Scratch", "A directory.")]]) == one);
static assert(renderGlossary(["scope"], ["hooks": [Entry("Control", "x")]]) == "");

// "book should have a page about the ground subcommands and ug and wind as well"
// "this style: ground shovel PostToolUse "*pr create*" also tells you everything you need to know"
// The chapter is the shell blocks, set as code, one after the other. No
// note beside them: the example is the whole entry.
import press : renderCommands, dispatched, verbsOf, inDispatchOrder, renderSkill;
enum blocks = ["# timing table:\nground profile\n", "# the watcher:\nground watch $PWD\n"];
static assert(renderCommands(blocks) ==
    "\\chapter{commands}\n"
    ~ "\n\\begin{gcode}\n# timing table:\nground profile\n\\end{gcode}\n\\vspace{10pt}\n"
    ~ "\n\\begin{gcode}\n# the watcher:\nground watch $PWD\n\\end{gcode}\n\\vspace{10pt}\n");
static assert(renderCommands([]) == "");

// What main.d answers to is read from main.d, so a command the book names
// exists and a command that exists is in the book.
static assert(dispatched("if (cmd == \"shovel\")\n  return x;\nif (cmd == \"fmt\") {\n") == ["shovel", "fmt"]);

// The verbs a block runs: the word after ground on each command line. A
// comment line names none, and a bare ground is the binary itself.
static assert(verbsOf("# search\nground shovel PostToolUse \"*x*\"\n# or\nground shovel session s\n") == ["shovel", "shovel"]);
static assert(verbsOf("ground < event.json\n") == [""]);

// The page lists the blocks in the order main.d answers to their verbs,
// the binary itself first, whatever order the files were read in.
enum ordered = inDispatchOrder(["ground fmt x\n", "ground shovel a b\n", "ground < e\n"], ["shovel", "fmt"]);
static assert(ordered[0] == "ground < e\n");
static assert(ordered[1] == "ground shovel a b\n");
static assert(ordered[2] == "ground fmt x\n");

// "maybe it should just move out of the claude.md and into a skill and that press creates the skill"
// The skill is the same blocks in one shell fence, under the front matter a
// skill carries, and nothing else.
static assert(renderSkill(blocks) ==
    "---\nname: ground-commands\n"
    ~ "description: Every ground subcommand with a working example. Written by press from the modules that implement them.\n"
    ~ "---\n\n```sh\n# timing table:\nground profile\n\n# the watcher:\nground watch $PWD\n```\n");

// "the term should be bold."
// press names the parts and book.tex sets them, so the term is escaped as a
// word here, and made bold there. A chapter none of whose terms is its word
// keeps the word as a heading over them.
enum braces = renderGlossary(["ritual"], ["rite": [Entry("Rites block", "rites{ .. }")]]);
static assert(braces ==
    "\\chapter{glossary}\n\n\\begin{gcolumns}\n"
    ~ "\\gsection{ritual}\n\\begin{gglossary}\n"
    ~ "\\gterm{Rites block}{rites\\{ .. \\}}\n"
    ~ "\\end{gglossary}\n\n"
    ~ "\\end{gcolumns}\n");
