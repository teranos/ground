module typeset_test;

// CTFE tests — failure shows as a compile error.

// "how to settle this forever?"
// A face named for fontconfig to find resolves differently on every machine.
// The book is set by the closure or it is not the same book twice.

import typeset : Decl, fontDecls, fromClosure, everyFontFromClosure,
                 withoutComments, setsAllRoles;

enum book = import("book.tex");

// The book sets three roles and every one of them comes from texlive.
static assert(fontDecls(book).length == 3);
static assert(setsAllRoles(book));
static assert(everyFontFromClosure(book));

// What stood here until tonight: Charter is a font macOS ships, and the Fira
// Code it names was a file installed by hand. Neither is in any closure.
enum wasThere = "\\setmainfont{Charter}[Mapping=]\n"
              ~ "\\setmonofont{Fira Code}[Scale=0.80]\n";
static assert(fontDecls(wasThere).length == 2);
static assert(!everyFontFromClosure(wasThere));
static assert(!setsAllRoles(wasThere), "no sans, so \\sffamily falls back");

// A declaration with no options cannot name a file for kpathsea to find.
static assert(fontDecls("\\setmainfont{Charter}\n").length == 1);
static assert(!everyFontFromClosure("\\setmainfont{Charter}\n"));

// One good declaration does not carry a bad one.
static assert(!everyFontFromClosure(
    "\\setmainfont{texgyreschola}[Extension=.otf]\n"
  ~ "\\setmonofont{Fira Code}[Scale=0.80]\n"));

// All three from the closure is the whole of what is asked.
enum settled = "\\setmainfont{texgyreschola}[Extension=.otf]\n"
             ~ "\\setsansfont{texgyreheros}[Extension=.otf]\n"
             ~ "\\setmonofont{IBMPlexMono}[Extension=.otf]\n";
static assert(everyFontFromClosure(settled));
static assert(setsAllRoles(settled));

// A commented declaration is not one. Left counted, a face could be disabled
// and still satisfy the check that was meant to guard it.
static assert(fontDecls("% \\setmainfont{Charter}[Mapping=]\n").length == 0);
static assert(fontDecls("  % \\setmonofont{Fira Code}[Scale=0.80]\n").length == 0);

// The options wrap across lines, the way the book's own do.
static assert(everyFontFromClosure(
    "\\setmainfont{texgyreschola}[Mapping=, Extension=.otf,\n"
  ~ "                            BoldFont=*-bold]\n"));

// Comments are dropped whole, and what is not a comment is kept as it stood.
static assert(withoutComments("a\n% b\nc\n") == "a\nc\n");
static assert(withoutComments("% only\n") == "");
static assert(withoutComments("") == "");

// One declaration, read field by field, so a failure says which part was wrong.
enum one = fontDecls("\\setsansfont{texgyreheros}[Extension=.otf, Scale=1.0]\n");
static assert(one.length == 1);
static assert(one[0].command == "\\setsansfont");
static assert(one[0].bracketed);
static assert(one[0].options == "Extension=.otf, Scale=1.0");
static assert(fromClosure(one[0]));

// A face that resolves through fontconfig is the one shape this refuses.
enum bad = fontDecls("\\setmonofont{SF Mono}[Scale=0.9]\n");
static assert(bad.length == 1);
static assert(bad[0].bracketed);
static assert(!fromClosure(bad[0]));
