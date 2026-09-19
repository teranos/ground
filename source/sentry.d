module sentry;

// What a performance says to sentry, and the one way it is said. Names,
// verdicts and codes: what a rite printed, what the agent said and where the
// tree is on disk have no parameter here, so they have no way in.
//
// A log and not a cron check-in. Asked of the ground project on 2026-09-17: a
// monitor upsert without a schedule is refused (422, missing field `schedule`),
// a check-in to a monitor that does not exist is accepted and creates none, and
// a monitor with a schedule reads every interval nobody performed in as missed.
// A ritual is performed when somebody performs it.

import rite : Verdict;

struct Dsn {
    bool ok;
    const(char)[] key;
    const(char)[] host;
    const(char)[] project;
}

// https://<key>@<host>/<project>. All three or it is not one.
Dsn parseDsn(const(char)[] dsn) {
    enum scheme = "https://";
    if (dsn.length <= scheme.length || dsn[0 .. scheme.length] != scheme) return Dsn.init;
    auto rest = dsn[scheme.length .. $];

    size_t at = rest.length;
    foreach (i, c; rest) if (c == '@') { at = i; break; }
    if (at == 0 || at == rest.length) return Dsn.init;

    auto after = rest[at + 1 .. $];
    size_t slash = after.length;
    foreach (i, c; after) if (c == '/') { slash = i; break; }
    if (slash == 0 || slash == after.length) return Dsn.init;

    auto project = after[slash + 1 .. $];
    while (project.length > 0 && project[$ - 1] == '/') project = project[0 .. $ - 1];
    if (project.length == 0) return Dsn.init;
    foreach (c; project) if (c < '0' || c > '9') return Dsn.init;

    return Dsn(true, rest[0 .. at], after[0 .. slash], project);
}

// Sized for one log and the widest set of attributes ground sends, a budget
// notice with every phase. A name long enough to overrun it is cut, and `over`
// says so, so a cut envelope is never posted as whole.
struct Envelope {
    char[4096] buf = 0;
    size_t len;
    bool over;
    const(char)[] text() const return { return over ? null : buf[0 .. len]; }
}

private void put(ref Envelope e, const(char)[] s) {
    foreach (c; s) { if (e.len < e.buf.length) e.buf[e.len++] = c; else e.over = true; }
}

private void putEscaped(ref Envelope e, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') e.put(`\"`);
        else if (c == '\\') e.put(`\\`);
        else if (c == '\n') e.put(`\n`);
        else if (c == '\r') e.put(`\r`);
        else if (c == '\t') e.put(`\t`);
        else if (c < 0x20) continue;
        else { char[1] one = [c]; e.put(one[]); }
    }
}

private void putLong(ref Envelope e, long v) {
    if (v < 0) { e.put("-"); v = -v; }
    char[20] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0 && n < d.length) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) e.put(d[n - 1 - i .. n - i]);
}

Envelope envelopeUrl(const Dsn d) {
    Envelope e;
    if (!d.ok) return e;
    e.put("https://");
    e.put(d.host);
    e.put("/api/");
    e.put(d.project);
    e.put("/envelope/");
    return e;
}

struct TraceId {
    char[32] buf = 0;
    const(char)[] text() const return { return buf[0 .. 32]; }
}

// Two FNV-1a walks over the performance id, from different offsets, written
// as hex. Not random: the same performance has to find the same trace from
// every process that reports on it.
TraceId traceId(const(char)[] performanceId) {
    static ulong walk(const(char)[] s, ulong h) {
        foreach (c; s) { h ^= cast(ulong) c; h *= 0x100000001b3UL; }
        return h;
    }
    ulong[2] halves = [walk(performanceId, 0xcbf29ce484222325UL),
                       walk(performanceId, 0x84222325cbf29ce4UL)];

    static immutable string HEX = "0123456789abcdef";
    TraceId t;
    foreach (hi, h; halves)
        foreach (i; 0 .. 16)
            t.buf[hi * 16 + i] = HEX[cast(size_t) ((h >> ((15 - i) * 4)) & 0xF)];
    return t;
}

// A hook over its budget, as the session is told it once per window. The
// session id threads a session's notices, since no performance is involved.
Item budgetItem(PM)(long unixSeconds, const(char)[] sessionId, const(char)[] event,
                    long avgMs, long budgetMs, const(char)[] version_,
                    const(char)[] project, ref PM means) {
    // The version file ends in a newline, and that is not part of the version.
    auto ver = version_;
    while (ver.length > 0 && (ver[$ - 1] == '\n' || ver[$ - 1] == '\r')) ver = ver[0 .. $ - 1];

    char[128] body_ = 0;
    size_t n;
    void say(const(char)[] s) { foreach (c; s) if (n < body_.length) body_[n++] = c; }
    void num(long v) {
        char[20] d = 0;
        size_t k;
        if (v <= 0) d[k++] = '0';
        while (v > 0 && k < d.length) { d[k++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. k) if (n < body_.length) body_[n++] = d[i];
    }
    say(event);
    say(" averages ");
    num(avgMs);
    say("ms against a budget of ");
    num(budgetMs);
    say("ms");

    auto it = openItem(unixSeconds, sessionId, "warn", body_[0 .. n]);
    it.str("event", event);
    it.str("project", project);
    it.str("version", ver);
    it.num("avg_ms", avgMs);
    it.num("budget_ms", budgetMs);
    foreach (i; 0 .. means.n) {
        char[64] key = 0;
        size_t kl;
        foreach (c; "phase_us.") key[kl++] = c;
        foreach (c; means.keys[i][0 .. means.keyLen[i]]) if (kl < key.length) key[kl++] = c;
        it.num(key[0 .. kl], means.counts[i] > 0 ? means.sums[i] / means.counts[i] : 0);
    }
    it.num("runs", cast(long) means.rows);
    it.close();
    return it;
}

// The same notice as one envelope of its own, for a caller that posts it.
Envelope budgetEnvelope(PM)(const(char)[] dsn, long unixSeconds, const(char)[] sessionId,
                            const(char)[] event, long avgMs, long budgetMs,
                            const(char)[] version_, const(char)[] project,
                            ref PM means) {
    Envelope e;
    if (!parseDsn(dsn).ok) return e;
    auto it = budgetItem(unixSeconds, sessionId, event, avgMs, budgetMs, version_, project, means);
    if (it.text().length == 0) return e;
    e.put(`{"dsn":"`);
    e.putEscaped(dsn);
    e.put(`"}` ~ "\n");
    e.put(`{"type":"log","item_count":1,"content_type":"application/vnd.sentry.items.log+json"}` ~ "\n");
    e.put(`{"items":[`);
    e.put(it.text());
    e.put(`]}` ~ "\n");
    return e;
}

extern (C) {
    private int fork();
    private int setsid();
    private void _exit(int status);
}

// Posted from a child that has let go of the hook's pipes. A hook is read by
// Claude Code until its stdout closes, and a post is a network round trip: said
// inline, the notice about a slow hook would be the slowest thing in it.
void reportDetached(const(char)[] dsn, const Envelope e, const(char)[] owedSession,
                    const(char)[] what) {
    if (dsn.length == 0) return;

    auto pid = fork();
    if (pid != 0) {
        if (pid < 0) {
            import exec : emitError;
            emitError("sentry.fork", "could not fork to post, so nothing was sent",
                      0, -1, cast(string) owedSession, cast(string) what, "", "", "");
        }
        return;
    }

    setsid();
    {
        import core.stdc.stdio : freopen, stdin, stdout, stderr;
        freopen("/dev/null\0".ptr, "r\0".ptr, stdin);
        freopen("/dev/null\0".ptr, "w\0".ptr, stdout);
        freopen("/dev/null\0".ptr, "w\0".ptr, stderr);
    }
    report(dsn, e, owedSession, what);
    _exit(0);
}

// One log item on its own, without the envelope around it. A hook writes one
// of these to the outbox and exits; the watcher wraps a batch in one envelope.
struct Item {
    char[4096] buf = 0;
    size_t len;
    bool over;
    bool open;   // between the attributes' `{` and their `}`
    bool first;  // no attribute written yet
    const(char)[] text() const return { return over ? null : buf[0 .. len]; }

    private void put(const(char)[] s) {
        foreach (c; s) { if (len < buf.length) buf[len++] = c; else over = true; }
    }

    private void putEscaped(const(char)[] s) {
        foreach (c; s) {
            if (c == '"') put(`\"`);
            else if (c == '\\') put(`\\`);
            else if (c == '\n') put(`\n`);
            else if (c == '\r') put(`\r`);
            else if (c == '\t') put(`\t`);
            else if (c < 0x20) continue;
            else { char[1] one = [c]; put(one[]); }
        }
    }

    private void putLong(long v) {
        if (v < 0) { put("-"); v = -v; }
        char[20] d = 0;
        size_t n;
        if (v == 0) d[n++] = '0';
        while (v > 0 && n < d.length) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. n) put(d[n - 1 - i .. n - i]);
    }

    private void key(const(char)[] k) {
        if (!first) put(",");
        first = false;
        put(`"`);
        putEscaped(k);
        put(`":{"value":`);
    }

    // A string attribute.
    void str(const(char)[] k, const(char)[] v) {
        key(k);
        put(`"`);
        putEscaped(v);
        put(`","type":"string"}`);
    }

    void num(const(char)[] k, long v) {
        key(k);
        putLong(v);
        put(`,"type":"integer"}`);
    }

    void flag(const(char)[] k, bool v) {
        key(k);
        put(v ? "true" : "false");
        put(`,"type":"boolean"}`);
    }

    // The attributes' close. Nothing may be added after, except by stamp.
    void close() {
        if (!open) return;
        put("}}");
        open = false;
    }

    // "i want to know on a time series if Fable, or Opus or Sonnet was active"
    // One attribute the builder could not know, put on by the funnel the item
    // passes through on its way to the store: the item is reopened for it and
    // closed again. Nothing to say leaves the item as it was.
    void stamp(const(char)[] k, const(char)[] v) {
        if (v.length == 0 || over) return;
        if (open) { str(k, v); return; }
        if (len < 2 || buf[len - 2 .. len] != "}}") return;
        len -= 2;
        open = true;
        // first stays what it was: an item with attributes takes a comma.
        str(k, v);
        close();
    }
}

Item openItem(long unixSeconds, const(char)[] traceFor, const(char)[] level,
              const(char)[] body_) {
    Item it;
    it.put(`{"timestamp":`);
    it.putLong(unixSeconds);
    it.put(`,"trace_id":"`);
    it.put(traceId(traceFor).text());
    it.put(`","level":"`);
    it.put(level);
    it.put(`","body":"`);
    it.putEscaped(body_);
    it.put(`","attributes":{`);
    it.open = true;
    it.first = true;
    return it;
}

// A batch of items already spelled out, wrapped in one envelope. Logs and
// metrics are two item types and go in two envelopes.
enum BATCH_CAP = 262_144;

struct Batch(size_t N = BATCH_CAP) {
    char[N] buf = 0;
    size_t len;
    size_t count;
    bool over;

    // Room for one more item of this size, with the envelope's own bytes.
    bool fits(size_t itemLen) const { return len + itemLen + 512 < buf.length; }

    void add(const(char)[] item) {
        if (!fits(item.length)) { over = true; return; }
        if (count > 0) buf[len++] = ',';
        foreach (c; item) buf[len++] = c;
        count++;
    }
}

// The whole envelope for a batch: header, item header with the count, and
// the items as one list. Empty when the batch holds nothing.
size_t envelopeInto(B)(const ref B b, const(char)[] dsn, const(char)[] contentType,
                       const(char)[] itemType, char[] dest) {
    if (b.count == 0 || !parseDsn(dsn).ok) return 0;
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    void num(size_t v) {
        char[20] d = 0;
        size_t n;
        if (v == 0) d[n++] = '0';
        while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. n) put(d[n - 1 - i .. n - i]);
    }
    put(`{"dsn":"`);
    put(dsn);
    put("\"}\n{\"type\":\"");
    put(itemType);
    put(`","item_count":`);
    num(b.count);
    put(`,"content_type":"`);
    put(contentType);
    put("\"}\n{\"items\":[");
    put(b.buf[0 .. b.len]);
    put("]}\n");
    return o < dest.length ? o : 0;
}

enum LOG_TYPE = "log";
enum LOG_CONTENT = "application/vnd.sentry.items.log+json";
enum METRIC_TYPE = "trace_metric";
enum METRIC_CONTENT = "application/vnd.sentry.items.trace-metric+json";

// One distribution metric, spelled out. `attrs` come in key, value pairs.
Item metricItem(long unixSeconds, const(char)[] traceFor, const(char)[] name,
                long value, const(char)[] unit) {
    Item it;
    it.put(`{"timestamp":`);
    it.putLong(unixSeconds);
    it.put(`,"trace_id":"`);
    it.put(traceId(traceFor).text());
    it.put(`","type":"distribution","name":"`);
    it.putEscaped(name);
    it.put(`","value":`);
    it.putLong(value);
    it.put(`,"unit":"`);
    it.put(unit);
    it.put(`","attributes":{`);
    it.open = true;
    it.first = true;
    return it;
}

// One envelope, posted. The status sentry answered with, or 0 when curl gave
// none. The dsn rides inside the envelope, so no header carries the key.
int postEnvelope(const(char)[] dsn, const Envelope e) {
    return postText(dsn, e.text()).status;
}

// An envelope already spelled out, posted, with everything libcurl said.
import http : Http;
Http postText(const(char)[] dsn, const(char)[] envelope) {
    import http : httpPost;
    auto url = envelopeUrl(parseDsn(dsn));
    if (url.text().length == 0 || envelope.length == 0) return Http.init;
    return httpPost(url.text(), envelope, null, 20, "application/x-sentry-envelope");
}

// Posts, and says so when it did not land. No dsn anywhere is nowhere to
// report, which is a pbt that asked for nothing and not a failure.
void report(const(char)[] dsn, const Envelope e, const(char)[] owedSession,
            const(char)[] ritual) {
    import exec : emitError;
    if (dsn.length == 0) return;

    if (e.text().length == 0) {
        emitError("sentry.envelope",
                  "the dsn is not https://<key>@<host>/<project>, or a name overran the envelope, so nothing was posted",
                  0, -1, cast(string) owedSession, cast(string) ritual, "", "", "");
        return;
    }

    auto code = postEnvelope(dsn, e);
    if (code == 200) return;

    __gshared char[64] said = 0;
    size_t n;
    void say(const(char)[] s) { foreach (c; s) if (n < said.length) said[n++] = c; }
    if (code == 0) say("sentry gave no answer to the post");
    else {
        say("sentry answered the post with HTTP ");
        char[3] d = [cast(char)('0' + code / 100 % 10), cast(char)('0' + code / 10 % 10),
                     cast(char)('0' + code % 10)];
        say(d[]);
    }
    emitError("sentry.post", cast(string) said[0 .. n], 0, -1,
              cast(string) owedSession, cast(string) ritual, "", "", "");
}

private void putAttr(ref Envelope e, const(char)[] key, const(char)[] value, bool last = false) {
    e.put(`"`);
    e.put(key);
    e.put(`":{"value":"`);
    e.putEscaped(value);
    e.put(`","type":"string"}`);
    if (!last) e.put(",");
}

// Envelope header, item header, and one log up to where its attributes open.
private bool openLog(ref Envelope e, const(char)[] dsn, long unixSeconds,
                     const(char)[] performance, const(char)[] level) {
    if (!parseDsn(dsn).ok) return false;
    e.put(`{"dsn":"`);
    e.putEscaped(dsn);
    e.put(`"}` ~ "\n");
    e.put(`{"type":"log","item_count":1,"content_type":"application/vnd.sentry.items.log+json"}` ~ "\n");
    e.put(`{"items":[{"timestamp":`);
    e.putLong(unixSeconds);
    e.put(`,"trace_id":"`);
    e.put(traceId(performance).text());
    e.put(`","level":"`);
    e.put(level);
    e.put(`","body":"`);
    return true;
}

private immutable string[3] VERDICT_WORD = ["advance", "hold", "halt"];

// Everything said about one rite's verdict. Names, codes, counts and times:
// a field for what the rite printed does not exist, so it cannot be filled.
struct RiteReport {
    const(char)[] performance;
    const(char)[] ritual;
    const(char)[] rite;
    Verdict verdict;
    int code;
    // What the author declared the code is read against.
    int pass;
    int[8] catches;
    size_t catchCount;
    long tookMs;             // this asking: the rite's commands, start to verdict
    long openMs;             // since the walk arrived at this rite
    size_t evals;            // times this rite has been asked
    size_t gotos;            // jumps taken this performance, against maxGoto
    size_t maxGoto;
    const(char)[] jumpedTo;  // the goto this verdict took, empty when none
    bool gotoSpent;          // halted because max_goto was reached
    bool evalsSpent;         // halted because the eval bound was reached
}

private void putNum(ref Envelope e, const(char)[] key, long v) {
    e.put(`"`);
    e.put(key);
    e.put(`":{"value":`);
    e.putLong(v);
    e.put(`,"type":"integer"},`);
}

private void putFlag(ref Envelope e, const(char)[] key, bool v, bool last = false) {
    e.put(`"`);
    e.put(key);
    e.put(`":{"value":`);
    e.put(v ? "true" : "false");
    e.put(`,"type":"boolean"}`);
    if (!last) e.put(",");
}

// One rite, one verdict, sent when it lands.
Envelope riteEnvelope(const(char)[] dsn, long unixSeconds, const RiteReport r) {
    Envelope e;
    auto word = VERDICT_WORD[cast(size_t) r.verdict];
    if (!openLog(e, dsn, unixSeconds, r.performance,
                 r.verdict == Verdict.Halt ? "error" : "info"))
        return Envelope.init;

    e.putEscaped(r.ritual);
    e.put(" ");
    e.putEscaped(r.rite);
    e.put(" ");
    e.put(word);
    if (r.gotoSpent) e.put(", max_goto spent");
    else if (r.evalsSpent) e.put(", max_evals spent");
    else if (r.jumpedTo.length > 0) {
        e.put(", goto ");
        e.putEscaped(r.jumpedTo);
    }
    e.put(`","attributes":{`);
    e.putAttr("performance", r.performance);
    e.putAttr("ritual", r.ritual);
    e.putAttr("rite", r.rite);
    e.putAttr("verdict", word);
    if (r.jumpedTo.length > 0) e.putAttr("goto", r.jumpedTo);

    // A list has no attribute type, so the codes go as the author wrote them.
    e.put(`"catches":{"value":"`);
    foreach (i; 0 .. r.catchCount) {
        if (i > 0) e.put(",");
        e.putLong(r.catches[i]);
    }
    e.put(`","type":"string"},`);

    e.putNum("code", r.code);
    e.putNum("pass", r.pass);
    e.putNum("took_ms", r.tookMs);
    e.putNum("open_ms", r.openMs);
    e.putNum("evals", cast(long) r.evals);
    e.putNum("gotos", cast(long) r.gotos);
    e.putNum("max_goto", cast(long) r.maxGoto);
    e.putFlag("max_goto_hit", r.gotoSpent);
    e.putFlag("max_evals_hit", r.evalsSpent, true);
    e.put(`}}]}` ~ "\n");
    return e;
}

// The start of a performance and its ending, in the ending's own word.
// `agent` is what became of the agent at an ending: stopped, failed or unbound,
// and empty at a start, where there is none to have stopped. One left running
// outranks how the ritual ended, because it is the one that costs the machine.
Envelope performanceEnvelope(const(char)[] dsn, long unixSeconds, const(char)[] performance,
                             const(char)[] ritual, const(char)[] state,
                             const(char)[] agent = "") {
    Envelope e;
    bool leaked = agent.length > 0 && agent != "stopped";
    auto level = (leaked || state == "halted") ? "error" : state == "aborted" ? "warn" : "info";
    if (!openLog(e, dsn, unixSeconds, performance, level)) return Envelope.init;

    e.putEscaped(ritual);
    e.put(" ");
    e.putEscaped(state);
    if (leaked) {
        e.put(", agent ");
        e.putEscaped(agent);
    }
    e.put(`","attributes":{`);
    e.putAttr("performance", performance);
    e.putAttr("ritual", ritual);
    if (agent.length > 0) e.putAttr("agent", agent);
    e.putAttr("state", state, true);
    e.put(`}}]}` ~ "\n");
    return e;
}
