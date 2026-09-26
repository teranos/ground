module minutes;

// The Actions minutes an org has used this month. GitHub says how many were
// used and never how many were included, so the quota comes from the org block
// and the two meet on the status line.
//
// Kept in a table of its own: ug redraws every few seconds, and the attestations
// are half a gigabyte with no index on what it would have to ask them.

import db : sqlite3;

// How old a reading may be before it is asked again.
enum EVERY = 600;

bool dueAt(long askedAt, long now) {
    return askedAt == 0 || now - askedAt >= EVERY;
}

struct Url {
    char[256] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref Url u, const(char)[] s) {
    foreach (c; s) if (u.len < u.buf.length) u.buf[u.len++] = c;
}

private void putNum(ref Url u, long v) {
    char[20] d = 0;
    size_t n;
    if (v <= 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) u.put(d[n - 1 - i .. n - i]);
}

Url summaryUrl(const(char)[] githubOrg, long year, long month) {
    Url u;
    u.put("https://api.github.com/organizations/");
    u.put(githubOrg);
    u.put("/settings/billing/usage/summary?year=");
    u.putNum(year);
    u.put("&month=");
    u.putNum(month);
    u.put("&product=actions");
    return u;
}

struct Used {
    bool ok;
    long minutes;
}

private ptrdiff_t find(const(char)[] h, const(char)[] needle, size_t from = 0) {
    if (needle.length == 0 || needle.length > h.length) return -1;
    foreach (i; from .. h.length - needle.length + 1)
        if (h[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

// The whole minutes of every item counted in minutes. Storage shares the list
// and is counted in gigabyte-hours. A body with no list is not zero minutes.
Used usedMinutes(const(char)[] json) {
    auto list = find(json, `"usageItems"`);
    if (list < 0) return Used(false, 0);

    long total = 0;
    size_t i = cast(size_t) list;
    while (i < json.length && json[i] != '[') i++;

    while (i < json.length) {
        while (i < json.length && json[i] != '{' && json[i] != ']') i++;
        if (i >= json.length || json[i] == ']') break;

        size_t start = i;
        size_t depth = 0;
        bool inStr = false;
        while (i < json.length) {
            auto c = json[i];
            if (inStr) {
                if (c == '\\') { i += 2; continue; }
                if (c == '"') inStr = false;
            } else if (c == '"') inStr = true;
            else if (c == '{') depth++;
            else if (c == '}') { depth--; if (depth == 0) { i++; break; } }
            i++;
        }
        auto item = json[start .. i];

        if (find(item, `"unitType":"minutes"`) < 0) continue;
        auto at = find(item, `"grossQuantity":`);
        if (at < 0) continue;
        size_t p = cast(size_t) at + `"grossQuantity":`.length;
        long v = 0;
        while (p < item.length && item[p] >= '0' && item[p] <= '9') {
            v = v * 10 + (item[p] - '0');
            p++;
        }
        total += v;
    }
    return Used(true, total);
}

// True for the one process that may ask now. The row is made on first sight
// with no reading in it, and the claim is an UPDATE only one caller can win.
bool claimAsking(sqlite3* db, const(char)[] githubOrg, long quota, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_changes, sqlite3_stmt,
                SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;

    enum seed = "INSERT OR IGNORE INTO org_minutes (org, used, quota, seen_at, asked_at) "
        ~ "VALUES (?1, -1, ?2, 0, 0)\0";
    enum claim = "UPDATE org_minutes SET asked_at = ?2, quota = ?3 "
        ~ "WHERE org = ?1 AND asked_at <= ?2 - ?4\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, seed.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, githubOrg.ptr, cast(int) githubOrg.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, quota);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (sqlite3_prepare_v2(db, claim.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, githubOrg.ptr, cast(int) githubOrg.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, now);
    sqlite3_bind_int64(stmt, 3, quota);
    sqlite3_bind_int64(stmt, 4, EVERY);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE && sqlite3_changes(db) > 0;
}

// How a write-down went. What sqlite answered is kept: a lock and a missing row
// are different facts, and "could not be written down" told neither.
struct Recorded {
    bool ok;
    int rc;      // sqlite's last answer
    bool noRow;  // the statement ran and no org by that name was there
}

extern (C) private uint usleep(uint);

// The child that asks writes while the Stop hook that forked it still holds
// the store, so a lock here is ordinary. Same shape as writeNote: wait and try
// again, and say so when the lock outlasts the waiting.
Recorded recordReading(sqlite3* db, const(char)[] githubOrg, long used, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_changes, sqlite3_stmt,
                SQLITE_OK, SQLITE_DONE, SQLITE_BUSY, SQLITE_TRANSIENT;

    enum sql = "UPDATE org_minutes SET used = ?2, seen_at = ?3 WHERE org = ?1\0";
    enum TRIES = 40;
    enum WAIT_US = 50_000;

    int rc = SQLITE_BUSY;
    foreach (attempt; 0 .. TRIES) {
        sqlite3_stmt* stmt;
        rc = sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null);
        if (rc == SQLITE_BUSY) { usleep(WAIT_US); continue; }
        if (rc != SQLITE_OK) return Recorded(false, rc, false);

        sqlite3_bind_text(stmt, 1, githubOrg.ptr, cast(int) githubOrg.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, used);
        sqlite3_bind_int64(stmt, 3, now);
        rc = sqlite3_step(stmt);
        sqlite3_finalize(stmt);

        if (rc == SQLITE_BUSY) { usleep(WAIT_US); continue; }
        if (rc != SQLITE_DONE) return Recorded(false, rc, false);
        bool landed = sqlite3_changes(db) > 0;
        return Recorded(landed, rc, !landed);
    }
    return Recorded(false, rc, false);
}

extern (C) {
    private int fork();
    private int setsid();
    private void _exit(int status);
}

// Every org that states a quota, asked when its reading is due. The asking is a
// network round trip, so it happens in a child that has let go of the hook.
// The orgs this process won the claim for. Made with the store open; asked
// after the caller shuts it, because the asking forks.
struct Due {
    const(char)[][8] names;
    size_t n;
}

Due dueOrgs(Orgs)(sqlite3* db, const Orgs orgs, long now) {
    import org : githubName;

    Due due;
    foreach (ref o; orgs) {
        if (due.n == due.names.length) break;
        if (o.actionsMinutes <= 0) continue;
        auto name = githubName(o.github);
        if (name.length == 0) continue;
        if (!claimAsking(db, name, o.actionsMinutes, now)) continue;
        due.names[due.n++] = name;
    }
    return due;
}

// Forks once per org. A connection open across fork() leaves the child with
// the parent's lock bookkeeping and none of its kernel locks; the child's
// own connection then writes unlocked. Reproduced 2026-09-26: the same
// "wrong # of entries in index" ground.db was found with. So: no store open.
void askDue(ref const Due due, const(char)[] sessionId, long now) {
    foreach (i; 0 .. due.n) askDetached(due.names[i], sessionId, now);
}

private void askDetached(const(char)[] githubOrg, const(char)[] sessionId, long now) {
    import errors : sayQuietly;

    auto pid = fork();
    if (pid < 0) {
        sayQuietly("minutes.fork", "could not fork to ask github for the org's minutes",
                   -1, sessionId, "org-minutes", githubOrg);
        return;
    }
    if (pid != 0) return;

    setsid();
    {
        import core.stdc.stdio : freopen, stdin, stdout, stderr;
        freopen("/dev/null\0".ptr, "r\0".ptr, stdin);
        freopen("/dev/null\0".ptr, "w\0".ptr, stdout);
        freopen("/dev/null\0".ptr, "w\0".ptr, stderr);
    }

    import core.stdc.time : time_t, tm, gmtime;
    import git : githubToken;
    import http : httpGet;
    import db : openDb, sqlite3_close;

    time_t t = cast(time_t) now;
    auto utc = gmtime(&t);
    auto url = summaryUrl(githubOrg, utc.tm_year + 1900, utc.tm_mon + 1);

    __gshared char[32768] body_ = 0;
    auto r = httpGet(url.text(), githubToken(), body_[], 20);

    // What was measured, whichever way it went wrong: libcurl's words when
    // nothing answered, github's own when it answered with a refusal. Said
    // to sentry and to nobody else: this reading feeds a table the tmux bar
    // reads, no session asked for it, and none can act on a DNS miss. The
    // bar keeps the last reading it had.
    if (r.code != 0 || r.overran) {
        sayQuietly("minutes.ask", cast(string) r.why(), -1, sessionId, "org-minutes", githubOrg);
        _exit(0);
    }
    auto used = usedMinutes(body_[0 .. r.len]);
    if (!used.ok) {
        auto said = body_[0 .. r.len > 400 ? 400 : r.len];
        sayQuietly("minutes.answer", "github answered without a usage list", -1,
                   sessionId, "org-minutes", said);
        _exit(0);
    }

    auto db = openDb();
    if (db is null) {
        // Which of the ways an open fails this was. Seen 2026-09-17 between two
        // askings that worked, and the record of it could not say.
        import db : dbFailureCode;
        __gshared char[160] why = 0;
        size_t n;
        void say(const(char)[] s) { foreach (c; s) if (n < why.length) why[n++] = c; }
        say("the org's minutes were read, and ground could not open its database to write them down: ");
        auto code = dbFailureCode();
        if (code == 0) say("sqlite gave no code, so the open itself failed or HOME is unset");
        else {
            say("sqlite code ");
            char[12] d = 0;
            size_t dl;
            auto v = code;
            while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
            foreach_reverse (i; 0 .. dl) if (n < why.length) why[n++] = d[i];
            say(" at the schema step");
        }
        sayQuietly("minutes.record", cast(string) why[0 .. n], -1, sessionId, "org-minutes", githubOrg);
        _exit(0);
    }
    auto wrote = recordReading(db, githubOrg, used.minutes, now);
    sqlite3_close(db);
    if (!wrote.ok) {
        import db : SQLITE_BUSY;
        string why = wrote.noRow
            ? "the org's minutes were read, and no row for that org was there to write them to"
            : wrote.rc == SQLITE_BUSY
                ? "the org's minutes were read, and the database stayed locked for two seconds of trying to write them down"
                : "the org's minutes were read, and sqlite refused the write";
        sayQuietly("minutes.record", why, -1, sessionId, "org-minutes", githubOrg);
    }
    _exit(0);
}
