module ctfe;

// "can you have a CTFE Chapter with one or two line graphs on ground CTFE"

import core.stdc.stdio : stdout, stderr, fwrite;

enum BOOK_COMMAND = q"EOS
# what each build of ground cost to compile, as the node holds it:
ground ctfe
# the same rows as the book draws them:
ground ctfe tex
EOS";

// --- one build ---

// A bench:ctfe row as the series reads it: where it was built, the UTC minute,
// seconds to the hundredth, and the peak in KiB.
struct Run {
    const(char)[] where;
    const(char)[] when;
    int centis;
    long peakKib;
}

int centisOf(double seconds) { return cast(int)(seconds * 100 + 0.5); }

long mibOf(long kib) { return (kib + 512) / 1024; }

struct Text {
    char[24] buf = 0;
    size_t n;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    const(char)[] text() const return { return buf[0 .. n]; }
    alias text this;
}

private void putNum(ref Text t, long v, int width = 1) {
    char[20] d;
    int k = 0;
    do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0 || k < width);
    while (k > 0) t.put(d[--k]);
}

Text secondsText(int centis) {
    Text t;
    putNum(t, centis / 100);
    t.put('.');
    putNum(t, centis % 100, 2);
    return t;
}

// --- the minute, in UTC ---

private bool digits(const(char)[] s, size_t at, size_t n, ref int v) {
    if (at + n > s.length) return false;
    v = 0;
    foreach (c; s[at .. at + n]) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
    }
    return true;
}

// Days since 1970-01-01 of a civil date, and back (Hinnant's algorithms).
private long daysFrom(int y, int m, int d) {
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

private void civilFrom(long z, ref int y, ref int m, ref int d) {
    z += 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    d = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    m = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    y = cast(int)(yoe + era * 400 + (m <= 2));
}

struct Minute {
    char[16] buf = 0;
    size_t n;
    const(char)[] text() const return { return buf[0 .. n]; }
    alias text this;
}

// An RFC 3339 timestamp, Z or a numeric offset, as the UTC minute the axis
// reads: 2026-10-24 05:36. Anything else is no minute.
Minute utcMinute(const(char)[] ts) {
    Minute out_;
    int y, mo, d, h, mi;
    if (!digits(ts, 0, 4, y) || ts.length < 16 || ts[4] != '-' || !digits(ts, 5, 2, mo)
        || ts[7] != '-' || !digits(ts, 8, 2, d) || ts[10] != 'T' || !digits(ts, 11, 2, h)
        || ts[13] != ':' || !digits(ts, 14, 2, mi))
        return out_;
    size_t z = 16;
    while (z < ts.length && ts[z] != 'Z' && ts[z] != '+' && ts[z] != '-') z++;
    if (z >= ts.length) return out_;
    int offset = 0;
    if (ts[z] != 'Z') {
        int oh, om;
        if (ts.length != z + 6 || !digits(ts, z + 1, 2, oh) || ts[z + 3] != ':' || !digits(ts, z + 4, 2, om))
            return out_;
        offset = (ts[z] == '+' ? 1 : -1) * (oh * 60 + om);
    } else if (ts.length != z + 1) return out_;

    long minutes = daysFrom(y, mo, d) * 1440 + h * 60 + mi - offset;
    long day = minutes >= 0 ? minutes / 1440 : (minutes - 1439) / 1440;
    long inDay = minutes - day * 1440;
    civilFrom(day, y, mo, d);

    Text t;
    putNum(t, y, 4); t.put('-'); putNum(t, mo, 2); t.put('-'); putNum(t, d, 2);
    t.put(' '); putNum(t, inDay / 60, 2); t.put(':'); putNum(t, inDay % 60, 2);
    foreach (i, c; t.text()) out_.buf[i] = c;
    out_.n = t.n;
    return out_;
}

// --- the graphs ---

struct Tex {
    char[32768] buf = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < buf.length) buf[n++] = c; }
    const(char)[] text() const return { return buf[0 .. n]; }
}

private void axis(ref Tex t, const(Run)[] runs, const(char)[] unit, bool seconds) {
    t.put("\\par\\noindent\\begin{tikzpicture}\n"
        ~ "\\begin{axis}[date coordinates in=x, xticklabel={\\day.\\month. \\hour:\\minute}, "
        ~ "xticklabel style={font=\\scriptsize}, max space between ticks=80, ymin=0, width=\\textwidth, height=60mm, "
        ~ "legend style={at={(0.5,-0.18)}, anchor=north, legend columns=-1}, ylabel={");
    t.put(unit);
    t.put("}]\n");
    foreach (i, r; runs) {
        bool seen = false;
        foreach (q; runs[0 .. i]) if (q.where == r.where) { seen = true; break; }
        if (seen) continue;
        t.put("\\addplot coordinates {");
        bool first = true;
        foreach (q; runs) {
            if (q.where != r.where) continue;
            if (!first) t.put(" ");
            first = false;
            t.put("("); t.put(q.when); t.put(",");
            Text v;
            if (seconds) v = secondsText(q.centis);
            else putNum(v, mibOf(q.peakKib));
            t.put(v.text());
            t.put(")");
        }
        t.put("};\n\\addlegendentry{"); t.put(r.where); t.put("}\n");
    }
    t.put("\\end{axis}\n\\end{tikzpicture}\n");
}

// Seconds, then MiB: one line a place a build ran, in the order the places were
// first measured. No run, no graph.
Tex seriesTex(const(Run)[] runs) {
    Tex t;
    if (runs.length == 0) return t;
    axis(t, runs, "s", true);
    t.put("\n");
    axis(t, runs, "MiB", false);
    return t;
}

// --- the rows, as the node answers them ---

struct Runs {
    char[32][256] wheres;
    ubyte[256] whereLen;
    Minute[256] whens;
    int[256] centis;
    long[256] peaks;
    size_t count;
    // Every row the node answered, placed or not.
    size_t rows;
    // What could not be placed, a line a row. Said, never dropped.
    char[4096] saidBuf = 0;
    size_t saidLen;
    const(char)[] said() const return { return saidBuf[0 .. saidLen]; }
    void say(const(char)[] s) { foreach (c; s) if (saidLen < saidBuf.length) saidBuf[saidLen++] = c; }
    Run at(size_t i) const return {
        return Run(wheres[i][0 .. whereLen[i]], whens[i].text(), centis[i], peaks[i]);
    }
}

// Oldest first. The minute is fixed width, so text order is time order.
Runs readRuns(const(char)[] json) {
    import libjsonc : json_object, json_type, parseJson, jsonField, json_object_put,
        json_object_get_type, json_object_array_length, json_object_array_get_idx,
        json_object_get_string, json_object_get_string_len, json_object_get_double;

    Runs rs;
    auto root = parseJson(json);
    scope (exit) if (root !is null) json_object_put(root);
    if (root is null || json_object_get_type(root) != json_type.array) {
        rs.say("the node's answer is not a list of rows\n");
        return rs;
    }

    const(char)[] str(json_object* o) {
        if (o is null || json_object_get_type(o) != json_type.string_) return null;
        return json_object_get_string(o)[0 .. json_object_get_string_len(o)];
    }
    bool num(json_object* o) {
        if (o is null) return false;
        auto ty = json_object_get_type(o);
        return ty == json_type.double_ || ty == json_type.int_;
    }

    rs.rows = json_object_array_length(root);
    foreach (i; 0 .. rs.rows) {
        auto row = json_object_array_get_idx(root, i);
        auto id = str(jsonField(row, "id"));
        void refuse(const(char)[] why) { rs.say(id.length > 0 ? id : "a row"); rs.say(" "); rs.say(why); rs.say("\n"); }

        auto contexts = jsonField(row, "contexts");
        auto where = contexts !is null && json_object_get_type(contexts) == json_type.array
            && json_object_array_length(contexts) > 0 ? str(json_object_array_get_idx(contexts, 0)) : null;
        if (where.length == 0) { refuse("names no place it was built"); continue; }
        if (where.length > rs.wheres[0].length) { refuse("names a place longer than the series holds"); continue; }
        auto when = utcMinute(str(jsonField(row, "timestamp")));
        if (when.n == 0) { refuse("carries no timestamp the series reads"); continue; }
        auto attrs = jsonField(row, "attributes");
        auto seconds = jsonField(attrs, "seconds");
        auto peak = jsonField(attrs, "peak_kib");
        if (!num(seconds)) { refuse("carries no seconds"); continue; }
        if (!num(peak)) { refuse("carries no peak_kib"); continue; }
        if (rs.count == rs.centis.length) { refuse("is past the rows the series holds"); continue; }

        // Inserted in place, so the series is oldest first whatever order came.
        size_t at = rs.count;
        while (at > 0 && rs.whens[at - 1].text() > when.text()) {
            rs.wheres[at] = rs.wheres[at - 1]; rs.whereLen[at] = rs.whereLen[at - 1];
            rs.whens[at] = rs.whens[at - 1]; rs.centis[at] = rs.centis[at - 1]; rs.peaks[at] = rs.peaks[at - 1];
            at--;
        }
        foreach (k, c; where) rs.wheres[at][k] = c;
        rs.whereLen[at] = cast(ubyte) where.length;
        rs.whens[at] = when;
        rs.centis[at] = centisOf(json_object_get_double(seconds));
        rs.peaks[at] = cast(long)(json_object_get_double(peak) + 0.5);
        rs.count++;
    }
    return rs;
}

// --- the command ---

// The page asked for, read from the node ground streams to, with its token. It
// is what the series holds, and a full page is said: a series cut short is not
// the series.
private enum PAGE = Runs.init.centis.length;

private void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stderr); }
private void out_(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); }

int handleCtfe(int argc, const(char)** argv) {
    import nodeconfig : nodeHere;
    import attest : qntxToken;
    import http : httpGet;
    import db : ZBuf;

    const(char)[] mode;
    if (argc >= 3) { size_t n = 0; while (argv[2][n] != 0) n++; mode = argv[2][0 .. n]; }
    if (mode.length > 0 && mode != "tex") {
        say("ground ctfe: "); say(mode); say(" is not a way ground ctfe answers; it answers bare or tex\n");
        return 2;
    }

    __gshared typeof(nodeHere()) node;
    node = nodeHere();
    if (node.why().length > 0) {
        say("ground ctfe: "); say(node.why()); say("\n");
        return 1;
    }
    if (node.url.length == 0) {
        say("ground ctfe: no qntx block and no nodes.pbt names a node, and the rows are on one\n");
        return 1;
    }
    auto token = qntxToken(node.token);
    if (token.length == 0) {
        say("ground ctfe: no token at "); say(node.token); say(" for "); say(node.url); say("\n");
        return 1;
    }

    __gshared ZBuf url;
    url.reset();
    url.put(node.url);
    url.put("/api/attestations?predicate=bench:ctfe&limit=");
    {
        Text p; putNum(p, PAGE); url.put(p.text());
    }
    __gshared char[1024 * 1024] body_ = "";
    auto r = httpGet(url.slice(), token, body_[], 30);
    if (r.code != 0 || r.status != 200) {
        say("ground ctfe: "); say(url.slice()); say(" answered ");
        Text s; putNum(s, r.status); say(s.text());
        if (r.why().length > 0) { say(": "); say(r.why()); }
        else if (r.len > 0) { say(": "); say(body_[0 .. r.len]); }
        say("\n");
        return 1;
    }

    __gshared Runs rs;
    rs = readRuns(body_[0 .. r.len]);
    if (rs.said.length > 0) { say("ground ctfe: "); say(rs.said); }
    if (rs.rows >= PAGE) {
        say("ground ctfe: the node answered a full page; rows past it are not in this series\n");
        return 1;
    }

    if (mode == "tex") {
        __gshared Run[256] runs;
        foreach (i; 0 .. rs.count) runs[i] = rs.at(i);
        out_(seriesTex(runs[0 .. rs.count]).text());
        return rs.said.length > 0 ? 1 : 0;
    }

    out_("when (UTC)        where           seconds  peak MiB\n");
    foreach (i; 0 .. rs.count) {
        auto run = rs.at(i);
        out_(run.when); out_("  ");
        out_(run.where);
        foreach (_; run.where.length .. 16) out_(" ");
        auto s = secondsText(run.centis);
        foreach (_; s.n .. 7) out_(" ");
        out_(s.text()); out_("  ");
        Text m; putNum(m, mibOf(run.peakKib));
        foreach (_; m.n .. 8) out_(" ");
        out_(m.text()); out_("\n");
    }
    return rs.said.length > 0 ? 1 : 0;
}
