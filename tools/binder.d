/// binder, the tool that binds the web copy from the printed sheets.
///
/// The pages come out of book.pdf, not out of book.tex a second time. A page
/// asked for by the number set on the paper is that page, because it is the
/// same typesetting rather than another one that agrees today.

import std.file : readText, write, exists, mkdirRecurse, remove;
import std.process : executeShell, environment;
import std.stdio : stderr;

import bind : Leaf, Spread, parseFolios, sheetOf, spreadOf, pageHtml, indexHtml;

enum PDF = "doc/book.pdf";
enum MAP = "doc/book.folios";
enum OUT = "doc/html";

void main() {
    if (!exists(PDF) || !exists(MAP)) {
        stderr.writefln("binder: no %s or %s — run the pdf first", PDF, MAP);
        return;
    }

    auto leaves = parseFolios(readText(MAP));
    if (leaves.length == 0) {
        stderr.writeln("binder: the folio map names no page");
        return;
    }

    mkdirRecurse(OUT);
    enum scratch = OUT ~ "/.sheet.html";

    // Each sheet is lifted once, however many spreads show it.
    string[size_t] sheets;
    foreach (l; leaves) {
        auto cmd = "mutool convert -F html -o " ~ scratch ~ " " ~ PDF
                 ~ " " ~ numeral(l.sheet);
        auto r = executeShell(cmd);
        if (r.status != 0) {
            stderr.writefln("binder: mutool exited %d on sheet %d", r.status, l.sheet);
            continue;
        }
        auto page = liftPage(readText(scratch));
        if (page.length == 0) {
            stderr.writefln("binder: sheet %d came back empty", l.sheet);
            continue;
        }
        sheets[l.sheet] = page;
    }

    size_t bound = 0;
    foreach (i, l; leaves) {
        auto s = spreadOf(leaves, l.folio);
        write(OUT ~ "/" ~ l.folio ~ ".html",
              pageHtml(l.folio,
                       s.left in sheets ? sheets[s.left] : "",
                       s.right in sheets ? sheets[s.right] : "",
                       turnBack(leaves, s.left),
                       turnOn(leaves, s.right),
                       leaves.length));
        bound++;
    }

    if (exists(scratch)) remove(scratch);

    write(OUT ~ "/index.html", indexHtml(leaves,
        environment.get("GROUND_COMMIT", ""),
        environment.get("GROUND_BUILT", "")));

    stderr.writefln("binder: %d of %d leaves bound", bound, leaves.length);
}

/// The page before this spread's left, and the one after its right. A turn
/// moves by the spread, so a reader never sees the same two pages twice.
string turnBack(Leaf[] leaves, size_t left) {
    if (left <= 1) return "";
    return folioAt(leaves, left - 1);
}

string turnOn(Leaf[] leaves, size_t right) {
    if (right == 0) return "";
    return folioAt(leaves, right + 1);
}

private string folioAt(Leaf[] leaves, size_t sheet) {
    foreach (l; leaves) if (l.sheet == sheet) return l.folio;
    return "";
}

/// The page mutool laid out, without the document it wrapped around it. The
/// wrapper carries a stylesheet of its own, and two would not agree.
string liftPage(string html) {
    auto a = indexOf(html, "<div id=\"page1\"");
    if (a < 0) return "";
    auto b = lastIndexOf(html, "</div>");
    if (b < a) return "";
    return html[a .. b + "</div>".length];
}

private ptrdiff_t indexOf(string hay, string needle) {
    if (needle.length > hay.length) return -1;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

private ptrdiff_t lastIndexOf(string hay, string needle) {
    if (needle.length > hay.length) return -1;
    foreach_reverse (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
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
