module hooktiming;

// Every hook run, shipped to sentry as the metric it is: the duration, and
// each phase of it, with the event, the project, the exit and the build.
// The rows are the timing table's, which every hook already writes.

import db : sqlite3;

// How many rows one pass takes. A row is up to nine metrics of a few hundred
// bytes, and the envelope holds a quarter megabyte.
enum TAKE = 100;

// A claim is a negative shipped_at: the pid of the watcher that took the rows.
// Two sessions' watchers share this queue, and a row claimed is not taken twice.
long claimTiming(sqlite3* db, long pid) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK;

    enum sql = "UPDATE timing SET shipped_at = -?1 WHERE id IN "
        ~ "(SELECT id FROM timing WHERE shipped_at = 0 ORDER BY id LIMIT ?2)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, TAKE);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db);
}

// A claim held by a pid that is gone is nobody's. A watcher killed between its
// claim and its post left the rows claimed forever; every watcher frees those
// on its way in, and the rows are counted.
long releaseDeadClaims(sqlite3* db, bool function(long) alive) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
                sqlite3_column_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

    long[64] dead;
    size_t n = 0;
    enum holders = "SELECT DISTINCT -shipped_at FROM timing WHERE shipped_at < 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, holders.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    while (n < dead.length && sqlite3_step(stmt) == SQLITE_ROW) {
        auto pid = sqlite3_column_int64(stmt, 0);
        if (!alive(pid)) dead[n++] = pid;
    }
    sqlite3_finalize(stmt);

    long freed = 0;
    enum free_ = "UPDATE timing SET shipped_at = 0 WHERE shipped_at = -?1\0";
    foreach (pid; dead[0 .. n]) {
        if (sqlite3_prepare_v2(db, free_.ptr, -1, &stmt, null) != SQLITE_OK) continue;
        sqlite3_bind_int64(stmt, 1, pid);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        freed += sqlite3_changes(db);
    }
    return freed;
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
    assert(claimTiming(db, 333) == 1, "and claimable");
    assert(claimTiming(db, 444) == 0, "222 keeps its claim, and 500 was shipped");
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
    assert(claimTiming(db, 111) == 2);
    assert(claimTiming(db, 222) == 0);

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
    assert(claimTiming(db, 333) == 2, "handed back, so claimable again");
    claimResolved(db, 333, true, 5001);
    assert(claimTiming(db, 444) == 0, "shipped is shipped");
    sqlite3_close(db);
}
