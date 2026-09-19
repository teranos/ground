module checks;

// The plan ask and the version check each run when the last one is a day old.
// Each is an attestation in ground's own store, the only place its age is read
// from. A copy goes to every QNTX backend a project names.

import db : sqlite3;

enum EVERY = 86400;

bool shouldCheck(long lastAt, long now, long every) {
    return lastAt == 0 || now - lastAt >= every;
}

// The string a key holds in a JSON object, or null when it holds none.
private const(char)[] stringField(const(char)[] json, const(char)[] key) {
    if (json.length < key.length) return null;
    foreach (i; 0 .. json.length - key.length + 1) {
        if (json[i .. i + key.length] != key) continue;
        size_t j = i + key.length;
        while (j < json.length && (json[j] == ' ' || json[j] == ':' || json[j] == '\t')) j++;
        if (j >= json.length || json[j] != '"') return null;
        auto start = j + 1;
        auto end = start;
        while (end < json.length && json[end] != '"') end++;
        if (end >= json.length || end == start) return null;
        return json[start .. end];
    }
    return null;
}

// Only the plan, of everything claude auth status prints.
const(char)[] planIn(const(char)[] json) { return stringField(json, `"subscriptionType"`); }

// Only the tag, of everything GitHub says about the latest release.
const(char)[] tagIn(const(char)[] json) { return stringField(json, `"tag_name"`); }

private void putNum(S)(ref S s, long v) {
    char[20] d = 0;
    size_t n = 0;
    bool negative = v < 0;
    if (negative) v = -v;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    if (negative) s.put("-");
    foreach (i; 0 .. n) s.put(d[n - 1 - i .. n - i]);
}

private void putAttributes(S)(ref S s, const(char)[] value, long exit, long at, bool withStatus) {
    s.put(`{"value":"`);
    foreach (c; value) {
        if (c == '"' || c == '\\') s.put(`\`);
        char[1] one = [c];
        s.put(one[]);
    }
    s.put(`","exit":`);
    putNum(s, exit);
    s.put(`,"checked_at":`);
    putNum(s, at);
    if (withStatus) s.put(`,"qntx_status":0`);
    s.put(`}`);
}

// What QNTX is sent for one check.
void checkBody(S)(ref S s, const(char)[] kind, const(char)[] value, long exit, long at) {
    s.put(`{"subjects":["`);
    s.put(kind);
    s.put(`"],"predicates":["check"],"contexts":["ground"],"actors":["ground"],"attributes":`);
    putAttributes(s, value, exit, at, false);
    s.put(`}`);
}

// One check as read back. qntxStatus is 0 until the copy is answered, -1 when
// no project names a backend, and -3 when a backend gave no answer at all.
struct Check {
    bool found;
    long at;
    long exit;
    long qntxStatus;
    char[128] buf = 0;
    size_t len;
    const(char)[] value() const return { return buf[0 .. len]; }
}

private void putId(S)(ref S s, const(char)[] kind, long at) {
    s.put("ground:check:");
    s.put(kind);
    s.put(":");
    putNum(s, at);
}

void recordCheck(sqlite3* db, const(char)[] kind, const(char)[] value, long exit, long at) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_finalize,
                sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT, formatTimestamp, versionString, ZBuf;

    __gshared ZBuf id;
    __gshared ZBuf subjects;
    __gshared ZBuf attrs;
    __gshared ZBuf source;
    id.reset();
    putId(id, kind, at);
    subjects.reset();
    subjects.put(`["`);
    subjects.put(kind);
    subjects.put(`"]`);
    attrs.reset();
    putAttributes(attrs, value is null ? "" : value, exit, at, true);
    source.reset();
    source.put("ground ");
    source.put(versionString());
    auto ts = formatTimestamp();

    enum sql = "INSERT OR REPLACE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, '[\"check\"]', '[\"ground\"]', '[\"ground\"]', ?3, ?4, ?5)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, id.ptr(), cast(int) id.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, source.ptr(), cast(int) source.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, attrs.ptr(), cast(int) attrs.len, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

Check lastCheck(sqlite3* db, const(char)[] kind) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_finalize,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    enum sql = "SELECT json_extract(attributes, '$.value'), json_extract(attributes, '$.exit'), "
        ~ "json_extract(attributes, '$.checked_at'), COALESCE(json_extract(attributes, '$.qntx_status'), 0) "
        ~ "FROM attestations WHERE json_extract(subjects, '$[0]') = ?1 "
        ~ "AND json_extract(predicates, '$[0]') = 'check' "
        ~ "ORDER BY json_extract(attributes, '$.checked_at') DESC, rowid DESC LIMIT 1\0";
    Check c;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return c;
    sqlite3_bind_text(stmt, 1, kind.ptr, cast(int) kind.length, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        c.found = true;
        auto text = sqlite3_column_text(stmt, 0);
        if (text !is null)
            while (text[c.len] != 0 && c.len < c.buf.length) { c.buf[c.len] = text[c.len]; c.len++; }
        c.exit = sqlite3_column_int64(stmt, 1);
        c.at = sqlite3_column_int64(stmt, 2);
        c.qntxStatus = sqlite3_column_int64(stmt, 3);
    }
    sqlite3_finalize(stmt);
    return c;
}

void noteQntx(sqlite3* db, const(char)[] kind, long at, long status) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64, sqlite3_step,
                sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT, ZBuf;

    __gshared ZBuf id;
    id.reset();
    putId(id, kind, at);
    enum sql = "UPDATE attestations SET attributes = json_set(attributes, '$.qntx_status', ?2) WHERE id = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, id.ptr(), cast(int) id.len, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, status);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// A node and the token file it is spoken to with; empty for ground attest's
// own, QNTX_TOKEN then ~/.qntx/token.
struct Node {
    string url;
    string token;
}

struct Backends {
    Node[1] items;
    size_t len;
}

// The one node the top-level qntx block names, or none.
Backends qntxBackends(PR)(const PR parsed) {
    Backends b;
    if (parsed.qntx.url.length == 0) return b;
    b.items[0] = Node(parsed.qntx.url, parsed.qntx.token);
    b.len = 1;
    return b;
}

// The exit code of a command, with what it printed in dest.
private long runInto(const(char)* cmd, char[] dest, ref size_t n) {
    import core.stdc.stdio : fread;
    import db : popen, pclose;
    n = 0;
    auto pipe = popen(cmd, "r\0".ptr);
    if (pipe is null) return -1;
    n = fread(dest.ptr, 1, dest.length, pipe);
    auto status = pclose(pipe);
    return status >= 0 ? (status >> 8) & 0xff : -1;
}

// claude auth status takes about 0.7s, and the start that asks waits for it.
Check askPlan(sqlite3* db, long now) {
    __gshared char[4096] out_ = 0;
    size_t n;
    auto code = runInto("claude auth status 2>/dev/null\0".ptr, out_[], n);
    auto plan = code == 0 ? planIn(out_[0 .. n]) : null;
    recordCheck(db, "plan", plan, plan is null && code == 0 ? 1 : code, now);
    return lastCheck(db, "plan");
}

Check fetchRelease(sqlite3* db, long now) {
    __gshared char[16384] out_ = 0;
    size_t n;
    auto code = runInto("/usr/bin/curl -sf --max-time 5 https://api.github.com/repos/teranos/ground/releases/latest 2>/dev/null\0".ptr,
                        out_[], n);
    auto tag = code == 0 ? tagIn(out_[0 .. n]) : null;
    recordCheck(db, "release", tag, tag is null && code == 0 ? 1 : code, now);
    return lastCheck(db, "release");
}

// The copy to QNTX outlives the start. A child in its own session posts the
// checks taken at `at` and writes what the backends answered beside them.
void sendDetached(const(char)[] first, const(char)[] second, long at) {
    import core.stdc.stdio : fflush, fputs, freopen, stdin, stdout, stderr;
    import core.sys.posix.unistd : fork, setsid, _exit;

    // A buffer the child inherits is written again when the child closes it.
    fflush(stdout);
    fflush(stderr);
    auto pid = fork();
    if (pid < 0) {
        fputs("ground: could not start the copy to QNTX; the checks stay unsent\n", stderr);
        return;
    }
    if (pid > 0) return;

    setsid();
    freopen("/dev/null\0".ptr, "r\0".ptr, stdin);
    freopen("/dev/null\0".ptr, "w\0".ptr, stdout);
    freopen("/dev/null\0".ptr, "w\0".ptr, stderr);

    import controls : allParsed;
    import attest : qntxToken;
    import http : curlPost;
    import db : openDb, sqlite3_close, ZBuf;

    static immutable backends = qntxBackends(allParsed);

    const(char)[][2] kinds = [first, second];
    foreach (kind; kinds) {
        if (kind.length == 0) continue;
        auto db = openDb();
        if (db is null) continue;
        auto c = lastCheck(db, kind);
        sqlite3_close(db);
        if (!c.found || c.at != at) continue;

        __gshared ZBuf body_;
        __gshared ZBuf url;
        body_.reset();
        checkBody(body_, kind, c.value, c.exit, c.at);

        long answer = -1;
        bool failed = false;
        foreach (i; 0 .. backends.len) {
            url.reset();
            url.put(backends.items[i].url);
            url.put("/api/attestations");
            long code = curlPost(url.slice(), body_.slice(), qntxToken(backends.items[i].token), 10);
            if (code == 0) code = -3;
            bool ok = code >= 200 && code < 300;
            if (failed) continue;
            answer = code;
            if (!ok) failed = true;
        }

        db = openDb();
        if (db is null) continue;
        noteQntx(db, kind, at, answer);
        sqlite3_close(db);
    }
    _exit(0);
}

// The whole seconds the first number of /proc/uptime carries, or -1 when the
// text begins with something no number can be read from.
long uptimeIn(const(char)[] text) {
    if (text.length == 0 || text[0] < '0' || text[0] > '9') return -1;
    long secs = 0;
    foreach (c; text) {
        if (c < '0' || c > '9') break;
        secs = secs * 10 + (c - '0');
    }
    return secs;
}

version (OSX) {
    private struct timeval {
        long tv_sec;
        int tv_usec;
    }

    extern (C) int sysctlbyname(const(char)* name, void* oldp, size_t* oldlenp,
                                void* newp, size_t newlen);

    // When the machine booted, from the kernel, with no process started. 0
    // when the kernel would not say.
    long bootTime() {
        timeval tv;
        size_t len = timeval.sizeof;
        if (sysctlbyname("kern.boottime\0".ptr, &tv, &len, null, 0) != 0) return 0;
        return tv.tv_sec;
    }
} else version (linux) {
    // Linux has no kern.boottime. The kernel says how long it has been up, and
    // /proc/uptime is a file read rather than a process started.
    long bootTime() {
        import core.stdc.stdio : fopen, fread, fclose;
        import core.stdc.time : time;

        auto f = fopen("/proc/uptime\0".ptr, "rb\0".ptr);
        if (f is null) return 0;
        char[64] buf = 0;
        auto n = fread(&buf[0], 1, buf.length - 1, f);
        fclose(f);
        if (n == 0) return 0;

        auto up = uptimeIn(buf[0 .. n]);
        if (up < 0) return 0;
        return cast(long) time(null) - up;
    }
} else {
    // A platform ground has no boot time for says so, rather than answering a
    // number it did not read.
    long bootTime() { return 0; }
}

void putUptime(S)(ref S s, long secs) {
    if (secs < 0) {
        s.put("uptime unknown: the kernel did not say when it booted");
        return;
    }
    s.put("up ");
    putNum(s, secs / 86400);
    s.put("d ");
    putNum(s, (secs / 3600) % 24);
    s.put(":");
    auto m = (secs / 60) % 60;
    char[2] mm = [cast(char)('0' + m / 10), cast(char)('0' + m % 10)];
    s.put(mm[]);
}

// What the session shows: the uptime, then the plan or why there is none.
void putStart(S)(ref S s, long uptime, const(char)[] plan, long exit, bool found) {
    putUptime(s, uptime);
    s.put(" | ");
    if (plan.length > 0) {
        s.put("plan ");
        s.put(plan);
    } else if (found) {
        s.put("plan unknown: claude auth status exited ");
        putNum(s, exit);
    } else {
        s.put("no plan recorded");
    }
}
