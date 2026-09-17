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
Envelope budgetEnvelope(PM)(const(char)[] dsn, long unixSeconds, const(char)[] sessionId,
                            const(char)[] event, long avgMs, long budgetMs,
                            const(char)[] version_, const(char)[] project,
                            ref PM means) {
    Envelope e;
    if (!openLog(e, dsn, unixSeconds, sessionId, "warn")) return Envelope.init;

    // The version file ends in a newline, and that is not part of the version.
    auto ver = version_;
    while (ver.length > 0 && (ver[$ - 1] == '\n' || ver[$ - 1] == '\r')) ver = ver[0 .. $ - 1];

    e.putEscaped(event);
    e.put(" averages ");
    e.putLong(avgMs);
    e.put("ms against a budget of ");
    e.putLong(budgetMs);
    e.put(`ms","attributes":{`);
    e.putAttr("event", event);
    e.putAttr("project", project);
    e.putAttr("version", ver);
    e.putNum("avg_ms", avgMs);
    e.putNum("budget_ms", budgetMs);
    foreach (i; 0 .. means.n) {
        e.put(`"phase_us.`);
        e.putEscaped(means.keys[i][0 .. means.keyLen[i]]);
        e.put(`":{"value":`);
        e.putLong(means.counts[i] > 0 ? means.sums[i] / means.counts[i] : 0);
        e.put(`,"type":"integer"},`);
    }
    e.put(`"runs":{"value":`);
    e.putLong(cast(long) means.rows);
    e.put(`,"type":"integer"}}}]}` ~ "\n");
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

// One envelope, posted. The status sentry answered with, or 0 when curl gave
// none. The dsn rides inside the envelope, so no header carries the key.
int postEnvelope(const(char)[] dsn, const Envelope e) {
    import http : curlPost;
    auto url = envelopeUrl(parseDsn(dsn));
    if (url.text().length == 0 || e.text().length == 0) return 0;
    return curlPost(url.text(), e.text(), null, 10, "application/x-sentry-envelope");
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
