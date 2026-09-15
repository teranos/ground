module usage;

// "i want to record the usage that is left in ground itself"
// Claude Code hands the rate limit windows to the status line and to no hook,
// so ug is the one process that can put them where ground reads.
//
// The row refreshes every second, and "If a new update triggers while a slow
// script is running, the in-flight script is cancelled". So the reading is
// claimed in the store before anything slow, and the attestation into QNTX
// happens in a child the cancel does not reach.

// "once every 4 hours"
enum RECORD_EVERY = 4 * 60 * 60;

// The weekly window is read more often as its reset comes: every hour in its
// last two days, every ten minutes in its last two hours.
enum CLOSE_RESET = 48 * 60 * 60;
enum CLOSE_EVERY = 60 * 60;
enum NEAR_RESET = 2 * 60 * 60;
enum NEAR_EVERY = 10 * 60;

// How long a window's last reading stays current. A window already reset is
// not near its reset, and the five-hour window keeps the four-hour rhythm.
long intervalFor(const(char)[] window, long resetsAt, long now) {
    if (window != "seven_day" || resetsAt <= now) return RECORD_EVERY;
    auto left = resetsAt - now;
    if (left <= NEAR_RESET) return NEAR_EVERY;
    if (left <= CLOSE_RESET) return CLOSE_EVERY;
    return RECORD_EVERY;
}

// One window as Claude Code sent it. The percentage stays the text it arrived
// as, so 23.5 is recorded as 23.5 and not as 23.
struct Window {
    const(char)[] name;
    const(char)[] percent;
    long resetsAt;
    bool present;
}

struct Windows { Window[2] w; }

immutable string[2] NAMES = ["five_hour", "seven_day"];

// Read inside rate_limits only. context_window carries a used_percentage of its
// own, and a search over the whole input takes whichever comes first.
Windows rateLimits(const(char)[] input) {
    Windows ws;
    auto limits = objectOf(input, "rate_limits");
    foreach (i, name; NAMES) {
        ws.w[i].name = name;
        if (limits.length == 0) continue;
        auto win = objectOf(limits, name);
        if (win.length == 0) continue;
        auto pct = numberOf(win, "used_percentage");
        if (pct.length == 0) continue;
        ws.w[i].percent = pct;
        long v = 0;
        foreach (c; numberOf(win, "resets_at")) {
            if (c < '0' || c > '9') break;
            v = v * 10 + (c - '0');
        }
        ws.w[i].resetsAt = v;
        ws.w[i].present = true;
    }
    return ws;
}

// The rule and the record are one statement: a session's first reading of a
// window, or none within the window's interval, ?6. qntx_exit starts at -2,
// since the attempt has not said how it went.
enum CLAIM_SQL = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session, qntx_status, qntx_exit) "
    ~ "SELECT ?1, ?2, ?3, ?4, ?5, 0, -2 "
    ~ "WHERE NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND session = ?5) "
    ~ "OR NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND seen_at > ?4 - ?6)";

// What the attempt answered: the HTTP status, and curl's exit code, -1 when no
// token was there to send.
enum UPDATE_SQL = "UPDATE usage SET qntx_status = ?1, qntx_exit = ?2 WHERE id = ?3";

// "and these shoudl also be attempted to be attested into qntx"
size_t attestationInto(const Window w, const(char)[] session, char[] dest) {
    size_t o = 0;
    void put(const(char)[] t) { foreach (c; t) if (o < dest.length) dest[o++] = c; }

    put(`{"subjects":["`);
    put(w.name);
    put(`"],"predicates":["rate_limit"],"contexts":["session:`);
    put(session);
    put(`"],"actors":["ug"],"attributes":{"used_percentage":`);
    put(w.percent);
    put(`,"resets_at":`);
    char[20] d = 0;
    size_t n = 0;
    long v = w.resetsAt;
    if (v <= 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) put(d[n - 1 - i .. n - i]);
    put(`}}`);
    if (o < dest.length) dest[o] = 0;
    return o;
}

// The object a key holds, braces included, or empty when the key holds none.
private const(char)[] objectOf(const(char)[] text, const(char)[] key) {
    auto at = valueAt(text, key);
    if (at >= text.length || text[at] != '{') return null;
    size_t depth = 0;
    bool inString = false;
    foreach (i; at .. text.length) {
        auto c = text[i];
        if (inString) {
            if (c == '\\') { continue; }
            if (c == '"' && text[i - 1] != '\\') inString = false;
            continue;
        }
        if (c == '"') inString = true;
        else if (c == '{') depth++;
        else if (c == '}') {
            depth--;
            if (depth == 0) return text[at .. i + 1];
        }
    }
    return null;
}

// The number a key holds, as written, or empty when it holds none.
private const(char)[] numberOf(const(char)[] obj, const(char)[] key) {
    auto at = valueAt(obj, key);
    if (at >= obj.length) return null;
    auto c0 = obj[at];
    if (!(c0 == '-' || (c0 >= '0' && c0 <= '9'))) return null;
    size_t e = at;
    while (e < obj.length) {
        auto c = obj[e];
        if ((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') e++;
        else break;
    }
    return obj[at .. e];
}

private size_t valueAt(const(char)[] text, const(char)[] key) {
    if (key.length == 0) return text.length;
    size_t i = 0;
    while (i + key.length + 2 < text.length) {
        if (text[i] != '"' || text[i + 1 .. i + 1 + key.length] != key
            || text[i + 1 + key.length] != '"') { i++; continue; }
        size_t j = i + 2 + key.length;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        if (j >= text.length || text[j] != ':') { i++; continue; }
        j++;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        return j;
    }
    return text.length;
}

import sql : sqlite3;

private bool openStore(const(char)[] home, ref char[512] path, ref sqlite3* db) {
    import core.stdc.stdio : fopen, fclose;
    import sql;

    if (dbPathInto(home, path[]) == 0) return false;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return false;
    fclose(probe);
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return false;
    }
    sqlite3_busy_timeout(db, BUSY_MS);
    return true;
}

// Once a frame. Claiming is a few milliseconds of sqlite and nothing else; the
// frame returns as soon as it is done.
void recordUsage(const(char)[] home, const(char)[] input, long now) {
    import core.stdc.stdio : fputs, stderr;
    import json : jsonString;
    import sql;

    auto ws = rateLimits(input);
    if (!ws.w[0].present && !ws.w[1].present) return;

    auto session = jsonString(input, "session_id");
    if (session is null) session = "";

    __gshared char[512] path = void;
    sqlite3* db;
    if (!openStore(home, path, db)) return;

    // IMMEDIATE takes the write lock before the NOT EXISTS is read, so two
    // sessions' frames in the same second cannot both claim one reading.
    if (sqlite3_exec(db, "BEGIN IMMEDIATE\0".ptr, null, null, null) != SQLITE_OK) {
        sqlite3_close(db);
        return;
    }

    long[2] claimed = [0, 0];
    size_t count = 0;
    foreach (i, ref w; ws.w) {
        if (!w.present) continue;
        sqlite3_stmt* ins;
        if (sqlite3_prepare_v2(db, CLAIM_SQL.ptr, cast(int) CLAIM_SQL.length, &ins, null) != SQLITE_OK) {
            fputs("ug: usage: cannot prepare the claim\n", stderr);
            break;
        }
        sqlite3_bind_text(ins, 1, w.name.ptr, cast(int) w.name.length, cast(void*) -1);
        sqlite3_bind_text(ins, 2, w.percent.ptr, cast(int) w.percent.length, cast(void*) -1);
        sqlite3_bind_int64(ins, 3, w.resetsAt);
        sqlite3_bind_int64(ins, 4, now);
        sqlite3_bind_text(ins, 5, session.ptr, cast(int) session.length, cast(void*) -1);
        sqlite3_bind_int64(ins, 6, intervalFor(w.name, w.resetsAt, now));
        if (sqlite3_step(ins) == SQLITE_DONE && sqlite3_changes(db) == 1) {
            claimed[i] = sqlite3_last_insert_rowid(db);
            count++;
        }
        sqlite3_finalize(ins);
    }

    if (sqlite3_exec(db, "COMMIT\0".ptr, null, null, null) != SQLITE_OK) {
        sqlite3_exec(db, "ROLLBACK\0".ptr, null, null, null);
        sqlite3_close(db);
        fputs("ug: usage: the claim did not commit\n", stderr);
        return;
    }
    sqlite3_close(db);
    if (count == 0) return;

    attestDetached(home, ws, claimed, session);
}

// The POST outlives the frame. A child in its own session is not the process
// Claude Code cancels, and it writes what QNTX answered onto the claimed row. A
// child that dies first leaves qntx_exit at -2, which says so.
private void attestDetached(const(char)[] home, const Windows ws, long[2] claimed,
                            const(char)[] session) {
    import core.stdc.stdio : fputs, stderr, freopen, stdin, stdout;
    import core.sys.posix.unistd : fork, setsid, _exit;
    import probe : post;
    import sql;

    auto pid = fork();
    if (pid < 0) {
        fputs("ug: usage: could not start the attempt; the rows stay pending\n", stderr);
        return;
    }
    if (pid > 0) return;

    setsid();
    freopen("/dev/null\0".ptr, "r\0".ptr, stdin);
    freopen("/dev/null\0".ptr, "w\0".ptr, stdout);
    freopen("/dev/null\0".ptr, "w\0".ptr, stderr);

    foreach (i, id; claimed) {
        if (id == 0) continue;
        __gshared char[1024] body_ = void;
        auto n = attestationInto(ws.w[i], session, body_[]);
        auto sent = post(home, "/api/attestations", body_[0 .. n]);

        __gshared char[512] path = void;
        sqlite3* db;
        if (!openStore(home, path, db)) continue;
        sqlite3_stmt* upd;
        if (sqlite3_prepare_v2(db, UPDATE_SQL.ptr, cast(int) UPDATE_SQL.length, &upd, null) == SQLITE_OK) {
            sqlite3_bind_int64(upd, 1, sent.status);
            sqlite3_bind_int64(upd, 2, sent.curlExit);
            sqlite3_bind_int64(upd, 3, id);
            sqlite3_step(upd);
            sqlite3_finalize(upd);
        }
        sqlite3_close(db);
    }
    _exit(0);
}
