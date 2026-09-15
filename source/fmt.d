module fmt;

// "it almost feels like we should want a ground fmt"
// The one layout pbt is written in. A value is copied as it is; only the
// whitespace between things is the formatter's, and a comment keeps its place.

// The book quotes fixtures, and a fixture that reads badly on the page reads
// badly in the file until fmt is run on it. press refuses the ones it would
// change rather than reshaping them on every build.

struct Formatted {
    char[4096] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

Formatted formatPbt(const(char)[] input) {
    Formatted f;
    auto n = formatInto(input, f.buf[]);
    f.len = n < 0 ? 0 : cast(size_t) n;
    return f;
}

// True when the text is already in the one layout.
bool isCanonical(const(char)[] input, char[] scratch) {
    auto n = formatInto(input, scratch);
    if (n < 0) return false;
    return scratch[0 .. cast(size_t) n] == input;
}

// A line longer than this sets a list one item per line.
enum LINE = 80;

// The deepest nesting fmt follows. pbt is three or four levels deep.
enum DEPTH = 16;

private struct Writer {
    char[] out_;
    size_t len;
    bool full;

    void put(const(char)[] s) {
        foreach (c; s) {
            if (len >= out_.length) { full = true; return; }
            out_[len++] = c;
        }
    }

    void indent(int depth) {
        foreach (i; 0 .. depth) put("  ");
    }
}

private bool isWs(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

private bool isBlank(char c) {
    return c == ' ' || c == '\t';
}

private void skipBlank(const(char)[] s, ref size_t pos) {
    while (pos < s.length && isBlank(s[pos])) pos++;
}

private size_t lineEnd(const(char)[] s, size_t pos) {
    while (pos < s.length && s[pos] != '\n') pos++;
    return pos;
}

// A word runs to whitespace, a colon or a brace, the way the lexer reads one.
private const(char)[] word(const(char)[] s, ref size_t pos) {
    auto start = pos;
    while (pos < s.length && !isWs(s[pos]) && s[pos] != ':' && s[pos] != '{' && s[pos] != '}')
        pos++;
    return s[start .. pos];
}

// A scalar value as written: quoted, backticked, or bare to the next space.
// Null when what stands there is not a scalar.
private const(char)[] scalar(const(char)[] s, ref size_t pos) {
    if (pos >= s.length) return null;
    auto start = pos;
    if (s[pos] == '"' || s[pos] == '`') {
        auto mark = s[pos];
        pos++;
        while (pos < s.length && s[pos] != mark) pos++;
        if (pos >= s.length) return null;
        pos++;
        return s[start .. pos];
    }
    while (pos < s.length && !isWs(s[pos]) && s[pos] != '}' && s[pos] != ']' && s[pos] != ',')
        pos++;
    return s[start .. pos];
}

// A comment after the thing on its line, two spaces off it.
private void trailing(const(char)[] s, ref size_t pos, ref Writer w) {
    skipBlank(s, pos);
    if (pos < s.length && s[pos] == '#') {
        auto e = lineEnd(s, pos);
        w.put("  ");
        w.put(s[pos .. e]);
        pos = e;
    }
}

// The raw JSON of an attestation's attributes, from its brace to the matching
// one, read the way proto reads it.
private const(char)[] jsonBlock(const(char)[] s, ref size_t pos) {
    auto start = pos;
    int depth = 0;
    while (pos < s.length) {
        if (s[pos] == '{') depth++;
        else if (s[pos] == '}') { depth--; if (depth == 0) { pos++; break; } }
        else if (s[pos] == '"') { pos++; while (pos < s.length && s[pos] != '"') pos++; }
        pos++;
    }
    return s[start .. pos];
}

private const(char)[] trim(const(char)[] s) {
    size_t a = 0;
    size_t b = s.length;
    while (a < b && isWs(s[a])) a++;
    while (b > a && isWs(s[b - 1])) b--;
    return s[a .. b];
}

// JSON is carried whole. Its lines are reindented to where the field sits,
// one level in, and nothing inside a line is touched.
private void putJson(const(char)[] raw, int depth, ref Writer w) {
    bool multi = false;
    foreach (c; raw) if (c == '\n') { multi = true; break; }
    if (!multi) { w.put(raw); return; }

    // The opening brace, then each inner line, then the closing brace.
    w.put("{\n");
    size_t i = 1;
    auto last = raw.length - 1;
    while (i < last) {
        auto e = i;
        while (e < last && raw[e] != '\n') e++;
        auto line = trim(raw[i .. e]);
        i = e + 1;
        if (line.length == 0) continue;
        w.indent(depth + 1);
        w.put(line);
        w.put("\n");
    }
    w.indent(depth);
    w.put("}");
}

// A list fits on its line or goes one item per line, decided by the width
// the line would have.
private bool putList(const(char)[] s, ref size_t pos, int depth, size_t keyLen, ref Writer w) {
    const(char)[][64] items;
    size_t n;
    pos++; // [
    while (pos < s.length) {
        while (pos < s.length && isWs(s[pos])) pos++;
        if (pos >= s.length) return false;
        if (s[pos] == ']') { pos++; break; }
        if (n >= items.length) return false;
        auto it = scalar(s, pos);
        if (it is null) return false;
        items[n++] = it;
        while (pos < s.length && isWs(s[pos])) pos++;
        if (pos < s.length && s[pos] == ',') pos++;
    }

    size_t width = 2 * depth + keyLen + 2 + 2;
    foreach (it; items[0 .. n]) width += it.length;
    if (n > 1) width += 2 * (n - 1);

    if (width <= LINE) {
        w.put("[");
        foreach (i, it; items[0 .. n]) {
            if (i > 0) w.put(", ");
            w.put(it);
        }
        w.put("]");
        return true;
    }

    w.put("[\n");
    foreach (i, it; items[0 .. n]) {
        w.indent(depth + 1);
        w.put(it);
        if (i + 1 < n) w.put(",");
        w.put("\n");
    }
    w.indent(depth);
    w.put("]");
    return true;
}

// A reference with values inside a ritual body is one line: it is one
// reference, not a block of its own.
private bool putInline(const(char)[] s, ref size_t pos, ref Writer w) {
    while (pos < s.length) {
        while (pos < s.length && isWs(s[pos])) pos++;
        if (pos >= s.length) return false;
        if (s[pos] == '}') { pos++; w.put(" }"); return true; }
        auto k = word(s, pos);
        if (k.length == 0) return false;
        skipBlank(s, pos);
        if (pos >= s.length || s[pos] != ':') return false;
        pos++;
        skipBlank(s, pos);
        auto v = scalar(s, pos);
        if (v is null) return false;
        w.put(" ");
        w.put(k);
        w.put(": ");
        w.put(v);
    }
    return false;
}

// The length written, or -1 when the text is not pbt fmt can follow or the
// buffer is too small. Nothing is written for a text fmt cannot read whole.
ptrdiff_t formatInto(const(char)[] s, char[] out_) {
    Writer w;
    w.out_ = out_;
    size_t pos = 0;
    int depth = 0;
    bool[DEPTH] ritualBody;
    bool opened = true;      // right after a brace, so no blank line there
    bool blank = false;      // a blank line the author left, owed before the next thing

    while (pos < s.length) {
        size_t newlines = 0;
        while (pos < s.length && isWs(s[pos])) { if (s[pos] == '\n') newlines++; pos++; }
        if (pos >= s.length) break;
        if (newlines >= 2 && !opened) blank = true;

        auto c = s[pos];
        if (c == '}') {
            pos++;
            depth--;
            if (depth < 0) return -1;
            w.indent(depth);
            w.put("}");
            trailing(s, pos, w);
            w.put("\n");
            opened = false;
            blank = false;
            continue;
        }

        if (blank) { w.put("\n"); blank = false; }
        opened = false;

        if (c == '#') {
            auto e = lineEnd(s, pos);
            w.indent(depth);
            w.put(s[pos .. e]);
            w.put("\n");
            pos = e;
            continue;
        }

        auto head = word(s, pos);
        if (head.length == 0) return -1;
        skipBlank(s, pos);

        // key: value
        if (pos < s.length && s[pos] == ':') {
            pos++;
            skipBlank(s, pos);
            if (pos >= s.length) return -1;
            w.indent(depth);
            w.put(head);
            w.put(": ");
            if (s[pos] == '[') {
                if (!putList(s, pos, depth, head.length, w)) return -1;
            } else if (s[pos] == '{') {
                putJson(jsonBlock(s, pos), depth, w);
            } else {
                auto v = scalar(s, pos);
                if (v is null) return -1;
                w.put(v);

                // A models rule is its condition and the model it picks, and
                // the two stay on one line wherever the author broke them.
                if (head == "five_hour" || head == "seven_day" || head == "plan") {
                    auto look = pos;
                    while (look < s.length && isWs(s[look])) look++;
                    auto next = word(s, look);
                    skipBlank(s, look);
                    if (next == "model" && look < s.length && s[look] == ':') {
                        look++;
                        skipBlank(s, look);
                        auto m = scalar(s, look);
                        if (m is null) return -1;
                        w.put("  model: ");
                        w.put(m);
                        pos = look;
                    }
                }
            }
            trailing(s, pos, w);
            w.put("\n");
            continue;
        }

        // include "file"
        if (pos < s.length && s[pos] == '"') {
            auto v = scalar(s, pos);
            if (v is null) return -1;
            w.indent(depth);
            w.put(head);
            w.put(" ");
            w.put(v);
            trailing(s, pos, w);
            w.put("\n");
            continue;
        }

        // word [name] {  — or a bare word on its own, a reference
        const(char)[] name;
        if (pos < s.length && s[pos] != '{' && s[pos] != '\n' && s[pos] != '\r'
            && s[pos] != '}' && s[pos] != '#') {
            name = word(s, pos);
            skipBlank(s, pos);
        }

        if (pos < s.length && s[pos] == '{') {
            pos++;
            if (depth > 0 && ritualBody[depth - 1]) {
                w.indent(depth);
                w.put(head);
                if (name.length > 0) { w.put(" "); w.put(name); }
                w.put(" {");
                if (!putInline(s, pos, w)) return -1;
                trailing(s, pos, w);
                w.put("\n");
                continue;
            }
            if (depth >= DEPTH) return -1;
            w.indent(depth);
            w.put(head);
            if (name.length > 0) { w.put(" "); w.put(name); }
            w.put(" {");
            trailing(s, pos, w);
            w.put("\n");
            ritualBody[depth] = head == "ritual";
            depth++;
            opened = true;
            continue;
        }

        w.indent(depth);
        w.put(head);
        if (name.length > 0) { w.put(" "); w.put(name); }
        trailing(s, pos, w);
        w.put("\n");
    }

    if (depth != 0 || w.full) return -1;
    return cast(ptrdiff_t) w.len;
}
