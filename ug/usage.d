module usage;

// "i want to record the usage that is left in ground itself"
// Claude Code hands the rate limit windows to the status line and to no hook,
// so ug is the one process that can put them where ground reads. The window
// scoped to Fable it hands to nothing; ug asks the usage endpoint for that one
// (fable.d) and records it beside the other two.
//
// The row refreshes every second, and "If a new update triggers while a slow
// script is running, the in-flight script is cancelled". So the reading is
// claimed in the store before anything slow, and the ask and the attestation
// into QNTX happen in a child the cancel does not reach.

// "once every 4 hours"
enum RECORD_EVERY = 4 * 60 * 60;

// The weekly window is read more often as its reset comes: every hour in its
// last two days, every ten minutes in its last two hours.
enum CLOSE_RESET = 48 * 60 * 60;
enum CLOSE_EVERY = 60 * 60;
enum NEAR_RESET = 2 * 60 * 60;
enum NEAR_EVERY = 10 * 60;

// The five-hour window lives five hours. Read every four it was stale for most
// of its life: on screen 5% while the account was at 22%.
enum SHORT_EVERY = 15 * 60;

// How long a window's last reading stays current. Every window is read every
// ten minutes in its last two hours; otherwise each keeps its own rhythm. The
// Fable window is asked for at the short rhythm: "i had no idea i was getting
// to 70 so fast" — it moved 76 points in the first day of its week.
long intervalFor(const(char)[] window, long resetsAt, long now) {
    auto base = window == "seven_day" ? RECORD_EVERY : SHORT_EVERY;
    if (resetsAt <= now) return base;
    auto left = resetsAt - now;
    if (left <= NEAR_RESET) return NEAR_EVERY;
    if (base == RECORD_EVERY && left <= CLOSE_RESET) return CLOSE_EVERY;
    return base;
}

// One window as Claude Code sent it. The percentage stays the text it arrived
// as, so 23.5 is recorded as 23.5 and not as 23.
struct Window {
    const(char)[] name;
    const(char)[] percent;
    long resetsAt;
    bool present;
}

struct Windows { Window[3] w; }

// The first two arrive in the payload. The third never does: ug asks Claude's
// usage endpoint for it, outside the frame, and fills the row in afterwards.
immutable string[3] NAMES = ["five_hour", "seven_day", "fable_week"];
enum ASKED_WINDOW = 2;

// A row claimed for an ask holds this until the answer is in. No reading is
// below zero, so every reader skips it by the sign.
enum PENDING = "-1";
enum ASKED = -2;

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
// since the attempt has not said how it went; ask_exit ?7 is 0 for a window
// the payload handed over and -2 for one that is still to be asked for.
enum CLAIM_SQL = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session, qntx_status, qntx_exit, ask_exit) "
    ~ "SELECT ?1, ?2, ?3, ?4, ?5, 0, -2, ?7 "
    ~ "WHERE NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND session = ?5) "
    ~ "OR NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND seen_at > ?4 - ?6) "
    // The tmux bar draws the week inside bands two points wide, and a reading
    // every four hours steps over one whole. Each whole percent of a week is
    // written the first time it is seen.
    ~ "OR (?1 = 'seven_day' AND NOT EXISTS (SELECT 1 FROM usage WHERE window = ?1 AND resets_at = ?3 "
    ~ "AND CAST(used_percentage AS INTEGER) = CAST(?2 AS INTEGER)))";

// What the attempt answered: the HTTP status, and curl's exit code, -1 when no
// token was there to send.
enum UPDATE_SQL = "UPDATE usage SET qntx_status = ?1, qntx_exit = ?2 WHERE id = ?3";

// What the ask answered: the reading it found, or -1 and no reset still, and
// how the request went. ask_exit -1 is no token in the keychain to send with.
enum ASK_SQL = "UPDATE usage SET used_percentage = ?1, resets_at = ?2, ask_status = ?3, ask_exit = ?4 WHERE id = ?5";

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

    long[3] claimed = [0, 0, 0];
    size_t count = 0;
    foreach (i, ref w; ws.w) {
        // The asked window is claimed with no reading in hand; its interval is
        // counted from the last claim, answered or not, so a child that died
        // is asked again after it and not every second until then.
        auto asked = i == ASKED_WINDOW;
        if (!w.present && !asked) continue;
        auto percent = asked ? PENDING : w.percent;
        sqlite3_stmt* ins;
        if (sqlite3_prepare_v2(db, CLAIM_SQL.ptr, cast(int) CLAIM_SQL.length, &ins, null) != SQLITE_OK) {
            fputs("ug: usage: cannot prepare the claim\n", stderr);
            break;
        }
        sqlite3_bind_text(ins, 1, w.name.ptr, cast(int) w.name.length, cast(void*) -1);
        sqlite3_bind_text(ins, 2, percent.ptr, cast(int) percent.length, cast(void*) -1);
        sqlite3_bind_int64(ins, 3, w.resetsAt);
        sqlite3_bind_int64(ins, 4, now);
        sqlite3_bind_text(ins, 5, session.ptr, cast(int) session.length, cast(void*) -1);
        sqlite3_bind_int64(ins, 6, intervalFor(w.name, asked ? lastReset(db, w.name) : w.resetsAt, now));
        sqlite3_bind_int64(ins, 7, asked ? ASKED : 0);
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

// When the asked window last answered it resets, so its rhythm can quicken
// toward the reset like the others'. 0 when it has never answered.
enum LAST_RESET_SQL = "SELECT resets_at FROM usage WHERE window = ?1 AND used_percentage >= 0 "
    ~ "ORDER BY seen_at DESC, id DESC LIMIT 1";

private long lastReset(sqlite3* db, const(char)[] window) {
    import sql;

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, LAST_RESET_SQL.ptr, cast(int) LAST_RESET_SQL.length, &stmt, null) != SQLITE_OK)
        return 0;
    sqlite3_bind_text(stmt, 1, window.ptr, cast(int) window.length, cast(void*) -1);
    long at = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_finalize(stmt);
    return at;
}

// The requests outlive the frame. A child in its own session is not the
// process Claude Code cancels. It asks for the window the payload lacks and
// writes the answer onto that row, then attests each reading into QNTX and
// writes what QNTX answered. A child that dies first leaves -2 behind, which
// says so.
private void attestDetached(const(char)[] home, Windows ws, long[3] claimed,
                            const(char)[] session) {
    import core.stdc.stdio : fputs, stderr, freopen, stdin, stdout;
    import core.sys.posix.unistd : fork, setsid, _exit;
    import probe : post, Posted;
    import fable : askFable;
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

    if (claimed[ASKED_WINDOW] != 0) {
        auto asked = askFable();
        auto percent = asked.limit.present ? asked.limit.percent : PENDING;
        ws.w[ASKED_WINDOW].percent = percent;
        ws.w[ASKED_WINDOW].resetsAt = asked.limit.resetsAt;
        ws.w[ASKED_WINDOW].present = asked.limit.present;

        __gshared char[512] path = void;
        sqlite3* db;
        if (openStore(home, path, db)) {
            sqlite3_stmt* upd;
            if (sqlite3_prepare_v2(db, ASK_SQL.ptr, cast(int) ASK_SQL.length, &upd, null) == SQLITE_OK) {
                sqlite3_bind_text(upd, 1, percent.ptr, cast(int) percent.length, cast(void*) -1);
                sqlite3_bind_int64(upd, 2, asked.limit.resetsAt);
                sqlite3_bind_int64(upd, 3, asked.status);
                sqlite3_bind_int64(upd, 4, asked.curlExit);
                sqlite3_bind_int64(upd, 5, claimed[ASKED_WINDOW]);
                sqlite3_step(upd);
                sqlite3_finalize(upd);
            }
            sqlite3_close(db);
        }
    }

    foreach (i, id; claimed) {
        if (id == 0) continue;
        // An ask that found nothing has no reading to attest: -1, a request
        // never made, the same as having no token for it.
        Posted sent = Posted(0, -1);
        if (ws.w[i].present) {
            __gshared char[1024] body_ = void;
            auto n = attestationInto(ws.w[i], session, body_[]);
            sent = post(home, "/api/attestations", body_[0 .. n]);
        }

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
