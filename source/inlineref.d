module inlineref;

// "I DONT WANT TO HAVE TO OPEN OP A FILE EDITOR WHEN WE CAN JUST SHOW WHATEVER CLAUDE WAS REFERRING TO INLINE"

// Where a reference sits and what it points at. The path is a slice of the
// text itself, so it is valid as long as the text is.
struct FileLineRef {
    bool ok;
    size_t start;
    size_t end;
    const(char)[] path;
    long first;
    long last;
}

private bool isDigit(char c) { return c >= '0' && c <= '9'; }

// A character a path can be made of. Backticks, brackets and parentheses are
// how a reference usually arrives, and none of them belong to the path.
private bool isPathChar(char c) {
    if (c >= 'a' && c <= 'z') return true;
    if (c >= 'A' && c <= 'Z') return true;
    if (isDigit(c)) return true;
    return c == '.' || c == '_' || c == '-' || c == '/' || c == '+';
}

// The next `path.ext:line` or `path.ext:line-line` at or after `from`.
FileLineRef nextFileLineRef(const(char)[] text, size_t from) {
    size_t i = from;
    while (i < text.length) {
        if (text[i] != ':') { i++; continue; }

        // A scheme's own colon, and the port that follows a host, both sit next
        // to slashes. Neither names a line in a file.
        if (i + 2 < text.length && text[i + 1] == '/' && text[i + 2] == '/') { i++; continue; }

        size_t d = i + 1;
        while (d < text.length && isDigit(text[d])) d++;
        if (d == i + 1) { i++; continue; }

        size_t s = i;
        while (s > 0 && isPathChar(text[s - 1])) s--;
        auto path = text[s .. i];

        // Without an extension it is not a file, which is what keeps a clock
        // and a host out of this.
        if (!hasExtension(path)) { i = d; continue; }

        // A host, not a path: walking back from a port's colon swallows the
        // whole authority, and `com` reads as an extension.
        if (path.length >= 2 && path[0] == '/' && path[1] == '/') { i = d; continue; }
        if (s > 0 && text[s - 1] == ':') { i = d; continue; }

        long first = digitsAt(text, i + 1, d);
        long last = first;
        size_t e = d;

        if (d < text.length && text[d] == '-') {
            size_t d2 = d + 1;
            while (d2 < text.length && isDigit(text[d2])) d2++;
            if (d2 > d + 1) { last = digitsAt(text, d + 1, d2); e = d2; }
        }

        return FileLineRef(true, s, e, path, first, last);
    }
    return FileLineRef(false, text.length, text.length, null, 0, 0);
}

// What goes after the opening fence. The extension already names the language
// to every renderer worth the name, so there is no table to fall out of date.
const(char)[] fenceTag(const(char)[] path) {
    ptrdiff_t dot = -1;
    foreach (i, c; path) {
        if (c == '/') dot = -1;
        else if (c == '.') dot = cast(ptrdiff_t) i;
    }
    if (dot < 0) return "";
    return path[dot + 1 .. $];
}

// An extension is a dot with letters after it and something before it, which
// is what a filename has and a bare number does not.
private bool hasExtension(const(char)[] path) {
    ptrdiff_t dot = -1;
    foreach (i, c; path) {
        if (c == '/') dot = -1;
        else if (c == '.') dot = cast(ptrdiff_t) i;
    }
    if (dot <= 0) return false;

    auto ext = path[dot + 1 .. $];
    if (ext.length == 0 || ext.length > 6) return false;
    foreach (c; ext) {
        bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!alpha) return false;
    }
    return true;
}

// The one tracked file this reference names, or null. Null when nothing
// matches and null when more than one does, because inlining the wrong file
// is worse than leaving the address where the writer put it.
const(char)[] resolvePath(const(char)[] written, const(string)[] files) {
    if (written.length == 0) return null;

    const(char)[] hit = null;
    foreach (f; files) {
        if (!namesSameFile(f, written)) continue;
        if (hit !is null) return null;
        hit = f;
    }
    return hit;
}

// True when `written` is the whole of a tracked path or a tail of it that
// begins at a directory boundary. A bare suffix would make xdeferred.d answer
// to deferred.d.
private bool namesSameFile(const(char)[] tracked, const(char)[] written) {
    if (written.length > tracked.length) return false;
    if (tracked[tracked.length - written.length .. $] != written) return false;
    if (written.length == tracked.length) return true;
    return tracked[tracked.length - written.length - 1] == '/';
}

// The referenced lines themselves, counted from one. Null when the file does
// not reach that far — a shorter answer is better than a wrong one, and the
// address stays put where the lines cannot be found.
const(char)[] sliceLines(const(char)[] content, long first, long last) {
    if (first < 1 || last < first || content.length == 0) return null;

    long line = 1;
    size_t lineStart = 0;
    size_t from = 0;
    bool haveFrom = false;

    while (true) {
        if (line == first) { from = lineStart; haveFrom = true; }

        size_t e = lineStart;
        while (e < content.length && content[e] != '\n') e++;

        if (line == last) return haveFrom ? content[from .. e] : null;

        // The bytes after the final newline are not a line, so a file of five
        // lines has no sixth to hand back.
        if (e >= content.length) return null;
        lineStart = e + 1;
        if (lineStart >= content.length) return null;
        line++;
    }
}

// Reading a file is the caller's to supply, so what replaces an address can be
// tested without one.
alias ReadFile = extern (C) const(char)[] function(const(char)[] path);

// The root a tracked path is opened against. A global because ReadFile takes a
// path and nothing else, which is what keeps the rewrite testable.
__gshared const(char)[] g_readRoot;

extern (C) const(char)[] readTracked(const(char)[] rel) {
    return readProjectFile(g_readRoot, rel);
}

// wind stores each file relative to the project that declared it, so the root
// is what turns one of those back into something openable.
const(char)[] readProjectFile(const(char)[] root, const(char)[] rel) {
    import core.stdc.stdio : fopen, fread, fclose;

    if (rel.length == 0) return null;

    __gshared char[4096] path = 0;
    if (root.length + rel.length + 2 > path.length) return null;

    size_t p = 0;
    foreach (c; root) path[p++] = c;
    if (p > 0 && path[p - 1] != '/') path[p++] = '/';
    foreach (c; rel) path[p++] = c;
    path[p] = 0;

    auto f = fopen(&path[0], "rb");
    if (f is null) return null;

    __gshared char[262144] content = 0;
    auto n = fread(&content[0], 1, content.length, f);
    fclose(f);
    if (n == 0) return null;

    return content[0 .. n];
}

struct Rewrite {
    const(char)[] text;
    size_t changed;
}

// Every address in the message replaced by the lines it names. An address that
// resolves to nothing, or names a line the file does not reach, is left as it
// was written — a wrong inline is worse than an address.
Rewrite inlineRefs(const(char)[] text, const(string)[] files, ReadFile read) {
    __gshared char[262144] buf = 0;
    size_t o = 0;
    size_t changed = 0;
    size_t cursor = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < buf.length) buf[o++] = c;
    }

    while (true) {
        auto r = nextFileLineRef(text, cursor);
        if (!r.ok) break;

        const(char)[] lines = null;
        auto path = resolvePath(r.path, files);
        if (path !is null) {
            auto content = read(path);
            if (content !is null) lines = sliceLines(content, r.first, r.last);
        }

        if (lines is null) {
            put(text[cursor .. r.end]);
            cursor = r.end;
            continue;
        }

        put(text[cursor .. r.start]);

        // One line belongs in the sentence it was written into. A range cannot
        // sit inside one, so it breaks out.
        if (r.first == r.last) {
            put("`");
            put(lines);
            put("`");
        } else {
            put("\n```");
            put(fenceTag(path));
            put("\n");
            put(lines);
            put("\n```\n");
        }

        changed++;
        cursor = r.end;
    }

    put(text[cursor .. $]);
    return Rewrite(buf[0 .. o], changed);
}

private long digitsAt(const(char)[] text, size_t from, size_t to) {
    long v = 0;
    foreach (i; from .. to) v = v * 10 + (text[i] - '0');
    return v;
}
