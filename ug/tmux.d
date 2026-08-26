module tmux;

// The QNTX row, drawn for a tmux status line rather than for a session.

// tmux keeps the first line of a #() and drops the rest, and it renders its own
// #[fg=...] rather than ANSI. Both are why this is a separate surface.

import json : jsonString;
import statusline : nextObject, itemsAt, lastAnswer, keepAnswer, QUIET;

enum GREEN = "#[fg=colour34]";
enum RED   = "#[fg=colour160]";
enum DIM   = "#[fg=colour244]";
enum PLAIN = "#[default]";

enum SEP = "  ";

const(char)[] glyphColour(const(char)[] glyph) {
    if (glyph == "+") return GREEN;
    if (glyph == "!") return RED;
    return null;
}

// A body the node already spelled for tmux, or one it has not. The deployed
// node serves items until the format parameter ships, so both are read.
bool isJson(const(char)[] body_) {
    foreach (c; body_) {
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        return c == '{';
    }
    return false;
}

// Items rendered here, for as long as the node still serves them.
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
        put(PLAIN);

        auto note = jsonString(obj, "note");
        if (note !is null && note.length > 0) {
            put(" ");
            put(DIM);
            put(note);
            put(PLAIN);
        }
    }

    return o;
}

// How long the node has been unreachable. Only this side can know it, so it is
// the one thing the node cannot spell for us.
size_t sinceInto(long since, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    put(RED);
    put("QNTX unreachable ");

    long n;
    const(char)[] unit;
    if (since < 3600) { n = since / 60; unit = "minute"; }
    else if (since < 86400) { n = since / 3600; unit = "hour"; }
    else { n = since / 86400; unit = "day"; }

    char[24] d = void;
    size_t dl = 0;
    long v = n;
    if (v <= 0) { d[dl++] = '0'; }
    else { while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];

    put(" ");
    put(unit);
    if (n != 1) put("s");
    put(PLAIN);
    return o;
}

// The whole of `ug tmux`: one line on stdout and nothing else. It reads no
// stdin, because tmux has no session to tell it about.
int tmuxMain(const(char)[] home, long now) {
    import core.stdc.stdio : stdout, fwrite, fputs;
    import probe : fetch;
    import qntx : State;

    auto answer = fetch(home, "/statusline?format=tmux");

    __gshared char[8192] line = void;
    size_t n;

    if (answer.state == State.ok) {
        keepAnswer(home, now, answer.body_);
        n = isJson(answer.body_)
            ? itemsInto(answer.body_, line[])
            : oneLineInto(answer.body_, line[]);
    } else if (answer.status > 0) {
        // The node answered and the answer was a refusal. That is not silence,
        // and it must not wait out the quiet window pretending it might pass.
        n = statusInto(answer.status, line[]);
    } else {
        auto seen = lastAnswer(home);
        if (seen.at > 0) {
            auto silence = now - seen.at;
            if (silence < QUIET)
                n = isJson(seen.body_)
                    ? itemsInto(seen.body_, line[])
                    : oneLineInto(seen.body_, line[]);
            else
                n = sinceInto(silence, line[]);
        }
    }

    if (n > 0) {
        fwrite(line.ptr, 1, n, stdout);
        fputs("\n", stdout);
    }
    return 0;
}

// `ug expand <name>` — what one item on the row is doing, for a popup. The row
// has one line and cannot carry this, so a click is where it goes.
int expandMain(const(char)[] home, const(char)[] name) {
    import core.stdc.stdio : stdout, fwrite, fputs;
    import probe : fetch;
    import qntx : State;

    if (name.length == 0) {
        fputs("nothing to expand\n", stdout);
        return 0;
    }

    __gshared char[512] path = void;
    size_t p = 0;
    foreach (c; "/statusline/") path[p++] = c;
    foreach (c; name) {
        if (p + 1 >= path.length) break;
        // A name is a plugin's own, and anything that could steer the request
        // elsewhere is not one.
        if (c == '/' || c == '?' || c == '#' || c == '&' || c == ' ') continue;
        path[p++] = c;
    }

    auto answer = fetch(home, path[0 .. p]);

    if (answer.state != State.ok) {
        fputs("QNTX did not answer for ", stdout);
        fwrite(name.ptr, 1, name.length, stdout);
        fputs("\n", stdout);
        return 0;
    }

    // The body is JSON and a popup is a terminal, so it goes out as it came:
    // readable, and nothing here pretending to format it.
    fwrite(answer.body_.ptr, 1, answer.body_.length, stdout);
    fputs("\n", stdout);
    return 0;
}

// A status the node chose is more use than a word chosen for it.
size_t statusInto(int status, char[] dest) {
    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    put(RED);
    put("QNTX ");
    if (status >= 100) { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 100) % 10); }
    if (status >= 10)  { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 10) % 10); }
    if (o < dest.length) dest[o++] = cast(char)('0' + status % 10);
    put(PLAIN);
    return o;
}

// A newline would end the row early, because tmux takes the first line only.
size_t oneLineInto(const(char)[] s, char[] dest) {
    size_t o = 0;
    foreach (c; s) {
        if (c == '\n' || c == '\r') break;
        if (o < dest.length) dest[o++] = c;
    }
    return o;
}
