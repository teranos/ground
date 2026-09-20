module outbox;

// What a hook has to say to sentry, left in the store as a finished log item.
// A hook opens no socket: it writes the row and exits, and the watcher of its
// session posts what is pending in one envelope per pass.

import db : sqlite3;
import sentry : Item;

// One row. The item is complete JSON, so the reader wraps and never parses.
// "i want to know on a time series if Fable, or Opus or Sonnet was active"
// "and effort as well"
// This is the one place every item passes with the store open, so the
// session's model and effort, as ug wrote them down, are stamped on here;
// a session ug never saw leaves its item as it came.
bool leave(sqlite3* db, const(char)[] session, const(char)[] level, const Item it, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT, modelOf;

    __gshared Item stamped;
    stamped = it;
    auto m = modelOf(db, session);
    stamped.stamp("model", m.model());
    stamped.stamp("effort", m.effort());

    auto text = stamped.text();
    if (text.length == 0) return false;
    enum sql = "INSERT INTO outbox (session, level, item, at) VALUES (?1, ?2, ?3, ?4)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, level.ptr, cast(int) level.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, now);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

// How many items one pass takes. The envelope holds a quarter megabyte, and an
// item is under four kilobytes.
enum TAKE = 60;

// A claim is a negative shipped_at: the pid of the watcher that took the rows.
// Items nobody's session wrote, an error raised with no session to name, go
// with whichever watcher claims first, and one update is one claimant.
long claimOutbox(sqlite3* db, const(char)[] session, long pid) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    enum sql = "UPDATE outbox SET shipped_at = -?2 WHERE id IN (SELECT id FROM outbox "
        ~ "WHERE shipped_at = 0 AND (session = ?1 OR session = '') ORDER BY id LIMIT ?3)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, pid);
    sqlite3_bind_int64(stmt, 3, TAKE);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db);
}

// The claimed items, oldest first, into the batch.
size_t claimedInto(B)(sqlite3* db, long pid, ref B batch) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
                sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

    enum sql = "SELECT item FROM outbox WHERE shipped_at = -?1 ORDER BY id\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);

    size_t rows = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto text = sqlite3_column_text(stmt, 0);
        if (text is null) continue;
        size_t n = 0;
        while (text[n] != 0) n++;
        if (!batch.fits(n)) break;
        batch.add(text[0 .. n]);
        rows++;
    }
    sqlite3_finalize(stmt);
    return rows;
}

// A claim held by a pid that is gone is nobody's, in this table, in timing
// and in the attestations stream, which claim the same way in their own
// column. The rows freed are counted.
long releaseDead(string table, string column = "shipped_at")(sqlite3* db, bool function(long) alive) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
                sqlite3_column_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

    long[64] dead;
    size_t n = 0;
    enum holders = "SELECT DISTINCT -" ~ column ~ " FROM " ~ table ~ " WHERE " ~ column ~ " < 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, holders.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    while (n < dead.length && sqlite3_step(stmt) == SQLITE_ROW) {
        auto pid = sqlite3_column_int64(stmt, 0);
        if (!alive(pid)) dead[n++] = pid;
    }
    sqlite3_finalize(stmt);

    long freed = 0;
    enum free_ = "UPDATE " ~ table ~ " SET " ~ column ~ " = 0 WHERE " ~ column ~ " = -?1\0";
    foreach (pid; dead[0 .. n]) {
        if (sqlite3_prepare_v2(db, free_.ptr, -1, &stmt, null) != SQLITE_OK) continue;
        sqlite3_bind_int64(stmt, 1, pid);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        freed += sqlite3_changes(db);
    }
    return freed;
}

long releaseDeadClaims(sqlite3* db, bool function(long) alive) {
    return releaseDead!"outbox"(db, alive);
}

// The claim resolved: shipped at `now`, or handed back for the next pass.
void claimResolved(sqlite3* db, long pid, bool landed, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK;

    enum sql = "UPDATE outbox SET shipped_at = ?2 WHERE shipped_at = -?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, landed ? now : 0);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import sentry : openItem, Batch;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(claimOutbox(db, "sess-o", 111) == 0, "nothing left is nothing pending");

    auto a = openItem(1000, "sess-o", "info", "control x fired"); a.close();
    auto b = openItem(1001, "sess-o", "warn", "over budget"); b.close();
    auto c = openItem(1002, "sess-p", "info", "somebody else's"); c.close();
    assert(leave(db, "sess-o", "info", a, 1000));
    assert(leave(db, "sess-o", "warn", b, 1001));
    assert(leave(db, "sess-p", "info", c, 1002));

    // One session's items, oldest first, and not another session's.
    Batch!8192 batch;
    assert(claimOutbox(db, "sess-o", 111) == 2);
    assert(claimedInto(db, 111, batch) == 2);
    assert(batch.count == 2);

    // Not shipped until the post landed: handed back, they are claimed again.
    claimResolved(db, 111, false, 1004);
    assert(claimOutbox(db, "sess-o", 111) == 2);
    claimResolved(db, 111, true, 1005);
    assert(claimOutbox(db, "sess-o", 111) == 0, "shipped is shipped");

    // The other session's item is still its watcher's to take.
    assert(claimOutbox(db, "sess-p", 222) == 1);

    // An item that did not fit its buffer is not left: half an item is not JSON.
    Item over;
    over.over = true;
    assert(!leave(db, "sess-o", "info", over, 1006));
    sqlite3_close(db);
}

unittest {
    // "i want to know on a time series if Fable, or Opus or Sonnet was active"
    // The session's model, as ug last wrote it down, is on every item the
    // session leaves. A session ug never saw leaves its items as they are.
    import db : sqlite3_open, sqlite3_close, applySchema, recordModel, SQLITE_OK,
                sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_text, sqlite3_stmt, SQLITE_ROW;
    import sentry : openItem;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(recordModel(db, "sess-m", "claude-opus-5", "high", 1000));
    assert(recordModel(db, "sess-m", "claude-fable-5-1", "high", 1100), "a change of model is a row");
    assert(!recordModel(db, "sess-m", "claude-fable-5-1", "high", 1200), "the same again is not");
    // "and effort as well"
    assert(recordModel(db, "sess-m", "claude-fable-5-1", "max", 1300), "a change of effort is a row");
    assert(recordModel(db, "sess-m", "claude-fable-5-1", "high", 1400));

    auto a = openItem(1300, "sess-m", "info", "control x fired"); a.close();
    auto b = openItem(1300, "sess-n", "info", "control y fired"); b.close();
    assert(leave(db, "sess-m", "info", a, 1300));
    assert(leave(db, "sess-n", "info", b, 1300));

    enum q = "SELECT item FROM outbox ORDER BY id\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, q.ptr, -1, &stmt, null) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    auto first = sqlite3_column_text(stmt, 0);
    assert(has(first, `"model":{"value":"claude-fable-5-1","type":"string"},"effort":{"value":"high","type":"string"}}}`),
           "the newest model and effort, not the first");
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    auto second = sqlite3_column_text(stmt, 0);
    assert(!has(second, `"model"`));
    assert(!has(second, `"effort"`));
    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

version (unittest)
private bool has(const(char)* text, const(char)[] needle) {
    size_t n = 0;
    while (text[n] != 0) n++;
    auto hay = (cast(const(char)*) text)[0 .. n];
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}

unittest {
    // Seen in sentry 2026-09-18 09:54:22Z: every sessionless item twice. Two
    // watchers each read it as pending before either had marked it, so the
    // taking is a claim by pid, as it is for timing, and a post that did not
    // land hands the claim back.
    import db : sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import sentry : openItem, Batch;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    auto a = openItem(1000, "", "warn", "watcher refused"); a.close();
    auto b = openItem(1001, "sess-o", "info", "control x fired"); b.close();
    assert(leave(db, "", "warn", a, 1000));
    assert(leave(db, "sess-o", "info", b, 1001));

    assert(claimOutbox(db, "sess-o", 111) == 2, "its own and the sessionless one");
    assert(claimOutbox(db, "sess-p", 222) == 0, "the sessionless one is taken");

    Batch!8192 batch;
    assert(claimedInto(db, 111, batch) == 2);
    Batch!8192 none;
    assert(claimedInto(db, 222, none) == 0);

    claimResolved(db, 111, false, 2000);
    assert(claimOutbox(db, "sess-p", 222) == 1, "handed back, the sessionless one goes to the next");
    claimResolved(db, 222, true, 2001);
    assert(claimOutbox(db, "sess-o", 111) == 1, "sess-o's own is still pending");

    // A claimant that died mid-post is gone, and its claim with it.
    static bool nobody(long) { return false; }
    assert(releaseDeadClaims(db, &nobody) == 1);
    assert(claimOutbox(db, "sess-o", 333) == 1, "claimable again");
    sqlite3_close(db);
}
