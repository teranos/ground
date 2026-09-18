module lifecycle;

// "needs to be instrumented"
// The watcher's and the driver's own record: when one started, for whom, that
// it is still polling, and how it ended.

import db : sqlite3;

// A poll is two seconds apart. Unseen for this long and not ended is a process
// that died without a word.
enum STALE_SEC = 10;

// One row per process. The row's id is the handle, since a pid is reused.
long processStarted(sqlite3* db, const(char)[] kind, long pid, long ppid,
                    const(char)[] who, const(char)[] tree, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_last_insert_rowid, sqlite3_stmt,
                SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;

    enum sql = "INSERT INTO process (kind, pid, ppid, who, tree, started_at, seen_at) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, kind.ptr, cast(int) kind.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, pid);
    sqlite3_bind_int64(stmt, 3, ppid);
    sqlite3_bind_text(stmt, 4, who.ptr, cast(int) who.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, tree.ptr, cast(int) tree.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 6, now);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE ? sqlite3_last_insert_rowid(db) : 0;
}

// Once a poll, so a row that stopped being seen can be told from one alive.
void processSeen(sqlite3* db, long id, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK;

    if (id == 0) return;
    enum sql = "UPDATE process SET seen_at = ?2, polls = polls + 1 WHERE id = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_bind_int64(stmt, 2, now);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// How it ended, in its own words, and how much it handed over on the way.
void processEnded(sqlite3* db, long id, const(char)[] ended, long delivered, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    if (id == 0) return;
    enum sql = "UPDATE process SET ended_at = ?2, ended = ?3, delivered = delivered + ?4, "
        ~ "seen_at = ?2 WHERE id = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_bind_int64(stmt, 2, now);
    sqlite3_bind_text(stmt, 3, ended.ptr, cast(int) ended.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, delivered);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Ended by somebody else, who knows the pid and nothing more.
void processKilled(sqlite3* db, long pid, const(char)[] why, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    enum sql = "UPDATE process SET ended_at = ?2, ended = ?3 WHERE pid = ?1 AND ended_at = 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, now);
    sqlite3_bind_text(stmt, 3, why.ptr, cast(int) why.length, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Whether the newest row for a pid says it ended. A pid is reused, so only the
// newest row speaks for it; no row at all is nothing the record can say.
bool pidEnded(sqlite3* db, long pid) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
                sqlite3_column_int64, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

    enum sql = "SELECT ended_at FROM process WHERE pid = ?1 ORDER BY id DESC LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_int64(stmt, 1, pid);
    bool ended = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) != 0;
    sqlite3_finalize(stmt);
    return ended;
}

// What the record says about one party at one moment.
struct Watching {
    bool alive;        // a process of that kind for `who` was polling then
    bool ever;         // any row for `who` at all
    long lastPid;
    long lastEndedAt;  // 0 when the newest row never ended
    char[160] endedBuf = 0;
    size_t endedLen;
    const(char)[] ended() const return { return endedBuf[0 .. endedLen]; }
}

// "why it fails"
// Alive means started by then, not ended before then, and seen within
// STALE_SEC of then. The newest row is what to say when it is not.
Watching watchingAt(sqlite3* db, const(char)[] kind, const(char)[] who, long at) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_column_int64, sqlite3_column_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    Watching w;
    enum alive = "SELECT 1 FROM process WHERE kind = ?1 AND who = ?2 AND started_at <= ?3 "
        ~ "AND (ended_at = 0 OR ended_at >= ?3) AND seen_at >= ?3 - ?4 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, alive.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kind.ptr, cast(int) kind.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, who.ptr, cast(int) who.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 3, at);
        sqlite3_bind_int64(stmt, 4, STALE_SEC);
        w.alive = sqlite3_step(stmt) == SQLITE_ROW;
        sqlite3_finalize(stmt);
    }

    enum last = "SELECT pid, ended_at, COALESCE(ended, '') FROM process "
        ~ "WHERE kind = ?1 AND who = ?2 ORDER BY id DESC LIMIT 1\0";
    if (sqlite3_prepare_v2(db, last.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kind.ptr, cast(int) kind.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, who.ptr, cast(int) who.length, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            w.ever = true;
            w.lastPid = sqlite3_column_int64(stmt, 0);
            w.lastEndedAt = sqlite3_column_int64(stmt, 1);
            auto t = sqlite3_column_text(stmt, 2);
            if (t !is null)
                while (t[w.endedLen] != 0 && w.endedLen < w.endedBuf.length) {
                    w.endedBuf[w.endedLen] = t[w.endedLen];
                    w.endedLen++;
                }
        }
        sqlite3_finalize(stmt);
    }
    return w;
}

unittest {
    // Measured 2026-09-18 07:39:38Z: a rite's failure sat unread for 65 seconds
    // in a session whose turn had ended four seconds before it, and the store
    // could say only that nothing was draining, not what became of the watcher.
    import db : sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    auto none = watchingAt(db, "watch", "sess-w", 1000);
    assert(!none.alive);
    assert(!none.ever, "nothing recorded is nothing, said as nothing");

    auto id = processStarted(db, "watch", 4242, 100, "sess-w", "QNTX", 1000);
    assert(id > 0);
    assert(watchingAt(db, "watch", "sess-w", 1000).alive);
    assert(!watchingAt(db, "watch", "sess-w", 999).alive, "not yet started");

    // Seen keeps it alive; silence does not.
    processSeen(db, id, 1004);
    assert(watchingAt(db, "watch", "sess-w", 1010).alive);
    assert(!watchingAt(db, "watch", "sess-w", 1020).alive, "unseen for ten seconds is dead without a word");

    // An ending says how, and after it the party is unwatched.
    processSeen(db, id, 1020);
    processEnded(db, id, "delivered 2 and exited 2", 2, 1021);
    assert(watchingAt(db, "watch", "sess-w", 1021).alive, "alive up to the moment it ended");
    auto after = watchingAt(db, "watch", "sess-w", 1022);
    assert(!after.alive);
    assert(after.ever);
    assert(after.lastPid == 4242);
    assert(after.lastEndedAt == 1021);
    assert(after.ended() == "delivered 2 and exited 2");

    // Killed by a Stop is an ending it did not choose, found by pid.
    processStarted(db, "watch", 4343, 100, "sess-w", "QNTX", 2000);
    processKilled(db, 4343, "killed by a stop of session sess-w", 2005);
    assert(!watchingAt(db, "watch", "sess-w", 2006).alive);
    assert(watchingAt(db, "watch", "sess-w", 2006).ended() == "killed by a stop of session sess-w");
    assert(pidEnded(db, 4343));
    assert(pidEnded(db, 4242), "4242 ended on its own");
    assert(!pidEnded(db, 9999), "never recorded is not ended");

    // The pid comes back for a new watcher, and the newest row is the one that speaks.
    processStarted(db, "watch", 4343, 100, "sess-w", "QNTX", 2100);
    assert(!pidEnded(db, 4343));

    // Another session's watcher is not this one's, and a driver is not a watcher.
    processStarted(db, "watch", 4444, 100, "sess-other", "QNTX", 3000);
    assert(!watchingAt(db, "watch", "sess-w", 3000).alive);
    processStarted(db, "drive", 4545, 1, "q-deploy-1", "", 3000);
    assert(watchingAt(db, "drive", "q-deploy-1", 3000).alive);
    assert(!watchingAt(db, "watch", "q-deploy-1", 3000).alive);

    sqlite3_close(db);
}
