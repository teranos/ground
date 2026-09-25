module hooktiming;

// Every hook run, shipped to sentry as the metric it is: the duration, and
// each phase of it, with the event, the project, the exit and the build.
// The rows are the timing table's, which every hook already writes.

import db : sqlite3;

// How many rows one pass takes. A row is up to nine metrics of a few hundred
// bytes, and the envelope holds a quarter megabyte.
enum TAKE = 100;

// What a claim came to: the rows taken, and sqlite's answer to the taking.
// A claim the store refused is not zero rows. 2026-09-25 between 20:10 and
// 20:18 the timing index went malformed; every claim answered 11 and was read
// as nothing to ship, and every hook lost its row the same way, for forty
// minutes with no word from either. "fix both"
struct TimingClaim {
    long rows;
    int rc;   // SQLITE_DONE when the claim ran
}

unittest {
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK, SQLITE_DONE;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    auto fine = claimTiming(db, 1);
    assert(fine.rc == SQLITE_DONE && fine.rows == 0, "an empty queue is a claim that ran");
    sqlite3_exec(db, "DROP TABLE timing\0".ptr, null, null, null);
    auto refused = claimTiming(db, 1);
    assert(refused.rc != SQLITE_DONE, "a store that refused the claim says so in its code");
    assert(refused.rows == 0);
    sqlite3_close(db);
}

unittest {
    // The hook's own row, the same way: sqlite's answer, not silence.
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK, SQLITE_DONE;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(insertTiming(db, 1234, "PreToolUse", "ground", "parse=1us") == SQLITE_DONE);
    sqlite3_exec(db, "DROP TABLE timing\0".ptr, null, null, null);
    assert(insertTiming(db, 1234, "PreToolUse", "ground", "parse=1us") != SQLITE_DONE,
           "a row the store refused is refused out loud");
    sqlite3_close(db);
}

// A claim is a negative shipped_at: the pid of the watcher that took the rows.
// Two sessions' watchers share this queue, and a row claimed is not taken twice.
TimingClaim claimTiming(sqlite3* db, long pid) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK, SQLITE_DONE;

    enum sql = "UPDATE timing SET shipped_at = -?1 WHERE id IN "
        ~ "(SELECT id FROM timing WHERE shipped_at = 0 ORDER BY id LIMIT ?2)\0";
    sqlite3_stmt* stmt;
    TimingClaim c;
    c.rc = sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null);
    if (c.rc != SQLITE_OK) return c;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, TAKE);
    c.rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (c.rc == SQLITE_DONE) c.rows = sqlite3_changes(db);
    return c;
}

// One hook's row. Sqlite's answer comes back whole: SQLITE_DONE when the row
// is in, its code when the store would not take it.
int insertTiming(sqlite3* db, long elapsedUs, const(char)[] hookEvent,
                 const(char)[] project, const(char)[] phases) {
    import db : sqlite3_prepare_v2, sqlite3_bind_int64, sqlite3_bind_text, sqlite3_step,
                sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    enum sql = "INSERT INTO timing (duration_us, hook_event, project, phases) VALUES (?1, ?2, ?3, ?4)\0";
    sqlite3_stmt* stmt;
    auto rc = sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null);
    if (rc != SQLITE_OK) return rc;
    sqlite3_bind_int64(stmt, 1, elapsedUs);
    if (hookEvent.length > 0)
        sqlite3_bind_text(stmt, 2, hookEvent.ptr, cast(int) hookEvent.length, SQLITE_TRANSIENT);
    if (project.length > 0)
        sqlite3_bind_text(stmt, 3, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
    if (phases.length > 0)
        sqlite3_bind_text(stmt, 4, phases.ptr, cast(int) phases.length, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc;
}

// A claim held by a pid that is gone is nobody's. A watcher killed between its
// claim and its post left the rows claimed forever; every watcher frees those
// on its way in, and the rows are counted.
long releaseDeadClaims(sqlite3* db, bool function(long) alive) {
    import outbox : releaseDead;
    return releaseDead!"timing"(db, alive);
}

// The exit label a phases string ends with, or empty.
const(char)[] exitOf(const(char)[] phases) {
    enum key = "exit=";
    if (phases.length < key.length) return "";
    foreach_reverse (i; 0 .. phases.length - key.length + 1) {
        if (phases[i .. i + key.length] != key) continue;
        size_t e = i + key.length;
        while (e < phases.length && phases[e] != ' ') e++;
        return phases[i + key.length .. e];
    }
    return "";
}

// The claimed rows, as metrics, into the batch.
size_t claimedInto(B)(sqlite3* db, long pid, const(char)[] version_, ref B batch) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
                sqlite3_column_int64, sqlite3_column_text, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW;
    import phases : parsePhases, PhaseEntry;
    import sentry : metricItem;

    enum sql = "SELECT duration_us, COALESCE(hook_event, ''), COALESCE(project, ''), "
        ~ "COALESCE(phases, ''), CAST(strftime('%s', created_at) AS INTEGER) "
        ~ "FROM timing WHERE shipped_at = -?1 ORDER BY id\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);

    static const(char)[] col(sqlite3_stmt* s, int i) {
        import db : sqlite3_column_text;
        auto t = sqlite3_column_text(s, i);
        if (t is null) return "";
        size_t n = 0;
        while (t[n] != 0) n++;
        return t[0 .. n];
    }

    // The version file ends in a newline, and that is not part of the version.
    auto ver = version_;
    while (ver.length > 0 && (ver[$ - 1] == '\n' || ver[$ - 1] == '\r')) ver = ver[0 .. $ - 1];

    size_t rows = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto took = sqlite3_column_int64(stmt, 0);
        auto event = col(stmt, 1);
        auto project = col(stmt, 2);
        auto ph = col(stmt, 3);
        auto at = sqlite3_column_int64(stmt, 4);
        auto exit_ = exitOf(ph);

        auto m = metricItem(at, project, "ground.hook.duration", took, "microsecond");
        m.str("event", event);
        m.str("project", project);
        m.str("exit", exit_);
        m.str("version", ver);
        m.close();
        batch.add(m.text());

        PhaseEntry[32] e;
        auto n = parsePhases(ph, e);
        foreach (i; 0 .. n) {
            if (e[i].isSub) continue;
            auto p = metricItem(at, project, "ground.hook.phase", e[i].val, "microsecond");
            p.str("event", event);
            p.str("project", project);
            p.str("phase", e[i].key);
            p.str("version", ver);
            p.close();
            batch.add(p.text());
        }
        rows++;
    }
    sqlite3_finalize(stmt);
    return rows;
}

// The claim resolved: shipped at `now`, or handed back for the next pass.
void claimResolved(sqlite3* db, long pid, bool landed, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK;

    enum sql = "UPDATE timing SET shipped_at = ?2 WHERE shipped_at = -?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, landed ? now : 0);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

unittest {
    // Recorded 2026-09-18 10:56: 600 rows claimed by watchers a Stop had killed
    // mid-post, and nothing gave them back. A claim whose pid is gone is free.
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    enum a = "INSERT INTO timing (duration_us, hook_event, shipped_at) VALUES (1, 'Stop', -111)\0";
    enum b = "INSERT INTO timing (duration_us, hook_event, shipped_at) VALUES (2, 'Stop', -222)\0";
    enum c = "INSERT INTO timing (duration_us, hook_event, shipped_at) VALUES (3, 'Stop', 500)\0";
    sqlite3_exec(db, a.ptr, null, null, null);
    sqlite3_exec(db, b.ptr, null, null, null);
    sqlite3_exec(db, c.ptr, null, null, null);

    static bool onlyTwoTwoTwo(long pid) { return pid == 222; }
    assert(releaseDeadClaims(db, &onlyTwoTwoTwo) == 1, "111 is gone, its row is free again");
    assert(claimTiming(db, 333).rows == 1, "and claimable");
    assert(claimTiming(db, 444).rows == 0, "222 keeps its claim, and 500 was shipped");
    sqlite3_close(db);
}

unittest {
    assert(exitOf("stdin=11us attest=2201us total=678us exit=bash-none") == "bash-none");
    assert(exitOf("parse=1us exit=deny") == "deny");
    assert(exitOf("parse=1us") == "");
    assert(exitOf("") == "");
}

unittest {
    // "ok, but i want to know this based on recorded metrics in sentry"
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK;
    import sentry : Batch;
    import matcher : contains;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    enum a = "INSERT INTO timing (duration_us, hook_event, project, phases, created_at) VALUES "
        ~ "(5769, 'PreToolUse', 'teranos/QNTX', 'stdin=13us attest=2513us handler=3243us total=3078us exit=bash-none', '2026-09-18 07:55:50')\0";
    enum b = "INSERT INTO timing (duration_us, hook_event, project, phases, created_at) VALUES "
        ~ "(2912, 'PreToolUse', 'teranos/ground', 'stdin=11us attest=2201us total=678us exit=deny', '2026-09-18 07:55:51')\0";
    sqlite3_exec(db, a.ptr, null, null, null);
    sqlite3_exec(db, b.ptr, null, null, null);

    // One watcher claims; a second finds nothing left to claim.
    assert(claimTiming(db, 111).rows == 2);
    assert(claimTiming(db, 222).rows == 0);

    Batch!65536 batch;
    assert(claimedInto(db, 111, "v0.19.1\n", batch) == 2);
    // A duration each, and the phases that are not total or exit.
    assert(batch.count == 2 + 3 + 2);
    auto text = batch.buf[0 .. batch.len];
    assert(contains(text, `"name":"ground.hook.duration","value":5769,"unit":"microsecond"`));
    assert(contains(text, `"phase":{"value":"attest","type":"string"}`));
    assert(contains(text, `"exit":{"value":"deny","type":"string"}`));
    assert(contains(text, `"version":{"value":"v0.19.1","type":"string"}`), "no newline in the version");
    assert(contains(text, `"timestamp":1789718150,`), "created_at as unix seconds");

    // A post that did not land hands the rows back; one that did keeps them.
    claimResolved(db, 111, false, 5000);
    assert(claimTiming(db, 333).rows == 2, "handed back, so claimable again");
    claimResolved(db, 333, true, 5001);
    assert(claimTiming(db, 444).rows == 0, "shipped is shipped");
    sqlite3_close(db);
}
