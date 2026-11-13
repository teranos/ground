module mycelia;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
//
// mycelia is the one process on a machine that asks the node. Each pass it
// asks for the node's row and its news, draws the row as tmux reads it, and
// keeps that under home with the moment it asked; ground_tmux draws what is
// kept and asks nothing. The news goes into ground's store, where sky hands
// it to the session.

import tmux : RED, PLAIN;
import qntx : State;

// How long between passes, and how old a kept row may be before mycelia is
// taken to have stopped: a pass that waits out every fetch's MAX_TIME is
// still well inside it.
enum PASS = 5;
enum SILENT = 60;

// Where the row is kept. ug's state lives beside it.
enum KEPT = ".local/state/ug/mycelia";

size_t keptPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0 || home.length + KEPT.length + 2 > dest.length) return 0;
    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; KEPT) dest[o++] = c;
    if (o < dest.length) dest[o] = 0;
    return o;
}

// The moment it asked, a newline, and the row.
size_t keptInto(long at, const(char)[] line, char[] dest) {
    size_t o = 0;
    char[24] d = 0;
    size_t dl = 0;
    long v = at;
    if (v <= 0) d[dl++] = '0';
    else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
    foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    if (o < dest.length) dest[o++] = '\n';
    foreach (c; line) if (o < dest.length) dest[o++] = c;
    return o;
}

struct Kept {
    long at;
    const(char)[] line;
}

// A stamp that is not a number is no pass.
Kept keptOf(const(char)[] text) {
    long v = 0;
    size_t i = 0;
    while (i < text.length && text[i] >= '0' && text[i] <= '9') {
        v = v * 10 + (text[i] - '0');
        i++;
    }
    if (i == 0 || i >= text.length || text[i] != '\n') return Kept(0, text[0 .. 0]);
    return Kept(v, text[i + 1 .. $]);
}

// mycelia has kept nothing for this long, or has never kept anything (-1).
size_t silentInto(long since, char[] dest) {
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }

    put(RED);
    put("mycelia silent");
    if (since >= 0) {
        long n;
        const(char)[] unit;
        if (since < 3600) { n = since / 60; unit = "minute"; }
        else if (since < 86400) { n = since / 3600; unit = "hour"; }
        else { n = since / 86400; unit = "day"; }

        put(" ");
        char[24] d = 0;
        size_t dl = 0;
        long v = n;
        if (v <= 0) d[dl++] = '0';
        else while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
        put(" ");
        put(unit);
        if (n != 1) put("s");
    }
    put(PLAIN);
    return o;
}

// The row as this pass learned it from the node.
size_t passInto(const(char)[] home, long now, char[] dest) {
    import probe : fetch;
    import qntx : State, standing;
    import statusline : lastAnswer, keepAnswer, QUIET;
    import tmux : readFocus, clearFocus, rowPathInto, oneLineInto, deploysOverInto,
                  statusInto, stateInto, sinceInto;

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

    size_t n = 0;
    if (answer.state == State.ok) {
        // What is kept stands in for the node's row through a short silence,
        // so a plugin's row is not what gets kept.
        if (focus is null) keepAnswer(home, now, answer.body_);
        n = oneLineInto(answer.body_, dest);
        // The node answered, so it can be asked what it left for this token,
        // and each deploy is drawn on its plugin's name.
        auto json = newsPass(home);
        __gshared char[8192] over = void;
        auto on = deploysOverInto(dest[0 .. n], json, now, over[]);
        foreach (i; 0 .. on) if (i < dest.length) dest[i] = over[i];
        n = on < dest.length ? on : dest.length;
    } else if (answer.status > 0) {
        // The node answered and the answer was a refusal. That is not silence,
        // and it must not wait out the quiet window pretending it might pass.
        n = statusInto(answer.status, dest);
    } else if (standing(answer.state)) {
        // Nothing was sent, and nothing about waiting will change that.
        n = stateInto(answer.state, dest);
    } else {
        auto seen = lastAnswer(home);
        if (seen.at > 0) {
            auto silence = now - seen.at;
            if (silence < QUIET)
                n = oneLineInto(seen.body_, dest);
            else
                n = sinceInto(silence, dest);
        }
    }
    return n;
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
    import json : jsonString;
    import statusline : nextObject, itemsAt;
    import tmux : isJson;

    // Asked for as the row's own token. The node files news under the person
    // a token speaks for, so what the ground token's push earned is found by
    // this one; the ground token itself cannot read the row.
    auto answer = fetch(home, "/am/statusline?format=json");
    if (answer.state != State.ok || !isJson(answer.body_)) return null;

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

        // "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"
        // What is said to a name is the session's that keeps the name. No
        // session here keeps it: it is another machine's, and is left on the
        // row for that machine's mycelia.
        auto to = jsonString(whole.body_, "to");
        __gshared char[128] keeper = void;
        if ((session is null || session.length == 0) && to !is null && to.length > 0) {
            import named : sessionKeeping;
            auto kept = sessionKeeping(home, to, keeper[]);
            if (kept == 0) continue;
            session = keeper[0 .. kept];
        }

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

        // A null slice is empty: no session names the project, no repo is none.
        leaveNews(home, id, session, repo, detail[0 .. d]);
    }
    return body_;
}

// "for knowing what is incoming"
// "and also what is outbound,"
// What agents said to an agent waits at the node until it is delivered or a
// person releases it (QNTX server/collected.go). mycelia keeps the node's
// answer whole, beside the row; who it is for and who said it are the
// reader's to pick out by DID.
enum COLLECTED = "/api/collected";
enum COLLECTED_KEPT = ".local/state/ug/collected";

size_t collectedPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0 || home.length + COLLECTED_KEPT.length + 2 > dest.length) return 0;
    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; COLLECTED_KEPT) dest[o++] = c;
    if (o < dest.length) dest[o] = 0;
    return o;
}

// What the node did not answer, in words: the status it chose, else the step
// that failed.
size_t refusedInto(State s, int status, char[] dest) {
    import qntx : word;
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }
    put("QNTX ");
    if (status > 0) {
        char[12] d = 0;
        size_t dl = 0;
        int v = status;
        while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) if (o < dest.length) dest[o++] = d[i];
    } else {
        put(word(s));
    }
    return o;
}

// The node's answer when it gave one, else what went wrong, kept with the
// moment it was asked.
void collectedPass(const(char)[] home, long now) {
    import probe : fetch;
    __gshared char[512] path = void;
    auto n = collectedPathInto(home, path[]);
    auto answer = fetch(home, COLLECTED);
    if (answer.state == State.ok) {
        keepAt(path[0 .. n], now, answer.body_);
        return;
    }
    __gshared char[64] why = void;
    auto w = refusedInto(answer.state, answer.status, why[]);
    keepAt(path[0 .. n], now, why[0 .. w]);
}

// Written beside and moved over, so ground_tmux never reads half a row.
void keep(const(char)[] home, long now, const(char)[] line) {
    __gshared char[512] path = void;
    auto n = keptPathInto(home, path[]);
    keepAt(path[0 .. n], now, line);
}

// The moment and the text at path, written beside it and moved over.
void keepAt(const(char)[] at, long now, const(char)[] text_) {
    import core.stdc.stdio : fopen, fwrite, fclose, rename;
    import core.sys.posix.sys.stat : mkdir;

    __gshared char[512] path = void;
    auto n = at.length;
    if (n == 0 || n + 6 > path.length) return;
    foreach (i, c; at) path[i] = c;
    path[n] = 0;
    foreach_reverse (i; 0 .. n) {
        if (path[i] != '/') continue;
        path[i] = 0;
        mkdir(&path[0], 493); // 0755
        path[i] = '/';
        break;
    }
    __gshared char[520] beside = void;
    foreach (i; 0 .. n) beside[i] = path[i];
    foreach (i, c; ".new") beside[n + i] = c;
    beside[n + 4] = 0;

    // As large as the most fetch answers with, and the stamp before it.
    __gshared char[262144 + 32] text = void;
    auto t = keptInto(now, text_, text[]);
    auto f = fopen(&beside[0], "wb");
    if (f is null) return;
    fwrite(text.ptr, 1, t, f);
    fclose(f);
    rename(&beside[0], &path[0]);
}

// What ground_tmux reads. Nothing kept is a Kept at 0.
Kept readKept(const(char)[] home) {
    import core.stdc.stdio : fopen, fread, fclose;
    __gshared char[512] path = void;
    if (keptPathInto(home, path[]) == 0) return Kept(0, null);
    auto f = fopen(&path[0], "rb");
    if (f is null) return Kept(0, null);
    __gshared char[8256] buf = void;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);
    return keptOf(buf[0 .. n]);
}

// "mycelia connect needs to also be a thing"
// With no verb mycelia asks the node, pass after pass. connect signs the key
// it asks with in to the node, as `ground_code login` does for an ACP client:
// the same device flow (source/code/login.d), against the node mycelia asks.
enum Verb { ask, connect, unknown }

Verb verbOf(const(char)[] verb) {
    if (verb.length == 0) return Verb.ask;
    if (verb == "connect") return Verb.connect;
    return Verb.unknown;
}

// The whole of mycelia: a pass, kept, then a wait, until it is stopped.
int myceliaMain(const(char)[] home) {
    import core.stdc.time : time;
    import core.sys.posix.unistd : sleep;
    while (true) {
        auto now = cast(long) time(null);
        __gshared char[8192] line = void;
        auto n = passInto(home, now, line[]);
        keep(home, now, line[0 .. n]);
        collectedPass(home, now);
        sleep(PASS);
    }
}
