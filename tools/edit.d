module edit;

// The pure half of the editor. A note is found in its module by what it says,
// never by where it sits: the run is located again at the moment of the save,
// so nothing an edit above it did can send the write to the wrong lines.

import cases : splitLines, unmark, opensFixture, holdsMark, extractCases, join, Case, isSaid, isGlossary;

// The lines of one comment run, joined the way the book joins them.
private string spoken(string[] lines, size_t from, size_t to) {
    string out_;
    foreach (i; from .. to) {
        auto s = unmark(lines[i]);
        if (s.length == 0) continue;
        if (out_.length > 0) out_ ~= " ";
        out_ ~= s;
    }
    return out_;
}

private bool isComment(string line) {
    size_t p = 0;
    while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
    return p + 1 < line.length && line[p] == '/' && line[p + 1] == '/';
}

// The indent a run was written at, so a rewritten run sits where it stood.
private string indentOf(string line) {
    size_t p = 0;
    while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
    return line[0 .. p];
}

// One comment run set again as `//` lines, broken near the column the file is
// written to. Breaking on a word keeps a rewritten note diffable.
string[] speak(string prose, string indent, size_t width) {
    string[] out_;
    string line;

    size_t i = 0;
    while (i < prose.length) {
        size_t j = i;
        while (j < prose.length && prose[j] != ' ') j++;
        auto word = prose[i .. j];

        if (line.length > 0 && indent.length + 3 + line.length + 1 + word.length > width) {
            out_ ~= indent ~ "// " ~ line;
            line = word;
        } else {
            line = line.length > 0 ? line ~ " " ~ word : word;
        }
        i = j + 1;
    }
    if (line.length > 0) out_ ~= indent ~ "// " ~ line;
    return out_;
}

// How the module ended. splitLines drops the final newline and join does not
// put it back, so a saved file lost the one it was written with.
string ending(string text) {
    return text.length > 0 && text[$ - 1] == '\n' ? "\n" : "";
}

// Where a run saying this begins and ends, or an empty span when the module no
// longer says it. Not finding it is the honest answer: the source moved on.
struct Span {
    size_t from;
    size_t to;
    bool found;
}

Span runSaying(string[] lines, string prose) {
    size_t i = 0;
    while (i < lines.length) {
        if (!isComment(lines[i])) { i++; continue; }

        size_t j = i;
        while (j < lines.length && isComment(lines[j])) j++;
        if (spoken(lines, i, j) == prose) return Span(i, j, true);
        i = j;
    }
    return Span(0, 0, false);
}

// "I see, i would expect to be able to also edit the pbt left side, and also to just insert a quote or edit quote or add more pose"
// A case is three things: what was said above it, the note, and the example.
struct Was {
    string said;
    string prose;
    string pbt;
}

// Where a fixture's literal stands: the declaring line, the body lines, and
// the line holding the closing mark. A one-line literal is all three at once.
private struct Literal {
    size_t open;    // the enum line
    size_t close;   // the line holding the closing mark
    bool oneLine;
    string text;
    bool found;
}

private string trimLeft(string s) {
    size_t n = 0;
    while (n < s.length && (s[n] == ' ' || s[n] == '\t')) n++;
    return s[n .. $];
}

private string trimEdges(string[] body_) {
    size_t a = 0;
    size_t b = body_.length;
    while (a < b && trimLeft(body_[a]).length == 0) a++;
    while (b > a && trimLeft(body_[b - 1]).length == 0) b--;
    string out_;
    foreach (i; a .. b) {
        if (i > a) out_ ~= "\n";
        out_ ~= body_[i];
    }
    return out_;
}

private Literal literalAt(string[] lines, size_t i) {
    Literal l;
    auto t = trimLeft(lines[i]);
    if (!opensFixture(t)) return l;
    size_t marks = 0;
    foreach (c; lines[i]) if (c == '`') marks++;
    if (marks >= 2) {
        size_t a = 0;
        while (lines[i][a] != '`') a++;
        size_t b = a + 1;
        while (lines[i][b] != '`') b++;
        return Literal(i, i, true, lines[i][a + 1 .. b], true);
    }
    size_t j = i + 1;
    string[] body_;
    while (j < lines.length && !holdsMark(lines[j])) { body_ ~= lines[j]; j++; }
    if (j >= lines.length) return l;
    return Literal(i, j, false, trimEdges(body_), true);
}

// The case as the page read it: the same walk, so the save looks where the
// page looked. The run is every line the case was read from, not the comment
// lines that happen to sit above its example.
private Case findCase(string[] lines, Was was) {
    foreach (c; extractCases(join(lines))) {
        if (c.heading) continue;
        if (c.pbt == was.pbt && c.prose == was.prose && c.said == was.said) return c;
    }
    return Case.init;
}

private bool among(size_t i, size_t[] at) {
    foreach (a; at) if (a == i) return true;
    return false;
}

// The module with one case said and shown differently. The case is found by
// what it was, so an edit anywhere else in the file cannot misplace this one.
// A module that no longer holds it is left as it is.
//
// What did not change is not touched. What did is written where it stood: the
// quotes at the first quote, the note at the first line of it. A case with
// neither gets them above its example.
string[] rewriteCase(string[] lines, Was was, Was now, size_t width = 78) {
    auto c = findCase(lines, was);
    if (c.to == 0) return lines;

    Literal lit;
    foreach (i; c.from .. c.to) {
        lit = literalAt(lines, i);
        if (lit.found) break;
    }
    if (!lit.found) return lines;

    size_t[] saidAt, proseAt;
    foreach (i; c.from .. c.to) {
        if (i >= lit.open && i <= lit.close) continue;
        if (!isComment(lines[i]) || isGlossary(lines[i])) continue;
        if (isSaid(lines[i])) saidAt ~= i;
        else if (unmark(lines[i]).length > 0) proseAt ~= i;
    }

    bool saidChanged = was.said != now.said;
    bool proseChanged = was.prose != now.prose;
    auto proseAnchor = proseAt.length > 0 ? proseAt[0] : lit.open;
    auto saidAnchor = saidAt.length > 0 ? saidAt[0] : proseAnchor;

    string[] out_;
    foreach (i; 0 .. c.from) out_ ~= lines[i];

    size_t i = c.from;
    while (i < c.to) {
        if (i == saidAnchor && saidChanged) {
            auto indent = indentOf(lines[i]);
            foreach (q; splitLines(now.said)) if (q.length > 0) out_ ~= indent ~ "// " ~ q;
        }
        if (i == proseAnchor && proseChanged)
            foreach (l; speak(now.prose, indentOf(lines[i]), width)) out_ ~= l;

        if (saidChanged && among(i, saidAt)) { i++; continue; }
        if (proseChanged && among(i, proseAt)) { i++; continue; }

        if (i == lit.open) {
            out_ ~= literal(lines, lit, now.pbt);
            i = lit.close + 1;
            continue;
        }
        out_ ~= lines[i];
        i++;
    }
    foreach (k; c.to .. lines.length) out_ ~= lines[k];
    return out_;
}

// The example set again between its own marks.
private string[] literal(string[] lines, Literal lit, string pbt) {
    string[] out_;
    bool multi = false;
    foreach (ch; pbt) if (ch == '\n') { multi = true; break; }
    auto openLine = lines[lit.open];
    if (lit.oneLine) {
        size_t a = 0;
        while (openLine[a] != '`') a++;
        size_t b = a + 1;
        while (openLine[b] != '`') b++;
        if (multi) {
            out_ ~= openLine[0 .. a + 1];
            foreach (l; splitLines(pbt)) out_ ~= l;
            out_ ~= openLine[b .. $];
        } else {
            out_ ~= openLine[0 .. a + 1] ~ pbt ~ openLine[b .. $];
        }
    } else {
        out_ ~= openLine;
        foreach (l; splitLines(pbt)) out_ ~= l;
        out_ ~= lines[lit.close];
    }
    return out_;
}

// The module with one run said differently. The run is named by what it says,
// so an edit anywhere else in the file cannot misplace this one.
string[] rewriteProse(string[] lines, string was, string now, size_t width = 78) {
    auto span = runSaying(lines, was);
    if (!span.found) return lines;

    string[] out_;
    foreach (i; 0 .. span.from) out_ ~= lines[i];
    foreach (l; speak(now, indentOf(lines[span.from]), width)) out_ ~= l;
    foreach (i; span.to .. lines.length) out_ ~= lines[i];
    return out_;
}
