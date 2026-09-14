module bind_test;

// CTFE tests — failure shows as a compile error.

import bind : Leaf, Spread, parseFolios, sheetOf, spreadOf, pageHtml, indexHtml;

private bool has(string hay, string needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}

// What the typesetter wrote: the sheet it shipped, and the number it printed
// on that sheet. Front matter is numbered apart, so the two never agree.
enum map = "1 i\n2 ii\n3 1\n4 2\n5 3\n";
enum leaves = parseFolios(map);

static assert(leaves.length == 5);
static assert(leaves[0].sheet == 1);
static assert(leaves[0].folio == "i");
static assert(leaves[2].sheet == 3);
static assert(leaves[2].folio == "1");

// "the person can open page 12 on the web and this person would be looking at
// the same page 12 i am looking at physically"
static assert(sheetOf(leaves, "1") == 3);
static assert(sheetOf(leaves, "3") == 5);
static assert(sheetOf(leaves, "i") == 1);

// A number nobody printed is not a page of this book.
static assert(sheetOf(leaves, "9") == 0);
static assert(sheetOf(leaves, "") == 0);

// A blank line is not a leaf, and neither is a line missing half of itself.
static assert(parseFolios("1 i\n\n2 ii\n").length == 2);
static assert(parseFolios("1\n").length == 0);
static assert(parseFolios("").length == 0);

// "why not two pages"
// A book falls open on two. The first sheet has nothing to its left, because
// it is the front of the first leaf and the reader's left hand holds the cover.
enum many = parseFolios("1 i\n2 ii\n3 1\n4 2\n5 3\n6 4\n");

static assert(spreadOf(many, "i").left == 0);
static assert(spreadOf(many, "i").right == 1);

// Everything after it faces its neighbour: the back of one leaf and the front
// of the next are seen together.
static assert(spreadOf(many, "ii").left == 2);
static assert(spreadOf(many, "ii").right == 3);
static assert(spreadOf(many, "1").left == 2);
static assert(spreadOf(many, "1").right == 3);
static assert(spreadOf(many, "2").left == 4);
static assert(spreadOf(many, "2").right == 5);

// A page asked for by a number the book does not print opens nothing.
static assert(spreadOf(many, "99").right == 0);

// The last sheet of an odd-length book has nothing facing it.
enum odd = parseFolios("1 i\n2 ii\n3 1\n");
static assert(spreadOf(odd, "1").left == 2);
static assert(spreadOf(odd, "1").right == 3);
enum shortRun = parseFolios("1 i\n2 ii\n");
static assert(spreadOf(shortRun, "ii").right == 0);

// The sheets are carried whole, exactly as the typesetter laid them out.
enum verso = "<div id=\"page1\" style=\"width:498.9pt;height:708.7pt\"><p>scope {</p></div>";
enum recto = "<div id=\"page1\" style=\"width:498.9pt;height:708.7pt\"><p>control {</p></div>";
enum page = pageHtml("10", verso, recto, "8", "12", 26);

static assert(has(page, "<title>Book of Ground: 10</title>"));
static assert(has(page, "width:498.9pt;height:708.7pt"));
static assert(has(page, "scope {"));
static assert(has(page, "control {"));
static assert(has(page, `href="8.html"`));
static assert(has(page, `href="12.html"`));
static assert(has(page, `href="index.html"`));

// The leaf says which one it is, so whoever lands on it can tell.
static assert(has(page, "10 of 26"));

// A line sits where it was set, which it cannot do without something to sit
// against. Dropping these put every line of the book on top of the page.
static assert(has(page, "position: relative"));
static assert(has(page, "position: absolute"));
static assert(has(page, "white-space: pre"));

// Nothing precedes the first spread and nothing follows the last.
enum only = pageHtml("i", "", recto, "", "", 1);
static assert(!has(only, ".html\">Previous"));
static assert(!has(only, ".html\">Next"));
static assert(has(only, "control {"));

// "L and R arrows should navigate the book on html"
// The key turns to wherever the link points, so the two can never disagree.
static assert(has(page, `rel="prev"`));
static assert(has(page, `rel="next"`));
static assert(has(page, "ArrowLeft"));
static assert(has(page, "ArrowRight"));

// A page with nothing either side offers no link, so no key turns from it.
static assert(!has(only, `rel="prev"`));
static assert(!has(only, `rel="next"`));

// Every leaf is reachable by the number printed on it.
enum idx = indexHtml(leaves, "abc1234", "2026-08-29T00:00:00Z");
static assert(has(idx, "<title>Book of Ground</title>"));
static assert(has(idx, `href="i.html"`));
static assert(has(idx, `href="1.html"`));
static assert(has(idx, "abc1234"));
static assert(has(idx, "2026-08-29T00:00:00Z"));

// A book nobody can read offline is not the book.
static assert(!has(page, "http://"));
static assert(!has(idx, "https://"));
