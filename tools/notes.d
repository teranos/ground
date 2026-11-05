module notes;

// "i expect to edit the book of ground by linking it via obsidia"
// The pure half of the book's notes. The prose of the Book of Ground is written in
// doc/book/<chapter>.md: the chapter's opening first, then one section per case,
// under the name the case carries on its `// book:` line in source. The asserts,
// the pbt fixtures and the operator's quotes stay in source, where they are
// proved and recorded; press joins the two and stops on anything it cannot join.

import cases : splitLines;

// One case's note: its name, the chapter whose file it is in, where its `## `
// heading stands, and the lines under it.
struct Note {
    string name;
    string chapter;
    string file;
    size_t line;
    string[] lines;
}

struct NoteFile {
    string[] opening;
    Note[] notes;
    string[] refused;
}

// A case the book sets, as press found it: where it is, the chapter it is set in,
// and the name on its `// book:` line, empty when it has none.
struct CaseRef {
    string file;
    size_t line;
    string chapter;
    string book;
}

enum NAME_MARK = "## ";

// A note file read into its opening and its sections. Every line outside the
// subset is refused with its file and line, and says what to write instead.
NoteFile readNote(string file, string chapter, string text) {
    NoteFile f;
    bool inNote = false;
    bool fenced = false;
    foreach (i, raw; splitLines(text)) {
        auto n = i + 1;
        auto line = trimRight(raw);
        auto t = trimLeft(line);
        if (t == "##" || startsWith(t, NAME_MARK)) {
            auto name = t.length > 2 ? trimLeft(t[2 .. $]) : "";
            if (name.length == 0) {
                f.refused ~= at(file, n) ~ "`##` names no case. "
                    ~ "Write after it the name a case carries on its `// book:` line in source.";
                continue;
            }
            f.notes ~= Note(name, chapter, file, n, []);
            inNote = true;
            continue;
        }
        auto why = outside(t);
        if (why.length > 0) {
            f.refused ~= at(file, n) ~ why;
            continue;
        }
        if (inNote) f.notes[$ - 1].lines ~= line;
        else f.opening ~= line;
    }
    return f;
}

// What a line is when it is markdown the book does not set, or nothing when it
// is text. A heading other than a case's name is one of them.
private string outside(string t) {
    if (t.length == 0) return "";
    enum sentence = " Write it as a sentence.";
    if (t[0] == '#')
        return "`" ~ t ~ "` is a heading, and the book sets none from a note. A chapter opens on the text "
            ~ "before its first `## `, and `## <name>` only ever names a case." ~ sentence;
    if (startsWith(t, "```") || startsWith(t, "~~~"))
        return "`" ~ t ~ "` opens a markdown code block, and a note is paragraphs of text. "
            ~ "An example is the pbt the case proves in source.";
    if (t[0] == '>') return "`" ~ t ~ "` is a markdown blockquote, and a note is paragraphs of text."
        ~ " An operator's quote stays in source, above its case.";
    if (t[0] == '|') return "`" ~ t ~ "` is a markdown table, and a note is paragraphs of text." ~ sentence;
    if (t[0] == '<') return "`" ~ t ~ "` is markup, and a note is paragraphs of text." ~ sentence;
    if (startsWith(t, "- ") || startsWith(t, "* ") || startsWith(t, "+ ") || numbered(t))
        return "`" ~ t ~ "` is a markdown list, and a note is paragraphs of text." ~ sentence;
    return "";
}

private bool numbered(string t) {
    size_t d = 0;
    while (d < t.length && t[d] >= '0' && t[d] <= '9') d++;
    return d > 0 && d + 1 < t.length && t[d] == '.' && t[d + 1] == ' ';
}

// Lines set as paragraphs: where a line wraps is the width of whatever it was
// typed in, so lines join with a space; a blank line is a paragraph break.
string flowText(const(string)[] lines) {
    string out_;
    bool broke = true;
    foreach (l; lines) {
        auto s = trimRight(trimLeft(l));
        if (s.length == 0) {
            if (out_.length > 0) broke = true;
            continue;
        }
        if (broke) {
            if (out_.length > 0) out_ ~= "\n\n";
            broke = false;
        } else {
            out_ ~= " ";
        }
        out_ ~= s;
    }
    return out_;
}

// Every case to its note, and every note to its case. Each refusal names the
// file and line it is at, and what to do at the other end: the person who meets
// it may have edited only the note, in the vault, and never opened the source.
string[] joinNotes(const(CaseRef)[] cases, const(Note)[] notes) {
    string[] refused;
    foreach (i, c; cases) {
        if (c.book.length == 0) {
            refused ~= at(c.file, c.line) ~ "the book sets this case in " ~ c.chapter ~ " and it names no note. "
                ~ "Add `// book: <name>` above it, and `## <name>` with its note in " ~ noteFile(c.chapter) ~ ".";
            continue;
        }
        bool twice = false;
        foreach (e; cases[0 .. i]) {
            if (e.book != c.book) continue;
            refused ~= at(c.file, c.line) ~ "`// book: " ~ c.book ~ "` is also " ~ e.file ~ ":" ~ num(e.line)
                ~ ", and a name is one case's. Rename one, and its `## ` heading in " ~ noteFile(c.chapter) ~ " with it.";
            twice = true;
            break;
        }
        if (twice) continue;
        bool found = false;
        foreach (n; notes) if (n.name == c.book) { found = true; break; }
        if (!found)
            refused ~= at(c.file, c.line) ~ "`// book: " ~ c.book ~ "` names no note: " ~ noteFile(c.chapter)
                ~ " has no `## " ~ c.book ~ "`. Add that heading there, or rename this line to a `## ` name that file has.";
    }
    foreach (i, n; notes) {
        bool twice = false;
        foreach (e; notes[0 .. i]) {
            if (e.name != n.name) continue;
            refused ~= at(n.file, n.line) ~ "`## " ~ n.name ~ "` is also " ~ e.file ~ ":" ~ num(e.line)
                ~ ", and a name is one case's. Remove one of the two sections.";
            twice = true;
            break;
        }
        if (twice) continue;
        bool named = false;
        foreach (c; cases) {
            if (c.book != n.name) continue;
            named = true;
            if (c.chapter != n.chapter)
                refused ~= at(n.file, n.line) ~ "`## " ~ n.name ~ "` is the note of a case the book sets in "
                    ~ c.chapter ~ " (" ~ c.file ~ ":" ~ num(c.line) ~ "). Move the section to " ~ noteFile(c.chapter) ~ ".";
            break;
        }
        if (!named)
            refused ~= at(n.file, n.line) ~ "`## " ~ n.name ~ "` names no case: no `// book: " ~ n.name
                ~ "` line is in source. Rename the heading back to the name a case carries, or remove its section.";
    }
    return refused;
}

// What the vault binds is the notes directly in doc/book/, so that is all the
// book reads: no folder inside it, nothing but .md, one file per chapter.
string refuseEntry(string path, bool isDir, const(string)[] chapters) {
    if (isDir)
        return path ~ ": a folder inside doc/book/ is not the book's, as the vault binds doc/book/ alone. "
            ~ "Move its notes up into doc/book/.";
    if (path.length < 3 || path[$ - 3 .. $] != ".md")
        return path ~ ": only .md notes are the book's. Remove it from doc/book/.";
    auto stem = chapterOfFile(path);
    foreach (c; chapters) if (c == stem) return "";
    string names;
    foreach (i, c; chapters) names ~= (i > 0 ? ", " : "") ~ c;
    return path ~ " names no chapter. Name it for one of: " ~ names ~ ".";
}

// The chapter a note file is for: its name without the folder and the .md.
string chapterOfFile(string path) {
    size_t s = 0;
    foreach (i, ch; path) if (ch == '/') s = i + 1;
    auto base = path[s .. $];
    return base.length > 3 ? base[0 .. $ - 3] : base;
}

string noteFile(string chapter) {
    return "doc/book/" ~ chapter ~ ".md";
}

private string at(string file, size_t line) {
    return file ~ ":" ~ num(line) ~ ": ";
}

private string num(size_t n) {
    if (n == 0) return "0";
    char[20] b;
    size_t l;
    while (n > 0) { b[l++] = cast(char)('0' + n % 10); n /= 10; }
    string o;
    foreach_reverse (i; 0 .. l) o ~= b[i];
    return o;
}

private bool startsWith(string s, string p) {
    return s.length >= p.length && s[0 .. p.length] == p;
}

private string trimLeft(string s) {
    size_t i;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) i++;
    return s[i .. $];
}

private string trimRight(string s) {
    size_t e = s.length;
    while (e > 0 && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r')) e--;
    return s[0 .. e];
}
