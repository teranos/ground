module typeset;

// Which faces the book is allowed to be set in. Not a taste: a face named for
// fontconfig to find is resolved by the machine, so the same source sets a
// different book on every one of them.

// The three roles book.tex sets. A role left unset falls back to Latin Modern,
// which is a fourth face nobody chose.
immutable string[3] FONT_COMMANDS = [
    "\\setmainfont", "\\setsansfont", "\\setmonofont",
];

// The option that makes a declaration name a file rather than a family: with
// it fontspec asks kpathsea, which looks inside the closure and nowhere else.
enum CLOSURE_OPTION = "Extension=.otf";

struct Decl {
    string command;
    // What stood between the brackets, empty when there were none.
    string options;
    // A declaration with no brackets names a family and nothing else.
    bool bracketed;
}

bool has(string hay, string needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}

// A commented declaration is not one. Counted, a face could be disabled and
// still satisfy the check that exists to guard it.
string withoutComments(string text) {
    string out_;
    size_t i = 0;
    while (i < text.length) {
        size_t start = i;
        while (i < text.length && text[i] != '\n') i++;
        auto line = text[start .. i];
        if (i < text.length) i++;

        size_t p = 0;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
        if (p < line.length && line[p] == '%') continue;

        out_ ~= line;
        out_ ~= "\n";
    }
    return out_;
}

// Every font-setting command in the text, with the options it was given.
Decl[] fontDecls(string text) {
    auto body_ = withoutComments(text);
    Decl[] out_;
    foreach (cmd; FONT_COMMANDS) {
        size_t i = 0;
        while (i + cmd.length <= body_.length) {
            if (body_[i .. i + cmd.length] != cmd) { i++; continue; }
            i += cmd.length;

            // Step over the family: {...}. Without one this is not a
            // declaration, only a word that begins like one.
            while (i < body_.length && body_[i] != '{' && body_[i] != '\n') i++;
            if (i >= body_.length || body_[i] != '{') break;
            while (i < body_.length && body_[i] != '}') i++;
            if (i >= body_.length) break;
            i++;

            if (i < body_.length && body_[i] == '[') {
                i++;
                size_t optStart = i;
                while (i < body_.length && body_[i] != ']') i++;
                out_ ~= Decl(cmd, body_[optStart .. i], true);
                if (i < body_.length) i++;
            } else {
                out_ ~= Decl(cmd, "", false);
            }
        }
    }
    return out_;
}

// One declaration names a file inside the closure.
bool fromClosure(Decl d) {
    return d.bracketed && has(d.options, CLOSURE_OPTION);
}

// The whole book. One face resolved by the machine is enough to make the
// build unreproducible, so every declaration has to answer.
bool everyFontFromClosure(string text) {
    auto ds = fontDecls(text);
    if (ds.length == 0) return false;
    foreach (d; ds) if (!fromClosure(d)) return false;
    return true;
}

// Text, sans and mono each set. A missing role is a face nobody chose.
bool setsAllRoles(string text) {
    auto ds = fontDecls(text);
    foreach (cmd; FONT_COMMANDS) {
        bool found = false;
        foreach (d; ds) if (d.command == cmd) { found = true; break; }
        if (!found) return false;
    }
    return true;
}
