module statusline;

// What QNTX serves, drawn. This module knows what a glyph looks like and
// nothing about what it stands for.

import json : jsonString;

enum GREEN = "\033[32m";
enum RED    = "\033[31m";
enum YELLOW = "\033[33m";
enum DIM   = "\033[2m";
enum RESET = "\033[0m";

// The whole of what ug understands about the served line.
const(char)[] glyphColour(const(char)[] glyph) {
    if (glyph == "+") return GREEN;
    if (glyph == "!") return RED;
    return null;
}

enum SEP = "  ";

// Where the last answer was stamped. ug is a fresh process every frame, so the
// only way it can know how long a silence has lasted is to have written it down.
enum STAMP = ".local/state/ug/qntx-seen";

size_t stampPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0) return 0;
    if (home.length + STAMP.length + 2 > dest.length) return 0;

    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; STAMP) dest[o++] = c;
    dest[o] = 0;
    return o;
}

// The last answer, kept so a short silence changes nothing on the row.
struct Seen {
    long at;
    const(char)[] body_;
}

Seen lastAnswer(const(char)[] home) {
    import core.stdc.stdio : fopen, fread, fclose;

    __gshared char[512] path = void;
    if (stampPathInto(home, path[]) == 0) return Seen(0, "");

    auto f = fopen(&path[0], "rb");
    if (f is null) return Seen(0, "");

    __gshared char[16384] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);

    long v = 0;
    size_t i = 0;
    while (i < n && buf[i] >= '0' && buf[i] <= '9') {
        v = v * 10 + (buf[i] - '0');
        i++;
    }
    if (i < n && buf[i] == '\n') i++;
    return Seen(v, buf[i .. n]);
}

void keepAnswer(const(char)[] home, long now, const(char)[] body_) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    import core.sys.posix.sys.stat : mkdir;

    __gshared char[512] path = void;
    auto n = stampPathInto(home, path[]);
    if (n == 0) return;

    // The directory before the file. Nothing here creates $HOME/.local itself.
    foreach_reverse (i; 0 .. n) {
        if (path[i] != '/') continue;
        path[i] = 0;
        mkdir(&path[0], octal!755);
        path[i] = '/';
        break;
    }

    auto f = fopen(&path[0], "wb");
    if (f is null) return;

    char[24] d = void;
    size_t dl = 0;
    long v = now;
    if (v <= 0) { d[dl++] = '0'; }
    else { while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach_reverse (i; 0 .. dl) fwrite(&d[i], 1, 1, f);
    fwrite("\n".ptr, 1, 1, f);
    fwrite(body_.ptr, 1, body_.length, f);
    fclose(f);
}

private template octal(int n) {
    enum octal = n / 100 * 64 + n / 10 % 10 * 8 + n % 10;
}

// Under this, a silence is a deploy and the row keeps showing what it last
// knew. Over it, the silence is the news.
enum QUIET = 4 * 60;

// Absent and unreadable are different facts with different fixes: one says
// mint a token, the other says the one on disk is fine and the permissions are not.
size_t tokenInto(bool absent, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    put(YELLOW);
    put(absent ? "QNTX token" : "QNTX token unreadable");
    put(RESET);
    return o;
}

// QNTX answered and the answer was a refusal or a fault. That is not a silence
// and the row must not spend four minutes pretending it might pass.
size_t answeredInto(bool refused, int status, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    put(refused ? YELLOW : RED);
    put("QNTX ");

    // A status the node chose is more use than a word chosen for it.
    if (status >= 100) { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 100) % 10); }
    if (status >= 10)  { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 10) % 10); }
    if (status > 0)    { if (o < dest.length) dest[o++] = cast(char)('0' + status % 10); }

    put(RESET);
    return o;
}

// How long it has been, in the largest unit that still says something true.
size_t sinceInto(long since, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    void putInt(long v) {
        char[24] d = void;
        size_t dl = 0;
        if (v <= 0) { d[dl++] = '0'; }
        else { while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; } }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    }

    put(RED);
    put("could not connect to QNTX since ");

    long n;
    const(char)[] unit;
    if (since < 3600) { n = since / 60; unit = "minute"; }
    else if (since < 86400) { n = since / 3600; unit = "hour"; }
    else { n = since / 86400; unit = "day"; }

    putInt(n);
    put(" ");
    put(unit);
    if (n != 1) put("s");
    put(" ago");
    put(RESET);
    return o;
}

// The next object at or after `from`, by brace depth, so a nested one does not
// end the object holding it.
struct Span {
    bool ok;
    size_t start;
    size_t end;
}

Span nextObject(const(char)[] text, size_t from) {
    size_t i = from;
    while (i < text.length && text[i] != '{') i++;
    if (i >= text.length) return Span(false, text.length, text.length);

    size_t depth = 0;
    size_t start = i;
    while (i < text.length) {
        if (text[i] == '{') depth++;
        else if (text[i] == '}') {
            depth--;
            if (depth == 0) return Span(true, start, i + 1);
        }
        i++;
    }
    return Span(false, text.length, text.length);
}

ptrdiff_t indexOf(const(char)[] text, const(char)[] needle) {
    if (needle.length == 0 || needle.length > text.length) return -1;
    foreach (i; 0 .. text.length - needle.length + 1)
        if (text[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

size_t itemsAt(const(char)[] body_) {
    auto at = indexOf(body_, `"items":`);
    return at < 0 ? body_.length : cast(size_t) at + 8;
}

// The items, in the order they were served. A glyph ug has no colour for draws
// nothing rather than being guessed at.
size_t itemsInto(const(char)[] body_, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    bool first = true;
    size_t at = itemsAt(body_);

    while (true) {
        auto span = nextObject(body_, at);
        if (!span.ok) break;
        at = span.end;

        auto obj = body_[span.start .. span.end];
        auto name = jsonString(obj, "name");
        if (name is null) continue;

        auto colour = glyphColour(jsonString(obj, "glyph"));
        if (colour is null) continue;

        if (!first) put(SEP);
        first = false;

        put(colour);
        put(name);
        put(RESET);

        auto note = jsonString(obj, "note");
        if (note !is null && note.length > 0) {
            put(" ");
            put(DIM);
            put(note);
            put(RESET);
        }
    }

    return o;
}
