module scan;

// Text scanning that knows nothing of controls: what matcher matches with, and
// what ground code and the store use without the hooks matcher matches for.

bool contains(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        bool match = true;
        foreach (j; 0 .. needle.length) {
            char a = haystack[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) { match = false; break; }
        }
        if (match) {
            auto after = i + needle.length;
            if (after < haystack.length && haystack[after] >= '0' && haystack[after] <= '9')
                continue;
            return true;
        }
    }
    return false;
}


bool containsExact(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        if (haystack[i .. i + needle.length] == needle)
            return true;
    }
    return false;
}

ptrdiff_t indexOf(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return 0;
    if (needle.length > haystack.length) return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
    return -1;
}

ptrdiff_t lastIndexOf(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return 0;
    if (needle.length > haystack.length) return -1;
    size_t i = haystack.length - needle.length;
    while (true) {
        if (haystack[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
        if (i == 0) break;
        i--;
    }
    return -1;
}

const(char)[] strip(const(char)[] s) {
    size_t start = 0;
    while (start < s.length && s[start] == ' ')
        start++;
    size_t end = s.length;
    while (end > start && s[end - 1] == ' ')
        end--;
    return s[start .. end];
}

// The home the shell expands a tilde to, for the callers that read a command
// at runtime. Empty leaves a tilde alone, which is what CTFE tests want.
const(char)[] shellHome() {
    if (__ctfe) return "";
    import core.stdc.stdlib : getenv;
    auto h = getenv("HOME\0".ptr);
    if (h is null) return "";
    size_t n;
    while (h[n] != 0) n++;
    return h[0 .. n];
}

// The shell expands a tilde before cd sees it: two pushes made as `cd ~/...; git push` started no ritual,
// the literal going to git, which found no repo there. Written into a buffer the caller owns, so CTFE and
// betterC both have somewhere to put it.
const(char)[] tildeExpanded(const(char)[] target, const(char)[] home, char[] joined) {
    if (home.length == 0 || target.length == 0 || target[0] != '~') return target;
    if (target.length == 1) return home;
    if (target[1] != '/') return target;
    size_t n;
    foreach (c; home) { if (n < joined.length) joined[n++] = c; }
    foreach (c; target[1 .. $]) { if (n < joined.length) joined[n++] = c; }
    return joined[0 .. n];
}

// The text after a line's `#` or `//`, and whether the line is one. `///` is
// the reference, not a comment.
bool commentText(const(char)[] line, out const(char)[] text) {
    size_t p = 0;
    while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
    auto rest = line[p .. $];
    if (rest.length >= 3 && rest[0 .. 3] == "///") return false;
    if (rest.length >= 2 && rest[0 .. 2] == "//") { text = rest[2 .. $]; return true; }
    if (rest.length >= 1 && rest[0] == '#') { text = rest[1 .. $]; return true; }
    return false;
}

// "i dont want code comments to be subject to consecutive run"
// A comment's text is code when it ends in `{` or `}`, or sits inside braces
// such a line opened. Braces in quotes are text; depth never goes below zero.
bool codeText(const(char)[] text, ref int depth) {
    size_t e = text.length;
    while (e > 0 && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r')) e--;
    bool code = depth > 0 || (e > 0 && (text[e - 1] == '{' || text[e - 1] == '}'));
    char quote = 0;
    foreach (c; text) {
        if (quote != 0) { if (c == quote) quote = 0; continue; }
        if (c == '"' || c == '`') quote = c;
        else if (c == '{') depth++;
        else if (c == '}' && depth > 0) depth--;
    }
    return code;
}

// Whether the line holding `pos` is code that was commented out. A line that
// is not a comment ends any block a commented line opened.
bool inCommentedCode(const(char)[] text, size_t pos) {
    int depth = 0;
    size_t i = 0;
    while (i <= text.length) {
        size_t end = i;
        while (end < text.length && text[end] != '\n') end++;
        const(char)[] body_;
        bool code = false;
        if (commentText(text[i .. end], body_)) code = codeText(body_, depth);
        else depth = 0;
        if (pos >= i && pos <= end) return code;
        i = end + 1;
    }
    return false;
}
