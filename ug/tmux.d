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

enum YELLOW = "#[fg=colour178]";
enum ORANGE = "#[fg=colour208]";

enum SEP = "  ";

// "between 50 and 52" — and 60 to 62, 70 to 75, and 80 and over. An org's
// Actions minutes are drawn inside those and nowhere else, hotter as they go.
// A whole percent is the unit: 52.9 is still between 50 and 52.
const(char)[] bandColour(long used, long quota) {
    if (used < 0 || quota <= 0) return null;
    auto pct = used * 100 / quota;
    if (pct >= 80) return RED;
    if (pct >= 70 && pct <= 75) return ORANGE;
    if (pct >= 60 && pct <= 62) return YELLOW;
    if (pct >= 50 && pct <= 52) return DIM;
    return null;
}

// "MAX is only MAX if the subscription plan is max like ground usage displays"
// `cc` and the plan in capitals: ccMAX on a Max plan, ccPRO on a Pro one. The
// plan is `subscriptionType` from `claude auth status`, which ground writes
// down as the `plan` check. Asked and not yet answered, the label is `cc`
// alone — the week is still worth the room, and it claims nothing it has not
// been told.
size_t weekLabelInto(const(char)[] plan, char[] dest) {
    size_t o = 0;
    foreach (c; "cc") if (o < dest.length) dest[o++] = c;
    foreach (c; plan) {
        if (o >= dest.length) break;
        dest[o++] = (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
    }
    return o;
}

// `ccMAX 71%`, inside the same bands, or nothing. A window that has already
// reset says nothing about the one running now. The label names the window:
// the account's week, or Fable's. How long until it resets is leftInto's, and
// the row draws that once for both.
size_t weekInto(const(char)[] label, long percent, long resetsAt, long now, char[] dest) {
    if (resetsAt <= now) return 0;
    auto colour = bandColour(percent, 100);
    if (colour is null) return 0;

    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    void num(long v) {
        char[24] d = void;
        size_t dl = 0;
        if (v <= 0) d[dl++] = '0';
        else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    }

    put(colour);
    put(label);
    put(" ");
    num(percent);
    put("%");
    put(PLAIN);
    return o;
}

// "right now i see it twice / instead y needs to be shown onece / before
// ccMAX". The account's week and Fable's reset within a minute of each other,
// so the row was spending the room twice to say one thing. The time stands
// once, in front of the first week drawn, in its own hand.
//
// The largest unit that is still true, and nothing after it. "i will just
// remember that its 'left' i wont forget" — the word said nothing the reader
// was not already holding, and the second unit beside the first was the same
// trade: room on a one-line bar for a digit nobody acts on.
size_t leftInto(long resetsAt, long now, char[] dest) {
    if (resetsAt <= now) return 0;

    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    void num(long v) {
        char[24] d = void;
        size_t dl = 0;
        if (v <= 0) d[dl++] = '0';
        else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    }

    auto left = resetsAt - now;
    auto days = left / 86_400;
    auto hours = (left % 86_400) / 3600;
    auto mins = (left % 3600) / 60;
    if (days > 0) { num(days); put("d"); }
    else if (hours > 0) { num(hours); put("h"); }
    else { num(mins); put("m"); }
    return o;
}

// `<org> actions 51% 1020/2000`, or nothing when the reading is in no band.
size_t minutesInto(const(char)[] org, long used, long quota, char[] dest) {
    auto colour = bandColour(used, quota);
    if (colour is null) return 0;

    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    void num(long v) {
        char[24] d = void;
        size_t dl = 0;
        if (v <= 0) d[dl++] = '0';
        else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    }

    put(colour);
    put(org);
    put(" actions ");
    num(used * 100 / quota);
    put("% ");
    num(used);
    put("/");
    num(quota);
    put(PLAIN);
    return o;
}

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

    auto answer = fetch(home, "/am/statusline?format=tmux");

    __gshared char[8192] line = void;
    size_t n;

    if (answer.state == State.ok) {
        keepAnswer(home, now, answer.body_);
        n = isJson(answer.body_)
            ? itemsInto(answer.body_, line[])
            : oneLineInto(answer.body_, line[]);
        // The node answered, so it can be asked what it left for this token.
        newsPass(home);
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

    // The readings go to the other end of the bar, away from what the node is
    // saying. tmux reads #[align=right] out of a #() exactly as it reads one
    // written into status-format itself — measured, both sides identical at 60
    // columns — so the split costs one directive and no change to the conf.
    // They are gathered first, because an empty right side must not emit the
    // directive and hand tmux a right-aligned nothing.
    __gshared char[2048] right = void;
    size_t r = 0;

    void append(const(char)[] seg) {
        if (r > 0) foreach (c; SEP) if (r < right.length) right[r++] = c;
        foreach (c; seg) if (r < right.length) right[r++] = c;
    }

    // The orgs' Actions minutes, from the table ground keeps. No network call:
    // ground asks github, and this reads what it wrote down.
    {
        import sql : OrgMinutes, readOrgMinutes, MAX_ORGS;
        OrgMinutes[MAX_ORGS] orgs;
        auto count = readOrgMinutes(home, orgs[]);
        foreach (i; 0 .. count) {
            __gshared char[160] seg = void;
            auto sn = minutesInto(orgs[i].org(), orgs[i].used, orgs[i].quota, seg[]);
            if (sn == 0) continue;
            append(seg[0 .. sn]);
        }
    }

    // The weekly Claude windows, the account's and Fable's, from the readings
    // ug wrote down while drawing a session's status line. tmux has no session
    // to be handed one. The account's week carries the plan in its name; the
    // Fable week is Fable's on every plan there is.
    {
        import sql : readWindow, readPlan;

        __gshared char[32] plan = void;
        auto pn = readPlan(home, plan[]);
        __gshared char[16] cc = void;
        auto cn = weekLabelInto(plan[0 .. pn], cc[]);

        auto ccWeek = readWindow(home, "seven_day");
        auto fableWeek = readWindow(home, "fable_week");

        __gshared char[96] ccSeg = void;
        size_t ccLen = 0;
        if (ccWeek.found)
            ccLen = weekInto(cc[0 .. cn], ccWeek.percent, ccWeek.resetsAt, now, ccSeg[]);

        __gshared char[96] fableSeg = void;
        size_t fableLen = 0;
        if (fableWeek.found)
            fableLen = weekInto("FABLE", fableWeek.percent, fableWeek.resetsAt, now, fableSeg[]);

        // The time belongs to the week it stands in front of, so it is drawn
        // as one piece with it: `3d ccMAX 71%`, a single space, against the
        // two that separate one reading from the next. That is the account's
        // week when the account's is drawn, and Fable's when it is the only
        // one there — never a time in front of nothing.
        if (ccLen > 0 || fableLen > 0) {
            __gshared char[160] lead = void;
            size_t l = 0;

            auto resetsAt = ccLen > 0 ? ccWeek.resetsAt : fableWeek.resetsAt;
            __gshared char[32] seg = void;
            auto sn = leftInto(resetsAt, now, seg[]);
            if (sn > 0) {
                foreach (c; DIM) if (l < lead.length) lead[l++] = c;
                foreach (c; seg[0 .. sn]) if (l < lead.length) lead[l++] = c;
                foreach (c; PLAIN) if (l < lead.length) lead[l++] = c;
                if (l < lead.length) lead[l++] = ' ';
            }
            foreach (c; ccLen > 0 ? ccSeg[0 .. ccLen] : fableSeg[0 .. fableLen])
                if (l < lead.length) lead[l++] = c;
            append(lead[0 .. l]);

            if (ccLen > 0 && fableLen > 0) append(fableSeg[0 .. fableLen]);
        }
    }

    if (r > 0) {
        foreach (c; "#[align=right]") if (n < line.length) line[n++] = c;
        foreach (c; right[0 .. r]) if (n < line.length) line[n++] = c;
    }

    if (n > 0) {
        fwrite(line.ptr, 1, n, stdout);
        fputs("\n", stdout);
    }
    return 0;
}

// What the node left for this token, written into ground's store once each so
// sky carries it to the session. The row is asked for as items rather than as
// the spelled line, because an id does not survive being drawn. An item that
// is already in the store costs one SELECT; a new one costs one more ask, for
// the whole of it, which is where the session it is for is named.
void newsPass(const(char)[] home) {
    import probe : fetch;
    import qntx : State;
    import sql : newsSeen, leaveNews;

    // Asked for as the row's own token. The node files news under the person
    // a token speaks for, so what the ground token's push earned is found by
    // this one; the ground token itself cannot read the row.
    auto answer = fetch(home, "/am/statusline?format=json");
    if (answer.state != State.ok || !isJson(answer.body_)) return;

    // fetch answers out of one static buffer, and the ask for an item's
    // detail below is a second fetch: it overwrote the items while they were
    // being walked, and two rows went into the store with ids cut from the
    // middle of a detail body. The items are copied out first.
    __gshared char[65536] items = void;
    size_t n = 0;
    foreach (c; answer.body_) { if (n >= items.length) break; items[n++] = c; }
    auto body_ = items[0 .. n];

    size_t at = itemsAt(body_);
    while (true) {
        auto span = nextObject(body_, at);
        if (!span.ok) break;
        at = span.end;

        auto obj = body_[span.start .. span.end];
        auto id = jsonString(obj, "id");
        if (id is null || id.length == 0) continue;
        if (newsSeen(home, id)) continue;

        __gshared char[512] path = void;
        size_t p = 0;
        foreach (c; "/am/statusline/") path[p++] = c;
        foreach (c; id) {
            if (p + 1 >= path.length) break;
            if (c == '/' || c == '?' || c == '#' || c == '&' || c == ' ') continue;
            path[p++] = c;
        }
        auto whole = fetch(home, path[0 .. p]);
        if (whole.state != State.ok) continue;

        auto session = jsonString(whole.body_, "session");
        auto repo = jsonString(whole.body_, "repo");
        if (repo is null) repo = "";

        // What sky speaks: the conclusion, where, and the run to open.
        __gshared char[1024] detail = void;
        size_t d = 0;
        void put(const(char)[] s) { foreach (c; s) if (d < detail.length) detail[d++] = c; }
        auto name = jsonString(obj, "name");
        auto note = jsonString(obj, "note");
        put(name is null ? "news" : name);
        if (note !is null && note.length > 0) { put(": "); put(note); }
        auto url = jsonString(whole.body_, "url");
        if (url !is null && url.length > 0) { put(" "); put(url); }

        leaveNews(home, id, session is null ? "" : session, repo, detail[0 .. d]);
    }
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
    foreach (c; "/am/statusline/") path[p++] = c;
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
