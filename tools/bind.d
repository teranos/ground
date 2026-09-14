module bind;

// The pure half of the binder. A leaf is one sheet of the printed book and the
// number set on it. The web copy is bound from the typeset pages themselves,
// so a page cannot come to hold something the paper does not.

struct Leaf {
    size_t sheet;
    string folio;
}

// What the typesetter wrote as it shipped each sheet.
Leaf[] parseFolios(string text) {
    Leaf[] out_;
    size_t i = 0;
    while (i <= text.length) {
        size_t start = i;
        while (i < text.length && text[i] != '\n') i++;
        auto line = text[start .. i];
        i++;

        size_t p = 0;
        size_t n = 0;
        while (p < line.length && line[p] >= '0' && line[p] <= '9') {
            n = n * 10 + (line[p] - '0');
            p++;
        }
        if (p == 0) continue;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
        if (p >= line.length) continue;
        out_ ~= Leaf(n, line[p .. $]);
    }
    return out_;
}

// The sheet carrying a printed number. Zero when the book has no such page.
size_t sheetOf(Leaf[] leaves, string folio) {
    if (folio.length == 0) return 0;
    foreach (l; leaves) if (l.folio == folio) return l.sheet;
    return 0;
}

// The two sheets seen at once. Zero on either side is the cover.
struct Spread {
    size_t left;
    size_t right;
}

// A book falls open on the back of one leaf and the front of the next. The
// first sheet is the front of the first leaf, so nothing faces it.
Spread spreadOf(Leaf[] leaves, string folio) {
    auto n = sheetOf(leaves, folio);
    if (n == 0) return Spread(0, 0);
    if (n == 1) return Spread(0, 1);
    auto left = (n % 2 == 0) ? n : n - 1;
    auto right = left + 1;
    if (!carries(leaves, right)) right = 0;
    return Spread(left, right);
}

private bool carries(Leaf[] leaves, size_t sheet) {
    foreach (l; leaves) if (l.sheet == sheet) return true;
    return false;
}

string escapeHtml(string s) {
    string out_;
    foreach (c; s) {
        if (c == '&')  { out_ ~= "&amp;";  continue; }
        if (c == '<')  { out_ ~= "&lt;";   continue; }
        if (c == '>')  { out_ ~= "&gt;";   continue; }
        if (c == '"')  { out_ ~= "&quot;"; continue; }
        if (c == '\'') { out_ ~= "&#39;";  continue; }
        out_ ~= c;
    }
    return out_;
}

// A left hand and a right hand turning the leaf. The key reads the href off
// the link rather than carrying a folio of its own, so a key and a click can
// never disagree about which leaf comes next.
private enum turnKeys =
    "<script>\n"
  ~ "document.addEventListener(\"keydown\", function (e) {\n"
  ~ "  if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;\n"
  ~ "  var rel = e.key === \"ArrowLeft\" ? \"prev\"\n"
  ~ "          : e.key === \"ArrowRight\" ? \"next\" : \"\";\n"
  ~ "  if (rel === \"\") return;\n"
  ~ "  var a = document.querySelector(\"nav.turn a[rel=\" + rel + \"]\");\n"
  ~ "  if (!a) return;\n"
  ~ "  e.preventDefault();\n"
  ~ "  location.href = a.getAttribute(\"href\");\n"
  ~ "});\n"
  ~ "</script>\n";

// One spread, carried whole, with the spreads either side of it.
string pageHtml(string folio, string verso, string recto,
                string prev, string next, size_t total) {
    string turn = "<nav class=\"turn\">\n";
    turn ~= prev.length > 0
        ? "<a rel=\"prev\" href=\"" ~ escapeHtml(prev) ~ ".html\">Previous</a>\n"
        : "<span></span>\n";
    turn ~= "<a href=\"index.html\">Contents</a>\n";
    turn ~= next.length > 0
        ? "<a rel=\"next\" href=\"" ~ escapeHtml(next) ~ ".html\">Next</a>\n"
        : "<span></span>\n";
    turn ~= "</nav>\n";

    string spread = "<div class=\"spread\">\n";
    spread ~= verso.length > 0 ? verso ~ "\n" : "<div class=\"cover\"></div>\n";
    spread ~= recto.length > 0 ? recto ~ "\n" : "<div class=\"cover\"></div>\n";
    spread ~= "</div>\n";

    return head("Book of Ground: " ~ folio)
        ~ spread
        ~ turn
        ~ "<p class=\"folio\">" ~ escapeHtml(folio) ~ " of " ~ numeral(total) ~ "</p>\n"
        ~ turnKeys
        ~ "</body>\n</html>\n";
}

// Every leaf, by the number printed on it.
string indexHtml(Leaf[] leaves, string commit, string built) {
    string list;
    foreach (l; leaves)
        list ~= "<li><a href=\"" ~ escapeHtml(l.folio) ~ ".html\">"
             ~ escapeHtml(l.folio) ~ "</a></li>\n";

    string prov;
    if (commit.length > 0 || built.length > 0) {
        prov = "<dl class=\"prov\">\n";
        if (commit.length > 0)
            prov ~= "<dt>commit</dt><dd>" ~ escapeHtml(commit) ~ "</dd>\n";
        if (built.length > 0)
            prov ~= "<dt>built</dt><dd>" ~ escapeHtml(built) ~ "</dd>\n";
        prov ~= "</dl>\n";
    }

    return head("Book of Ground")
        ~ "<div class=\"title\">\n<h1>Book of Ground</h1>\n"
        ~ "<p class=\"draft\">draft</p>\n" ~ prov ~ "</div>\n"
        ~ "<nav class=\"pages\">\n<h2>Pages</h2>\n<ul>\n" ~ list ~ "</ul>\n</nav>\n"
        ~ "</body>\n</html>\n";
}

private string head(string title) {
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        ~ "<meta charset=\"utf-8\">\n"
        ~ "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        ~ "<title>" ~ escapeHtml(title) ~ "</title>\n"
        ~ "<style>\n" ~ CSS ~ "</style>\n</head>\n<body>\n";
}

private string numeral(size_t n) {
    if (n == 0) return "0";
    char[20] buf;
    size_t len = 0;
    while (n > 0 && len < buf.length) { buf[len++] = cast(char)('0' + n % 10); n /= 10; }
    string out_;
    foreach_reverse (i; 0 .. len) out_ ~= buf[i];
    return out_;
}

// The sheet arrives already laid out, down to the point. Nothing here may set
// type: it draws the paper the leaves sit on and the way to the next spread.
// A line is placed against its own page, so the page is what it is placed in.
// "For some reason it feels like I want to be able to look at the CSS separately"
// "css should be shared. there ought to be a tokens.css"
// The palette is doc/tokens.css, shared with the author's tool; the rest is
// doc/book.css. Both are read at build, and each page carries its own copy.
private enum CSS = import("tokens.css") ~ import("book.css");
