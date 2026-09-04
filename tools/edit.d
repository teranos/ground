module edit;

// The pure half of the editor. A note is found in its module by what it says,
// never by where it sits: the run is located again at the moment of the save,
// so nothing an edit above it did can send the write to the wrong lines.

import cases : splitLines, unmark;

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
