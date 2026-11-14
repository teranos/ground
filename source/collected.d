module collected;

// "for knowing what is incoming"
// "and also what is outbound,"
//
// What agents said to an agent waits at the node until it is delivered or a
// person releases it (QNTX server/collected.go). mycelia keeps the node's
// answer under ~/.local/state/ug/collected; this reads it for the session it
// runs in, by the DID of the session's own key.

import zbuf : ZBuf;

enum BOOK_COMMAND = q"EOS
# what waits for this session, and what it said that waits for another, as mycelia kept them:
ground collected
# the same, as the data ag draws above the prompt:
ground collected json
# what a person does with what waits for an agent, signed with ~/.qntx/key:
ground collected release Mycelia
ground collected hold Mycelia 18:00
ground collected cancel Mycelia 6f1c2a9d3b4e5f60
EOS";

// How old an answer may be before mycelia is taken to have stopped asking: as
// ground_tmux takes it (ug/mycelia.d SILENT).
enum SILENT = 60;

// What is kept for did, said into out_, one line a message: when it is due
// on the clock offset seconds from UTC, <-- for what comes in and --> for
// what goes out, who said it or is to hear it, and what it says. Nothing
// waiting either way says nothing. 0 when it is the node's answer, 1 when it
// is what kept mycelia from one.
// "18:37 <-- Shiitake: \"the things Shiitake said to us\""
// "we dont need three lines for 1 message"
int collectedFor(const(char)[] kept, const(char)[] did, long now, long offset, ref ZBuf out_) {
    import libjsonc : json_object, json_type, json_object_get_type, json_object_array_length,
        json_object_array_get_idx, json_object_get_string, json_object_get_string_len,
        json_object_put, jsonField, parseJson;

    out_.reset();
    long at = 0;
    size_t i = 0;
    while (i < kept.length && kept[i] >= '0' && kept[i] <= '9') at = at * 10 + (kept[i++] - '0');
    if (i == 0 || i >= kept.length || kept[i] != '\n') {
        out_.put("mycelia has kept nothing: it has not asked the node\n");
        return 1;
    }
    auto answer = kept[i + 1 .. $];
    if (now - at > SILENT) {
        out_.put("mycelia last asked the node ");
        out_.putUint(cast(ulong)(now - at));
        out_.put("s ago: what it kept is not current\n");
        return 1;
    }
    auto o = parseJson(answer);
    scope (exit) json_object_put(o);
    auto all = jsonField(o, "collected");
    if (json_object_get_type(all) != json_type.array) {
        out_.put("mycelia could not ask the node: ");
        out_.put(answer);
        out_.put("\n");
        return 1;
    }

    static const(char)[] text(json_object* v) {
        if (json_object_get_type(v) != json_type.string_) return null;
        return json_object_get_string(v)[0 .. cast(size_t) json_object_get_string_len(v)];
    }
    void line(const(char)[] due, const(char)[] way, const(char)[] who, const(char)[] says) {
        out_.put(clockOf(due, offset));
        out_.put(way);
        out_.put(who);
        out_.put(": \"");
        out_.put(says);
        out_.put("\"\n");
    }

    auto n = json_object_array_length(all);
    // What comes in: what waits for did.
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        if (text(jsonField(one, "did")) != did) continue;
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array) continue;
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            line(text(jsonField(one, "due")), " <-- ", text(jsonField(said, "from")), text(jsonField(said, "says")));
        }
    }
    // What goes out: what did said that waits for another.
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array) continue;
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            if (text(jsonField(said, "from_did")) != did) continue;
            line(text(jsonField(one, "due")), " --> ", text(jsonField(one, "to")), text(jsonField(said, "says")));
        }
    }
    return 0;
}

enum USAGE = `usage: ground collected                      what waits, and what this session said that waits
       ground collected json                 the same, as the data ag draws
       ground collected release <to> [says]  delivers what waits for <to> now, as says when given
       ground collected later <to>           passes it to the next delivery
       ground collected hold <to> <HH:MM>    nothing is delivered before then, on this clock
       ground collected cancel <to> [id]     never delivered: the one by id, else all of it
` ~ "\0";
enum NO_SESSION = `ground collected: CLAUDE_CODE_SESSION_ID is not set, so this is no session's` ~ "\n\0";
enum NO_KEY = `ground collected: this session has no key of its own, so no DID to read for: ground name gives it one` ~ "\n\0";
enum NO_HOME = `ground collected: HOME names no home to read what mycelia kept from` ~ "\n\0";

// ground collected: what mycelia kept, for the session this runs in; `json`
// as the data ag draws; a sigil of the collected signum asked of the node as
// the person, signed with ~/.qntx/key.
int handleCollected(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs, fopen, fread, fclose;
    import core.stdc.stdlib : getenv;
    import core.stdc.time : time, time_t, tm;
    import core.sys.posix.time : localtime_r;
    import hookrun : argLen;
    import naming : sessionKeyFile;
    import signed : keptKey, putDID;

    const(char)[] arg(int at) { return argc > at ? argv[at][0 .. argLen(argv[at])] : null; }
    auto verb = arg(2);
    auto now = cast(long) time(null);
    time_t t = cast(time_t) now;
    tm local;
    localtime_r(&t, &local);
    long offset = local.tm_gmtoff;

    if (verb == "release" || verb == "later" || verb == "cancel" || verb == "hold")
        return ask(verb, arg(3), arg(4), now, offset);
    if (verb.length > 0 && verb != "json") {
        fputs(USAGE.ptr, stderr);
        return 2;
    }

    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs(NO_SESSION.ptr, stderr);
        return 1;
    }
    size_t sn = 0;
    while (sid[sn] != 0) sn++;
    auto key = keptKey(sessionKeyFile(sid[0 .. sn]));
    if (!key.held) {
        fputs(NO_KEY.ptr, stderr);
        return 1;
    }
    __gshared ZBuf did;
    did.reset();
    putDID(did, key.public_[]);

    auto home = getenv("HOME\0".ptr);
    if (home is null) {
        fputs(NO_HOME.ptr, stderr);
        return 1;
    }
    size_t hn = 0;
    while (home[hn] != 0) hn++;
    __gshared ZBuf path;
    path.reset();
    path.put(home[0 .. hn]);
    path.put("/.local/state/ug/collected");

    __gshared char[262144 + 32] kept;
    size_t got = 0;
    auto f = fopen(path.ptr(), "rb");
    if (f !is null) {
        got = fread(kept.ptr, 1, kept.length, f);
        fclose(f);
    }

    __gshared ZBuf said;
    if (verb == "json") {
        auto rc = collectedJson(kept[0 .. got], did.slice(), now, offset, said);
        said.put("\n");
        fputs(said.ptr(), stdout);
        return rc;
    }
    auto rc = collectedFor(kept[0 .. got], did.slice(), now, offset, said);
    if (rc != 0) fputs(`ground collected: `.ptr, stderr);
    fputs(said.ptr(), rc == 0 ? stdout : stderr);
    return rc;
}

// One sigil of the collected signum, asked of the node this ground is signed
// in to, as the person: signed with ~/.qntx/key.
private int ask(const(char)[] verb, const(char)[] to, const(char)[] more, long now, long offset) {
    import core.stdc.stdio : stderr, fputs;

    void no(const(char)[] why) {
        __gshared ZBuf line;
        line.reset();
        line.put(`ground collected `);
        line.put(verb);
        line.put(`: `);
        line.put(why);
        line.put("\n");
        fputs(line.ptr(), stderr);
    }
    if (to.length == 0) { no(`names no agent it is for`); return 2; }
    __gshared ZBuf until, body_;
    const(char)[][4] pairs;
    pairs[0] = "to";
    pairs[1] = to;
    size_t np = 2;
    if (verb == "hold") {
        if (!untilOf(more, now, offset, until)) { no(`holds until a time on this clock, HH:MM`); return 2; }
        pairs[2] = "until";
        pairs[3] = until.slice();
        np = 4;
    } else if (verb == "release" && more.length > 0) {
        pairs[2] = "says";
        pairs[3] = more;
        np = 4;
    } else if (verb == "cancel" && more.length > 0) {
        pairs[2] = "id";
        pairs[3] = more;
        np = 4;
    }
    bodyOf(pairs[0 .. np], body_);

    // "kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"
    // Signed as the person by mycelia, which holds the person's key after one
    // touch: ground's own key is an agent's to the node, and is refused.
    __gshared ZBuf path, asked;
    path.reset();
    path.put("/api/collected/");
    path.put(verb);
    pressFor(path.slice(), body_.slice(), asked);
    __gshared ZBuf said;
    auto reached = toMycelia(asked.slice(), said);
    if (reached.length > 0) { no(reached); return 1; }
    auto answer = answerOf(said.slice());
    if (answer.status == 200) return 0;
    __gshared ZBuf why;
    why.reset();
    why.put(path.slice());
    if (answer.status > 0) {
        why.put(` answered `);
        why.putUint(cast(ulong) answer.status);
        why.put(`: `);
    } else {
        why.put(` was not asked: `);
    }
    why.put(answer.body_);
    no(why.slice());
    return 1;
}

// A press as mycelia's socket takes it: the path, a newline, the body.
void pressFor(const(char)[] path, const(char)[] body_, ref ZBuf out_) {
    out_.reset();
    out_.put(path);
    out_.put("\n");
    out_.put(body_);
}

struct Answer {
    int status;
    const(char)[] body_;
}

// mycelia's answer: the node's status on the first line, 0 when the node was
// not asked, and its body or why after.
Answer answerOf(const(char)[] said) {
    int status = 0;
    size_t i = 0;
    while (i < said.length && said[i] >= '0' && said[i] <= '9') status = status * 10 + (said[i++] - '0');
    if (i >= said.length || said[i] != '\n') return Answer(0, said[0 .. 0]);
    return Answer(status, said[i + 1 .. $]);
}

// Asks mycelia over its socket, its answer into said; empty when it answered,
// else why it could not be asked.
private const(char)[] toMycelia(const(char)[] asked, ref ZBuf said) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.sys.socket : socket, connect, shutdown, AF_UNIX, SOCK_STREAM, SHUT_WR, sockaddr;
    import core.sys.posix.sys.un : sockaddr_un;
    import core.sys.posix.unistd : read, write, close;
    said.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null) return `HOME names no home to find mycelia's socket in`;
    __gshared char[104] path = 0;
    size_t o = 0;
    for (size_t i = 0; home[i] != 0 && o < 60; i++) path[o++] = home[i];
    foreach (c; "/.local/state/ug/mycelia.sock") path[o++] = c;
    path[o] = 0;
    auto fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return `no socket could be made to ask mycelia`;
    scope (exit) close(fd);
    sockaddr_un at;
    at.sun_family = AF_UNIX;
    foreach (i; 0 .. o + 1) at.sun_path[i] = cast(byte) path[i];
    if (connect(fd, cast(sockaddr*) &at, cast(uint) sockaddr_un.sizeof) != 0)
        return `mycelia is not listening at ~/.local/state/ug/mycelia.sock, so nothing signs as the person`;
    if (write(fd, asked.ptr, asked.length) != asked.length) return `the press was not handed to mycelia whole`;
    shutdown(fd, SHUT_WR);
    __gshared char[65536] got = void;
    size_t n = 0;
    while (n < got.length) {
        auto r = read(fd, &got[n], got.length - n);
        if (r <= 0) break;
        n += r;
    }
    said.put(got[0 .. n]);
    return null;
}

// --- What ag draws, and what its buttons ask ---

// Seconds since the epoch of an RFC3339 instant as the node writes it, in
// UTC; -1 for what is not one.
long epochOf(const(char)[] t) {
    if (t.length < 19 || t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':') return -1;
    long num(size_t from, size_t n) {
        long v = 0;
        foreach (i; from .. from + n) {
            if (t[i] < '0' || t[i] > '9') return -1;
            v = v * 10 + (t[i] - '0');
        }
        return v;
    }
    long y = num(0, 4), m = num(5, 2), d = num(8, 2), hh = num(11, 2), mm = num(14, 2), ss = num(17, 2);
    if (y < 0 || m < 1 || m > 12 || d < 1 || hh < 0 || mm < 0 || ss < 0) return -1;
    // Days from the civil date, Howard Hinnant's algorithm, as ug/tmux.d reads them.
    y -= m <= 2 ? 1 : 0;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss;
}

private void put2(ref ZBuf out_, long v) {
    out_.putChar(cast(char)('0' + v / 10 % 10));
    out_.putChar(cast(char)('0' + v % 10));
}

// The instant on the clock offset seconds from UTC, as hours and minutes;
// empty for what is not an instant.
const(char)[] clockOf(const(char)[] t, long offset) {
    __gshared ZBuf clock;
    clock.reset();
    auto at = epochOf(t);
    if (at < 0) return clock.slice();
    auto s = ((at + offset) % 86400 + 86400) % 86400;
    put2(clock, s / 3600);
    clock.putChar(':');
    put2(clock, s / 60 % 60);
    return clock.slice();
}

private void putString(ref ZBuf out_, const(char)[] s) {
    enum hex = "0123456789abcdef";
    out_.putChar('"');
    foreach (c; s) {
        if (c == '"' || c == '\\') { out_.putChar('\\'); out_.putChar(c); }
        else if (c == '\n') out_.put("\\n");
        else if (c == '\r') out_.put("\\r");
        else if (c == '\t') out_.put("\\t");
        else if (cast(ubyte) c < 0x20) { out_.put("\\u00"); out_.putChar(hex[c >> 4]); out_.putChar(hex[c & 15]); }
        else out_.putChar(c);
    }
    out_.putChar('"');
}

// What is kept for did, as the data ag draws: what comes in, by the agent it
// waits for, and what did said that goes out, each item with its id; times on
// the clock offset seconds from UTC. 1, with what went wrong as error, when
// what is kept is no answer of the node's.
int collectedJson(const(char)[] kept, const(char)[] did, long now, long offset, ref ZBuf out_) {
    import libjsonc : json_object, json_type, json_object_get_type, json_object_array_length,
        json_object_array_get_idx, json_object_get_string, json_object_get_string_len,
        json_object_put, jsonField, parseJson;

    __gshared ZBuf why;
    out_.reset();
    void error(const(char)[] said) {
        out_.put(`{"error":`);
        auto s = said;
        while (s.length > 0 && s[$ - 1] == '\n') s = s[0 .. $ - 1];
        putString(out_, s);
        out_.put("}");
    }
    // What is no answer is said as collectedFor says it.
    if (collectedFor(kept, did, now, offset, why) != 0) { error(why.slice()); return 1; }
    size_t i = 0;
    while (kept[i] != '\n') i++;
    auto o = parseJson(kept[i + 1 .. $]);
    scope (exit) json_object_put(o);
    auto all = jsonField(o, "collected");

    static const(char)[] text(json_object* v) {
        if (json_object_get_type(v) != json_type.string_) return null;
        return json_object_get_string(v)[0 .. cast(size_t) json_object_get_string_len(v)];
    }
    void field(const(char)[] name, const(char)[] value, bool first = false) {
        if (!first) out_.putChar(',');
        putString(out_, name);
        out_.putChar(':');
        putString(out_, value);
    }

    auto n = json_object_array_length(all);
    out_.put(`{"incoming":[`);
    bool firstIn = true;
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        if (text(jsonField(one, "did")) != did) continue;
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array || json_object_array_length(waiting) == 0) continue;
        if (!firstIn) out_.putChar(',');
        firstIn = false;
        out_.putChar('{');
        field("to", text(jsonField(one, "to")), true);
        field("did", did);
        field("due", clockOf(text(jsonField(one, "due")), offset));
        out_.put(`,"items":[`);
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            if (w > 0) out_.putChar(',');
            out_.putChar('{');
            field("id", text(jsonField(said, "id")), true);
            field("from", text(jsonField(said, "from")));
            field("says", text(jsonField(said, "says")));
            field("at", clockOf(text(jsonField(said, "at")), offset));
            out_.putChar('}');
        }
        out_.put("]}");
    }
    out_.put(`],"outbound":[`);
    bool firstOut = true;
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array) continue;
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            if (text(jsonField(said, "from_did")) != did) continue;
            if (!firstOut) out_.putChar(',');
            firstOut = false;
            out_.putChar('{');
            field("to", text(jsonField(one, "to")), true);
            field("did", text(jsonField(one, "did")));
            field("due", clockOf(text(jsonField(one, "due")), offset));
            field("id", text(jsonField(said, "id")));
            field("says", text(jsonField(said, "says")));
            field("at", clockOf(text(jsonField(said, "at")), offset));
            out_.putChar('}');
        }
    }
    out_.put("]}");
    return 0;
}

// The next moment a clock offset seconds from UTC reads hhmm ("HH:MM") at or
// after now, as RFC3339 in UTC; false for what is no such time.
bool untilOf(const(char)[] hhmm, long now, long offset, ref ZBuf out_) {
    out_.reset();
    if (hhmm.length != 5 || hhmm[2] != ':') return false;
    foreach (j; [0, 1, 3, 4]) if (hhmm[j] < '0' || hhmm[j] > '9') return false;
    long h = (hhmm[0] - '0') * 10 + (hhmm[1] - '0');
    long m = (hhmm[3] - '0') * 10 + (hhmm[4] - '0');
    if (h > 23 || m > 59) return false;
    auto local = now + offset;
    auto at = local - ((local % 86400) + 86400) % 86400 + h * 3600 + m * 60;
    if (at <= local) at += 86400;
    auto utc = at - offset;
    // The civil date of a day count, Howard Hinnant's algorithm.
    long z = (utc >= 0 ? utc : utc - 86399) / 86400 + 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    long d = doy - (153 * mp + 2) / 5 + 1;
    long mo = mp + (mp < 10 ? 3 : -9);
    long y = yoe + era * 400 + (mo <= 2 ? 1 : 0);
    auto s = ((utc % 86400) + 86400) % 86400;
    out_.putUint(cast(ulong) y);
    out_.putChar('-'); put2(out_, mo);
    out_.putChar('-'); put2(out_, d);
    out_.putChar('T'); put2(out_, s / 3600);
    out_.putChar(':'); put2(out_, s / 60 % 60);
    out_.putChar(':'); put2(out_, s % 60);
    out_.putChar('Z');
    return true;
}

// A sigil's parameters, name then value, as the JSON object the node reads.
void bodyOf(const(char)[][] pairs, ref ZBuf out_) {
    out_.reset();
    out_.putChar('{');
    for (size_t j = 0; j + 1 < pairs.length; j += 2) {
        if (j > 0) out_.putChar(',');
        putString(out_, pairs[j]);
        out_.putChar(':');
        putString(out_, pairs[j + 1]);
    }
    out_.putChar('}');
}
