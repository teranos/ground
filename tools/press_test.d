module press_test;

// CTFE tests for what press sets. Failure shows as a compile error.

import press : renderGlossary;
import cases : Entry;

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
