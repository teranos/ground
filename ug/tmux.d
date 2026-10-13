module tmux;

// The QNTX row, drawn for a tmux status line rather than for a session.

// tmux keeps the first line of a #() and drops the rest, and it renders its own
// #[fg=...] rather than ANSI. Both are why this is a separate surface.

import json : jsonString, jsonNumber;
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

// Whether a body is the node's JSON row.
bool isJson(const(char)[] body_) {
    foreach (c; body_) {
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
        return c == '{';
    }
    return false;
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

// Which plugin the row is showing instead of the node, written down because ug
// is a fresh process every frame. Absent is the node's row.
enum FOCUS = ".local/state/ug/focus";

// A plugin's name as the node holds it. Anything else is not one, and does not
// go into a request.
bool isPluginName(const(char)[] name) {
    if (name.length == 0 || name.length > 64) return false;
    foreach (c; name) {
        auto ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '-' || c == '_' || c == '.';
        if (!ok) return false;
    }
    return true;
}

// What the row asks the node for: its own row, or one plugin's.
size_t rowPathInto(const(char)[] focus, const(char)[] format, char[] dest) {
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    put("/am/statusline?format=");
    put(format);
    if (isPluginName(focus)) {
        put("&plugin=");
        put(focus);
    }
    return o;
}

size_t focusPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0 || home.length + FOCUS.length + 2 > dest.length) return 0;
    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; FOCUS) dest[o++] = c;
    dest[o] = 0;
    return o;
}

const(char)[] readFocus(const(char)[] home) {
    import core.stdc.stdio : fopen, fread, fclose;
    __gshared char[512] path = void;
    if (focusPathInto(home, path[]) == 0) return null;
    auto f = fopen(&path[0], "rb");
    if (f is null) return null;
    __gshared char[80] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) n--;
    return isPluginName(buf[0 .. n]) ? buf[0 .. n] : null;
}

void writeFocus(const(char)[] home, const(char)[] name) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    import core.sys.posix.sys.stat : mkdir;
    __gshared char[512] path = void;
    auto n = focusPathInto(home, path[]);
    if (n == 0) return;
    foreach_reverse (i; 0 .. n) {
        if (path[i] != '/') continue;
        path[i] = 0;
        mkdir(&path[0], 493); // 0755
        path[i] = '/';
        break;
    }
    auto f = fopen(&path[0], "wb");
    if (f is null) return;
    fwrite(name.ptr, 1, name.length, f);
    fclose(f);
}

void clearFocus(const(char)[] home) {
    import core.stdc.stdio : remove;
    __gshared char[512] path = void;
    if (focusPathInto(home, path[]) == 0) return;
    remove(&path[0]);
}

// `ug click <name>`: what tmux runs when a name on the row is clicked. On the
// node's row, a plugin's name turns the row into that plugin's row; on a
// plugin's row, any click turns it back. The row changes in place, and tmux is
// told to draw it again now rather than at its next interval.
int clickMain(const(char)[] home, const(char)[] name) {
    import core.stdc.stdlib : system;
    import probe : fetch;
    import qntx : State;

    if (readFocus(home) !is null) {
        clearFocus(home);
    } else if (isPluginName(name)) {
        // Only a name the node holds a plugin under. Clicking `handlers` or the
        // caller leaves the row as it is.
        __gshared char[160] path = void;
        auto p = rowPathInto(name, "json", path[]);
        auto answer = fetch(home, path[0 .. p]);
        if (answer.state == State.ok) writeFocus(home, name);
    }
    system("tmux refresh-client -S >/dev/null 2>&1");
    return 0;
}

// The whole of `ug tmux`: one line on stdout and nothing else. It reads no
// stdin, because tmux has no session to tell it about.
int tmuxMain(const(char)[] home, long now) {
    import core.stdc.stdio : stdout, fwrite, fputs;
    import probe : fetch;
    import qntx : State;

    auto focus = readFocus(home);
    __gshared char[160] rowPath = void;
    auto rp = rowPathInto(focus, "tmux", rowPath[]);
    auto answer = fetch(home, rowPath[0 .. rp]);

    // A plugin the node no longer holds is not a row to keep asking for.
    if (focus !is null && answer.status == 404) {
        clearFocus(home);
        focus = null;
        answer = fetch(home, "/am/statusline?format=tmux");
    }

    __gshared char[8192] line = void;
    size_t n;

    if (answer.state == State.ok) {
        // What is kept stands in for the node's row through a short silence,
        // so a plugin's row is not what gets kept.
        if (focus is null) keepAnswer(home, now, answer.body_);
        n = oneLineInto(answer.body_, line[]);
        // The node answered, so it can be asked what it left for this token,
        // and each deploy is drawn on its plugin's name.
        auto json = newsPass(home);
        __gshared char[8192] over = void;
        auto on = deploysOverInto(line[0 .. n], json, now, over[]);
        foreach (i; 0 .. on) line[i] = over[i];
        n = on;
    } else if (answer.status > 0) {
        // The node answered and the answer was a refusal. That is not silence,
        // and it must not wait out the quiet window pretending it might pass.
        n = statusInto(answer.status, line[]);
    } else {
        auto seen = lastAnswer(home);
        if (seen.at > 0) {
            auto silence = now - seen.at;
            if (silence < QUIET)
                n = oneLineInto(seen.body_, line[]);
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
const(char)[] newsPass(const(char)[] home) {
    import probe : fetch;
    import qntx : State;
    import sql : newsSeen, leaveNews;

    // Asked for as the row's own token. The node files news under the person
    // a token speaks for, so what the ground token's push earned is found by
    // this one; the ground token itself cannot read the row.
    auto answer = fetch(home, "/am/statusline?format=json");
    if (answer.state != State.ok || !isJson(answer.body_)) return "";

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
        // Decoded once here, because leaveNews encodes it again for the row.
        import json : jsonUnescapeInto;
        __gshared char[1024] detail = void;
        size_t d = 0;
        void put(const(char)[] s) { foreach (c; s) if (d < detail.length) detail[d++] = c; }
        void putDecoded(const(char)[] raw) { d += jsonUnescapeInto(raw, detail[d .. $]); }
        auto name = jsonString(obj, "name");
        auto note = jsonString(obj, "note");
        if (name is null) put("news"); else putDecoded(name);
        if (note !is null && note.length > 0) { put(": "); putDecoded(note); }
        auto url = jsonString(whole.body_, "url");
        if (url !is null && url.length > 0) { put(" "); putDecoded(url); }

        leaveNews(home, id, session is null ? "" : session, repo, detail[0 .. d]);
    }
    return body_;
}

// A plugin's deploy is drawn on the plugin's own name, from what the node holds
// of it. Behind the letters: purple as far as the node's own build is, green as
// far as GitHub's checks passed, yellow and blinking for the rest.
enum BUILT    = "#[fg=colour231,bg=colour91]";
enum CHECKED  = "#[fg=colour16,bg=colour34]";
enum TO_GO    = "#[fg=colour16,bg=colour178]";
enum FAILED   = "#[fg=colour231,bg=colour160]";
// "i dont want blinking bg when its building, just slight blink on finish"
enum FINISHED = "#[fg=colour231,bg=colour91,blink]";

// How far one bar is, in columns of a name `width` wide.
struct Fill {
    int done;
    int of;
    bool failed;
    bool present;
}

size_t columns(Fill f, size_t width) {
    if (!f.present) return width;
    if (f.of <= 0 || f.done <= 0) return 0;
    auto c = width * cast(size_t) f.done / cast(size_t) f.of;
    return c > width ? width : c;
}

// The name with its background filled. A deploy no push began has no checks
// bar, and is green behind all of it.
size_t filledNameInto(const(char)[] name, Fill checks, Fill node, char[] dest) {
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }

    if (checks.failed || node.failed) {
        put(FAILED); put(name); put(PLAIN);
        return o;
    }
    auto green = columns(checks, name.length);
    auto purple = columns(node, name.length);
    const(char)[] was = null;
    foreach (i; 0 .. name.length) {
        auto now = i < purple ? BUILT : i < green ? CHECKED : TO_GO;
        if (now != was) { put(now); was = now; }
        if (o < dest.length) dest[o++] = name[i];
    }
    put(PLAIN);
    return o;
}

// How long the slot shows the name, and then the version coming in.
enum ALTERNATE = 2;
// How long a deploy that went live blinks: tmux redraws every 5 seconds.
enum FINISH = 10;
// How long a failure stays when no other news comes after it.
enum FAILURE = 120;

// Seconds since the epoch of an RFC 3339 time as Go writes it, UTC:
// 2026-10-13T07:31:10.060881525Z. Zero for one that is not that.
long epochOf(const(char)[] t) {
    if (t.length < 19 || t[4] != '-' || t[7] != '-' || t[10] != 'T') return 0;
    long num(size_t from, size_t n) {
        long v = 0;
        foreach (i; from .. from + n) v = v * 10 + (t[i] - '0');
        return v;
    }
    long y = num(0, 4), m = num(5, 2), d = num(8, 2);
    // Days from the civil date, Howard Hinnant's algorithm.
    y -= m <= 2 ? 1 : 0;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long days = era * 146097 + doe - 719468;
    return days * 86400 + num(11, 2) * 3600 + num(14, 2) * 60 + num(17, 2);
}

// The value of a key inside the named object of obj: `"began":{"live":"…"}`.
const(char)[] inObject(const(char)[] obj, const(char)[] object, const(char)[] key) {
    import statusline : indexOf;
    char[32] open;
    size_t n = 0;
    foreach (c; `"`) open[n++] = c;
    foreach (c; object) if (n < open.length - 3) open[n++] = c;
    foreach (c; `":{`) open[n++] = c;
    auto at = indexOf(obj, open[0 .. n]);
    if (at < 0) return null;
    auto inner = nextObject(obj, cast(size_t) at + n - 1);
    if (!inner.ok) return null;
    return jsonString(obj[inner.start .. inner.end], key);
}

// How many of a deploy's checks said state.
int checksSaid(const(char)[] obj, const(char)[] state) {
    import statusline : indexOf;
    auto at = indexOf(obj, `"checks":{`);
    if (at < 0) return 0;
    auto inner = nextObject(obj, cast(size_t) at + 9);
    if (!inner.ok) return 0;
    auto checks = obj[inner.start .. inner.end];
    char[16] said;
    size_t n = 0;
    foreach (c; `:"`) said[n++] = c;
    foreach (c; state) if (n < said.length - 1) said[n++] = c;
    said[n++] = '"';
    int count = 0;
    size_t from = 0;
    while (from < checks.length) {
        auto hit = indexOf(checks[from .. $], said[0 .. n]);
        if (hit < 0) break;
        count++;
        from += cast(size_t) hit + n;
    }
    return count;
}

// How far along the node's own build a stage is, of three.
int builtOf(const(char)[] stage) {
    if (stage == "building") return 1;
    if (stage == "restarting") return 2;
    if (stage == "live") return 3;
    return 0;
}

// When a deploy last moved: the latest of the stages it began.
long movedAt(const(char)[] obj) {
    long latest = 0;
    foreach (stage; ["checks", "queued", "building", "restarting", "live", "failed", "unchanged", "disabled", "interrupted"]) {
        auto at = epochOf(inObject(obj, "began", stage));
        if (at > latest) latest = at;
    }
    return latest;
}

// One deploy as the node's data says it, drawn on the plugin's own name, with
// the version its build said in the name's place every other turn.
// Nothing for a deploy that is over; newest is when another deploy last moved.
size_t deployInto(const(char)[] obj, long now, long newest, char[] dest) {
    import statusline : indexOf;

    auto name = jsonString(obj, "plugin");
    auto stage = jsonString(obj, "stage");
    if (name is null || stage is null) return 0;

    bool failed = stage == "failed";
    bool live = stage == "live";
    bool flying = stage == "checks" || stage == "queued" || stage == "building" || stage == "restarting";
    if (live && now - epochOf(inObject(obj, "began", "live")) >= FINISH) return 0;
    // Time clears a failure, and so does other news.
    if (failed) {
        auto at = epochOf(inObject(obj, "began", "failed"));
        if (now - at >= FAILURE || newest > at) return 0;
    }
    if (!flying && !live && !failed) return 0;

    auto incoming = jsonString(obj, "version");
    if (incoming is null) incoming = name;
    auto shown = (now / ALTERNATE) % 2 == 0 ? name : incoming;
    auto width = name.length > incoming.length ? name.length : incoming.length;
    char[64] slot;
    size_t w = 0;
    foreach (c; shown) if (w < slot.length) slot[w++] = c;
    while (w < width && w < slot.length) slot[w++] = ' ';

    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    if (live) {
        put(FINISHED); put(slot[0 .. w]); put(PLAIN);
        return o;
    }

    auto passed = checksSaid(obj, "done");
    auto total = passed + checksSaid(obj, "failed") + checksSaid(obj, "running") + checksSaid(obj, "waiting");
    auto checks = Fill(passed, total, checksSaid(obj, "failed") > 0, indexOf(obj, `"pushed":true`) >= 0);
    auto node = Fill(builtOf(stage), 3, failed, true);
    return filledNameInto(slot[0 .. w], checks, node, dest);
}

// The row with each deploy drawn in place of its plugin's item: tmux names the
// item's span after the plugin, so the span is found by that. A plugin the row
// has no span for is drawn first.
size_t deploysOverInto(const(char)[] line, const(char)[] body_, long now, char[] dest) {
    import statusline : indexOf;

    char[8192] work;
    size_t w = 0;
    foreach (c; line) if (w < work.length) work[w++] = c;

    auto deploysAt = indexOf(body_, `"deploys":`);
    if (deploysAt < 0) {
        foreach (i; 0 .. w) if (i < dest.length) dest[i] = work[i];
        return w < dest.length ? w : dest.length;
    }
    auto deploys = body_[cast(size_t) deploysAt .. $];

    size_t at = 0;
    while (true) {
        auto span = nextObject(deploys, at);
        if (!span.ok) break;
        at = span.end;
        auto obj = deploys[span.start .. span.end];

        // Other news, for a failure: when any other deploy last moved.
        long newest = 0;
        size_t other = 0;
        while (true) {
            auto o = nextObject(deploys, other);
            if (!o.ok) break;
            other = o.end;
            if (o.start == span.start) continue;
            auto moved = movedAt(deploys[o.start .. o.end]);
            if (moved > newest) newest = moved;
        }

        char[2048] drawn;
        auto dn = deployInto(obj, now, newest, drawn[]);
        if (dn == 0) continue;

        char[64] marker;
        size_t m = 0;
        foreach (c; "#[range=user|") marker[m++] = c;
        foreach (i, c; jsonString(obj, "plugin")) {
            if (i >= 15) break;
            marker[m++] = c == '/' ? '.' : c;
        }
        marker[m++] = ']';

        char[8192] next;
        size_t n = 0;
        void put(const(char)[] t) { foreach (c; t) if (n < next.length) next[n++] = c; }

        auto start = indexOf(work[0 .. w], marker[0 .. m]);
        auto end = start < 0 ? -1 : indexOf(work[cast(size_t) start .. w], "#[norange]");
        if (start < 0 || end < 0) {
            put(drawn[0 .. dn]);
            if (w > 0) put(SEP);
            put(work[0 .. w]);
        } else {
            auto s = cast(size_t) start;
            auto e = s + cast(size_t) end;
            put(work[0 .. s]);
            put(marker[0 .. m]);
            put(drawn[0 .. dn]);
            put(work[e .. w]);
        }
        foreach (i; 0 .. n) work[i] = next[i];
        w = n;
    }

    size_t o = 0;
    foreach (c; work[0 .. w]) if (o < dest.length) dest[o++] = c;
    return o;
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
