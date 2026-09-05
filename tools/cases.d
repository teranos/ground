module cases;

// The pure half of press. A case is an assertion the compiler has already
// proved, together with the comment that says why it holds. The book quotes
// those rather than prose about them, so an entry cannot describe a ground
// that stopped being true.

struct Case {
    string subject;
    string text;
    // Prose with no assertion under it. It is where the file says what the
    // next stretch is about, and it is the only structure the author put in.
    bool heading;
    // The pbt between the marks. A reader writing a control needs the block,
    // not the enum it was assigned to or the D that parses it.
    string pbt;
    // The comment lines above the example, without their markers.
    string prose;
}

// The symbol an assertion is about: the first thing it calls. A negation is
// about the same symbol as the positive form, so the mark comes off first.
string subject(string line) {
    auto s = trimLeft(line);
    if (startsAt(s, 0, "static ")) s = trimLeft(s["static ".length .. $]);
    if (!startsAt(s, 0, "assert(")) return "";

    s = s["assert(".length .. $];
    while (s.length > 0 && (s[0] == '!' || s[0] == ' ')) s = s[1 .. $];

    size_t n = 0;
    while (n < s.length && isNameChar(s[n])) n++;
    return s[0 .. n];
}

// A glossary entry: one term, one sentence, from one line in the module that
// owns the term. Which terms have one is decided by writing the line.
struct Entry {
    // Empty when the line carried the marker but not the shape, and text is
    // then the line itself, so press can say which one.
    string term;
    string text;
}

// "so its deliberate which terms deserve a glossary entry"
// The marker is the first word of the comment, the term stands between two
// pairs of asterisks, and the sentence follows the colon.
enum GLOSSARY_MARK = "BOOK_GLOSSARY";

bool isGlossary(string line) {
    auto s = trimLeft(line);
    if (!startsAt(s, 0, "//")) return false;
    s = unmark(line);
    return startsAt(s, 0, GLOSSARY_MARK ~ " ");
}

// Every glossary line in the module, in the order the file states them.
Entry[] extractGlossary(string source) {
    Entry[] found;
    foreach (line; splitLines(source)) {
        if (!isGlossary(line)) continue;
        auto s = unmark(line)[GLOSSARY_MARK.length .. $];
        s = trimLeft(s);

        if (!startsAt(s, 0, "**")) { found ~= Entry("", trimLeft(line)); continue; }
        s = s[2 .. $];
        size_t n = 0;
        while (n + 1 < s.length && !(s[n] == '*' && s[n + 1] == '*')) n++;
        if (n + 1 >= s.length) { found ~= Entry("", trimLeft(line)); continue; }
        auto term = s[0 .. n];
        s = s[n + 2 .. $];

        if (!startsAt(s, 0, ":")) { found ~= Entry("", trimLeft(line)); continue; }
        found ~= Entry(term, trimLeft(s[1 .. $]));
    }
    return found;
}

// Walk the module, gathering runs of comment and assertion lines. Anything
// else ends the run: a blank line separates two thoughts, and a line of setup
// beneath a case is not part of what the case claims.
Case[] extractCases(string source) {
    Case[] found;
    string[] block;
    string fixture;

    void flush() {
        scope (exit) { block = null; fixture = null; }

        // A glossary line defines a word; it is not about the stretch beneath
        // it and not part of any case, so it leaves the run before the run is
        // read as either.
        {
            string[] kept;
            foreach (line; block) if (!isGlossary(line)) kept ~= line;
            block = kept;
        }

        string asserted;
        foreach (line; block) {
            auto s = subject(line);
            if (s.length == 0) continue;
            asserted = s;
            break;
        }

        if (asserted.length == 0) {
            // Comment lines with nothing proved under them are the file's own
            // headings. Anything else with no assertion is setup.
            foreach (line; block)
                if (!startsAt(trimLeft(line), 0, "//")) return;
            if (block.length == 0) return;
            found ~= Case("", join(undent(block)), true);
            return;
        }

        found ~= Case(fixture.length > 0 ? fixture : asserted,
                      join(undent(block)), false,
                      liftPbt(block), liftProse(block));
    }

    auto all = splitLines(source);
    size_t i = 0;
    while (i < all.length) {
        auto line = all[i];
        auto t = trimLeft(line);

        // A unittest is one case, whole. Its setup is what makes the
        // assertion mean anything: the command that went in, and the comment
        // saying who is doing what.
        if (startsAt(t, 0, "unittest")) {
            flush();
            string[] body_;
            int depth = 0;
            bool opened = false;
            while (i < all.length) {
                depth += braceDelta(all[i]);
                if (!opened && depth > 0) {
                    opened = true;
                    i++;
                    continue;
                }
                if (opened && depth == 0) break;
                body_ ~= all[i];
                i++;
            }
            i++;

            string named;
            foreach (b; body_) {
                if (startsAt(trimLeft(b), 0, "//")) continue;
                named = calleeOf(b);
                if (named.length > 0) break;
            }
            bool proves = false;
            foreach (b; body_) if (subject(b).length > 0) { proves = true; break; }
            if (proves && named.length > 0)
                found ~= Case(named, join(undent(body_)));
            continue;
        }

        bool isComment = startsAt(t, 0, "//");
        bool isAssert = subject(line).length > 0;
        bool isEnum = startsAt(t, 0, "enum ");

        // A blank line between an example and its proof does not separate
        // them. Test modules put one there to breathe, and ending the block on
        // it kept the assertions and threw the example away.
        if (t.length == 0 && fixture.length > 0) {
            block ~= line;
            i++;
            continue;
        }

        if (!isComment && !isAssert && !isEnum) {
            flush();
            i++;
            continue;
        }

        // A comment after something proved introduces what comes next, not
        // what was just shown. Keeping it printed every note one case early,
        // under the example before the one it was written for.
        if (isComment && fixture.length > 0 && proves(block)) flush();

        // A second example is a second lesson, not a continuation of the first.
        if (isEnum && fixture.length > 0 && holdsMark(t)) flush();

        block ~= line;

        // A one-line literal names the example too. Requiring a continuation
        // left `enum a = ` ~ "`x`;" ~ ` unnamed.
        if (isEnum && fixture.length == 0 && holdsMark(t)) fixture = enumName(t);

        // A block literal spans lines. Its body is pbt, not D, so nothing in
        // it is read as code and the run does not end until the mark closes.
        if (isEnum && opensLiteral(t)) {
            if (fixture.length == 0) fixture = enumName(t);
            i++;
            while (i < all.length) {
                block ~= all[i];
                if (holdsMark(all[i])) break;
                i++;
            }
        }
        i++;
    }
    flush();

    return found;
}

// The pbt between the marks. Everything outside them is D, which is how the
// example is carried rather than what it is.
string liftPbt(string[] block) {
    string[] body_;
    bool inside = false;
    foreach (line; block) {
        if (holdsMark(line)) {
            if (inside) break;
            inside = true;
            // A one-line literal carries its whole body between the marks.
            auto b = between(line);
            if (b.length > 0) return b;
            continue;
        }
        if (inside) body_ ~= line;
    }
    if (!inside) return "";
    while (body_.length > 0 && trimLeft(body_[0]).length == 0) body_ = body_[1 .. $];
    while (body_.length > 0 && trimLeft(body_[$ - 1]).length == 0) body_ = body_[0 .. $ - 1];
    return join(body_);
}

// The comment lines above the example, without their markers.
string liftProse(string[] block) {
    string out_;
    foreach (line; block) {
        auto s = trimLeft(line);
        if (!startsAt(s, 0, "//")) continue;
        s = s[2 .. $];
        while (s.length > 0 && (s[0] == ' ' || s[0] == '-')) s = s[1 .. $];
        while (s.length > 0 && (s[$ - 1] == ' ' || s[$ - 1] == '-')) s = s[0 .. $ - 1];
        if (s.length == 0) continue;
        if (out_.length > 0) out_ ~= " ";
        out_ ~= s;
    }
    return out_;
}

// What sits between the first two marks on one line.
private string between(string line) {
    size_t a = 0;
    while (a < line.length && line[a] != '`') a++;
    if (a >= line.length) return "";
    size_t b = a + 1;
    while (b < line.length && line[b] != '`') b++;
    if (b >= line.length) return "";
    return line[a + 1 .. b];
}

// What a line calls. An assertion is about the thing it tests rather than
// about assert, and a setup line is about the function it runs.
string calleeOf(string line) {
    auto s = subject(line);
    if (s.length > 0) return s;

    size_t p = 0;
    while (p < line.length && line[p] != '(') p++;
    if (p >= line.length) return "";

    size_t b = p;
    while (b > 0 && isNameChar(line[b - 1])) b--;
    return line[b .. p];
}

// Braces outside a string. A pbt fixture is full of them and none of them
// close the unittest they sit in.
int braceDelta(string line) {
    int depth = 0;
    bool inMark = false;
    bool inQuote = false;
    foreach (c; line) {
        if (c == '`') { inMark = !inMark; continue; }
        if (inMark) continue;
        if (c == '"') { inQuote = !inQuote; continue; }
        if (inQuote) continue;
        if (c == '{') depth++;
        if (c == '}') depth--;
    }
    return depth;
}

// The name a block literal was given, which is what the example is called.
string enumName(string trimmed) {
    auto s = trimmed["enum ".length .. $];
    size_t n = 0;
    while (n < s.length && isNameChar(s[n])) n++;
    return s[0 .. n];
}

// An opening mark with nothing closing it on the same line.
bool opensLiteral(string trimmed) {
    return countMarks(trimmed) == 1;
}

bool holdsMark(string line) {
    return countMarks(line) > 0;
}

private size_t countMarks(string s) {
    size_t n = 0;
    foreach (c; s) if (c == '`') n++;
    return n;
}

// Whether anything in the run has been proved yet. A block that has claimed
// something is finished; what follows it belongs to the next one.
private bool proves(string[] block) {
    foreach (line; block) if (subject(line).length > 0) return true;
    return false;
}

// A comment line without its marker. The marker is how D carries prose, not
// part of what was written.
string unmark(string line) {
    auto s = trimLeft(line);
    if (s.length >= 2 && s[0 .. 2] == "//") s = s[2 .. $];
    // A ddoc line is prose too, and its third slash is marker, not text.
    if (s.length >= 1 && s[0] == '/') s = s[1 .. $];
    while (s.length > 0 && (s[0] == ' ' || s[0] == '-')) s = s[1 .. $];
    while (s.length > 0 && (s[$ - 1] == ' ' || s[$ - 1] == '-')) s = s[0 .. $ - 1];
    return s;
}

// A comment run set as a paragraph. Where a comment wraps is a width the
// editor chose and means nothing on the page, so the lines join. A blank line
// is a break the author did mean, so it stays one.
string flow(string text) {
    string out_;
    bool broke = true;

    foreach (line; splitLines(text)) {
        auto s = unmark(line);
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

// One name per symbol, so a `///` refers to the cases for a thing by naming
// the thing.
string caseName(string s) {
    string out_ = "EX_";
    foreach (c; s) out_ ~= upper(c);
    return out_;
}

// A ddoc macro definition. Continuation lines are indented by one space,
// which is what makes ddoc read them as part of this definition rather than
// as the start of the next one.
string renderCase(string s, string text) {
    string out_ = caseName(s) ~ " =\n \\begin{gcode}\n";
    foreach (line; splitLines(text)) out_ ~= " " ~ line ~ "\n";
    out_ ~= " \\end{gcode}\n\n";
    return out_;
}

// Take the common indent off every line. A case written inside a unittest is
// indented by its block, and printing that would step each example further
// right than the last for no reason a reader could see.
string[] undent(string[] block) {
    size_t common = size_t.max;
    foreach (line; block) {
        if (trimLeft(line).length == 0) continue;
        size_t n = 0;
        while (n < line.length && (line[n] == ' ' || line[n] == '\t')) n++;
        if (n < common) common = n;
    }
    if (common == size_t.max || common == 0) return block;

    string[] out_;
    foreach (line; block)
        out_ ~= line.length >= common ? line[common .. $] : line;
    return out_;
}

string join(string[] lines) {
    string out_;
    foreach (i, line; lines) {
        if (i > 0) out_ ~= "\n";
        out_ ~= line;
    }
    return out_;
}

string[] splitLines(string s) {
    string[] out_;
    size_t start = 0;
    foreach (i, c; s) {
        if (c != '\n') continue;
        out_ ~= s[start .. i];
        start = i + 1;
    }
    if (start < s.length) out_ ~= s[start .. $];
    return out_;
}

private string trimLeft(string s) {
    size_t n = 0;
    while (n < s.length && (s[n] == ' ' || s[n] == '\t')) n++;
    return s[n .. $];
}

private bool startsAt(string s, size_t i, string what) {
    if (i + what.length > s.length) return false;
    return s[i .. i + what.length] == what;
}

private bool isNameChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private char upper(char c) {
    return (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
}
